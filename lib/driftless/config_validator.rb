require 'set'

require 'driftless/config'
require 'driftless/detectors'
require 'driftless/detectors/base'

module Driftless
  # Strict validator for a loaded {Driftless::Config}. Rejects unknown
  # top-level subsystem keys, unknown detector keys under `detectors:`, and
  # unknown per-detector options. Uses stdlib {DidYouMean} for suggestions
  # when a typo has a close match.
  #
  # Called by {Driftless::CLI::Root#after_own_parse} after config load;
  # failures surface as `config error: ...` on stderr + exit 2.
  class ConfigValidator
    KNOWN_SUBSYSTEMS   = %w[detectors puppet output scan logging].freeze
    KNOWN_PUPPET_KEYS  = %w[environments allow_missing_envs].freeze

    def initialize(config)
      @config = config
    end

    def validate!
      check_top_level_keys
      check_detector_keys
      check_detector_options
      check_puppet_keys
    end

    private

    def check_top_level_keys
      unknown = @config.to_h.keys - KNOWN_SUBSYSTEMS
      return if unknown.empty?

      first = unknown.first
      msg   = "unknown top-level config key: #{first.inspect}"
      msg +=
        if (sug = suggest(first, KNOWN_SUBSYSTEMS))
          " (did you mean #{sug.inspect}?)"
        else
          " (known: #{KNOWN_SUBSYSTEMS.join(', ')})"
        end
      raise ConfigValidationError, msg
    end

    def check_detector_keys
      detectors_section = @config['detectors']
      return unless detectors_section.is_a?(Hash)

      known = Set.new(['defaults'])
      Driftless::Detectors.registry.each { |k| known.add(k.key) }

      detectors_section.keys.each do |section_key|
        next if known.include?(section_key)

        msg = "unknown detector key in config: #{section_key.inspect}"
        if (sug = suggest(section_key, known.to_a))
          msg += " (did you mean #{sug.inspect}?)"
        end
        raise ConfigValidationError, msg
      end
    end

    def check_detector_options
      detectors_section = @config['detectors']
      return unless detectors_section.is_a?(Hash)

      detectors_section.each do |section_key, section_body|
        next unless section_body.is_a?(Hash)

        known_options =
          if section_key == 'defaults'
            # defaults: may hold any option declared by any detector (universal
            # options from Base included, per-detector options too — the merge
            # only applies where the detector actually declares the option).
            all_declared_options
          else
            klass = Driftless::Detectors.find(section_key)
            next unless klass   # already flagged by check_detector_keys
            klass.config_options.keys.map(&:to_s).to_set
          end

        section_body.keys.each do |opt|
          next if known_options.include?(opt)

          msg = "unknown option in detectors.#{section_key}: #{opt.inspect}"
          if (sug = suggest(opt, known_options.to_a))
            msg += " (did you mean #{sug.inspect}?)"
          end
          raise ConfigValidationError, msg
        end
      end
    end

    def all_declared_options
      set = Set.new
      # Universal options on Base (also inherited by all subclasses, but including
      # Base explicitly guarantees they're always accepted in defaults:).
      Driftless::Detectors::Base.config_options.keys.each { |name| set << name.to_s }
      Driftless::Detectors.registry.each do |k|
        k.config_options.keys.each { |name| set << name.to_s }
      end
      set
    end

    def check_puppet_keys
      puppet_section = @config['puppet']
      return unless puppet_section.is_a?(Hash)

      puppet_section.keys.each do |key|
        next if KNOWN_PUPPET_KEYS.include?(key)

        msg = "unknown puppet config key: #{key.inspect}"
        msg +=
          if (sug = suggest(key, KNOWN_PUPPET_KEYS))
            " (did you mean #{sug.inspect}?)"
          else
            " (known: #{KNOWN_PUPPET_KEYS.join(', ')})"
          end
        raise ConfigValidationError, msg
      end
    end

    def suggest(input, candidates)
      require 'did_you_mean'
      DidYouMean::SpellChecker.new(dictionary: candidates).correct(input.to_s).first
    rescue LoadError
      nil
    end
  end

  # Raised by {ConfigValidator} for any strict-check violation.
  class ConfigValidationError < StandardError; end
end
