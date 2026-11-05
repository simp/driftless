require 'yaml'

require 'pupgrade/logging'

module Pupgrade
  module Compile
    # What an ENC would tell the compiler about a node: its top-scope
    # variables and classes, derived per node from the certname and facts.
    # Two files, both optional:
    #
    # `pupgrade/enc.yaml`, rules applied in order, later assignments
    # overriding earlier ones:
    #
    #     rules:
    #       - set:                                   # for every node
    #           role: role::base
    #       - when:                                  # for the nodes matching
    #           certname: 'pup*'                     #   a glob on the certname
    #           facts.os.family: [RedHat, Rocky]     #   a fact, any of the values
    #         set:
    #           role: role::puppetserver
    #         classes: [profile::puppetserver]
    #       - set:
    #           site: '${certname[/\A[^.]+\.([^.]+)\./, 1]}'   # a capture
    #           family: '${facts.os.family}'
    #
    # A value interpolates `${certname}`, `${facts.a.b}`, `${trusted.a.b}`,
    # and `${vars.name}` (a variable set so far), each with an optional
    # `[/regexp/, n]` taking a capture group.
    #
    # `pupgrade/compiler.rb`, plain Ruby loaded after the rules for what
    # they cannot say, each block given the node as resolved so far:
    #
    #     variable(:tenant) { |node| node.certname =~ /\.b\./ ? 'blue' : 'green' }
    #     classes { |node| ['profile::el'] if node.fact('os.family') == 'RedHat' }
    #     mock(/\Arpm -q (\S+)\z/) { |node, m| "#{m[1]}-1.0-1.el9\n" }
    #     fact('os.selinux.enabled') { |node| false if node.fact('os.family') == 'Debian' }
    #
    # A `variable` block returning nil leaves what the rules set; a `mock`
    # block returning nil declines, and the YAML mocks are tried; a `fact`
    # block sees the factset's facts as read and answers before the YAML
    # `facts:` mocks, nil declining.
    class Enc
      class Error < StandardError; end

      # A node as the ENC stand-in sees it and what it decided.
      #
      # @!attribute [r] certname
      #   @return [String]
      # @!attribute [r] facts
      #   @return [Hash]
      # @!attribute [r] trusted
      #   @return [Hash]
      # @!attribute [r] vars
      #   @return [Hash{String => Object}] the top-scope variables so far
      # @!attribute [r] classes
      #   @return [Array<String>]
      Node = Data.define(:certname, :facts, :trusted, :vars, :classes) do
        # @param path [String] dotted, into the facts
        def fact(path)
          Enc.dig(facts, path)
        end

        def [](name)
          vars[name.to_s]
        end
      end

      # One rule of the YAML file.
      Rule = Data.define(:conditions, :set, :classes, :source)

      # The Ruby file's definitions.
      class Rules
        attr_reader :variables, :class_blocks, :mocks, :functions, :facts

        def initialize
          @variables    = []
          @class_blocks = []
          @mocks        = []
          @functions    = []
          @facts        = []
        end

        # @param name [String, Symbol]
        # @yieldparam node [Node]
        # @yieldreturn [Object, nil] the value, or nil to leave it
        def variable(name, &block)
          raise Error, "variable #{name.inspect} needs a block" unless block

          @variables << [name.to_s, block]
        end

        # @yieldparam node [Node]
        # @yieldreturn [Array<String>, String, nil] classes to add
        def classes(&block)
          raise Error, 'classes needs a block' unless block

          @class_blocks << block
        end

        # @param pattern [Regexp]
        # @yieldparam node [Node]
        # @yieldparam match [MatchData]
        # @yieldreturn [String, Hash, nil] stdout, `{stdout:, exit:}`, or nil
        #   to decline
        def mock(pattern, &block)
          raise Error, "mock #{pattern.inspect} needs a Regexp and a block" unless pattern.is_a?(Regexp) && block

          @mocks << [pattern, block]
        end

        # @param name [String, Symbol] the Puppet function, "puppetdb_query"
        # @yieldparam node [Node]
        # @yieldparam args [Array] the call's arguments
        # @yieldreturn [Object, nil] what the call returns, or nil to let the
        #   function run
        def function(name, &block)
          raise Error, "function #{name.inspect} needs a block" unless block

          @functions << [name.to_s.delete_prefix('::'), block]
        end

        # @param path [String, Symbol] the fact, dotted for a path into a
        #   structured one ("os.family")
        # @yieldparam node [Node] the factset's facts as read, no mock applied
        # @yieldreturn [Object, nil] the fact's value for this node, merged
        #   over the factset's as a `facts:` mock is; nil to decline
        def fact(path, &block)
          raise Error, "fact #{path.inspect} needs a block" unless block

          @facts << [path.to_s, block]
        end

        # @param path [String]
        # @return [Rules]
        def self.load(path)
          rules = new
          rules.instance_eval(File.read(path), path, 1)
          rules
        rescue Errno::ENOENT
          raise Error, "#{path}: no such file"
        rescue Error
          raise
        rescue StandardError, ScriptError => e
          raise Error, "#{path}: #{e.class}: #{e.message.lines.first.to_s.strip}"
        end
      end

      INTERPOLATION = %r{\$\{([a-z_]+(?:\.[A-Za-z0-9_-]+)*)(?:\[/((?:[^/\\]|\\.)+)/,\s*(\d+)\])?\}}.freeze

      # @param yaml_path [String, nil] the rules file
      # @param ruby_path [String, nil] the Ruby file
      # @param vars [Hash] variables set for every node first (`compile.vars`)
      # @return [Enc]
      # @raise [Error] when a file does not read as expected
      def self.load(yaml_path, ruby_path, vars: {})
        rules = yaml_path ? read_rules(yaml_path) : []
        ruby  = ruby_path ? Rules.load(ruby_path) : Rules.new
        Pupgrade.logger.info("enc: #{rules.size} rule(s) from #{yaml_path || 'nowhere'}; #{ruby.variables.size} variable, " \
                             "#{ruby.class_blocks.size} classes, #{ruby.mocks.size} mock, #{ruby.facts.size} fact block(s) from #{ruby_path || 'nowhere'}")
        new(rules: rules, ruby: ruby, vars: vars)
      end

      def self.read_rules(path)
        data = YAML.safe_load(File.read(path), aliases: true, filename: path) || {}
        raise Error, "#{path}: expected a mapping with `rules`, got #{data.class}" unless data.is_a?(Hash)

        Array(data['rules']).each_with_index.map do |entry, i|
          source = "#{path}: rule #{i + 1}"
          raise Error, "#{source}: expected a mapping, got #{entry.class}" unless entry.is_a?(Hash)

          unknown = entry.keys - %w[when set classes]
          raise Error, "#{source}: unknown key #{unknown.first.inspect} (known: when, set, classes)" unless unknown.empty?

          Rule.new(conditions: (entry['when'] || {}).to_h { |k, v| [k.to_s, v] },
                   set: (entry['set'] || {}).to_h { |k, v| [k.to_s, v] },
                   classes: Array(entry['classes']).map(&:to_s), source: source)
        end
      rescue Errno::ENOENT
        raise Error, "#{path}: no such file"
      rescue Psych::SyntaxError => e
        raise Error, "#{path}: #{e.message}"
      end

      # @param hash [Hash]
      # @param path [String] dotted
      def self.dig(hash, path)
        path.to_s.split('.').reduce(hash) do |v, k|
          next nil unless v.is_a?(Hash)

          v.key?(k) ? v[k] : v[k.to_sym]
        end
      end

      # @return [Rules] the Ruby file's definitions; its mock blocks are
      #   consulted by the mocks
      attr_reader :ruby

      def initialize(rules: [], ruby: Rules.new, vars: {})
        @rules = rules
        @ruby  = ruby
        @vars  = vars.to_h { |k, v| [k.to_s, v] }
      end

      # Whether anything could change a node: no rules, no blocks, and no
      # static variables leave the node as the factset describes it.
      def empty?
        @rules.empty? && @ruby.variables.empty? && @ruby.class_blocks.empty? && @vars.empty?
      end

      # @param factset [Factset]
      # @return [Node]
      def resolve(factset)
        node = Node.new(certname: factset.certname, facts: factset.values, trusted: factset.trusted.is_a?(Hash) ? factset.trusted : {},
                        vars: @vars.dup, classes: [])
        @rules.each do |rule|
          next unless matches?(rule, node)

          set = rule.set.to_h { |k, v| [k, interpolate(v, node, rule.source)] }
          node = node.with(vars: node.vars.merge(set), classes: (node.classes + rule.classes).uniq)
          Pupgrade.logger.debug("enc: #{node.certname}: #{rule.source} sets #{set.keys.join(', ')}#{" and classes #{rule.classes.join(', ')}" unless rule.classes.empty?}") unless set.empty? && rule.classes.empty?
        end
        @ruby.variables.each do |name, block|
          value = block.call(node)
          next if value.nil?

          node = node.with(vars: node.vars.merge(name => value))
          Pupgrade.logger.debug("enc: #{node.certname}: variable #{name} = #{value.inspect} (ruby)")
        end
        @ruby.class_blocks.each do |block|
          added = Array(block.call(node)).compact.map(&:to_s)
          node = node.with(classes: (node.classes + added).uniq) unless added.empty?
        end
        unless node.vars.empty? && node.classes.empty?
          Pupgrade.logger.info("enc: #{node.certname}: variables #{node.vars.inspect}#{"; classes #{node.classes.join(', ')}" unless node.classes.empty?}")
        end
        node
      end

      def self.interpolate(value, node, source)
        return value unless value.is_a?(String)

        value.gsub(INTERPOLATION) do
          path, regexp, group = Regexp.last_match.captures
          text = reference(path, node, source).to_s
          if regexp
            m = Regexp.new(regexp).match(text)
            m ? m[group.to_i].to_s : ''
          else
            text
          end
        end
      end

      def self.reference(path, node, source)
        head, rest = path.split('.', 2)
        value = case head
                when 'certname' then node.certname
                when 'facts'    then rest ? dig(node.facts, rest) : node.facts
                when 'trusted'  then rest ? dig(node.trusted, rest) : node.trusted
                when 'vars'     then rest ? node.vars[rest] : node.vars
                else raise Error, "#{source}: ${#{path}}: references start with certname, facts, trusted, or vars"
                end
        Pupgrade.logger.debug("enc: #{node.certname}: ${#{path}} is unset (#{source})") if value.nil?
        value
      end
      private_class_method :reference

      private

      # A rule applies when every condition holds: `certname` as a glob, a
      # fact path by value, any of a list.
      def matches?(rule, node)
        rule.conditions.all? do |key, wanted|
          if key == 'certname'
            Array(wanted).any? { |g| File.fnmatch?(g.to_s, node.certname, File::FNM_CASEFOLD) }
          else
            actual = key.start_with?('facts.') ? self.class.dig(node.facts, key.delete_prefix('facts.')) : self.class.dig(node.facts, key)
            Array(wanted).map(&:to_s).include?(actual.to_s)
          end
        end
      end

      # A value with its `${...}` references replaced; a non-string value
      # is taken as it is.
      def interpolate(value, node, source)
        self.class.interpolate(value, node, source)
      end
    end
  end
end
