module Driftless
  module Inputs
    # Reads the control repo's Puppetfile: which module goes where, from which
    # git remote, at which ref.
    #
    # The Puppetfile is Ruby, evaluated with `instance_eval` against a DSL
    # object that accepts the r10k declarations (`mod`, `forge`, `moduledir`)
    # and nothing else. This runs repo-supplied code, as r10k itself does.
    class Puppetfile
      class Error < StandardError; end

      FILENAME          = 'Puppetfile'.freeze
      DEFAULT_MODULEDIR = 'modules'.freeze

      # A `mod` declaration, resolved to where r10k deploys it.
      #
      # @!attribute [r] name
      #   @return [String] as declared, e.g. "puppetlabs-stdlib"
      # @!attribute [r] path
      #   @return [String] repo-relative directory r10k deploys the module
      #     into: the `moduledir` in force or the entry's `:install_path`,
      #     joined with the name's last segment ("modules/stdlib")
      # @!attribute [r] git
      #   @return [String, nil] the `:git` remote; nil for a Forge module
      # @!attribute [r] ref
      #   @return [String, Symbol, nil] the declared ref — r10k's precedence:
      #     `:ref`, `:tag`, `:commit`, then `:branch`. `:control_branch`
      #     stays the Symbol for the caller to resolve. nil when none is
      #     declared.
      # @!attribute [r] ref_type
      #   @return [String, nil] "ref", "tag", "commit", or "branch" — which
      #     option supplied ref; a 40-hex `:ref` reads as "commit"
      Module = Data.define(:name, :path, :git, :ref, :ref_type)

      # What {Puppetfile.load} returns.
      #
      # @!attribute [r] exists
      #   @return [Boolean] whether the file was there
      # @!attribute [r] modules
      #   @return [Array<Module>] in declaration order; empty on error
      # @!attribute [r] error
      #   @return [String, nil] why the file could not be evaluated
      Result = Data.define(:exists, :modules, :error) do
        def exists?
          exists
        end
      end

      def self.load(repo_dir)
        new(repo_dir).load
      end

      def initialize(repo_dir)
        @path      = File.join(repo_dir, FILENAME)
        @moduledir = DEFAULT_MODULEDIR
        @modules   = []
      end

      # @return [Result]
      def load
        return Result.new(exists: false, modules: [], error: nil) unless File.file?(@path)

        DSL.new(self).instance_eval(File.read(@path), @path)
        Result.new(exists: true, modules: @modules, error: nil)
      rescue Error, StandardError, ScriptError => e
        Result.new(exists: true, modules: [], error: "#{e.class}: #{e.message}")
      end

      # Called by the DSL for each declaration.
      def add_module(name, args)
        opts = args.is_a?(Hash) ? args.transform_keys(&:to_sym) : {}
        install_dir = opts[:install_path] || @moduledir
        ref, ref_type = declared_ref(opts)
        @modules << Module.new(
          name:     name.to_s,
          path:     File.join(install_dir.to_s.sub(%r{\A\./}, ''), name.to_s.split(%r{[-/]}).last),
          git:      opts[:git]&.to_s,
          ref:      ref,
          ref_type: ref_type,
        )
      end

      def moduledir=(location)
        @moduledir = location.to_s
      end

      private

      # @return [Array(String|Symbol|nil, String|nil)] ref and its type
      def declared_ref(opts)
        return [opts[:ref].to_s, opts[:ref].to_s.match?(/\A[0-9a-f]{40}\z/) ? 'commit' : 'ref'] if opts[:ref]
        return [opts[:tag].to_s, 'tag']       if opts[:tag]
        return [opts[:commit].to_s, 'commit'] if opts[:commit]
        if opts[:branch]
          branch = opts[:branch]
          return [(branch == :control_branch) ? branch : branch.to_s, 'branch']
        end
        [nil, nil]
      end

      # The receiver a Puppetfile is evaluated against.
      class DSL
        def initialize(reader)
          @reader = reader
        end

        def mod(name, args = nil)
          @reader.add_module(name, args)
        end

        def forge(_location); end

        def moduledir(location)
          @reader.moduledir = location
        end

        def method_missing(name, *_args)
          raise Error, "unrecognized Puppetfile declaration '#{name}'"
        end

        def respond_to_missing?(_name, _include_private = false)
          false
        end
      end
    end
  end
end
