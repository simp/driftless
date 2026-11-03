require 'json'
require 'set'

require 'pupgrade/compile/probe_record'
require 'pupgrade/logging'

module Pupgrade
  module Impact
    # What a `compile` run shows each node using, from its compile record
    # and catalog: the classes it includes, from where, and the parameters
    # set on them, the resources it declares with their parameters, the
    # functions its code called and from where, the facts it read, and the
    # providers it names.
    class Evidence
      class Error < StandardError; end

      # One node's usage.
      #
      # @!attribute [r] certname
      #   @return [String]
      # @!attribute [r] classes
      #   @return [Hash{String => Set<String>}] class (lowercase) to the
      #     parameters the catalog sets on it
      # @!attribute [r] class_sites
      #   @return [Hash{String => Array<String>}] class (lowercase) to the
      #     sites that added it, "file:line" or "enc"
      # @!attribute [r] resources
      #   @return [Array<Hash>] catalog resources: "type" (lowercase),
      #     "title", "parameters"
      # @!attribute [r] functions
      #   @return [Hash{String => Array<String>}] function to call sites
      # @!attribute [r] facts
      #   @return [Set<String>] fact names read, by top-level name and
      #     dotted path
      # @!attribute [r] providers
      #   @return [Set<String>] "type/provider" named by resources
      # @!attribute [r] aliases
      #   @return [Set<String>] type aliases resolved during the compile,
      #     lowercase
      # @!attribute [r] lookups
      #   @return [Hash{String => Boolean}] the automatic parameter lookups
      #     the compile made, "class::param" to whether Hiera answered
      Node = Data.define(:certname, :classes, :class_sites, :resources, :functions, :facts, :providers, :lookups, :aliases)

      # @return [Array<Node>]
      attr_reader :nodes

      # @param dir [String] a `compile` output directory
      # @raise [Error] when it holds no compile records
      def initialize(dir)
        dir = File.expand_path(dir)
        @nodes = ::Pupgrade::Compile::ProbeRecord.paths(dir).map do |p|
          Pupgrade.logger.debug("evidence: reading #{File.dirname(p)}")
          node(File.dirname(p))
        end
        Pupgrade.logger.info("evidence: #{@nodes.size} node(s) from #{dir}")
      rescue ::Pupgrade::Compile::ProbeRecord::Error => e
        raise Error, e.message
      rescue JSON::ParserError => e
        raise Error, "#{dir}: #{e.message}"
      end

      # @return [Array<String>] certnames whose catalog includes the class
      def including(klass)
        name = klass.downcase
        @nodes.select { |n| n.classes.key?(name) }.map(&:certname)
      end

      # @return [Array<String>] where the class was added across nodes,
      #   unique: "file:line", or "enc"
      def class_sites(klass)
        name = klass.downcase
        @nodes.flat_map { |n| n.class_sites.fetch(name, []) }.uniq
      end

      # Certnames giving the class parameter a value: Hiera answered its
      # automatic lookup, or no lookup was made because a resource-style
      # declaration gave it. A catalog's class carries every parameter,
      # defaults included, so the catalog alone cannot tell.
      #
      # @return [Array<String>]
      def setting(klass, param)
        name = klass.downcase
        key  = "#{name}::#{param}"
        @nodes.select { |n| n.classes.key?(name) && n.lookups.fetch(key, true) }.map(&:certname)
      end

      # @return [Array<String>] certnames including the class whose
      #   automatic lookup of the parameter found nothing: the default applies
      def defaulting(klass, param)
        name = klass.downcase
        key  = "#{name}::#{param}"
        @nodes.select { |n| n.classes.key?(name) && n.lookups.key?(key) && !n.lookups[key] }.map(&:certname)
      end

      # @return [Array<Array(String, Hash)>] certname and resource, for every
      #   resource of the type; with `with`, only those setting the parameter
      def resources(type, with: nil)
        name = type.downcase
        @nodes.flat_map do |n|
          n.resources.select { |r| r['type'] == name && (with.nil? || r['parameters'].key?(with)) }.map { |r| [n.certname, r] }
        end
      end

      # @return [Array<String>] call sites across nodes, unique
      def call_sites(function)
        @nodes.flat_map { |n| n.functions.fetch(function, []) }.uniq
      end

      # @return [Array<String>] certnames reading the fact, by its top-level
      #   name
      def reading(fact)
        name = fact.downcase
        @nodes.select { |n| n.facts.any? { |f| f == name || f.start_with?("#{name}.") } }.map(&:certname)
      end

      # @return [Array<String>] certnames whose compile resolved the type alias
      def using_alias(name)
        wanted = name.downcase
        @nodes.select { |n| n.aliases.include?(wanted) }.map(&:certname)
      end

      # @return [Array<String>] certnames whose resources name the provider
      def naming(type, provider)
        key = "#{type}/#{provider}".downcase
        @nodes.select { |n| n.providers.include?(key) }.map(&:certname)
      end

      private

      def node(dir)
        probes  = ::Pupgrade::Compile::ProbeRecord.read(File.join(dir, ::Pupgrade::Compile::ProbeRecord::FILENAME))
        catalog = File.file?(File.join(dir, 'catalog.json')) ? JSON.parse(File.read(File.join(dir, 'catalog.json'))) : {}
        classes   = {}
        resources = []
        Array(catalog['resources']).each do |r|
          params = (r['parameters'] || {})
          if r['type'] == 'Class'
            classes[r['title'].to_s.downcase] = params.keys.to_set
          else
            resources << { 'type' => r['type'].to_s.downcase, 'title' => r['title'].to_s, 'parameters' => params }
          end
        end
        class_sites = {}
        (probes['classes'] || {}).each do |c, entry|
          classes[c.downcase] ||= Set.new
          class_sites[c.downcase] = Array(entry.is_a?(Hash) ? entry['sites'] : nil)
        end
        facts = Set.new
        (probes['facts'] || {}).each_key { |f| facts << f.sub(/ \(Facter\)\z/, '').downcase }
        (probes['legacy_facts'] || {}).each_key { |f| facts << f.downcase }
        lookups = {}
        (probes['lookups'] || {}).each do |key, l|
          lookups[key.downcase] = l['found'] ? true : false if l.is_a?(Hash) && l['automatic'].to_i.positive?
        end
        Node.new(certname: probes['certname'] || File.basename(dir), classes: classes, class_sites: class_sites, resources: resources,
                 functions: (probes['functions'] || {}).transform_values { |f| Array(f['sites']) },
                 facts: facts, providers: (probes['providers_named'] || {}).keys.map(&:downcase).to_set, lookups: lookups,
                 aliases: (probes['type_aliases'] || {}).keys.map(&:downcase).to_set)
      end
    end
  end
end
