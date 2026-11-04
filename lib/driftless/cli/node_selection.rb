require 'driftless/node_selector'

module Driftless
  module CLI
    # The node-selection flags `list factsets` and `export factsets` share.
    module NodeSelection
      # Adds --role, --environment, --collector, --os, --certname, and
      # --exclude-certname to the parser. Each takes globs, repeatable and
      # comma-separated; values accumulate in options under the matching
      # plural key.
      def declare_node_selection(parser)
        parser.separator ''
        parser.separator 'Node selection (globs, case-insensitive; any value of a flag; every flag given):'
        parser.on('--role=GLOB', Array, 'Nodes classified with a matching role') { |v| accumulate(:roles, v) }
        parser.on('--environment=GLOB', Array, 'Nodes in a matching environment, inside puppet.environments or not') { |v| accumulate(:environments_selected, v) }
        parser.on('--collector=GLOB', Array, 'Nodes reported by a matching collector') { |v| accumulate(:collectors, v) }
        parser.on('--os=GLOB', Array, 'Nodes whose os.name or os.family fact matches') { |v| accumulate(:os, v) }
        parser.on('--certname=GLOB', Array, 'Nodes whose certname matches') { |v| accumulate(:certname_globs, v) }
        parser.on('--exclude-certname=GLOB', Array, 'Drop nodes whose certname matches, whatever else they match') do |v|
          accumulate(:exclude_certname_globs, v)
        end
      end

      # @return [::Driftless::NodeSelector] built from the accumulated options
      def node_selector
        ::Driftless::NodeSelector.new(
          roles:                  @options[:roles] || [],
          environments:           @options[:environments_selected] || [],
          collectors:             @options[:collectors] || [],
          os:                     @options[:os] || [],
          certname_globs:         @options[:certname_globs] || [],
          exclude_certname_globs: @options[:exclude_certname_globs] || [],
        )
      end

      private

      def accumulate(key, values)
        (@options[key] ||= []).concat(values)
      end
    end
  end
end
