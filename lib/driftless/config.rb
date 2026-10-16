require 'yaml'

module Driftless
  # Layered driftless.yaml config loader.
  #
  # - Discovers config (system < user < project)
  # - Project is CWD-only, no parent walk
  # - Merging logic:
  #   - scalars: latest one wins
  #   - arrays:  union
  #
  # `--config=PATH` replaces the entire chain (this file is the only source).
  # `--no-config` skips all files (returns an empty config).
  #
  # Any file may name further files under `.include:`; each is a layer
  # merged before the file naming it, so the includer wins on scalars and
  # lists union, and includes nest. A value tagged `!reference [key, ...]`
  # is replaced by the merged config's value at that path, after every
  # file has merged, so one file may point at a value another holds.
  #
  # @!attribute [r] sources
  #   @return [Array<String>] Absolute paths of every file that actually
  #     contributed to the merged config, in load order (lowest to highest
  #     precedence). Useful for debugging ("which file set this?").
  class Config
    SYSTEM_PATH        = '/etc/puppetlabs/driftless/config.yaml'.freeze
    PROJECT_FILENAME   = 'driftless.yaml'.freeze
    XDG_CONFIG_DEFAULT = '~/.config'.freeze

    # The key under which a file lists the files to merge before it,
    # relative to its own directory. Dropped from the merged config.
    INCLUDE_KEY = '.include'.freeze

    # The tag on a list of keys that stands for the merged config's value
    # at that path; an unquoted integer indexes a list.
    REFERENCE_TAG = '!reference'.freeze

    # What a tagged node becomes until the merge is complete: this prefix
    # and its index in the references read during the load.
    PLACEHOLDER = "\u0000driftless:ref:".freeze

    PERMITTED_YAML_CLASSES = [
      Hash, Array, String, Integer, Float, TrueClass, FalseClass, NilClass,
    ].freeze

    # Loads the merged config from the discovered sources
    #
    # @param config_path [String, nil] If set, REPLACES the search chain
    #   entirely — this file becomes the only source. Nil means normal
    #   layered discovery
    # @param no_config [Boolean] If true, skip all files + return empty config
    # @return [Config] Loaded config instance.
    def self.load(config_path: nil, no_config: false)
      references = []
      sources = discover_sources(config_path: config_path, no_config: no_config, references: references)
      merged  = sources.reduce({}) { |acc, (_path, data)| deep_merge(acc, data) }
      merged  = flatten_lists(resolve_references(merged, references))
      new(merged: merged, sources: sources.map(&:first))
    end

    # The static search chain, lowest to highest precedence
    #
    # @return [Array<String>] Absolute paths in load order
    def self.search_chain
      [SYSTEM_PATH, user_path, project_path]
    end

    # The user-scoped config path, honoring $XDG_CONFIG_HOME.
    #
    # @return [String] Absolute path
    def self.user_path
      base = ENV['XDG_CONFIG_HOME']
      base = File.expand_path(XDG_CONFIG_DEFAULT) if base.nil? || base.empty?
      File.join(base, 'driftless', 'config.yaml')
    end

    # The project-scoped config path (CWD-only, no parent walk).
    #
    # @return [String] Absolute path:.
    def self.project_path
      File.join(Dir.pwd, PROJECT_FILENAME)
    end

    # Returns the sources that actually exist on disk (or just the
    # explicit --config path). Each entry is [absolute_path, parsed_hash].
    #
    # @param references [Array<Hash>] filled with each `!reference` read,
    #   in placeholder order
    # @return [Array<[String, Hash]>] In load order.
    def self.discover_sources(config_path:, no_config:, references: [])
      return [] if no_config

      if config_path
        # Explicit --config=PATH: strict. Missing file is a user error, not
        # a silent no-op — the user said "use THIS file" and we can't.
        path = File.expand_path(config_path)
        raise ConfigLoadError, "#{path}: file not found" unless File.file?(path)
        load_with_includes(path, [], references)
      else
        # Implicit search chain: lenient. Absent files are the common case
        # (most users won't have all three).
        search_chain.flat_map do |path|
          File.file?(path) ? load_with_includes(path, [], references) : []
        end
      end
    end

    # One file and, before it, every file its `.include` names, each with
    # their own includes first: `[[path, hash], ...]` in merge order.
    #
    # @param path [String] absolute
    # @param chain [Array<String>] the files whose includes led here
    # @raise [ConfigLoadError] on a file including itself through any chain,
    #   or naming a file that is not there
    def self.load_with_includes(path, chain, references = [])
      if chain.include?(path)
        raise ConfigLoadError, "#{chain.last}: #{INCLUDE_KEY} loops back to #{path} (via #{chain.join(' -> ')})"
      end

      data     = load_file(path, references: references)
      includes = data.delete(INCLUDE_KEY)
      unless includes.nil? || includes.is_a?(Array) || includes.is_a?(String)
        raise ConfigLoadError, "#{path}: #{INCLUDE_KEY} must be a path or a list of paths, got #{includes.class}"
      end

      included = Array(includes).flat_map do |rel|
        target = File.expand_path(rel.to_s, File.dirname(path))
        raise ConfigLoadError, "#{path}: #{INCLUDE_KEY} names #{target}, which is not there" unless File.file?(target)

        load_with_includes(target, chain + [path], references)
      end
      included + [[path, data]]
    end

    # Reads and parses one config file. Empty files are treated as `{}`;
    # anchors, aliases, and merge keys are resolved. Each `!reference` is
    # recorded and left as a placeholder for {resolve_references}.
    #
    # @param references [Array<Hash>] appended to, one per tagged node
    # @raise [ConfigLoadError] if the file is unreadable or contains invalid YAML.
    def self.load_file(path, references: [])
      stream = Psych.parse_stream(File.read(path), filename: path)
      docs   = stream.children
      raise ConfigLoadError, "#{path}: holds #{docs.size} YAML documents, expected one" if docs.size > 1
      return {} if docs.empty?

      mark_references(docs.first.root, docs.first, 0, path, references)
      parsed = YAML.safe_load(stream.to_yaml, permitted_classes: PERMITTED_YAML_CLASSES, aliases: true, filename: path)
      case parsed
      when nil  then {}   # empty file
      when Hash then parsed
      else
        raise ConfigLoadError, "#{path}: top-level YAML must be a mapping, got #{parsed.class}"
      end
    rescue Psych::SyntaxError, Psych::BadAlias, Psych::DisallowedClass => e
      raise ConfigLoadError, "#{path}: invalid YAML — #{e.message}"
    rescue Errno::ENOENT
      raise ConfigLoadError, "#{path}: file not found"
    end

    # Swaps every node tagged `!reference` under `node` for a placeholder,
    # recording its keys and position.
    #
    # @raise [ConfigLoadError] on a tagged node that is not a list of keys
    def self.mark_references(node, parent, index, path, references)
      if node.tag == REFERENCE_TAG
        unless node.is_a?(Psych::Nodes::Sequence) && node.children.any? && node.children.all?(Psych::Nodes::Scalar)
          raise ConfigLoadError, "#{path}:#{node.start_line + 1}: #{REFERENCE_TAG} takes a list of keys, like [section, key]"
        end

        keys = node.children.map { |c| (!c.quoted && c.value.match?(/\A\d+\z/)) ? c.value.to_i : c.value }
        references << { keys: keys, file: path, line: node.start_line + 1 }
        parent.children[index] = Psych::Nodes::Scalar.new("#{PLACEHOLDER}#{references.size - 1}")
        return
      end

      node.children&.each_with_index { |child, i| mark_references(child, node, i, path, references) }
    end

    # The merged config with every placeholder replaced by a copy of the
    # value its reference names, references inside that value included.
    #
    # @raise [ConfigLoadError] on a path with nothing at it, or a reference
    #   that reaches itself
    def self.resolve_references(merged, references, resolving = [])
      return merged if references.empty?

      substitute(merged, merged, references, resolving)
    end

    def self.substitute(value, merged, references, resolving)
      case value
      when Hash  then value.to_h { |k, v| [k, substitute(v, merged, references, resolving)] }
      when Array then value.map { |v| substitute(v, merged, references, resolving) }
      when String
        return value unless value.start_with?(PLACEHOLDER)

        resolve_one(references.fetch(value.delete_prefix(PLACEHOLDER).to_i), merged, references, resolving)
      else value
      end
    end

    def self.resolve_one(ref, merged, references, resolving)
      where = "#{ref[:file]}:#{ref[:line]}"
      if resolving.include?(ref)
        chain = resolving.map { |r| "#{r[:file]}:#{r[:line]}" }.join(', ')
        raise ConfigLoadError, "#{where}: #{REFERENCE_TAG} #{ref[:keys].inspect} reaches itself (via #{chain})"
      end

      target =
        begin
          merged.dig(*ref[:keys])
        rescue TypeError
          nil
        end
      raise ConfigLoadError, "#{where}: #{REFERENCE_TAG} #{ref[:keys].inspect}: nothing at that path in the merged config" if target.nil?

      substitute(target, merged, references, resolving + [ref])
    end

    # Every list with any list inside it spliced flat, one level per pass
    # until none remain: `- *shared` where the anchor is a list, or a
    # `!reference` to one, nests it, and no setting takes a list of lists.
    def self.flatten_lists(value)
      case value
      when Hash  then value.to_h { |k, v| [k, flatten_lists(v)] }
      when Array then value.flatten.map { |v| flatten_lists(v) }
      else value
      end
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
    # rubocop:disable Style/SingleLineMethods -- These are concise and legible
    def [](key);    @merged[key];       end
    def dig(*keys); @merged.dig(*keys); end
    def to_h;       @merged;            end
    def empty?;     @merged.empty?;     end
    def fetch(key, *args, &block); @merged.fetch(key, *args, &block); end
    # rubocop:enable Style/SingleLineMethods

    private

    def deep_freeze(obj)
      case obj
      when Hash  then obj.each_value { |v| deep_freeze(v) }
      when Array then obj.each       { |v| deep_freeze(v) }
      end
      obj.freeze
    end
  end

  # Raised for config load failures (missing file with --config=PATH,
  # invalid YAML, non-mapping top-level, etc)
  class ConfigLoadError < StandardError; end

  # Module-level accessor for the process-wide loaded config. Matches the
  # {Driftless.logger} pattern: set once at startup by Root's config-load
  # step; accessed by detectors and other consumers
  class << self
    attr_writer :config

    def config
      @config ||= Config.new
    end
  end
end
