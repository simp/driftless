require 'driftless/params_schema'

module Driftless
  module ParamsSchema
    # The differences between two params documents: the repo revision and
    # deployments, then classes and params added, removed, or redeclared.
    module Compare
      KINDS = %w[class-added class-removed param-added param-removed type-changed default-changed].freeze

      # One class or param difference.
      #
      # @!attribute [r] kind
      #   @return [String] one of {KINDS}
      # @!attribute [r] class_name
      #   @return [String]
      # @!attribute [r] param
      #   @return [String, nil] nil for a class-level change
      # @!attribute [r] detail
      #   @return [String] what it was and what it is
      Change = Data.define(:kind, :class_name, :param, :detail)

      module_function

      # @param from [Hash] a params document
      # @param to [Hash] a params document
      # @return [Array<String>] one line per repo difference: the control
      #   repo's revision, then each deployment by path
      def repo_changes(from, to)
        lines = []
        git_from = from['repo']['git']
        git_to   = to['repo']['git']
        lines << "control repo: #{describe_git(git_from)} -> #{describe_git(git_to)}" if git_from != git_to

        deployed_from = from['repo']['deployments']
        deployed_to   = to['repo']['deployments']
        (deployed_from.keys | deployed_to.keys).sort.each do |path|
          x = deployed_from[path]
          y = deployed_to[path]
          lines << "#{path}: #{describe_deployment(x)} -> #{describe_deployment(y)}" if x != y
        end
        lines
      end

      # @return [Array<Change>] by class name, then param in declaration order
      def class_changes(from, to)
        classes_from = from['classes']
        classes_to   = to['classes']
        (classes_from.keys | classes_to.keys).sort.flat_map do |name|
          x = classes_from[name]
          y = classes_to[name]
          if x.nil?
            [Change.new(kind: 'class-added', class_name: name, param: nil, detail: "#{y['params'].size} params in #{y['file']}")]
          elsif y.nil?
            [Change.new(kind: 'class-removed', class_name: name, param: nil, detail: "was in #{x['file']}")]
          else
            param_changes(name, x['params'], y['params'])
          end
        end
      end

      def param_changes(name, params_from, params_to)
        (params_from.keys | params_to.keys).flat_map do |param|
          x = params_from[param]
          y = params_to[param]
          if x.nil?
            [Change.new(kind: 'param-added', class_name: name, param: param, detail: describe_param(y))]
          elsif y.nil?
            [Change.new(kind: 'param-removed', class_name: name, param: param, detail: "was #{describe_param(x)}")]
          else
            changes = []
            if x['type'] != y['type']
              changes << Change.new(kind: 'type-changed', class_name: name, param: param,
                                    detail: "#{type_text(x)} -> #{type_text(y)}")
            end
            if x['default'] != y['default']
              changes << Change.new(kind: 'default-changed', class_name: name, param: param,
                                    detail: "#{default_text(x)} -> #{default_text(y)}")
            end
            changes
          end
        end
      end

      def describe_param(p)
        "#{type_text(p)} = #{default_text(p)}"
      end

      def type_text(p)
        p['type'] || '(untyped)'
      end

      def default_text(p)
        p['default'] || '(required)'
      end

      def describe_git(git)
        git ? "#{git['sha'].to_s[0, 12]} (#{git['branch']})" : '(no git)'
      end

      def describe_deployment(d)
        d ? [d['ref'], d['sha']&.slice(0, 12)].compact.join(' ') : '(absent)'
      end
    end
  end
end
