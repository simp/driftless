require 'json'

require 'driftless/finding'
require 'driftless/logger'
require 'driftless/reported'
require 'driftless/models/node'

module Driftless
  module Inputs
    class ReportLoader
      QUERIES = %w[all-active-nodes factsets-for-all-active-nodes].freeze
      NODE_REPORTS = %w[all-active-nodes factsets-for-all-active-nodes].freeze

      def self.load(incoming_dir)
        new(incoming_dir).load
      end

      def initialize(incoming_dir)
        @incoming_dir = incoming_dir
      end

      def load
        data     = {}
        findings = []
        QUERIES.each do |query|
          records, errs = load_query(query)
          data[query] = records
          findings.concat(errs)
        end
        [Reported.new(data: data), findings]
      end

      private

      def load_query(query)
        return [Reported::MissingReport, []] if query.start_with?('.')

        query_dir = File.join(@incoming_dir, query)
        return [Reported::MissingReport, []] unless File.directory?(query_dir)

        files = Dir[File.join(query_dir, '*.json'), File.join(query_dir, '*.ndjson')]
          .reject { |f| File.basename(f).start_with?('.') }
        return [Reported::MissingReport, []] if files.empty?

        per_collector = newest_per_collector(files)
        records, errs = merge_per_certname(per_collector, query)
        records = records.map { |r| build_node(r) } if NODE_REPORTS.include?(query)
        [records, errs]
      end

      def newest_per_collector(files)
        per = {}
        files.each do |path|
          base = File.basename(path, '.*')
          collector, timestamp = base.split('--', 2)
          next unless collector && timestamp
          if !per[collector] || timestamp > per[collector][:timestamp]
            per[collector] = { timestamp: timestamp, path: path }
          end
        end
        per
      end

      def merge_per_certname(per_collector, query)
        per_certname = {}
        errs = []
        per_collector.each do |collector, info|
          records =
            begin
              parse_records(info[:path])
            rescue JSON::ParserError => e
              errs << Finding.new(
                key: 'data:json-parse-error', path: info[:path], line: nil,
                message: "JSON parse error in #{query}/#{collector}: #{e.message}", meta: {},
              )
              next
            end
          Array(records).each do |record|
            certname = record['certname']
            next unless certname
            candidate = { record: record, collector: collector }
            per_certname[certname] = pick_winner(per_certname[certname], candidate)
          end
        end
        [per_certname.values.map { |v| v[:record] }, errs]
      end

      def pick_winner(existing, candidate)
        return candidate if existing.nil?
        et = existing[:record]['report_timestamp']  || ''
        ct = candidate[:record]['report_timestamp'] || ''
        winner =
          if ct > et then candidate
          elsif et > ct then existing
          else (candidate[:collector] < existing[:collector]) ? candidate : existing
          end

        ee = existing[:record]['catalog_environment']  || existing[:record]['environment']
        ce = candidate[:record]['catalog_environment'] || candidate[:record]['environment']
        if ee && ce && ee != ce
          certname    = winner[:record]['certname']
          winning_env = winner.equal?(candidate) ? ce : ee
          Driftless.logger.warn(
            "certname #{certname.inspect} appears in multiple environments " \
            "(#{ee.inspect} vs #{ce.inspect}); keeping #{winning_env.inspect}",
          )
        end

        winner
      end

      def parse_records(path)
        if path.end_with?('.ndjson')
          File.foreach(path).filter_map do |line|
            line = line.strip
            next if line.empty?
            JSON.parse(line)
          end
        else
          JSON.parse(File.read(path))
        end
      end

      def build_node(record)
        Node.new(
          certname:    record['certname'],
          environment: record['catalog_environment'] || record['environment'],
          facts:       record['facts']   || {},
          trusted:     record['trusted'] || {},
        )
      end
    end
  end
end
