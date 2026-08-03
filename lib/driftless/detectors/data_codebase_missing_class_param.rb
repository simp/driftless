require 'driftless/detectors/base'

module Driftless
  module Detectors
    class DataCodebaseMissingClassParam < Base
      key 'data:codebase-missing-class-param'
      about 'Data key references a parameter that does not exist on the referenced class'

      def call
        []
      end
    end
  end
end
