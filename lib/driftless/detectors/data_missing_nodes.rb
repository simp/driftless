require 'driftless/detectors/base'

module Driftless
  module Detectors
    class DataMissingNodes < Base
      key 'data:missing-nodes'
      about 'Data under certnames/fqdns not present in report:all-active-nodes'
      requires_reports 'all-active-nodes'

      def call
        []
      end
    end
  end
end
