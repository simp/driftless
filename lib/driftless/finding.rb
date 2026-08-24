module Driftless
  # A single driftless finding.
  #
  # @!attribute [rw] key
  #   @return [String] namespaced detector key, e.g. "hierarchy:unreachable-data-files"
  # @!attribute [rw] path
  #   @return [String, nil] repo-relative path the finding anchors to (nil for structural findings)
  # @!attribute [rw] line
  #   @return [Integer, nil] 1-indexed line, when applicable
  # @!attribute [rw] message
  #   @return [String] human-readable one-liner
  # @!attribute [rw] meta
  #   @return [Hash] detector-specific structured payload
  # @!attribute [rw] severity
  #   @return [Symbol] one of {SEVERITIES} — SARIF-aligned: :error, :warning, :note
  # @!attribute [rw] quality
  #   @return [Symbol, nil] one of {QUALITIES} — categorical tag or nil (unlabelled)
  Finding = Struct.new(
    :key, :path, :line, :message, :meta, :severity, :quality,
    keyword_init: true,
  )

  class Finding
    SEVERITIES = %i[error warning note].freeze
    QUALITIES  = %i[stale wrong weird impossible].freeze

    def initialize(key:, message:, path: nil, line: nil, meta: {},
                   severity: :warning, quality: nil)
      unless SEVERITIES.include?(severity)
        raise ArgumentError,
              "invalid Finding severity #{severity.inspect}; " \
              "must be one of #{SEVERITIES.inspect}"
      end
      unless quality.nil? || QUALITIES.include?(quality)
        raise ArgumentError,
              "invalid Finding quality #{quality.inspect}; " \
              "must be nil or one of #{QUALITIES.inspect}"
      end
      super
    end
  end
end
