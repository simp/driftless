require 'driftless/config'
require 'driftless/detectors'
require 'driftless/finding'

module Driftless
  module Detectors
    class Base
      class << self
        def key(k = nil)
          k.nil? ? @key : (@key = k)
        end

        def about(text = nil)
          text.nil? ? @about : (@about = text)
        end

        def requires_reports(*names)
          if names.empty?
            @requires_reports ||= []
          else
            @requires_reports = names.flatten.map(&:to_s)
          end
        end

        # SARIF-aligned severity applied by default to every finding this
        # detector emits (per-finding override via {Base#build_finding}).
        # Defaults to :warning; declare :error to force intentionality.
        def severity(s = nil)
          return (@severity || :warning) if s.nil?

          unless Finding::SEVERITIES.include?(s)
            raise ArgumentError,
                  "invalid severity #{s.inspect} for #{self}; " \
                  "must be one of #{Finding::SEVERITIES.inspect}"
          end
          @severity = s
        end

        # Optional categorical tag applied by default to every finding this
        # detector emits (per-finding override via {Base#build_finding}).
        # Nil means unlabelled — filter-only utility, no reader-facing tag.
        def quality(q = nil)
          return @quality if q.nil?

          unless Finding::QUALITIES.include?(q)
            raise ArgumentError,
                  "invalid quality #{q.inspect} for #{self}; " \
                  "must be one of #{Finding::QUALITIES.inspect}"
          end
          @quality = q
        end

        def inherited(subclass)
          super
          Detectors.register(subclass)
        end

        # Declares a config-supported option for this detector class. Called at
        # class-body evaluation time; subclasses inherit their ancestors' options
        # via {.config_options}.
        #
        # @param name    [Symbol]      Option key (as it appears in YAML too).
        # @param type    [Symbol]      One of :boolean, :string, :integer, :array, :regexp.
        # @param default [Object]      Fallback if not set in any config source.
        # @param about   [String, nil] Description for `list detectors --verbose`.
        def config_option(name, type:, default:, about: nil)
          @config_options ||= {}
          @config_options[name.to_sym] = {
            name:    name.to_sym,
            type:    type,
            default: default,
            about:   about,
          }.freeze
        end

        # All config options this class understands, INCLUDING inherited ones
        # from Base (:enabled, :exclude_paths) and any intermediate ancestor
        # that declared its own.
        #
        # @return [Hash{Symbol => Hash}] Keyed by option name.
        def config_options
          own = @config_options || {}
          if superclass.respond_to?(:config_options)
            superclass.config_options.merge(own)
          else
            own
          end
        end
      end

      # Universal detector controls, declared once on Base and inherited by
      # every subclass.
      # - :enabled — {Scan#run} skips detectors where option(:enabled) is false.
      # - :exclude_paths — findings whose path matches any pattern are dropped.
      config_option :enabled, type: :boolean, default: true,
        about: 'Enables/disables detector during a scan'
      config_option :exclude_paths, type: :array, default: [],
        about: 'List (of glob patterns) to filter out any finding with a matching path'
      config_option :exclude_tiers, type: :array, default: [],
        about: 'List (of glob patterns) used by tier-iterating detectors to filter out matching Hiera tiers'
      config_option :exclude_facts, type: :array, default: [],
        about: 'List (of glob patterns) to exclude fact/variable names'

      attr_reader :corpus

      def initialize(corpus)
        @corpus = corpus
      end

      def call
        raise NotImplementedError, "#{self.class} must implement #call"
      end

      # Reads the effective value of a declared config option, merging (in
      # ascending precedence): declared default → detectors.defaults section →
      # detectors.<this-key> section. Merge semantics vary by declared type
      # (:array unions, scalars later-wins, :regexp compiles string→Regexp).
      #
      # Memoized per instance — safe to call in a loop within a detector.
      #
      # @param key [Symbol, String] The option name (as declared).
      # @return [Object] The resolved value, type-coerced where needed.
      # @raise [ArgumentError] If the option was not declared on this class.
      def option(key)
        @option_cache ||= {}
        sym = key.to_sym
        return @option_cache[sym] if @option_cache.key?(sym)

        @option_cache[sym] = resolve_option(sym)
      end

      protected

      def build_finding(message:, path: nil, line: nil, meta: {},
                        severity: nil, quality: nil)
        Finding.new(
          key:      self.class.key,
          path:     path,
          line:     line,
          message:  message,
          meta:     meta,
          severity: severity || self.class.severity,
          quality:  quality  || self.class.quality,
        )
      end

      def meta_finding(key:, message:, path: nil, line: nil, meta: {},
                       severity: nil, quality: nil)
        Finding.new(
          key:      key,
          path:     path,
          line:     line,
          message:  message,
          meta:     meta,
          severity: severity || self.class.severity,
          quality:  quality  || self.class.quality,
        )
      end

      def skip_meta_finding(reason:)
        Finding.new(
          key:      "skipped:#{self.class.key}",
          path:     nil,
          line:     nil,
          message:  "detector skipped: #{reason}",
          meta:     {},
          severity: :note,
          quality:  nil,
        )
      end

      private

      def resolve_option(key)
        meta = self.class.config_options.fetch(key) do
          raise ArgumentError, "unknown config option #{key.inspect} for #{self.class}"
        end

        detector_config      = ::Driftless.config.dig('detectors') || {}
        defaults_section     = detector_config['defaults'] || {}
        per_detector_section = detector_config[self.class.key] || {}
        key_str              = key.to_s

        case meta[:type]
        when :array
          combined = Array(meta[:default]).dup
          combined.concat(Array(defaults_section[key_str])) if defaults_section.key?(key_str)
          combined.concat(Array(per_detector_section[key_str])) if per_detector_section.key?(key_str)
          combined.uniq
        when :regexp
          raw = if per_detector_section.key?(key_str)
                  per_detector_section[key_str]
                elsif defaults_section.key?(key_str)
                  defaults_section[key_str]
                else
                  meta[:default]
                end
          raw.is_a?(Regexp) ? raw : Regexp.new(raw.to_s)
        else # :boolean, :string, :integer — precedence: per_detector > defaults > declared
          if per_detector_section.key?(key_str)
            per_detector_section[key_str]
          elsif defaults_section.key?(key_str)
            defaults_section[key_str]
          else
            meta[:default]
          end
        end
      end
    end
  end
end
