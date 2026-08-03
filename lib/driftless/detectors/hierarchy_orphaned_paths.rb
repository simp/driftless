require 'driftless/detectors/base'

module Driftless
  module Detectors
    class HierarchyOrphanedPaths < Base
      key 'hierarchy:orphaned-paths'
      about 'Hiera data files on disk that no hierarchy tier resolves to'
      requires_reports 'all-active-nodes'

      def call
        []
      end
    end
  end
end
