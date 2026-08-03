require 'json'

require 'driftless/finding'
require 'driftless/reported'
require 'driftless/models/node'

module Driftless
  module Inputs
    class ReportLoader
      MVP_QUERIES = %w[all-active-nodes].freeze

      def self.load(incoming_dir)
        new(incoming_dir).load
      end

      def initialize(incoming_dir)
        @incoming_dir = incoming_dir
      end

      def load
        data     = {}
        findings = []
        MVP_QUERIES.each do |query|
          records, errs = load_query(query)
          data[query] = records
          findings.concat(errs)
        end
        [Reported.new(data: data), findings]
      end

      private

      def load_query(query)
        query_dir = File.join(@incoming_dir, query)
        return [Reported::MissingReport, []] unless File.directory?(query_dir)

        files = Dir[File.join(query_dir, '*.json')]
        return [Reported::MissingReport, []] if files.empty?

        per_contributor = newest_per_contributor(files)
        records, errs   = merge_per_certname(per_contributor, query)
        records = records.map { |r| build_node(r) } if query == 'all-active-nodes'
        [records, errs]
      end

      def newest_per_contributor(files)
        per = {}
        files.each do |path|
          base = File.basename(path, '.json')
          contributor, timestamp = base.split('--', 2)
          next unless contributor && timestamp
          if !per[contributor] || timestamp > per[contributor][:timestamp]
            per[contributor] = { timestamp: timestamp, path: path }
          end
        end
        per
      end

      def merge_per_certname(per_contributor, query)
        per_certname = {}
        errs = []
        per_contributor.each do |contributor, info|
          records =
            begin
              JSON.parse(File.read(info[:path]))
            rescue JSON::ParserError => e
              errs << Finding.new(
                key: 'data:json-parse-error', path: info[:path], line: nil,
                message: "JSON parse error in #{query}/#{contributor}: #{e.message}", meta: {},
              )
              next
            end
          Array(records).each do |record|
            certname = record['certname']
            next unless certname
            candidate = { record: record, contributor: contributor }
            per_certname[certname] = pick_winner(per_certname[certname], candidate)
          end
        end
        [per_certname.values.map { |v| v[:record] }, errs]
      end

      def pick_winner(existing, candidate)
        return candidate if existing.nil?
        et = existing[:record]['report_timestamp']  || ''
        ct = candidate[:record]['report_timestamp'] || ''
        return candidate if ct > et
        return existing  if et > ct
        # Tie on report_timestamp — alphabetically-first contributor wins (deterministic)
        candidate[:contributor] < existing[:contributor] ? candidate : existing
      end

      def build_node(record)
        Node.new(
          certname: record['certname'],
          facts:    record['facts']   || {},
          trusted:  record['trusted'] || {},
        )
      end
    end
  end
end
