module Driftless
  # Timing for the steps of a load or scan: each block's runtime goes to the
  # log at DEBUG.
  module Phases
    private

    # @param name [String] what the log line calls the step
    # @return the block's value
    def phase(name)
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)
      Driftless.logger.debug("  [#{elapsed_ms}ms] #{name}")
      result
    end
  end
end
