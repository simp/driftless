require 'driftless/finding'
require 'driftless/inputs/environment_conf'

module Driftless
  module Inputs
    class ModulepathLoader
      DEFAULT_MODULEPATH_DIRS = %w[site-modules modules].freeze
      DEFAULT_BASEMODULEPATH  = %w[
        /etc/puppetlabs/code/modules
        /opt/puppetlabs/puppet/modules
      ].freeze

      def self.load(repo_dir, basemodulepath: DEFAULT_BASEMODULEPATH)
        new(repo_dir, basemodulepath: basemodulepath).load
      end

      def initialize(repo_dir, basemodulepath: DEFAULT_BASEMODULEPATH)
        @repo_dir       = repo_dir
        @basemodulepath = Array(basemodulepath)
      end

      def load
        env_conf = EnvironmentConf.load(@repo_dir)
        files    = []
        findings = []

        modulepath_entries(env_conf).each do |entry|
          unless File.directory?(entry[:path])
            # Only "explicit" entries (env.conf modulepath, user-supplied
            # basemodulepath) get called out when missing — convention
            # defaults (site-modules, modules, Puppet's ./modules) are widely
            # optional and would be noise.
            if entry[:source] == :explicit
              findings << finding(
                'hierarchy:absolute-modulepath-missing',
                entry[:path],
                "modulepath component not present: #{entry[:path]}",
              )
            end
            next
          end
          files.concat(Dir[File.join(entry[:path], '*/manifests/**/*.pp')])
        end

        manifest_target = resolve_manifest_target(env_conf)
        files.concat(env_manifest_files(manifest_target)) if manifest_target

        [files.sort.uniq, findings]
      end

      private

      # Returns [{path:, source:}, ...] in modulepath order. `source` is
      # :explicit (declared in env.conf or user-supplied basemodulepath) or
      # :convention (driftless/Puppet defaults).
      def modulepath_entries(env_conf)
        if env_conf.modulepath
          env_conf.modulepath.flat_map { |e| entries_for(e, source: :explicit) }
        elsif env_conf.exists?
          # env.conf present but no modulepath= line → Puppet's default.
          entries_for('./modules', source: :convention) +
            @basemodulepath.map { |p| { path: p, source: :explicit } }
        else
          # No env.conf → driftless legacy fallback (site-modules is an r10k
          # convention, not a Puppet default).
          DEFAULT_MODULEPATH_DIRS.flat_map { |d| entries_for(d, source: :convention) } +
            @basemodulepath.map { |p| { path: p, source: :explicit } }
        end
      end

      def entries_for(token, source:)
        if token == '$basemodulepath'
          @basemodulepath.map { |p| { path: p, source: source } }
        elsif token.start_with?('/')
          [{ path: token, source: source }]
        else
          [{ path: File.expand_path(token, @repo_dir), source: source }]
        end
      end

      def resolve_manifest_target(env_conf)
        raw = env_conf.manifest
        return File.join(@repo_dir, 'manifests') if raw.nil? || raw.empty?
        raw.start_with?('/') ? raw : File.expand_path(raw, @repo_dir)
      end

      def env_manifest_files(target)
        if File.file?(target)
          [target]
        elsif File.directory?(target)
          Dir[File.join(target, '**', '*.pp')]
        else
          []
        end
      end

      def finding(key, path, message)
        Finding.new(key: key, path: path, line: nil, message: message, meta: {})
      end
    end
  end
end
