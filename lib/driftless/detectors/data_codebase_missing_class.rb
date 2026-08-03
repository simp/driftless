require 'driftless/detectors/base'

module Driftless
  module Detectors
    class DataCodebaseMissingClass < Base
      key 'data:codebase-missing-class'
      about 'Data key references class::param where the class is not defined in the control repo'

      def call
        []
      end
    end
  end
end
