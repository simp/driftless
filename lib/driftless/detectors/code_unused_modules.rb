require 'set'

require 'driftless/detectors/callable'

module Driftless
  module Detectors
    class CodeUnusedModules < Callable
      key      'code:unused-modules'
      severity :warning
      quality  :stale
      about 'Modules with no class classified by any active node'
      requires_reports 'classes-for-all-active-nodes'

      def call
        if corpus.reported.missing?('classes-for-all-active-nodes')
          return [skip_meta_finding(reason: 'no report:classes-for-all-active-nodes data')]
        end

        active_modules = corpus.reported.all_active_classes
          .map { |fqname| fqname.split('::').first }.to_set
        corpus.puppet_classes.values
          .group_by { |cls| cls.fqname.split('::').first }
          .reject { |module_name, _| active_modules.include?(module_name) }
          .sort
          .map do |module_name, classes|
            build_finding(
              path:    module_dir(classes),
              message: "no class from module #{module_name.inspect} is classified by any active node",
              meta:    { module_name: module_name, classes: classes.map(&:fqname).sort },
            )
          end
      end

      private

      # Every class file sits at <module dir>/manifests/**.pp, so trimming the
      # manifests suffix names the module directory whatever the modulepath
      # entry is called.
      def module_dir(classes)
        classes.map(&:file).min&.sub(%r{/manifests/.*\z}, '')
      end
    end
  end
end
