require 'set'

require 'driftless/config'
require 'driftless/config_keys'
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
    # Listed explicitly because its keys are detector names from the registry
    # rather than declared config keys.
    DETECTORS_SUBSYSTEM = 'detectors'.freeze

    # Keys that moved between subsystems. The old section does not validate its
    # own keys, so without this a stale key is silently ignored.
    MOVED_KEYS = {
      %w[scan incoming_dir] => 'reports.incoming_dir',
    }.freeze

    def initialize(config)
      @config = config
    end

    def validate!
      check_top_level_keys
      check_moved_keys
      check_withheld_keys
      check_subsystem_keys
      check_detector_keys
      check_detector_options
    end

    # Every subsystem some class has declared a key for, plus detectors.
    def self.known_subsystems
      (ConfigKeys.subsystems + [DETECTORS_SUBSYSTEM]).uniq.sort
    end

    private

    def check_top_level_keys
      known   = self.class.known_subsystems
      unknown = @config.to_h.keys - known
      return if unknown.empty?

      first = unknown.first
      msg   = "unknown top-level config key: #{first.inspect}"
      msg +=
        if (sug = suggest(first, known))
          " (did you mean #{sug.inspect}?)"
        else
          " (known: #{known.join(', ')})"
        end
      raise ConfigValidationError, msg
    end

    def check_withheld_keys
      ConfigKeys.withheld.each do |key|
        next if @config.dig(key.subsystem, key.name).nil?
        raise ConfigValidationError, "#{key.path} cannot be set in config: #{key.because}"
      end
    end

    # Applies to every subsystem except detectors, whose keys are detector names.
    def check_subsystem_keys
      @config.to_h.each do |subsystem, body|
        next if subsystem == DETECTORS_SUBSYSTEM
        next unless body.is_a?(Hash)

        known = ConfigKeys.settable(subsystem).map(&:name)
        body.each_key do |key|
          next if known.include?(key)

          msg = "unknown #{subsystem} config key: #{key.inspect}"
          msg +=
            if (sug = suggest(key, known))
              " (did you mean #{sug.inspect}?)"
            else
              " (known: #{known.join(', ')})"
            end
          raise ConfigValidationError, msg
        end
      end
    end

    def check_moved_keys
      MOVED_KEYS.each do |(section, key), destination|
        next if @config.dig(section, key).nil?
        raise ConfigValidationError,
              "#{section}.#{key} has moved to #{destination}"
      end
    end

    def check_detector_keys
      detectors_section = @config['detectors']
      return unless detectors_section.is_a?(Hash)

      known = Set.new(['defaults'] + ConfigKeys.settable(DETECTORS_SUBSYSTEM).map(&:name))
      Driftless::Detectors.registry.each { |k| known.add(k.key) }

      detectors_section.each_key do |section_key|
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

        section_body.each_key do |opt|
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
      Driftless::Detectors::Base.config_options.each_key { |name| set << name.to_s }
      Driftless::Detectors.registry.each do |k|
        k.config_options.each_key { |name| set << name.to_s }
      end
      set
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
