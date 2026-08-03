require 'driftless/detectors/base'

module Driftless
  module Detectors
    class CodeLookupMissingHieraKeys < Base
      key 'code:lookup-missing-hiera-keys'
      about 'Explicit lookup() calls searching for keys not defined anywhere in Hiera'

      def call
        []
      end
    end
  end
end
