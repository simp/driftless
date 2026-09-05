require 'driftless/node_selector'

module Driftless
  module CLI
    # The node-selection flags `list factsets` and `export factsets` share.
    module NodeSelection
      # Adds --role, --environment, --collector, --os, and --certname to the
      # parser. Each is repeatable and comma-separated; values accumulate in
      # options under the matching plural key.
      def declare_node_selection(parser)
        parser.separator ''
        parser.separator 'Node selection (any value of a flag; every flag given):'
        parser.on('--role=NAME', Array,
                  'Nodes classified with a role (glob, case-insensitive)') { |v| accumulate(:roles, v) }
        parser.on('--environment=ENV', Array, 'Nodes in an environment') { |v| accumulate(:environments_selected, v) }
        parser.on('--collector=NAME', Array, 'Nodes reported by a collector') { |v| accumulate(:collectors, v) }
        parser.on('--os=NAME', Array,
                  'Nodes whose os.name or os.family fact matches (case-insensitive)') { |v| accumulate(:os, v) }
        parser.on('--certname=GLOB', Array,
                  'Nodes whose certname matches GLOB (File.fnmatch syntax)') { |v| accumulate(:certname_globs, v) }
      end

      # @return [::Driftless::NodeSelector] built from the accumulated options
      def node_selector
        ::Driftless::NodeSelector.new(
          roles:          @options[:roles] || [],
          environments:   @options[:environments_selected] || [],
          collectors:     @options[:collectors] || [],
          os:             @options[:os] || [],
          certname_globs: @options[:certname_globs] || [],
        )
      end

      private

      def accumulate(key, values)
        (@options[key] ||= []).concat(values)
      end
    end
  end
end
