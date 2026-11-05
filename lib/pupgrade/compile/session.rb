require 'fileutils'
require 'tmpdir'
require 'puppet'

require 'driftless/git_clone'
require 'pupgrade/config_keys'
require 'pupgrade/compile/catalog_document'
require 'pupgrade/compile/factset'
require 'pupgrade/compile/module_index'
require 'pupgrade/logging'
require 'pupgrade/compile/probes'
require 'pupgrade/compile/enc'
require 'pupgrade/compile/mocks'
require 'pupgrade/compile/on_mock'

module Pupgrade
  module Compile
    # Compiles catalogs against one deployed environment directory: Puppet
    # settings pointed at scratch directories, the environment read from the
    # directory's environment.conf and hiera.yaml, the probes installed, and
    # one {Result} per factset.
    class Session
      extend ConfigKeys::DSL

      config_key 'compile.environment', type: :string, default: 'production',
          about: "The environment name the catalogs are compiled in.\n" \
                 'Can interpolate w/enc.yaml syntax, ex: ${facts.agent_specified_environment}'
      config_key 'compile.manifest', type: :string, default: nil, example: 'manifests/site.pp',
                 about: 'A manifest file/directory to compile instead of environment.conf\'s'
      config_key 'compile.hiera', type: :string, default: nil, example: 'pupgrade/hiera.yaml',
                 about: 'Overrides repo\'s hiera.yaml; its datadir will be relative to its own location'
      config_key 'compile.pson', type: :boolean, default: false,
                 about: 'Loads optional gem `puppet-pson`, to enable compiling some (pre-Puppet 8) code'
      config_key 'compile.prepend_file', type: :string, default: nil, example: 'pupgrade/pre-manifest.pp',
                 about: "Puppet manifest, evaluated before compling control repo manifests,\n" \
                 "Analagous to rspec-puppet's :pre_condition + onceover's spec/pre_condition/"
      config_key 'compile.mocks', type: :string, default: nil, example: 'pupgrade/compiler-mocks.yaml',
                 about: 'File of command and Facter responses to mock while compiling'
      config_key 'compile.default_mocks', type: :boolean, default: true,
                 about: 'Whether pupgrade applies its built-in mocks for common issues'
      config_key 'compile.on_leak', type: :string, default: 'fail',
                 about: "Handle unmocked executions: 'fail' compile, or 'allow' to run/record"
      config_key 'compile.on_mock', type: :array, default: nil, example: ['silent', 'certname=web01*:info'],
                 about: "Rules to decide mocked execs' log levels using --on-mock\'s LEVEL|FILTER:LEVEL for the nodes " \
                        'the filter matches; the flag\'s rules come after these'
      config_key 'compile.vars', type: :hash, default: nil, example: { 'role' => 'web' },
                 about: 'Top-scope variables set on every node before the manifest'
      config_key 'compile.server_facts', type: :hash, default: nil, example: { 'servername' => 'puppet.example.com' },
                 about: 'Entries of $server_facts to set or override; servername, serverip, and serverversion have defaults'
      config_key 'compile.settings', type: :hash, default: nil, example: { 'strict' => 'error', 'strict_variables' => true },
                 about: 'Puppet settings for the compile, applied after pupgrade\'s own'
      config_key 'compile.ignorable_puppet_compile_messages', type: :array, default: [],
                 example: ['is deprecated', '\\AUnknown variable'],
                 about: 'Regexes matching Puppet compile messages to redirect as debug; ' \
                        'completely removed from terminal output when compiling with `-QQ`'
      config_key 'compile.suppress_ignorable_puppet_compile_messages', type: :boolean, default: false,
                 about: 'Suppress the ignorable message from terminal output (logs files always include them)'

      class Error < StandardError; end

      ON_LEAK = %w[fail allow].freeze
      # The old name of fail, still taken.
      ON_LEAK_ALIASES = { 'raise' => 'fail' }.freeze

      DEFAULT_SERVER_FACTS = { 'servername' => 'pupgrade.local', 'serverip' => '127.0.0.1' }.freeze

      # One node's compile.
      #
      # @!attribute [r] certname
      #   @return [String]
      # @!attribute [r] factset
      #   @return [Factset]
      # @!attribute [r] catalog
      #   @return [Hash, nil] the catalog document; nil when the compile failed
      # @!attribute [r] probes
      #   @return [Hash] the probe record, partial when the compile failed
      # @!attribute [r] error
      #   @return [String, nil] why the compile failed
      # @!attribute [r] seconds
      #   @return [Float]
      # @!attribute [r] environment
      #   @return [String, nil] the environment compiled in; nil when the
      #     name could not be decided
      Result = Data.define(:certname, :factset, :catalog, :probes, :error, :seconds, :environment) do
        def ok?
          error.nil?
        end
      end

      # @param repo_dir [String] the deployed environment directory
      # @param environment [String] the environment name, or an
      #   interpolation in the ENC's syntax (`${facts.a.b}`, `${vars.x}`)
      #   resolved per node; a node whose value is empty is compiled in
      #   `production` with a warning
      # @param manifest [String, nil] a manifest file or directory in place of
      #   environment.conf's
      # @param code [String, nil] Puppet code compiled in place of the manifest
      # @param prepend [String, nil] Puppet code evaluated before the
      #   manifest, or before `code`
      # @param prepend_from [String, nil] the file `prepend` was read from,
      #   named as the site of what it adds; `--prepend` when none
      # @param enc [Enc] what decides each node's top-scope variables and
      #   classes; `vars:` is the static shorthand for an ENC setting them
      #   on every node
      # @param vars [Hash{String => Object}] top-scope variables for every node
      # @param server_facts [Hash{String => Object}]
      # @param mocks [Mocks]
      # @param on_leak [String] one of {ON_LEAK}
      # @param on_mock [OnMock, Array<String>, String] at what level each
      #   node's mocked answers are logged; see {OnMock}
      # @param settings [Hash{String => Object}] Puppet settings by name,
      #   applied after pupgrade's own
      # @param hiera [String, nil] the environment layer's hiera.yaml, in
      #   place of the repo's
      # @param pson [Boolean] whether to load the puppet-pson gem, which
      #   defines the `PSON` Puppet 8 dropped
      # @param ignorable [Array<String, Regexp>] Puppet warnings to keep off
      #   the terminal, by regex on the message; recorded all the same
      # @param ignorable_log [String, nil] the level an ignorable message is
      #   logged at instead; nil for not at all
      def initialize(repo_dir:, environment: 'production', manifest: nil, code: nil, prepend: nil, prepend_from: nil, vars: {}, enc: nil, hiera: nil, pson: false,
                     server_facts: {}, mocks: Mocks.empty, on_leak: 'fail', on_mock: 'debug', settings: {}, ignorable: [], ignorable_log: 'debug')
        on_leak = ON_LEAK_ALIASES.fetch(on_leak, on_leak)
        raise Error, "on_leak must be one of #{ON_LEAK.join(', ')}, got #{on_leak.inspect}" unless ON_LEAK.include?(on_leak)
        begin
          on_mock = on_mock.is_a?(OnMock) ? on_mock : OnMock.parse(on_mock)
        rescue OnMock::Error => e
          raise Error, e.message
        end
        unless environment.include?('${') || environment.match?(ENVIRONMENT_NAME)
          raise Error, "environment name #{environment.inspect} must be lowercase letters, digits, and underscores"
        end

        @repo_dir     = File.expand_path(repo_dir)
        @environment  = environment
        @manifest     = manifest && File.expand_path(manifest, @repo_dir)
        @hiera        = hiera && File.expand_path(hiera, @repo_dir)
        @pson         = pson
        @code         = code
        @prepend      = prepend
        @prepend_from = prepend_from ? File.expand_path(prepend_from, @repo_dir) : '--prepend'
        @enc          = enc || Enc.new(vars: vars)
        @server_facts = DEFAULT_SERVER_FACTS.merge(server_facts.to_h { |k, v| [k.to_s, v] })
        @mocks        = mocks
        @on_leak      = on_leak
        @on_mock      = on_mock
        @settings     = (settings || {}).to_h { |k, v| [k.to_s, v] }
        @ignorable    = Array(ignorable).map { |r| r.is_a?(Regexp) ? r : Regexp.new(r.to_s) }
        @ignorable_log = ignorable_log
      rescue RegexpError => e
        raise Error, "ignorable message: #{e.message}"
      end

      # What Puppet takes for an environment name.
      ENVIRONMENT_NAME = /\A[a-z0-9_]+\z/.freeze

      # @return [Array<String>] the environment's modulepath, absolute
      attr_reader :modulepath

      # @return [String] the environment directory
      attr_reader :repo_dir

      # @return [String, Integer] the catalog version: the repo's HEAD sha
      #   when it is a git clone, else 0
      attr_reader :version

      # Points Puppet at scratch directories and loads the environment.
      #
      # @raise [Error] when the directory is not an environment
      def start
        raise Error, "#{@repo_dir}: no environment.conf" unless File.file?(File.join(@repo_dir, 'environment.conf'))
        raise Error, "#{@hiera}: no such hiera.yaml" if @hiera && !File.file?(@hiera)

        @scratch = Dir.mktmpdir('pupgrade-compile')
        self.class.boot!
        load_pson! if @pson
        settings!
        conf = Puppet::Settings::EnvironmentConf.load_from(@repo_dir, [])
        @modulepath = conf.modulepath.to_s.split(File::PATH_SEPARATOR).reject(&:empty?)
        @manifest ||= conf.manifest
        @envs    = {}
        @loader  = Environments.new(self)
        @index   = ModuleIndex.new(@modulepath)
        @version = catalog_version
        Probes.install!
        Probes.attach_log
        EnvHiera.install!
        EnvHiera.path = @hiera
        Pupgrade.logger.info "compile:  | environment:  '#{@environment}' at #{@repo_dir}/"
        Pupgrade.logger.info 'compile:  | PSON:         loaded' if @pson
        Pupgrade.logger.info "compile:  | mocks:        #{@mocks.commands.size} commands and #{@mocks.facts.size} facts; on leak: #{@on_leak}"
        Pupgrade.logger.info "compile:  | hiera:        #{@hiera || File.join(@repo_dir, 'hiera.yaml')}"
        Pupgrade.logger.info "compile:  | manifest:     #{@manifest}"
        Pupgrade.logger.info "compile:  | modulepath:   #{@modulepath.map{ |x| "\n#{' '*16}| - #{x}"}.join}"
        Pupgrade.logger.debug "compile: | prepend_from: '#{@prepend_from}'" if File.exist?(File.expand_path(@prepend_from.to_s, @repo_dir))
        self
      end

      # @param factset [Factset]
      # @return [Result]
      def compile(factset)
        started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        resolved = @enc.resolve(factset)
        recorder = Recorder.new(factset: factset, mocks: @mocks, on_leak: @on_leak, repo_dir: @repo_dir, on_mock: @on_mock.level_for(factset), node: resolved,
                                ignorable: @ignorable, ignorable_log: @ignorable_log)
        catalog  = nil
        error    = nil
        env      = nil
        Probes.current = recorder
        begin
          env = environment_for(resolved)
          Puppet.override(environments: @loader, current_environment: env, pupgrade_sources: sources) do
            Puppet[:code] = ''
            catalog = Puppet::Parser::Compiler.compile(node_for(factset, resolved, recorder.facts, env))
          end
        rescue Leak, Puppet::Error, StandardError => e
          error = e.message
        ensure
          Probes.current = nil
        end
        probes = recorder.to_h
        probes['type_aliases'].each { |name, entry| entry['module'] = @index.type_alias(name) }
        probes.merge!(catalog_summary(catalog, recorder, env)) if catalog
        Result.new(certname: factset.certname, factset: factset, error: error, environment: env&.name&.to_s,
                   catalog: catalog && CatalogDocument.build(catalog, version: @version, repo_dir: @repo_dir), probes: probes,
                   seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      end

      # The node's environment: the name configured, or the interpolation
      # resolved for the node; one Puppet environment per distinct name,
      # all on the one directory.
      #
      # @param resolved [Enc::Node]
      # @return [Puppet::Node::Environment]
      # @raise [Error] when the resolved name is not one Puppet takes
      def environment_for(resolved)
        name = @environment.include?('${') ? Enc.interpolate(@environment, resolved, 'compile.environment').to_s : @environment
        if name.empty?
          Pupgrade.logger.warning("compile: #{resolved.certname}: #{@environment} is empty for this node; compiling in production")
          name = 'production'
        end
        raise Error, "#{resolved.certname}: environment name #{name.inspect} (from #{@environment}) must be lowercase letters, digits, and underscores" unless name.match?(ENVIRONMENT_NAME)

        environment(name)
      end

      # @return [Puppet::Node::Environment] the one of that name, made on
      #   first use
      def environment(name)
        @envs[name.to_s] ||= Puppet::Node::Environment.create(name.to_sym, @modulepath, @manifest, nil)
      end

      # @return [Array<Puppet::Node::Environment>] those made so far
      def environments
        @envs.values
      end

      # The top scope of a compile of the node, for a lookup. The manifest
      # is evaluated only when asked; `puppet lookup` skips it too. The
      # mocks and guard are in force either way.
      #
      # @param factset [Factset]
      # @param compile [Boolean] whether to evaluate the manifests first
      # @yieldparam scope [Puppet::Parser::Scope]
      # @yieldparam node [Enc::Node] what the ENC stand-in decided
      def scope(factset, compile: false)
        resolved = @enc.resolve(factset)
        recorder = Recorder.new(factset: factset, mocks: @mocks, on_leak: @on_leak, repo_dir: @repo_dir, on_mock: @on_mock.level_for(factset), node: resolved)
        Probes.current = recorder
        env = environment_for(resolved)
        Puppet.override(environments: @loader, current_environment: env, pupgrade_sources: compile ? sources : nil) do
          Puppet[:code] = compile ? '' : 'undef'
          compiler = Puppet::Parser::Compiler.new(node_for(factset, resolved, recorder.facts, env))
          compiler.compile do |catalog|
            yield compiler.topscope, resolved
            catalog
          end
        end
      ensure
        Probes.current = nil
      end

      def close
        EnvHiera.path = nil
        (@restore || {}).each { |name, value| Puppet[name.to_sym] = value }
        FileUtils.rm_rf(@scratch) if @scratch
      end

      # Puppet's global settings are initialised once per process.
      def self.boot!
        return if Puppet.settings.global_defaults_initialized?

        Puppet.initialize_settings([])
      end

      private

      # `PSON`, from the puppet-pson gem. Once loaded it stays for the
      # process.
      #
      # @raise [Error] when the gem is not installed
      def load_pson!
        require 'puppet/external/pson'
      rescue LoadError
        raise Error, 'PSON needs the puppet-pson gem (gem install puppet-pson, or add it to the bundle)'
      end

      # Every path setting under the scratch directory, and a global
      # hiera.yaml with nothing in it, so the host's Puppet configuration
      # plays no part; then the settings asked for.
      #
      # @raise [Error] for a setting Puppet does not know or a value it
      #   refuses
      def settings!
        File.write(File.join(@scratch, 'hiera.yaml'), "---\nversion: 5\nhierarchy: []\n")
        %i[confdir vardir codedir logdir rundir statedir].each { |s| Puppet[s] = @scratch }
        Puppet[:hiera_config] = File.join(@scratch, 'hiera.yaml')
        Puppet[:environmentpath] = @scratch
        Puppet[:log_level] = 'warning'
        Puppet[:disable_warnings] = []
        # Puppet's settings are global to the process, so what a session sets
        # it puts back when it closes
        @restore = {}
        @settings.each do |name, value|
          @restore[name] = Puppet[name.to_sym]
          Puppet[name.to_sym] = value
          Pupgrade.logger.debug("compile: setting #{name} = #{value.inspect}")
        rescue ArgumentError, Puppet::Error => e
          raise Error, "setting #{name}: #{e.message}"
        end
      end

      def catalog_version
        clone = ::Driftless::GitClone.new(@repo_dir)
        (clone.own? && clone.sha) || 0
      end

      # @return [Probes::Sources, nil] the code pupgrade adds, for
      #   {Probes::ImportHooks}: the prepended code, then the code
      #   replacing the manifest; nil when the manifest is read as it is
      def sources
        pieces = []
        pieces << [@prepend_from, @prepend] if @prepend
        pieces << ['--code', @code] if @code
        return nil if pieces.empty?

        Probes::Sources.new(pieces: pieces, then_manifest: @code.nil?)
      end

      # @param resolved [Enc::Node] the variables and classes the ENC
      #   stand-in decided for the node
      # @param facts [Hash] the node's facts, mocks merged ({Recorder#facts})
      # @param env [Puppet::Node::Environment]
      def node_for(factset, resolved, facts, env)
        node = Puppet::Node.new(factset.certname, environment: env)
        node.fact_merge(Puppet::Node::Facts.new(factset.certname, deep_dup(facts)))
        node.trusted_data = trusted_for(factset)
        node.add_server_facts(@server_facts.merge('serverversion' => Puppet.version))
        node.merge(resolved.vars) unless resolved.vars.empty?
        node.classes = resolved.classes unless resolved.classes.empty?
        node
      end

      def trusted_for(factset)
        return deep_dup(factset.trusted) if factset.trusted.is_a?(Hash)

        Puppet::Context::TrustedInformation.new('remote', factset.certname, {}, deep_dup(factset.trusted_external)).to_h
      end

      # Classes, defined types, resource types, and the providers resources
      # name, each with the module providing it, and a class with the
      # sites that added it. Providers are not loaded by a compile (the
      # agent chooses them), so the catalog's `provider` parameters are
      # what can be known here.
      def catalog_summary(catalog, recorder, env)
        types     = Hash.new { |h, k| h[k] = { 'module' => nil, 'resources' => 0 } }
        defines   = Hash.new { |h, k| h[k] = { 'module' => nil, 'resources' => 0 } }
        providers = Hash.new { |h, k| h[k] = { 'module' => nil, 'resources' => 0 } }
        krt = env.known_resource_types
        catalog.resources.each do |r|
          next if %w[Class Stage Node].include?(r.type.to_s)

          name = r.type.to_s.downcase
          if (definition = krt.find_definition(name))
            defines[name]['module'] ||= @index.module_of(definition.file)
            defines[name]['resources'] += 1
          else
            types[name]['module'] ||= @index.type(name)
            types[name]['resources'] += 1
            provider = r[:provider]
            next if provider.nil? || provider.to_s.empty?

            key = "#{name}/#{provider}"
            providers[key]['module'] ||= @index.provider(name, provider)
            providers[key]['resources'] += 1
          end
        end
        classes = catalog.classes.sort.to_h do |name|
          hostclass = krt.find_hostclass(name.to_s.downcase)
          [name, { 'module' => hostclass && @index.module_of(hostclass.file), 'sites' => recorder.class_sites(name.to_s.downcase) }]
        end
        { 'classes' => classes, 'defined_types' => defines.sort.to_h, 'types' => types.sort.to_h,
          'providers_named' => providers.sort.to_h }
      end

      def deep_dup(obj)
        case obj
        when Hash  then obj.to_h { |k, v| [k, deep_dup(v)] }
        when Array then obj.map { |v| deep_dup(v) }
        else obj
        end
      end

      # Puppet's view of the environments: every name a node resolves to,
      # each on the session's one directory, made as asked for.
      class Environments < Puppet::Environments::Static
        def initialize(session)
          super()
          @session = session
        end

        def list
          @session.environments
        end

        def get(name)
          @session.environment(name.to_s)
        end

        def get_conf(_name)
          Puppet::Settings::EnvironmentConf.load_from(@session.repo_dir, [])
        end
      end

      # The environment layer read from another hiera.yaml. Puppet finds it
      # as `<env>/hiera.yaml` in two places: the lookup adapter checks the
      # file is there, and the environment's data provider reads it. While
      # {path} is set both use it instead. Installed once per process.
      module EnvHiera
        class << self
          # @return [String, nil] the hiera.yaml a session reads, absolute
          attr_accessor :path

          def install!
            return if @installed

            @installed = true
            Puppet::Pops::Lookup::LookupAdapter.prepend(AdapterHook)
            Puppet::Pops::Lookup::EnvironmentDataProvider.prepend(ProviderHook)
          end
        end

        # The adapter's environment provider, made whether or not the
        # environment has a hiera.yaml of its own.
        module AdapterHook
          private

          def initialize_env_provider(lookup_invocation)
            return super unless EnvHiera.path

            provider = Puppet::Pops::Lookup::EnvironmentDataProvider.new
            provider.config(lookup_invocation) && provider
          end
        end

        # The environment provider's hiera.yaml: {EnvHiera.path} when set.
        module ProviderHook
          protected

          def configuration_path(lookup_invocation)
            EnvHiera.path ? Pathname(EnvHiera.path) : super
          end
        end
      end
    end
  end
end
