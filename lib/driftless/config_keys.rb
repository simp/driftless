module Driftless
  # Registry of config keys, populated at class-definition time by the classes
  # that own them. {ConfigValidator} and `driftless config new` both read it,
  # so neither keeps a list of its own.
  #
  # Every declaring class must be loaded before the registry is consulted.
  # `bin/driftless` requires `driftless` and the CLI tree before Root validates.
  module ConfigKeys
    Key = Struct.new(:path, :subsystem, :name, :type, :default, :example, :about, :owner, :because,
                     keyword_init: true) do
      # Withheld keys are declared so the validator can reject them by name and
      # say why, rather than reporting them as unknown.
      def withheld?
        !because.nil?
      end

      # What to show in a generated config. Keys whose real default is computed
      # at runtime declare an `example:` instead.
      def sample
        default.nil? ? example : default
      end
    end

    class << self
      def declare(key)
        prior = registry[key.path]
        if prior && prior.owner != key.owner
          raise "config key collision on #{key.path}: claimed by both #{prior.owner} and #{key.owner}"
        end
        registry[key.path] = key
      end

      def registry
        @registry ||= {}
      end

      def all
        registry.values
      end

      def [](path)
        registry[path]
      end

      def subsystems
        all.map(&:subsystem).uniq
      end

      def for_subsystem(name)
        all.select { |k| k.subsystem == name.to_s }
      end

      def settable(name)
        for_subsystem(name).reject(&:withheld?)
      end

      def withheld
        all.select(&:withheld?)
      end
    end

    # Extended by any class that owns config keys.
    module DSL
      def config_key(path, type:, default: nil, example: nil, about: nil)
        ConfigKeys.declare(ConfigKeys.send(:build, path, self, type: type, default: default,
                                                              example: example, about: about))
      end

      # Declares a key that must NOT be settable, with the reason surfaced when
      # someone tries. Accepts several paths when the key has more than one
      # plausible spelling.
      def withheld_key(paths, because:)
        Array(paths).each do |path|
          ConfigKeys.declare(ConfigKeys.send(:build, path, self, because: because))
        end
      end
    end

    def self.build(path, owner, type: nil, default: nil, example: nil, about: nil, because: nil)
      subsystem, name = path.to_s.split('.', 2)
      raise ArgumentError, "config key #{path.inspect} must be 'subsystem.key'" if name.nil?

      Key.new(path: path.to_s, subsystem: subsystem, name: name, type: type, default: default,
              example: example, about: about, owner: owner, because: because)
    end
    private_class_method :build
  end
end
