require 'driftless/config_keys'
require 'json'

require 'driftless/detectors/input_registrations'
require 'driftless/logger'
require 'driftless/reported'
require 'driftless/models/node'

module Driftless
  module Inputs
    class ReportLoader
      extend ::Driftless::ConfigKeys::DSL

      config_key 'reports.incoming_dir', type: :string, default: 'incoming',
        about: "Raw-report landing directory tree for PDB reports from all enclaves. \nPopulated by `driftless import`, read by `driftless scan` and others "

      QUERIES = %w[all-active-nodes factsets-for-all-active-nodes].freeze
      NODE_REPORTS = %w[all-active-nodes factsets-for-all-active-nodes].freeze

      def self.load(incoming_dir)
        new(incoming_dir).load
      end

      def initialize(incoming_dir)
        @incoming_dir = incoming_dir
      end

      def load
        data       = {}
        findings   = []
        duplicates = {}
        QUERIES.each do |query|
          records, errs, dups = load_query(query)
          data[query] = records
          findings.concat(errs)
          dups.each { |certname, collectors| (duplicates[certname] ||= []).concat(collectors) }
        end
        duplicates.each_value { |collectors| collectors.replace(collectors.uniq.sort) }
        [Reported.new(data: data, duplicate_certnames: duplicates), findings]
      end

      private

      def load_query(query)
        return [Reported::MissingReport, [], {}] if query.start_with?('.')

        query_dir = File.join(@incoming_dir, query)
        return [Reported::MissingReport, [], {}] unless File.directory?(query_dir)

        files = Dir[File.join(query_dir, '*.json'), File.join(query_dir, '*.ndjson')]
          .reject { |f| File.basename(f).start_with?('.') }
        return [Reported::MissingReport, [], {}] if files.empty?

        per_collector       = newest_per_collector(files)
        winners, errs, dups = merge_per_certname(per_collector, query)
        records =
          if NODE_REPORTS.include?(query)
            winners.map { |w| build_node(w[:record], w[:collector]) }
          else
            winners.map { |w| w[:record] }
          end
        [records, errs, dups]
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
        claimed_by   = Hash.new { |h, k| h[k] = [] }
        errs = []
        per_collector.each do |collector, info|
          records =
            begin
              parse_records(info[:path])
            rescue JSON::ParserError => e
              errs << Detectors::DataJsonParseError.finding(
                path: info[:path],
                message: "JSON parse error in #{query}/#{collector}: #{e.message}",
              )
              next
            end
          Array(records).each do |record|
            certname = record['certname']
            next unless certname
            claimed_by[certname] << collector
            candidate = { record: record, collector: collector }
            per_certname[certname] = pick_winner(per_certname[certname], candidate)
          end
        end
        dups = claimed_by.each_with_object({}) do |(certname, collectors), acc|
          uniq = collectors.uniq
          acc[certname] = uniq.sort if uniq.length > 1
        end
        [per_certname.values, errs, dups]
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

      def build_node(record, collector = nil)
        Node.new(
          certname:    record['certname'],
          environment: record['catalog_environment'] || record['environment'],
          collector:   collector,
          facts:       record['facts']   || {},
          trusted:     record['trusted'] || {},
        )
      end
    end
  end
end
