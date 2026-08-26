require 'driftless/finding'

module Driftless
  # Parsed `--fail-on` / `scan.fail_on` value: decides whether a finished scan
  # exits non-zero given its findings.
  #
  # Grammar: `any` (any finding fails), `none` (findings never fail), or
  # comma-joined terms — a severity term matches that severity or worse, a
  # quality term matches exactly, and terms OR together, so `error,stale`
  # fails on any error-severity finding and on any stale finding. `any` and
  # `none` stand alone.
  class FailOn
    # `never` is the pre-1.0 spelling of `none`; accepted until 1.0.
    NONE_TERMS = %w[none never].freeze

    # @param value [String] raw flag or config value
    # @return [FailOn]
    # @raise [ArgumentError] on an unknown term or a disallowed combination
    def self.parse(value)
      terms = value.to_s.split(',').map(&:strip).reject(&:empty?)
      raise ArgumentError, "invalid fail-on value #{value.inspect}: no terms" if terms.empty?

      standalone = terms.select { |t| t == 'any' || NONE_TERMS.include?(t) }
      if standalone.any? && terms.length > 1
        raise ArgumentError, "fail-on term #{standalone.first.inspect} cannot be combined with other terms"
      end
      return new(any: true) if terms == ['any']
      return new if NONE_TERMS.include?(terms.first)

      severities = []
      qualities  = []
      terms.each do |term|
        sym = term.to_sym
        if Finding::SEVERITIES.include?(sym)
          # SEVERITIES is ordered most-severe-first, so "this severity or
          # worse" is the prefix through the named one.
          severities |= Finding::SEVERITIES.take(Finding::SEVERITIES.index(sym) + 1)
        elsif Finding::QUALITIES.include?(sym)
          qualities |= [sym]
        else
          raise ArgumentError,
                "unknown fail-on term #{term.inspect}: expected any, none, " \
                "a severity (#{Finding::SEVERITIES.join(', ')}), " \
                "or a quality (#{Finding::QUALITIES.join(', ')})"
        end
      end
      new(severities: severities, qualities: qualities)
    end

    def initialize(any: false, severities: [], qualities: [])
      @any        = any
      @severities = severities
      @qualities  = qualities
    end

    # @param findings [Array<Finding>]
    # @return [Boolean] whether the scan should exit non-zero
    def fail?(findings)
      return findings.any? if @any

      findings.any? do |f|
        @severities.include?(f.severity) || @qualities.include?(f.quality)
      end
    end
  end
end
