require 'json'

require 'pupgrade/cli/base'
require 'pupgrade/cli/catalog'
require 'pupgrade/cli/table'
require 'pupgrade/config_keys'
require 'driftless/control_repo'
require 'pupgrade/cli/compile_options'
require 'pupgrade/compile/factset'
require 'pupgrade/compile/probe_record'
require 'pupgrade/compile/session'
require 'pupgrade/compile/mocks'

module Pupgrade
  module CLI
    class Catalog
      # `pupgrade catalog compile`
      #
      # One catalog per factset, compiled against the deployed environment
      # directory, written with a record of what the compile used:
      # OUT/<certname>/catalog.json and compile.json, plus error.txt when
      # the compile failed. Exit 1 when any did.
      class Compile < Base
        include Table
        include CompileOptions
        extend ::Pupgrade::ConfigKeys::DSL

        register_command name: 'compile', subcommand_of: Catalog
        desc <<~'DESC'
        Compile factsets into catalogs + analyze the build (cached)

        Each factset generates two files (both cached under <certname>/):
          * catalog.json - the full catalog for the factset
          * compile.json - the compile's record (what code ran, leaks, etc)

        The compiler can mock an ENC, server-side executions, and pre-run Puppet code
        DESC

        config_key 'compile.factsets', type: :array, default: [], example: ['spec/factsets'],
                   about: 'Factset files or directories (onceover layout or a plain facts hash), relative to the control repo'
        config_key 'compile.cache_dir', type: :string, default: 'pupgrade/cache/catalogs',
                   about: 'Cache location for <certname>/{catalog,compile}.json files'

        COLUMNS = %w[certname resources classes warnings mocks leaks missing status].freeze

        config_key 'compile.enc', type: :string, default: nil, example: DEFAULT_ENC_FILE,
                   about: 'Rules deciding each node\'s top-scope variables and classes'
        config_key 'compile.ruby', type: :string, default: nil, example: DEFAULT_RUBY_FILE,
                   about: 'Ruby blocks deciding variables, classes, and mock answers per node, loaded after the rules, ' \
                          "relative to the control repo; #{DEFAULT_RUBY_FILE} when it exists"

        def execute(argv)
          reject_extra_args!(argv)
          if @options[:show_default_mocks]
            print File.read(::Pupgrade::Compile::Mocks::DEFAULTS_FILE)
            exit 0
          end
          repo     = control_repo!('compile')
          factsets = load_factsets(repo, 'compile')
          ::Pupgrade.logger.notice("compile: #{factsets.size} factset(s) against #{repo.dir}")
          session  = build_session(repo, 'compile')
          out      = File.expand_path(@options[:cache_dir], repo.dir)
          rows     = []
          failures = []
          progress = @options[:progress].nil? ? $stdout.tty? : @options[:progress]
          begin
            factsets.each do |factset|
              result = session.compile(factset)
              write(out, result)
              rows << row(result)
              $stdout.print(result.ok? ? paint('P', :green) : paint('F', :red)) if progress
              if result.ok?
                ::Pupgrade.logger.info("compile: #{result.certname} in #{'%.1f' % result.seconds}s")
              else
                failures << result
                ::Pupgrade.logger.warning("compile: #{result.certname} failed in #{'%.1f' % result.seconds}s: #{result.error}")
              end
              ::Pupgrade.logger.debug("compile: #{result.certname}: #{probe_counts(result.probes)}")
              break if @options[:fail_fast] && !result.ok?
            end
          ensure
            session.close
          end
          puts '' if progress
          print_table(COLUMNS, rows)
          failures.each { |r| puts "#{paint(r.certname, :red)}: #{r.error}" }
          failed = failures.size
          if @options[:fail_fast] && failed.positive? && rows.size < factsets.size
            ::Pupgrade.logger.notice("compile: stopped at the first failure; #{factsets.size - rows.size} factset(s) not compiled")
          end
          stale = (Array(@options[:certnames]).empty? && !@options[:keep_stale]) ? remove_stale(out, factsets) : []
          ::Pupgrade.logger.notice("compile: #{rows.size - failed} compiled, #{failed} failed; written to #{out}" \
                                 "#{"; removed #{stale.size} node(s) no factset names: #{stale.join(', ')}" unless stale.empty?}")
          exit(failed.zero? ? 0 : 1)
        end

        protected

        def configure_parser(o)
          declare_repo_and_factsets(o)
          o.on('-o', '--cache-dir=DIR', 'Cache location for <certname>/{catalog,compile}.json files (config: compile.cache_dir)') { |v| @options[:cache_dir] = v }
          o.on('--certname=GLOB[,…]', Array, 'Compile factsets with matching certnames; !GLOB leaves its matches out') { |v| accumulate(:certnames, v) }
          o.on('-f', '--[no-]fail-fast', 'Stop at the first compile that fails') { |v| @options[:fail_fast] = v }
          o.on('--[no-]progress', 'Print a green P or red F per compile as it goes (default: when stdout is a terminal)') { |v| @options[:progress] = v }
          o.on('--keep-stale', 'Keep <certname>/ directories of nodes the factsets no longer name') { @options[:keep_stale] = true }

          declare_what_to_compile(o)
          declare_guard(o)

        end

        private

        def write(out, result)
          dir = File.join(out, result.certname)
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, ::Pupgrade::Compile::ProbeRecord::FILENAME), JSON.pretty_generate(record(result)) + "\n")
          FileUtils.rm_f(File.join(dir, ::Pupgrade::Compile::ProbeRecord::OLD_FILENAME))
          if result.catalog
            File.write(File.join(dir, 'catalog.json'), JSON.pretty_generate(result.catalog) + "\n")
          else
            FileUtils.rm_f(File.join(dir, 'catalog.json'))
          end
          error = File.join(dir, 'error.txt')
          result.ok? ? FileUtils.rm_f(error) : File.write(error, result.error + "\n")
        end

        # A full run owns its output directory: a node directory from an
        # earlier run whose factset is gone is removed, so the evidence never
        # outlives the factsets.
        #
        # @return [Array<String>] the certnames removed
        def remove_stale(out, factsets)
          return [] unless File.directory?(out)

          current = factsets.map(&:certname)
          Dir.children(out).select { |n| File.directory?(File.join(out, n)) && File.file?(File.join(out, n, ::Pupgrade::Compile::ProbeRecord::FILENAME)) && !current.include?(n) }.sort.each do |name|
            FileUtils.rm_rf(File.join(out, name))
          end
        end

        def probe_counts(probes)
          %w[classes defined_types functions facts lookups warnings mocks leaks missing].filter_map { |k| "#{probes[k].size} #{k.tr('_', ' ')}" if probes[k].respond_to?(:size) }.join(', ')
        end

        # The compile record: the outcome, then the probes' findings.
        def record(result)
          {
            'document'       => ::Pupgrade::Compile::ProbeRecord::DOCUMENT,
            'schema_version' => ::Pupgrade::Compile::ProbeRecord::SCHEMA_VERSION,
            'certname'       => result.certname,
            'factset'        => result.factset.path,
            'environment'    => @options[:environment],
            'status'         => result.ok? ? 'ok' : 'failed',
            'error'          => result.error,
            'seconds'        => result.seconds.round(3),
          }.compact.merge(result.probes)
        end

        # mocks counts mocked commands; leaks unmocked ones, red when one
        # stopped the compile, yellow when it ran; missing the fact reads
        # with no value in the factset or the mocks, which run nothing.
        def row(result)
          p = result.probes
          raised  = p['leaks'].count { |l| l['action'] == 'raised' }
          leaked  = p['leaks'].size
          leaks   = if raised.positive? then paint(leaked.to_s, :red)
                    elsif leaked.positive? then paint(leaked.to_s, :yellow)
                    else leaked.to_s
                    end
          [result.certname,
           result.catalog ? result.catalog['resources'].size.to_s : '-',
           result.catalog ? result.catalog['classes'].size.to_s : '-',
           (p['warnings'].size + p['deprecations'].size).to_s,
           p['mocks'].size.to_s, leaks, p['missing'].any? ? paint(p['missing'].size.to_s, :yellow) : '0',
           result.ok? ? paint('ok', :green) : paint('failed', :red)]
        end

        def config_defaults
          compile_config_defaults
        end
      end
    end
  end
end
