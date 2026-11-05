require 'puppet'
require 'facter'

require 'pupgrade/compile/mocks'
require 'pupgrade/logging'

module Pupgrade
  module Compile
    # Raised inside a compile when module code tries to run a command the
    # mocks do not answer and the run's policy is to stop.
    class Leak < StandardError; end

    # What one node's compile used, from the hooks in {Probes}:
    # classes added and from where, functions called, facts read, lookups
    # made, providers loaded, warnings and deprecations logged, and
    # commands or facts that reached the execution guard. One per compile; {Probes.current} points at it while
    # the compile runs.
    class Recorder
      LOGGED_LEVELS = %i[warning err alert emerg crit].freeze

      # @param factset [Factset] the node's facts, answering Facter reads
      # @param mocks [Mocks] what the guard answers commands with
      # @param on_leak [String] "fail" or "allow" for unmocked commands
      # @param repo_dir [String] call sites are reported relative to it
      # @param ignorable [Array<Regexp>] Puppet warnings logged at
      #   `ignorable_log` instead of their level, recorded all the same
      # @param ignorable_log [String, nil] that level; nil for not at all
      # The levels a mocked answer can be logged at; `silent` logs nothing.
      ON_MOCK = %w[silent trace debug info notice warning].freeze

      def initialize(factset:, mocks:, on_leak:, repo_dir:, on_mock: 'debug', node: nil, ignorable: [], ignorable_log: 'debug')
        @factset  = factset
        @node     = node
        @mocks    = mocks
        @on_leak  = on_leak
        @on_mock  = on_mock.to_s
        @ignorable = ignorable
        @ignorable_log = ignorable_log
        @repo_dir = File.expand_path(repo_dir)
        @fact_mocks = {}
        @facts      = nil
        @prefixes = {}
        @modules  = {}
        @functions = Hash.new { |h, k| h[k] = { 'module' => nil, 'calls' => 0, 'sites' => [] } }
        @class_sites = Hash.new { |h, k| h[k] = [] }
        @declared_at = nil
        @facts_read = Hash.new(0)
        @legacy    = Hash.new(0)
        @lookups   = Hash.new { |h, k| h[k] = { 'found' => false, 'automatic' => 0, 'explicit' => 0 } }
        @providers = {}
        @aliases   = Hash.new { |h, k| h[k] = { 'module' => nil, 'uses' => 0, 'sites' => [] } }
        @warnings  = []
        @deprecations = []
        @mocked  = []
        @leaks   = []
        @missing = []
        # Puppet reports each deprecation and each unique warning once per
        # process; reset so every node's compile reports its own.
        $deprecation_warnings = {} # rubocop:disable Style/GlobalVars -- Puppet's own
        $unique_warnings = {} # rubocop:disable Style/GlobalVars -- Puppet's own
      end

      # ---- facts -----------------------------------------------------------

      # The node's facts as the compile sees them: the factset's, with the
      # Ruby `fact` blocks' answers and then the `facts:` mocks merged over
      # them, each `${...}` resolved for the node; a YAML mock at a path a
      # block answered is passed over. A mock the factset lacks fills it in, logged at the
      # `--on-mock` level; one the factset has overrides it, logged at
      # notice with both values, or at the `--on-mock` level when the two
      # are the same. Either is recorded under `mocks` when the compile
      # reads it.
      #
      # @return [Hash]
      def facts
        @facts ||= begin
          facts = deep_dup(@factset.values)
          merge_fact_blocks(facts)
          merge_mocks(facts, @mocks.facts, nil)
          facts
        end
      end

      # ---- facts: reads ----------------------------------------------------

      # Remembers every hash inside `hash` by identity, so a later access on
      # one of them can be named by its path.
      #
      # @param hash [Hash] `$facts` or `$trusted` as the scope holds them
      # @param prefix [String, nil] nil for `$facts`
      def index_hash(hash, prefix)
        return unless hash.is_a?(Hash)

        @prefixes[hash.object_id] = prefix.to_s
        hash.each { |k, v| index_hash(v, [prefix, k.to_s].compact.join('.')) if v.is_a?(Hash) }
      end

      # A `[]` access on a hash: recorded when the hash is inside `$facts`
      # or `$trusted`.
      def hash_access(hash, keys)
        prefix = @prefixes[hash.object_id]
        return if prefix.nil?

        keys.each { |k| fact_read([prefix, k.to_s].reject(&:empty?).join('.')) }
      end

      # The `dig` function walking keys from a value: recorded when the value
      # is inside `$facts` or `$trusted`, by the path dug.
      def dig(data, keys)
        prefix = @prefixes[data.object_id]
        return if prefix.nil?

        fact_read(([prefix] + keys.map(&:to_s)).reject(&:empty?).join('.'))
      end

      # `key in $facts`: a membership test on a hash inside `$facts` or
      # `$trusted`.
      def membership(hash, key)
        prefix = @prefixes[hash.object_id]
        return if prefix.nil? || !key.is_a?(String)

        fact_read([prefix, key].reject(&:empty?).join('.'))
      end

      # A dotted path walked from a value: Hiera interpolation and the
      # `get`-style functions walk them.
      def sub_lookup(value, segments)
        prefix = @prefixes[value.object_id]
        return if prefix.nil?

        fact_read(([prefix] + segments.map(&:to_s)).reject(&:empty?).join('.'))
      end

      # A variable read: recorded as a legacy fact when the bare name is a
      # top-level fact carrying that value.
      def variable(name, value)
        bare = name.to_s.delete_prefix('::')
        return if bare.include?('::') || !facts.key?(bare)
        return unless facts[bare] == value

        @legacy[bare] += 1
        mocked_read(bare)
      end

      # A `Facter.value` or `Facter.fact` read from Ruby code: answered from
      # the facts the compile sees, mocks merged.
      #
      # @return [Array(Boolean, Object)] whether anything answered, and the value
      def facter_value(query)
        name = query.to_s.downcase
        found, value = dig_fact(name)
        if found
          @facts_read["#{name} (Facter)"] += 1
          mocked_read(name)
          return [true, value]
        end

        intercepted('fact', name, 'missing', nil)
        Pupgrade.logger.info("guard: #{@factset.certname}: fact #{name}: neither the factset nor the mocks have it")
        [false, nil]
      end

      # ---- classes, functions, and lookups ----------------------------------

      # The site the ENC's classes are recorded at.
      ENC_SITE = 'enc'.freeze

      # Classes the compiler was asked to add, by `include`, `require`,
      # `contain`, a resource-style declaration, or the ENC, from where:
      # the site given, else the declaration in progress ({#declaring}),
      # else the Puppet code at the top of the stack. Code with no file
      # names no site.
      #
      # @param names [Array<String>] as given to the compiler
      # @param site [String, nil] where, when the caller knows
      def classes_added(names, site: nil)
        top = Puppet::Pops::PuppetStack.top_of_stack
        site ||= @declared_at || site(top[0], top[1])
        @declared_at = nil
        return unless site

        names.each do |name|
          sites = @class_sites[name.to_s.delete_prefix('::').downcase]
          sites << site if sites.size < 20 && !sites.include?(site)
        end
      end

      # Names the site of the class a resource-style declaration adds
      # while the block runs. The first classes added take it; the ones
      # the class itself adds, evaluated inside the block, have their own
      # Puppet stack frames.
      #
      # @param site [String, nil]
      def declaring(site)
        @declared_at = site
        yield
      ensure
        @declared_at = nil
      end

      # @param file [String, nil] a file, or `--prepend` or `--code` for
      #   code pupgrade gave the parser ({Session#sources}); Puppet's
      #   `unknown` is code with no file
      # @return [String, nil] "file:line", relative to the repo
      def site(file, line)
        return nil if file.nil? || file.to_s.empty? || file == 'unknown'

        "#{relative(file)}:#{line}"
      end

      # @param name [String] a class, lowercase
      # @return [Array<String>] where it was added, first 20
      def class_sites(name)
        @class_sites.fetch(name, [])
      end

      # @param func [Puppet::Pops::Functions::Function, nil] what the loader gave
      def function_call(name, func, file, line)
        entry = @functions[name.to_s]
        entry['module'] ||= module_of_loader(func&.loader)
        entry['calls'] += 1
        site = site(file, line)
        entry['sites'] << site if site && entry['sites'].size < 20 && !entry['sites'].include?(site)
      end

      # A mocked function call, recorded under `mocks` and logged at the
      # `--on-mock` level; nothing for a call that is not mocked.
      #
      # @param file [String, nil] the call site's file, when the caller
      #   knows it; else the site is where the Puppet stack is
      # @param line [Integer, nil]
      # @return [Array(Boolean, Object)] whether the call is mocked, and with what
      def mocked_function(name, args, file: nil, line: nil)
        found, value = @mocks.for_function(name, args, @node || @factset.values)
        return [false, nil] unless found

        where = site(file, line) || location
        intercepted('function', name.to_s, 'mocked', where)
        log_mock("guard: #{@factset.certname}: function #{name}: mocked#{" at #{where}" if where}")
        [true, value]
      end

      # A value checked against a type alias: a parameter typed with it, a
      # match, or a data type expression, once per check. Puppet's own
      # aliases have no namespace; a module's or environment's always do.
      def type_alias(name)
        @aliases[name.to_s]['uses'] += 1 if name.to_s.include?('::')
      end

      # Where an alias is referenced: the parser resolves a definition's
      # parameter types once per environment, so the sites are gathered
      # process-wide by {Probes.alias_sites} and joined here.
      def alias_sites!
        @aliases.each do |name, entry|
          sites = Probes.alias_sites.fetch(name, []).select { |file, _| file.to_s.start_with?("#{@repo_dir}/") }
          entry['sites'] = sites.map { |file, line| site(file, line) }.compact.uniq.first(20)
        end
      end

      def lookup(name, found, automatic)
        entry = @lookups[name.to_s]
        entry['found'] ||= found
        entry[automatic ? 'automatic' : 'explicit'] += 1
      end

      # ---- providers, logs ---------------------------------------------------

      def provider_loaded(type, provider, path)
        @providers["#{type}/#{provider}"] = { 'type' => type.to_s, 'provider' => provider.to_s, 'file' => relative(path) }
      end

      # Puppet's own log: a warning or worse is logged at warning and
      # recorded; the rest is trace. A deprecation is logged by Puppet as a
      # warning too, and is left to {#deprecation}, which saw it first. A
      # warning the site calls ignorable is logged at debug, so a thousand
      # nodes do not repeat it, and recorded like any other.
      def log(msg)
        where = " (#{msg.file && relative(msg.file.to_s)}:#{msg.line})" if msg.file
        unless LOGGED_LEVELS.include?(msg.level) && !deprecation_text?(msg.message)
          Pupgrade.logger.trace("puppet: #{@factset.certname}: #{msg.level}: #{msg.message}#{where}")
          return
        end

        level = (msg.level == :warning) ? '' : "#{msg.level}: "
        logged("puppet: #{@factset.certname}: #{level}#{one_line(msg.message)}#{where}", :warning, ignorable?(msg.message))
        @warnings << { 'level' => msg.level.to_s, 'message' => msg.message.to_s,
                       'file' => msg.file && relative(msg.file.to_s), 'line' => msg.line }.compact
      end

      # Puppet's own location suffix, when it has one, says less than the
      # message's file and line (often "file & line not available"), so a
      # logged line does without it, and without Puppet's line breaks.
      PUPPET_LOCATION = /\s*\((?:file & line not available|file: [^)]*|location: [^)]*)\)\s*\z/.freeze

      def one_line(text)
        text.to_s.sub(PUPPET_LOCATION, '').gsub(/\s*\n\s*/, ' ').strip
      end

      # Puppet logs a deprecation as its message, a newline, and the
      # location; the message itself may hold newlines, so the first lines
      # are compared.
      def deprecation_text?(text)
        first = text.to_s.split("\n").first
        $deprecation_warnings.values.any? { |m| m.to_s.split("\n").first == first } # rubocop:disable Style/GlobalVars -- Puppet's own
      end

      # A deprecation, logged at info on one line; one the site calls
      # ignorable at debug. Recorded whole either way.
      def deprecation(message, file, line)
        text = "puppet: #{@factset.certname}: deprecation: #{one_line(message)}#{" (#{relative(file.to_s)}:#{line})" if file}"
        logged(text, :info, ignorable?(message))
        @deprecations << { 'message' => message.to_s, 'file' => file && relative(file.to_s), 'line' => line }.compact
      end

      # Whether an ignorable regex matches the message, read as one line.
      def ignorable?(message)
        line = one_line(message)
        @ignorable.any? { |r| r.match?(line) }
      end

      # A line at its level; an ignorable one at the ignorable level marked
      # so, or not at all, so a thousand nodes do not repeat it.
      def logged(text, level, ignorable)
        return Pupgrade.logger.public_send(level, text) unless ignorable

        Pupgrade.logger.public_send(@ignorable_log, "#{text} (ignorable)") if @ignorable_log
      end

      # ---- the execution guard -------------------------------------------------

      # What to do with a command module code wants to run.
      #
      # @param kind [String] which entry point: "execute", "execpipe", "backtick", ...
      # @param command [String] the command line
      # @return [Array(Symbol, Mocks::Command|nil)] [:mock, the entry] or [:run, nil]
      # @raise [Leak] when the command is not mocked and the policy is to stop
      def guard(kind, command)
        entry = @mocks.for_command(command, @node || @factset.values)
        where = location
        if entry&.action == 'mock'
          action = entry.exit.zero? ? 'mocked' : "mocked (exit #{entry.exit})"
          intercepted(kind, command, action, where)
          log_mock("guard: #{@factset.certname}: #{kind}: #{command.inspect}: #{action}#{" at #{where}" if where}")
          return [:mock, entry]
        end
        if entry || @on_leak == 'allow'
          intercepted(kind, command, 'allowed', where)
          Pupgrade.logger.info("guard: #{@factset.certname}: #{kind}: #{command.inspect}: allowed to run#{" at #{where}" if where}")
          return [:run, nil]
        end

        intercepted(kind, command, 'raised', where)
        Pupgrade.logger.warning(Pupgrade::Ansi.stressed("guard: #{@factset.certname}: #{kind}: #{command.inspect} is not mocked#{" at #{where}" if where}"))
        raise Leak, "#{kind}: #{command.inspect} is not mocked (#{where})"
      end

      # A mocked answer at the level asked for, or not at all.
      def log_mock(message)
        Pupgrade.logger.public_send(@on_mock, message) unless @on_mock == 'silent'
      end

      # @return [Hash] the probe record, JSON-ready
      def to_h
        alias_sites!
        {
          'functions'    => @functions.sort.to_h,
          'facts'        => @facts_read.sort.to_h,
          'legacy_facts' => @legacy.sort.to_h,
          'lookups'      => @lookups.sort.to_h,
          'providers'    => @providers.sort.to_h.values,
          'type_aliases' => @aliases.sort.to_h,
          'warnings'     => @warnings,
          'deprecations' => @deprecations,
          'mocks'        => @mocked,
          'leaks'        => @leaks,
          'missing'      => @missing,
          'enc'          => { 'variables' => @node ? @node.vars : {}, 'classes' => @node ? @node.classes : [] },
        }
      end

      private

      # One interception, filed by its outcome: mocked, a command run or
      # stopped, or a fact read with no value in the factset or the mocks.
      def intercepted(kind, what, action, where)
        list = if action.start_with?('mocked') then @mocked
               elsif action == 'missing' then @missing
               else @leaks
               end
        list << { 'kind' => kind, 'command' => what, 'action' => action, 'location' => where }.compact
      end

      # "file:line" of the innermost Puppet call in progress and the first
      # Ruby frame outside the gems, when there are any.
      def location
        parts = []
        top = Puppet::Pops::PuppetStack.top_of_stack
        if top.is_a?(Array) && top[0] && top[0] != 'unknown'
          parts << "#{relative(top[0])}:#{top[1]}"
        end
        frame = caller_locations(2, 30).find { |l| !l.path.include?('/gems/') && !l.path.include?('pupgrade/compile') }
        parts << "#{relative(frame.path)}:#{frame.lineno}" if frame
        parts.empty? ? nil : parts.join(' via ')
      end

      def relative(path)
        path.to_s.delete_prefix("#{@repo_dir}/")
      end

      # A fact read by path, and a mocked read when a mock answers it.
      def fact_read(path)
        @facts_read[path] += 1
        mocked_read(path)
      end

      # A read of a path a `facts:` mock answers, at the path or under it,
      # recorded under `mocks` once per mocked path.
      def mocked_read(path)
        return if @fact_mocks.empty? || path.start_with?('trusted')

        @fact_mocks.each do |mocked, action|
          next unless mocked == path || mocked.start_with?("#{path}.")
          next if action.nil?

          intercepted('fact', mocked, action, location)
          @fact_mocks[mocked] = nil
        end
      end

      # The Ruby `fact` blocks asked with the factset's facts as read, each
      # answer merged at its path as a `facts:` mock is.
      def merge_fact_blocks(base)
        return if @mocks.fact_blocks.empty?

        node = @node || Enc::Node.new(certname: @factset.certname, facts: @factset.values,
                                      trusted: @factset.trusted.is_a?(Hash) ? @factset.trusted : {}, vars: {}, classes: [])
        @mocks.fact_blocks.each do |path, block|
          value = block.call(node)
          next if value.nil?

          merge_mocks(base, path.split('.').reverse.reduce(value) { |acc, k| { k => acc } }, nil, interpolate: false)
        end
      end

      # The `facts:` mocks merged over the factset's facts, leaf by leaf, the
      # paths applied kept in @fact_mocks with the action to record.
      def merge_mocks(base, mocks, prefix, interpolate: true)
        mocks.each do |key, value|
          path  = [prefix, key.to_s].compact.join('.')
          if @fact_mocks.key?(path)
            Pupgrade.logger.debug("guard: #{@factset.certname}: fact #{path}: answered by a fact block; the facts: mock is passed over")
            next
          end

          value = Enc.interpolate(value, @node, 'mock') if interpolate && @node && value.is_a?(String)
          if value.is_a?(Hash) && base[key.to_s].is_a?(Hash)
            merge_mocks(base[key.to_s], value, path, interpolate: interpolate)
            next
          end
          if base.key?(key.to_s) && base[key.to_s] == value
            @fact_mocks[path] = 'mocked (same as factset)'
            log_mock("guard: #{@factset.certname}: fact #{path}: mocked, identical to the factset's #{value.inspect}")
          elsif base.key?(key.to_s)
            @fact_mocks[path] = 'mocked (overrides factset)'
            Pupgrade.logger.notice("guard: #{@factset.certname}: fact #{path}: mocked, overriding the factset's #{base[key.to_s].inspect} " \
                                   "with #{Pupgrade::Ansi.stressed(value.inspect)}")
          else
            @fact_mocks[path] = 'mocked'
            log_mock("guard: #{@factset.certname}: fact #{path}: mocked")
          end
          base[key.to_s] = deep_dup(value)
        end
      end

      def deep_dup(obj)
        case obj
        when Hash  then obj.to_h { |k, v| [k, deep_dup(v)] }
        when Array then obj.map { |v| deep_dup(v) }
        else obj
        end
      end

      # @return [Array(Boolean, Object)] a fact by dotted name, mocks merged
      def dig_fact(name)
        values = facts
        return [true, values[name]] if values.key?(name)

        value = values
        name.split('.').each do |seg|
          return [false, nil] unless value.is_a?(Hash) && value.key?(seg)

          value = value[seg]
        end
        [true, value]
      end

      # The module a function's loader belongs to: a module loader is named
      # after its module ("stdlib" or "stdlib private"); loaders for the
      # environment and Puppet itself name no module; a local loader's name
      # is a Symbol, so the parent chain is walked to a named one.
      def module_of_loader(loader)
        loader = loader.parent while loader && loader.loader_name.is_a?(Symbol)
        return nil unless loader

        name = loader.loader_name.to_s.sub(/ private\z/, '')
        %w[puppet_system environment static].include?(name) ? nil : name
      end
    end

    # The hooks into Puppet and Facter that report to {Probes.current}, and
    # the execution guard. Installed once per process; every hook is a
    # pass-through while no compile is running.
    module Probes
      class << self
        # @return [Recorder, nil] the compile in progress
        attr_accessor :current

        # @return [Hash{String => Array<Array(String, Integer)>}] where each
        #   type alias is referenced, by name, for the whole process
        def alias_sites
          @alias_sites ||= Hash.new { |h, k| h[k] = [] }
        end

        def install!
          return if @installed

          @installed = true
          Puppet::Parser::Scope.prepend(ScopeHooks)
          Puppet::Parser::Compiler.prepend(ClassHooks)
          Puppet::Pops::Evaluator::Runtime3ResourceSupport.singleton_class.prepend(ResourceHooks)
          Puppet::Node::Environment.prepend(ImportHooks)
          Puppet::Pops::Evaluator::AccessOperator.prepend(AccessHooks)
          Puppet::Pops::Lookup::SubLookup.prepend(SubLookupHooks)
          Puppet::Pops::Evaluator::EvaluatorImpl.prepend(CallHooks)
          Puppet::Pops::Functions::Function.prepend(FunctionCallHooks)
          Puppet::Functions.singleton_class.prepend(FunctionFactoryHooks)
          Puppet::Pops::Lookup.singleton_class.prepend(LookupHooks)
          Puppet::Pops::Types::TypeParser.prepend(TypeParserHooks)
          Puppet::Pops::Types::PTypeAliasType.prepend(TypeAliasHooks)
          Puppet::Util::Logging.prepend(DeprecationHooks)
          Puppet::Type.singleton_class.prepend(ProviderHooks)
          Puppet::Node::Environment.prepend(ConfigVersionHooks)
          Puppet::Util::Execution.singleton_class.prepend(ExecutionGuard)
          Facter::Core::Execution.singleton_class.prepend(FacterExecutionGuard)
          Facter.singleton_class.prepend(FacterGuard)
          Puppet::Util::Log.newdesttype(:pupgrade_probes) do
            match 'Pupgrade::Compile::Probes::LogSink'

            def initialize(sink)
              @sink = sink
            end

            def handle(msg)
              @sink.call(msg)
            end
          end
        end

        # Makes sure Puppet's log reaches the recorder, through one sink:
        # Puppet keys destinations by the object given, and drops them all
        # whenever it closes its log.
        def attach_log
          @sink ||= LogSink.new
          Puppet::Util::Log.newdestination(@sink) unless Puppet::Util::Log.destinations.key?(@sink)
        end
      end

      # Receives every Puppet log message.
      class LogSink
        def call(msg)
          Probes.current&.log(msg)
        end
      end

      # Every way a class reaches the catalog ends here: the `include`,
      # `require`, and `contain` functions, a `class { 'x': }` declaration,
      # and the ENC's classes.
      module ClassHooks
        def evaluate_classes(classes, scope, lazy_evaluate = true)
          Probes.current&.classes_added(classes.is_a?(Hash) ? classes.keys : Array(classes))
          super
        end

        # The ENC's classes, which no Puppet code adds.
        def evaluate_node_classes
          classes = @node.classes
          Probes.current&.classes_added(classes.is_a?(Hash) ? classes.keys : Array(classes), site: Recorder::ENC_SITE)
          super
        end
      end

      # A resource-style declaration, `class { 'x': }`, comes with its file
      # and line but pushes no Puppet stack frame.
      module ResourceHooks
        def create_resources(file, line, scope, virtual, exported, type_name, resource_titles, evaluated_parameters)
          probes = Probes.current
          return super unless probes

          probes.declaring(probes.site(file, line)) { super }
        end
      end

      # The code pupgrade adds to a compile, and whether the environment's
      # manifest follows it.
      #
      # @!attribute [r] pieces
      #   @return [Array<Array(String, String)>] a source's name and its
      #     Puppet code: `--prepend` or the prepended file's path, `--code`
      # @!attribute [r] then_manifest
      #   @return [Boolean] false when `--code` stands in for the manifest
      Sources = Data.define(:pieces, :then_manifest)

      # Parses each piece as its own source, named for where it came from,
      # and the manifest from its files, in place of one string under
      # `Puppet[:code]`: sites, warnings, and errors then name the file and
      # line they are in.
      module ImportHooks
        def perform_initial_import
          sources = Puppet.lookup(:pupgrade_sources) { nil }
          return super unless sources && Puppet[:code].to_s.empty?

          results = sources.pieces.map do |name, code|
            parser = Puppet::Parser::ParserFactory.parser
            parser.file   = name
            parser.string = code
            parser.parse
          end
          results << super if sources.then_manifest
          Puppet::Parser::AST::Hostclass.new('', code: Puppet::Parser::ParserFactory.code_merger.concatenate(results))
        rescue Puppet::Error
          @known_resource_types.parse_failed = true
          raise
        end
      end

      module ScopeHooks
        def set_facts(hash)
          super
          Probes.current&.index_hash(hash, nil)
        end

        def set_trusted(hash)
          super
          Probes.current&.index_hash(hash, 'trusted')
        end

        # Every scope on the way up answers a lookup; the top scope is
        # where a fact lives, so only its answer is recorded.
        def lookupvar(name, options = {})
          value = super
          Probes.current&.variable(name, value) if is_topscope?
          value
        end
      end

      module AccessHooks
        def access_Hash(o, scope, keys) # rubocop:disable Naming/MethodName -- Puppet's name
          Probes.current&.hash_access(o, keys)
          super
        end
      end

      module SubLookupHooks
        def sub_lookup(key, context, segments, value)
          Probes.current&.sub_lookup(value, segments)
          super
        end
      end

      # A Ruby function calling another (`call_function`). This call is
      # mocked the same way as one from Puppet code.
      module FunctionCallHooks
        def call_function(function_name, *args, &block)
          if (rec = Probes.current)
            found, value = rec.mocked_function(function_name, args)
            return value if found
          end
          super
        end
      end

      module CallHooks
        # `key in $hash` hands the hash to the evaluator whole.
        def eval_InExpression(o, scope) # rubocop:disable Naming/MethodName -- Puppet's name
          if (rec = Probes.current)
            right = evaluate(o.right_expr, scope)
            rec.membership(right, evaluate(o.left_expr, scope)) if right.is_a?(Hash)
          end
          super
        end

        def call_function(name, args, o, scope, &block)
          if (rec = Probes.current)
            file, line = extract_file_line(o)
            loader = Puppet::Pops::Adapters::LoaderAdapter.loader_for_model_object(o, file)
            func   = loader.load(:function, name) if loader
            rec.function_call(name, func, file, line)
            found, value = rec.mocked_function(name, args, file: file, line: line)
            return value if found
          end
          super
        end
      end

      # Puppet builds a function's class once per loader; the `dig` function
      # gets the hook below as it is created, whichever loader builds it.
      module FunctionFactoryHooks
        def create_function(func_name, function_base = Puppet::Functions::Function, &block)
          klass = super
          klass.prepend(DigHooks) if func_name.to_s == 'dig'
          klass
        end
      end

      # `dig($facts, 'os', 'family')`, which `$facts.dig(...)` also calls,
      # receives the hash itself.
      module DigHooks
        def dig(data, *args)
          Probes.current&.dig(data, args)
          super
        end
      end

      module LookupHooks
        def search_and_merge(name, lookup_invocation, merge, apl = true)
          found = false
          value = super
          found = true
          value
        ensure
          Probes.current&.lookup(name, found, apl)
        end
      end

      # Every type reference the evaluator resolves passes through here; one
      # that resolves to an alias names a site referencing it. Puppet resolves
      # a definition's parameter types once per environment, so this fires
      # for the first compile only and the sites are kept for the process.
      module TypeParserHooks
        def interpret_QualifiedReference(name_ast, context) # rubocop:disable Naming/MethodName -- Puppet's name
          type = super
          if type.is_a?(Puppet::Pops::Types::PTypeAliasType) && Probes.current && name_ast.respond_to?(:file)
            Probes.alias_sites[name_ast.cased_value] << [name_ast.file, name_ast.line]
          end
          type
        end
      end

      # A value checked against an alias, which happens on every compile.
      module TypeAliasHooks
        def instance?(o, guard = nil)
          Probes.current&.type_alias(name)
          super
        end
      end

      module DeprecationHooks
        def issue_deprecation_warning(message, key, file, line, use_caller)
          Probes.current&.deprecation(message, file, line)
          super
        end
      end

      module ProviderHooks
        def provide(name, options = {}, &block)
          Probes.current&.provider_loaded(self.name, name, caller_locations(1, 1).first&.path)
          super
        end
      end

      # A control repo's config_version script would run during the compile;
      # the catalog's version is set from the repo instead.
      module ConfigVersionHooks
        def config_version
          Probes.current ? nil : super
        end
      end

      module ExecutionGuard
        def execute(command, options = {})
          rec = Probes.current
          return super unless rec

          line = command.is_a?(Array) ? command.flatten.join(' ') : command.to_s
          action, entry = rec.guard('execute', line)
          return super unless action == :mock

          # as Puppet's execute does: a failing command raises unless told not to
          failonfail = options.equal?(Puppet::Util::Execution::NoOptionsSpecified) ? true : options.fetch(:failonfail, false)
          raise Puppet::ExecutionFailure, "Execution of '#{line}' returned #{entry.exit}: #{entry.stdout}" if failonfail && !entry.exit.zero?

          Puppet::Util::Execution::ProcessOutput.new(entry.stdout, entry.exit)
        end

        def execpipe(command, failonfail = true, &block)
          rec = Probes.current
          return super unless rec

          line = command.respond_to?(:join) ? command.join(' ') : command.to_s
          action, entry = rec.guard('execpipe', line)
          return super unless action == :mock
          raise Puppet::ExecutionFailure, entry.stdout if failonfail && !entry.exit.zero?

          block ? yield(StringIO.new(entry.stdout)) : entry.stdout
        end
      end

      module FacterExecutionGuard
        def execute(command, options = {})
          rec = Probes.current
          return super unless rec

          action, entry = rec.guard('facter-execute', command.to_s)
          (action == :mock) ? entry.stdout : super
        end

        def exec(command)
          rec = Probes.current
          return super unless rec

          action, entry = rec.guard('facter-exec', command.to_s)
          (action == :mock) ? entry.stdout : super
        end
      end

      FactValue = Struct.new(:name, :value)

      module FacterGuard
        def value(user_query)
          rec = Probes.current
          return super unless rec

          rec.facter_value(user_query).last
        end

        def fact(user_query)
          rec = Probes.current
          return super unless rec

          found, value = rec.facter_value(user_query)
          found ? FactValue.new(user_query.to_s.downcase, value) : nil
        end

        def to_hash
          rec = Probes.current
          rec ? rec.facts : super
        end
      end
    end
  end
end
