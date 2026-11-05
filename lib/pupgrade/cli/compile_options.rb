require 'driftless/control_repo'
require 'pupgrade/certname_globs'
require 'pupgrade/compile/enc'
require 'pupgrade/compile/factset'
require 'pupgrade/compile/mocks'
require 'pupgrade/compile/on_mock'
require 'pupgrade/compile/session'

module Pupgrade
  module CLI
    # What `compile` and `lookup` share: the options naming the factsets,
    # the code to compile, the ENC stand-in, and the execution guard, and
    # the session they build from them.
    module CompileOptions
      # The files read when the config names none and they exist.
      DEFAULT_MOCKS_FILE = 'pupgrade/compiler-mocks.yaml'.freeze
      DEFAULT_ENC_FILE   = 'pupgrade/enc.yaml'.freeze
      DEFAULT_RUBY_FILE  = 'pupgrade/compiler.rb'.freeze

      def declare_repo_and_factsets(o)
        o.on('-d', '--repo-dir=DIR', 'Path of deployed control repostory (Default: `.`)') { |v| @options[:repo_dir] = v }
        o.on('--factsets=PATH[,…]', Array, 'Factset files or directories (config: compile.factsets)') { |v| accumulate(:factsets, v) }
      end

      def declare_what_to_compile(o, label=nil)
        o.separator ''
        o.separator "#{label||'Compiler options'}:"
        o.on('--environment=NAME', 'Environment name, or ${facts.PATH} resolved per node (config: compile.environment)') { |v| @options[:environment] = v }
        o.on('--manifest=PATH', 'Override Puppet manifest (config: compile.manifest)') { |v| @options[:manifest] = v }
        o.on('--hiera=FILE', 'Environment-layer hiera.yaml in place of the control repo\'s (config: compile.hiera)') { |v| @options[:hiera] = v }
        o.on('--code=CODE', 'Puppet code to compile in place of the manifest') { |v| @options[:code] = v }
        o.on('--prepend=CODE', 'Puppet code evaluated before the manifest or --code; @FILE reads it from a file (config: compile.prepend_file)') { |v| @options[:prepend] = v }
        o.on('--var=NAME=VALUE[,…]', 'Set top-scope variable (for every node) (config: compile.vars)') { |v| pair(:vars, v) }
        o.on('--enc=FILE', "Rules for per-node variables and classes (config: compile.enc; default: #{DEFAULT_ENC_FILE}") { |v| @options[:enc] = v }
        o.on('--ruby=FILE', "Rules for per-node ENC variables + classes, exec guard mocks (config: compile.ruby; default: #{DEFAULT_RUBY_FILE}") { |v| @options[:ruby] = v }
        o.on('--server-fact=NAME=VALUE[,…]', 'Set $server_facts (config: compile.server_facts)') { |v| pair(:server_facts, v) }
        o.on('--setting=NAME=VALUE', 'Set a Puppet setting, e.g. strict=error (config: compile.settings)') { |v| pair(:settings, v) }
        o.on('--[no-]pson', 'Load the puppet-pson gem, for code written before Puppet 8 that calls PSON (config: compile.pson)') { |v| @options[:pson] = v }
        o.on('-Q', '--suppress-ignorable', 'Keep the ignorable Puppet messages off the terminal, and the mocked answers unless --on-mock',
             'asks for them; -QQ drops the ignorable messages from debug too (config: compile.suppress_ignorable_puppet_compile_messages)') do
          @options[:suppress_ignorable] = true
          @options[:ignorable_log] = @options.key?(:ignorable_log) ? nil : 'debug'
        end
      end

      def declare_guard(o)
        o.separator ''
        o.separator 'Mocking options (compiler execution guard):'
        o.on('--mocks=FILE', "Rules for mocking command and fact executions (config: compile.mocks; default: #{DEFAULT_MOCKS_FILE}") { |v| @options[:mocks] = v }
        o.on('--show-default-mocks', 'Print the mocks pupgrade applies after the file, and exit') { @options[:show_default_mocks] = true }
        o.on('--on-mock=RULE', "Log mocked execs at a level (#{::Pupgrade::Compile::OnMock::LEVELS.join(', ')}; default: debug): RULE is LEVEL,",
             'or FILTER:LEVEL for the nodes FILTER matches (certname=GLOB[,…], facts.PATH=VALUE[,…], joined by ";");',
             'repeatable, the last matching rule deciding (config: compile.on_mock)') { |v| accumulate(:on_mock, [v]) }
        o.on('--[no-]default-mocks', 'Apply pupgrade\'s built-in mocks for known exec leaks (config: compile.default_mocks)') { |v| @options[:default_mocks] = v }
        o.on('--on-leak=POLICY', ::Pupgrade::Compile::Session::ON_LEAK + ::Pupgrade::Compile::Session::ON_LEAK_ALIASES.keys,
             %q[Response to unmocked commands: 'fail' (default) or 'allow' (config: compile.on_leak)]) { |v| @options[:on_leak] = v }
      end

      # @return [Driftless::ControlRepo]
      def control_repo!(command)
        repo = @options[:repo_dir] ? ::Driftless::ControlRepo.new(@options[:repo_dir]) : ::Driftless::ControlRepo.detect(Dir.pwd)
        fatal!("#{command} requires --repo-dir (auto-detection did not supply it)", help: true) unless repo
        fatal!("repo-dir not readable: #{repo.dir}", 3) unless repo.readable?
        repo
      end

      # The factsets named, narrowed by `--certname` globs ({CertnameGlobs}).
      #
      # @return [Array<Compile::Factset>]
      def load_factsets(repo, command)
        fatal!("#{command} needs at least one --factsets PATH (config: compile.factsets)", help: true) if Array(@options[:factsets]).empty?
        paths = Array(@options[:factsets]).map { |p| File.expand_path(p, repo.dir) }
        all   = ::Pupgrade::Compile::Factset.load_all(paths)
        all   = all.select { |f| ::Pupgrade::CertnameGlobs.match?(@options[:certnames], f.certname) }
        all   = one_per_certname(command, all)
        fatal!("#{command}: no factsets matched", 3) if all.empty?
        all
      rescue ::Pupgrade::Compile::Factset::Error => e
        fatal!("#{command}: #{e.message}", 3)
      end

      # One factset per certname: the first by path is kept and the others
      # named in a warning, since one record is written per certname.
      def one_per_certname(command, factsets)
        factsets.group_by(&:certname).flat_map do |certname, list|
          next list if list.size == 1

          others = list.drop(1).map(&:path).join(', ')
          ::Pupgrade.logger.warning(::Pupgrade::Ansi.stressed("#{command}: #{certname}: #{list.size} factsets carry this certname; compiling #{list.first.path}, not #{others}"))
          [list.first]
        end
      end

      # The ENC stand-in from the files named or found.
      #
      # @return [Compile::Enc]
      def build_enc(repo)
        ::Pupgrade::Compile::Enc.load(file_option(repo, :enc, DEFAULT_ENC_FILE), file_option(repo, :ruby, DEFAULT_RUBY_FILE),
                                      vars: @options[:vars] || {})
      end

      # A started session: mocks, ENC stand-in, and what to compile, from
      # the options.
      #
      # @return [Compile::Session]
      def build_session(repo, command)
        defaults = @options.fetch(:default_mocks, true)
        path  = file_option(repo, :mocks, DEFAULT_MOCKS_FILE)
        mocks = path ? ::Pupgrade::Compile::Mocks.load(path, defaults: defaults) : ::Pupgrade::Compile::Mocks.empty(defaults: defaults)
        ::Pupgrade.logger.info("#{command}: mocks from #{path || 'nowhere'}#{' plus the defaults' if defaults}")
        enc = build_enc(repo)
        mocks.blocks = enc.ruby.mocks
        mocks.function_blocks = enc.ruby.functions
        mocks.fact_blocks = enc.ruby.facts
        prepend = @options[:prepend]
        prepend = "@#{@options[:prepend_file]}" if prepend.nil? && @options[:prepend_file]
        prepend_from = nil
        if prepend&.start_with?('@')
          prepend_from = File.expand_path(prepend.delete_prefix('@'), repo.dir)
          prepend      = File.file?(prepend_from) ? File.read(prepend_from) : missing(command, 'prepend file', prepend_from)
        end
        ::Pupgrade::Compile::Session.new(
          repo_dir: repo.dir, environment: @options[:environment], manifest: @options[:manifest], hiera: @options[:hiera], pson: @options[:pson],
          code: @options[:code],
          prepend: prepend, prepend_from: prepend_from, enc: enc, server_facts: @options[:server_facts] || {}, settings: @options[:settings] || {},
          mocks: mocks, on_leak: @options[:on_leak], on_mock: @options[:on_mock] || [suppress_ignorable? ? 'silent' : 'debug'],
          ignorable: suppress_ignorable? ? @options[:ignorable] : [], ignorable_log: ignorable_log,
        ).start
      rescue ::Pupgrade::Compile::Session::Error, ::Pupgrade::Compile::Mocks::Error, ::Pupgrade::Compile::Enc::Error, Errno::ENOENT => e
        fatal!("#{command}: #{e.message}", 3)
      end

      # Whether the ignorable Puppet messages are kept off the terminal:
      # -Q, or the config key set to true or debug.
      def suppress_ignorable?
        value = @options[:suppress_ignorable]
        value == true || %w[true debug].include?(value.to_s)
      end

      # The level an ignorable message is logged at: debug under -Q or the
      # key's `debug`; nil, not at all, under -QQ or the key's `true`.
      def ignorable_log
        return @options[:ignorable_log] if @options.key?(:ignorable_log)

        (@options[:suppress_ignorable].to_s == 'debug') ? 'debug' : nil
      end

      # The file an option names, relative to the repo, else the default
      # when it is there. A named file that is not there is warned about
      # and done without: a config may name every file before the site has
      # written them.
      #
      # @return [String, nil] absolute
      def file_option(repo, key, default)
        return (File.file?(path = File.expand_path(@options[key], repo.dir)) ? path : missing(command_name, key, path)) if @options[key]

        path = File.join(repo.dir, default)
        File.file?(path) ? path : nil
      end

      def missing(command, what, path)
        ::Pupgrade.logger.warning("#{command}: #{what} #{path} is not there; going on without it")
        nil
      end

      def command_name
        self.class.canonical_name
      end

      def accumulate(key, values)
        (@options[key] ||= []).concat(values)
      end

      def pair(key, text)
        name, value = text.split('=', 2)
        fatal!("expected NAME=VALUE, got #{text.inspect}", help: true) if name.nil? || name.empty? || value.nil?
        (@options[key] = (@options[key] || {}).dup)[name] = value
      end

      # The `compile.*` keys as option defaults.
      def compile_config_defaults
        cfg = ::Pupgrade.config
        {
          factsets:      cfg.dig('compile', 'factsets'),
          cache_dir:     cfg.dig('compile', 'cache_dir') || 'pupgrade/cache/catalogs',
          environment:   cfg.dig('compile', 'environment') || 'production',
          manifest:      cfg.dig('compile', 'manifest'),
          hiera:         cfg.dig('compile', 'hiera'),
          pson:          cfg.dig('compile', 'pson'),
          prepend_file:  cfg.dig('compile', 'prepend_file'),
          mocks:         cfg.dig('compile', 'mocks'),
          enc:           cfg.dig('compile', 'enc'),
          ruby:          cfg.dig('compile', 'ruby'),
          default_mocks: cfg.dig('compile', 'default_mocks'),
          on_leak:       cfg.dig('compile', 'on_leak') || 'fail',
          on_mock:       cfg.dig('compile', 'on_mock'),
          vars:          cfg.dig('compile', 'vars'),
          server_facts:  cfg.dig('compile', 'server_facts'),
          settings:      cfg.dig('compile', 'settings'),
          ignorable:          cfg.dig('compile', 'ignorable_puppet_compile_messages'),
          suppress_ignorable: cfg.dig('compile', 'suppress_ignorable_puppet_compile_messages'),
        }.compact
      end
    end
  end
end
