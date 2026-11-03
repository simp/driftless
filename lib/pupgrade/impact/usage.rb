require 'pupgrade/impact/uses'
require 'pupgrade/surface/diff'
require 'pupgrade/surface/render'

module Pupgrade
  module Impact
    # What the site uses of one module, item by item of its surface
    # document: for each class, defined type, function, type alias, type,
    # provider, and fact, where the evidence shows it used; on request
    # each class parameter too, with the nodes setting it and the nodes
    # leaving it at its default.
    class Usage
      include Uses

      # The labels of a class parameter's two uses.
      SET     = 'set'.freeze
      DEFAULT = 'default'.freeze

      # One item of the surface and its uses.
      #
      # @!attribute [r] section
      #   @return [String] one of {Surface::Diff::SECTIONS}
      # @!attribute [r] name
      #   @return [String] the entry
      # @!attribute [r] param
      #   @return [String, nil] a parameter of the class; nil for the entry
      #     itself
      # @!attribute [r] uses
      #   @return [Array<Use>] empty when nothing uses it
      Row = Data.define(:section, :name, :param, :uses) do
        # A parameter is used when some node sets it; an entry when it has
        # any use.
        def used?
          param ? uses.any? { |u| u.label == SET } : !uses.empty?
        end

        # The item as a filter names it: a parameter as `CLASS::PARAM`.
        #
        # @return [String]
        def item
          param ? "#{name}::#{param}" : name
        end

        # The surface kind, the namespace, and the leaf, split as
        # `module diff` splits an item; a parameter is "param", its class
        # the namespace.
        #
        # @return [Array(String, String, String)]
        def parts
          return ['param', "#{name}::", param] if param

          kind = Surface::Render::SINGULAR.fetch(section)
          head, sep, tail = name.rpartition('::')
          sep.empty? ? [kind, '', name] : [kind, "#{head}::", tail]
        end
      end

      # @param evidence [Evidence]
      def initialize(evidence)
        @evidence = evidence
      end

      # @param doc [Hash] a surface document
      # @param params [Boolean] whether each class's parameters follow it
      # @return [Array<Row>] in section order, names sorted
      def rows(doc, params: false)
        Surface::Diff::SECTIONS.flat_map do |section|
          doc.fetch(section, {}).sort.flat_map do |name, entry|
            out = [Row.new(section: section, name: name, param: nil, uses: uses_of(section, name))]
            out.concat(param_rows(name, entry)) if params && section == 'classes'
            out
          end
        end
      end

      private

      def uses_of(section, name)
        case section
        when 'classes'                then nodes(@evidence.including(name)) + sites(@evidence.class_sites(name))
        when 'defined_types', 'types' then resources(@evidence.resources(name))
        when 'functions'              then sites(@evidence.call_sites(name))
        when 'type_aliases'           then nodes(@evidence.using_alias(name))
        when 'providers'              then nodes(@evidence.naming(*name.split('/', 2)))
        when 'facts'                  then nodes(@evidence.reading(name))
        else []
        end
      end

      def param_rows(klass, entry)
        (entry['params'] || {}).keys.sort.map do |param|
          uses = nodes(@evidence.setting(klass, param), label: SET) + nodes(@evidence.defaulting(klass, param), label: DEFAULT)
          Row.new(section: 'classes', name: klass, param: param, uses: uses)
        end
      end
    end
  end
end
