require 'driftless/ansi'
require 'driftless/cli/base'
require 'driftless/cli/import'
require 'driftless/cli/root'
require 'driftless/control_repo'
require 'driftless/inputs/report_loader'
require 'driftless/report'
require 'driftless/report_data'
require 'driftless/utilization'

module Driftless
  module CLI
    # `driftless report`: print fleet utilization tables from the incoming
    # report tree, shaped by --group-by / --sort-by / --show / --show-count.
    class Report < Base
      register_command name: 'report', subcommand_of: Root
      desc 'Summarize fleet utilization from PuppetDB reports'
      positional '[<category> ...]'

      GROUP_BYS = %w[collector environment].freeze
      SORT_KEYS = %w[name number].freeze
      SINGULAR  = { 'modules' => 'module', 'roles' => 'role',
                    'profiles' => 'profile', 'classes' => 'class' }.freeze

      def execute(argv)
        categories = resolve_categories(argv)
        shape = {
          group_bys:  (@options[:group_by] || []).map { |t| resolve(t, GROUP_BYS, '--group-by') },
          matchers:   compile_matchers(@options[:show] || []),
          count_test: parse_count_expr(@options[:show_count]),
        }
        shape[:sort_key], shape[:reversed] = resolve_sort(@options[:sort_by])

        @options[:incoming_dir] ||= ::Driftless::ControlRepo.detect(Dir.pwd)&.default_incoming_dir
        @options[:incoming_dir]   = File.expand_path(@options[:incoming_dir]) if @options[:incoming_dir]
        unless @options[:incoming_dir]
          fatal!('report requires --incoming-dir (auto-detection did not supply it)', help: true)
        end
        unless File.directory?(@options[:incoming_dir])
          fatal!("incoming-dir not readable: #{@options[:incoming_dir]}", 3)
        end
        unless @options[:environments]&.any?
          fatal!('report error: puppet.environments is required — set it in driftless.yaml or pass --environments', help: true)
        end

        summary_dir =
          if @options[:summary_dir]
            File.expand_path(@options[:summary_dir])
          else
            ::Driftless::Inputs::ReportLoader.summary_dir_for(@options[:incoming_dir])
          end

        begin
          reporter = ::Driftless::Report.new(
            incoming_dir:                   @options[:incoming_dir],
            summary_dir:                    summary_dir,
            environments:                   @options[:environments],
            proceed_with_subset_of_configured_envs: @options[:proceed_with_subset_of_configured_envs] || false,
            accept_duplicate_certnames:     @options[:accept_duplicate_certnames] || false,
            accept_partial_report_sessions: @options[:accept_partial_report_sessions],
          )
          utilization = reporter.run
        rescue ::Driftless::ScanError => e
          fatal!("report error: #{e.message}")
        end

        categories.each { |category| table(category, utilization[category], shape) }
        write_data_file(reporter) if @options[:data_file]
        exit 0
      end

      protected

      def configure_parser(o)
        o.separator ''
        o.separator 'Input (auto-detected when omitted):'
        o.on('-i', '--incoming-dir=DIR',
             'Path to the incoming PuppetDB reports directory tree',
             "Default: 'incoming/' (if it exists)") { |v| @options[:incoming_dir] = v }
        o.on('-s', '--summary-dir=DIR',
             'Path to the summary/ tree written by `driftless import`',
             'Default: sibling summary/ of --incoming-dir') { |v| @options[:summary_dir] = v }

        o.separator ''
        o.separator 'Table shaping:'
        o.on('--group-by=WHO', Array,
             'Break counts down by collector and/or environment',
             '(comma-separated; prefixes accepted, e.g. env)') { |v| @options[:group_by] = v }
        o.on('--sort-by=KEY',
             'Order rows by name (default) or number of nodes;',
             ':reversed flips (e.g. number:reversed)') { |v| @options[:sort_by] = v }
        o.on('--show=REGEX',
             'Show only names matching REGEX (repeatable: any match shows)') do |v|
          (@options[:show] ||= []) << v
        end
        o.on('--show-count=EXPR',
             'Show only rows whose node count satisfies EXPR:',
             'a number (0) or comparisons (">1 <10", all must hold)') { |v| @options[:show_count] = v }

        o.separator ''
        o.separator 'Output:'
        o.on('--data-file[=PATH]',
             'Also write the report data document for `driftless site`',
             "(default PATH: #{::Driftless::ReportData::DEFAULT_PATH})") do |v|
          @options[:data_file] = v || ::Driftless::ReportData::DEFAULT_PATH
        end

        o.separator ''
        o.separator 'Environment scoping:'
        o.on('--environments=ENVS', Array,
             'Puppet environment(s) to count, comma-separated (required)') do |v|
          @options[:environments] = v
        end
        o.on('--accept-duplicate-certnames',
             'Warn instead of erroring when one certname is reported by two collectors') do
          @options[:accept_duplicate_certnames] = true
        end
        o.on('-b', '--proceed-with-subset-of-configured-envs',
             'Proceed with the reports for the environments present, even when they',
             'do not cover every environment in puppet.environments') do
          @options[:proceed_with_subset_of_configured_envs] = true
        end
        Import.declare_accept_partial(o, @options)
      end

      private

      # Writes the report data document `driftless site` builds from.
      #
      # @param reporter [::Driftless::Report] populated by {::Driftless::Report#run}
      def write_data_file(reporter)
        path = File.expand_path(@options[:data_file])
        ::Driftless::ReportData.write(::Driftless::ReportData.assemble(reporter), path)
        ::Driftless.logger.info("report data written: #{path}")
      end

      def config_defaults
        cfg = ::Driftless.config
        {
          environments:               cfg.dig('puppet', 'environments'),
          proceed_with_subset_of_configured_envs: cfg.dig('puppet', 'proceed_with_subset_of_configured_envs'),
          accept_duplicate_certnames: cfg.dig('reports', 'accept_duplicate_certnames'),
          incoming_dir:               cfg.dig('reports',  'incoming_dir'),
        }.compact
      end

      def resolve_categories(argv)
        return ::Driftless::Utilization::CATEGORIES if argv.empty?
        argv.map { |a| resolve(a, ::Driftless::Utilization::CATEGORIES, '<category>') }.uniq
      end

      # Resolves token against candidates by unique prefix.
      #
      # @raise [SystemExit] on no or ambiguous match, via fatal!
      def resolve(token, candidates, label)
        hits = candidates.select { |c| c.start_with?(token.to_s) }
        return hits.first if hits.length == 1
        fatal!("#{label}: #{token.inspect} does not match one of #{candidates.join(', ')}", help: true)
      end

      # @return [Array(String, Boolean)] the sort key and whether to reverse
      def resolve_sort(raw)
        return ['name', false] if raw.nil?
        key, direction = raw.split(':', 2)
        [resolve(key.to_s, SORT_KEYS, '--sort-by'),
         direction.nil? ? false : !resolve(direction, ['reversed'], '--sort-by').nil?]
      end

      def compile_matchers(patterns)
        patterns.map do |raw|
          pattern = (raw =~ %r{\A/.*/\z}m) ? raw[1..-2] : raw
          begin
            Regexp.new(pattern, Regexp::IGNORECASE)
          rescue RegexpError => e
            fatal!("--show: #{e.message}", help: true)
          end
        end
      end

      # Compiles EXPR into a test of a node count: whitespace-separated
      # terms, ANDed; each `[>|>=|<|<=|=]N`, a bare N meaning `=N`.
      #
      # @return [Proc, nil] nil when EXPR is nil or empty (no filter)
      # @raise [SystemExit] on an unparseable term, via fatal!
      def parse_count_expr(raw)
        return nil if raw.nil?
        terms = raw.split.map do |term|
          m = /\A(>=|<=|>|<|=)?(\d+)\z/.match(term)
          fatal!("--show-count: #{term.inspect} is not [>|>=|<|<=|=]N", help: true) unless m
          n = Integer(m[2], 10)
          { '=' => ->(v) { v == n }, '>' => ->(v) { v > n }, '<' => ->(v) { v < n },
            '>=' => ->(v) { v >= n }, '<=' => ->(v) { v <= n } }.fetch(m[1] || '=')
        end
        return nil if terms.empty?
        ->(v) { terms.all? { |t| t.call(v) } }
      end

      # Prints one category's table: name | nodes | one column per breakdown
      # value. Breakdown columns come from every entry in the category, not
      # only the shown rows, so the columns match the site page's.
      def table(category, entries, shape)
        columns = shape[:group_bys].map { |by| [by, breakdown_values(entries, by)] }
        rows    = shown(entries, shape)

        heading = ::Driftless::Ansi.enabled?($stdout) ? ::Driftless::Ansi.wrap(category, :bold) : category
        puts heading
        if rows.empty?
          puts '  (nothing matches)'
          puts
          return
        end

        header = [SINGULAR.fetch(category), 'nodes'] +
                 columns.flat_map { |_, values| values }
        body = rows.map do |e|
          [e['name'], e['nodes'].to_s] + columns.flat_map do |by, values|
            values.map { |v| (e["by_#{by}"] || {}).fetch(v, 0).to_s }
          end
        end
        widths = header.each_index.map { |i| ([header[i]] + body.map { |r| r[i] }).map(&:length).max }
        puts "  #{align(header, widths)}"
        puts "  #{widths.map { |w| '-' * w }.join('-+-')}"
        body.each { |r| puts "  #{align(r, widths)}" }
        puts
      end

      def shown(entries, shape)
        rows = entries
        if shape[:matchers].any?
          rows = rows.select { |e| shape[:matchers].any? { |m| m.match?(e['name']) } }
        end
        rows = rows.select { |e| shape[:count_test].call(e['nodes']) } if shape[:count_test]
        sorted =
          if shape[:sort_key] == 'number'
            rows.sort_by { |e| [e['nodes'], e['name']] }
          else
            rows.sort_by { |e| e['name'] }
          end
        shape[:reversed] ? sorted.reverse : sorted
      end

      def breakdown_values(entries, by)
        entries.flat_map { |e| (e["by_#{by}"] || {}).keys }.uniq.sort
      end

      # Name column left-aligned, count columns right-aligned.
      def align(cells, widths)
        cells.each_with_index.map { |c, i| i.zero? ? c.ljust(widths[i]) : c.rjust(widths[i]) }.join(' | ')
      end
    end
  end
end
