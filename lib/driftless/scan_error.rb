module Driftless
  # The one error that halts a run: inputs unusable enough that findings
  # drawn from them could not be trusted. Findings themselves never halt.
  class ScanError < StandardError; end
end
