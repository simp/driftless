require 'yaml'

module Driftless
  # Layered driftless.yaml config loader. Discovers config from the standard
  # search chain (system → user → project — CWD-only, no parent walk), merges
  # with later-wins-for-scalars and union-for-arrays semantics, returns a
  # hash-like accessor.
  #
  # `--config=PATH` replaces the entire chain (this file is the only source).
  # `--no-config` skips all files (returns an empty config).
  #
  # @!attribute [r] sources
  #   @return [Array<String>] Absolute paths of every file that actually
  #     contributed to the merged config, in load order (lowest to highest
  #     precedence). Useful for debugging ("which file set this?").
  class Config
    SYSTEM_PATH        = '/etc/driftless/config.yaml'.freeze
    PROJECT_FILENAME   = 'driftless.yaml'.freeze
    XDG_CONFIG_DEFAULT = '~/.config'.freeze

    PERMITTED_YAML_CLASSES = [
      Hash, Array, String, Integer, Float, TrueClass, FalseClass, NilClass,
    ].freeze

    # Loads the merged config from the discovered sources.
    #
    # @param config_path [String, nil] If set, REPLACES the search chain
    #   entirely — this file becomes the only source. Nil means normal
    #   layered discovery (system → user → project).
    # @param no_config [Boolean] If true, skip all files; return empty config.
    # @return [Config] Loaded config instance.
    def self.load(config_path: nil, no_config: false)
      sources = discover_sources(config_path: config_path, no_config: no_config)
      merged  = sources.reduce({}) { |acc, (_path, data)| deep_merge(acc, data) }
      new(merged: merged, sources: sources.map(&:first))
    end

    # The static search chain, lowest to highest precedence. Doesn't check
    # what exists on disk; call {.discover_sources} for that.
    #
    # @return [Array<String>] Absolute paths in load order.
    def self.search_chain
      [SYSTEM_PATH, user_path, project_path]
    end

    # The user-scoped config path, honoring $XDG_CONFIG_HOME.
    #
    # @return [String] Absolute path.
    def self.user_path
      base = ENV['XDG_CONFIG_HOME']
      base = File.expand_path(XDG_CONFIG_DEFAULT) if base.nil? || base.empty?
      File.join(base, 'driftless', 'config.yaml')
    end

    # The project-scoped config path (CWD-only, no parent walk).
    #
    # @return [String] Absolute path.
    def self.project_path
      File.join(Dir.pwd, PROJECT_FILENAME)
    end

    # Returns the sources that actually exist on disk (or just the
    # explicit --config path). Each entry is [absolute_path, parsed_hash].
    #
    # @return [Array<[String, Hash]>] In load order.
    def self.discover_sources(config_path:, no_config:)
      return [] if no_config

      if config_path
        # Explicit --config=PATH: strict. Missing file is a user error, not
        # a silent no-op — the user said "use THIS file" and we can't.
        path = File.expand_path(config_path)
        raise ConfigLoadError, "#{path}: file not found" unless File.file?(path)
        [[path, load_file(path)]]
      else
        # Implicit search chain: lenient. Absent files are the common case
        # (most users won't have all three).
        search_chain.filter_map do |path|
          next unless File.file?(path)
          [path, load_file(path)]
        end
      end
    end

    # Reads and parses one config file. Empty files are treated as `{}`.
    #
    # @raise [ConfigLoadError] if the file is unreadable or contains invalid YAML.
    def self.load_file(path)
      raw    = File.read(path)
      parsed = YAML.safe_load(raw, permitted_classes: PERMITTED_YAML_CLASSES, aliases: false, filename: path)
      case parsed
      when nil  then {}   # empty file
      when Hash then parsed
      else
        raise ConfigLoadError, "#{path}: top-level YAML must be a mapping, got #{parsed.class}"
      end
    rescue Psych::SyntaxError => e
      raise ConfigLoadError, "#{path}: invalid YAML — #{e.message}"
    rescue Errno::ENOENT
      raise ConfigLoadError, "#{path}: file not found"
    end

    # Deep-merge two hashes:
    # - Nested hashes: recursively merged.
    # - Arrays: unioned (a + b, deduplicated).
    # - Scalars: later wins (b overrides a).
    def self.deep_merge(a, b)
      a.merge(b) do |_key, av, bv|
        if av.is_a?(Hash) && bv.is_a?(Hash)
          deep_merge(av, bv)
        elsif av.is_a?(Array) && bv.is_a?(Array)
          (av + bv).uniq
        else
          bv
        end
      end
    end

    attr_reader :sources

    def initialize(merged: {}, sources: [])
      @merged  = deep_freeze(merged)
      @sources = sources.freeze
    end

    # Hash-like access.
    def [](key);    @merged[key];       end
    def dig(*keys); @merged.dig(*keys); end
    def to_h;       @merged;            end
    def empty?;     @merged.empty?;     end
    def fetch(key, *args, &block); @merged.fetch(key, *args, &block); end

    private

    def deep_freeze(obj)
      case obj
      when Hash  then obj.each_value { |v| deep_freeze(v) }; obj.freeze
      when Array then obj.each       { |v| deep_freeze(v) }; obj.freeze
      else            obj.freeze
      end
    end
  end

  # Raised for config load failures (missing file with --config=PATH,
  # invalid YAML, non-mapping top-level, etc).
  class ConfigLoadError < StandardError; end

  # Module-level accessor for the process-wide loaded config. Matches the
  # {Driftless.logger} pattern: set once at startup by Root's config-load
  # step; accessed by detectors and other consumers.
  class << self
    attr_writer :config

    def config
      @config ||= Config.new
    end
  end
end
