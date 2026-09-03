require 'set'

require 'driftless/inputs/datadir_loader'
require 'driftless/inputs/hierarchy_loader'

module Driftless
  module Inputs
    # Reads the Hiera data layer of each module that has a hiera.yaml.
    class ModuleDataLoader
      # @param module_dirs [Array<String>] absolute module directories
      # @return [Set<String>] keys the modules' own data files define,
      #   limited to each module's namespace (`<module>::`), which is all
      #   Puppet's module layer serves
      def self.load(module_dirs)
        keys = Set.new
        module_dirs.each do |dir|
          next unless File.file?(File.join(dir, 'hiera.yaml'))
          prefix = "#{File.basename(dir)}::"
          # Findings from a module's hiera.yaml and data files describe the
          # module, not the control repo, and are dropped.
          tiers, = HierarchyLoader.load(dir)
          data_files, = DatadirLoader.load(tiers)
          data_files.each do |df|
            keys.merge(df.top_level_keys.keys.select { |k| k.start_with?(prefix) })
          end
        end
        keys
      end
    end
  end
end
