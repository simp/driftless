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

      # Report name => its row shape. Only :classes has more than one row per
      # certname — one per (certname, class) — collected into a class list.
      REPORTS = {
        'all-active-nodes'              => :node,
        'factsets-for-all-active-nodes' => :node,
        'classes-for-all-active-nodes'  => :classes,
      }.freeze

      QUERIES = REPORTS.keys.freeze

      NODE_REPORTS = REPORTS.select { |_, shape| shape == :node }.keys.freeze

      # The sibling summary/ tree `driftless import` maintains beside incoming_dir.
      def self.summary_dir_for(incoming_dir)
        File.join(File.dirname(incoming_dir), 'summary')
      end

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
        read_from  = Hash.new { |h, k| h[k] = [] }
        QUERIES.each do |query|
          records, errs, dups, sessions = load_query(query)
          data[query] = records
          findings.concat(errs)
          dups.each { |certname, collectors| (duplicates[certname] ||= []).concat(collectors) }
          sessions.each { |collector, session_id| read_from[[collector, session_id]] << query }
        end
        duplicates.each_value { |collectors| collectors.replace(collectors.uniq.sort) }
        sessions = read_from.sort.map do |(collector, session_id), queries|
          Reported::Session.new(collector: collector, session_id: session_id, reports: queries.sort)
        end
        [Reported.new(data: data, duplicate_certnames: duplicates, sessions: sessions), findings]
      end

      private

      # @return [Array(records, Array<Finding>, Hash, Array<Array(String, String)>)]
      #   the rows, parse-error findings, duplicate certnames, and the
      #   (collector, session_id) pairs the rows were read from
      def load_query(query)
        query_dir = File.join(@incoming_dir, query)
        return [Reported::MissingReport, [], {}, []] unless File.directory?(query_dir)

        files = Dir[File.join(query_dir, '*.json'), File.join(query_dir, '*.ndjson')]
          .reject { |f| File.basename(f).start_with?('.') }
        return [Reported::MissingReport, [], {}, []] if files.empty?

        per_collector = newest_per_collector(files)
        sessions      = per_collector.map { |collector, info| [collector, info[:timestamp]] }
        if REPORTS[query] == :classes
          [*collect_per_certname(per_collector, query), sessions]
        else
          winners, errs, dups = merge_per_certname(per_collector, query)
          [winners.map { |w| build_node(w[:record], w[:collector]) }, errs, dups, sessions]
        end
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

      # Walks every record across a query's collectors, yielding
      # (record, certname, collector). Records with no certname are skipped, and
      # a certname claimed by more than one collector lands in the returned
      # duplicates hash.
      #
      # @return [Array(Array<Finding>, Hash)] parse-error findings, duplicates
      def each_record(per_collector, query)
        claimed_by = Hash.new { |h, k| h[k] = [] }
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
            yield record, certname, collector
          end
        end
        dups = claimed_by.each_with_object({}) do |(certname, collectors), acc|
          uniq = collectors.uniq
          acc[certname] = uniq.sort if uniq.length > 1
        end
        [errs, dups]
      end

      def merge_per_certname(per_collector, query)
        per_certname = {}
        errs, dups = each_record(per_collector, query) do |record, certname, collector|
          candidate = { record: record, collector: collector }
          per_certname[certname] = pick_winner(per_certname[certname], candidate)
        end
        [per_certname.values, errs, dups]
      end

      # One row per (certname, class) becomes one Node per certname, carrying
      # its class list.
      def collect_per_certname(per_collector, query)
        by_certname = {}
        errs, dups = each_record(per_collector, query) do |record, certname, collector|
          entry = (by_certname[certname] ||= { titles: [], environment: nil, collector: collector })
          entry[:titles] << record['title'] if record['title']
          entry[:environment] ||= record['environment']
        end
        nodes = by_certname.map do |certname, entry|
          Node.new(
            certname:    certname,
            classes:     entry[:titles].uniq.sort,
            environment: entry[:environment],
            collector:   entry[:collector],
          )
        end
        [nodes, errs, dups]
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
