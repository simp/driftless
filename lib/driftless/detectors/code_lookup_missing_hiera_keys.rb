require 'set'

require 'driftless/detectors/base'

module Driftless
  module Detectors
    class CodeLookupMissingHieraKeys < Base
      key 'code:lookup-missing-hiera-keys'
      about 'Explicit lookup() calls searching for keys not defined anywhere in Hiera'

      # Matches any file under a Puppet module directory (modules/ or
      # site-modules/), capturing the module name. Includes .pp AND .epp
      # AND any other file inside the module tree. Greedy `.*` at the start
      # implicitly resolves nested cases (a/modules/b/modules/c/x.pp → c).
      MODULE_FILE_RE = %r{/(?:site-)?modules/([^/]+)/}.freeze

      # Matches Puppet manifest files under a module and captures both the
      # module name AND the subpath inside manifests/, for class-name
      # derivation via Puppet's autoloading convention.
      CLASS_PATH_RE = %r{/(?:site-)?modules/([^/]+)/manifests/(.*)\.pp\z}.freeze

      # Defaults for role/profile class detection. Sites with non-standard
      # naming (e.g. baseline::role::*, baseline::profile::*) will override
      # these via config in Phase 3. Convention adopted from onceover's
      # role_regex / profile_regex config keys.
      ROLE_REGEX_DEFAULT    = /\Arole::/.freeze
      PROFILE_REGEX_DEFAULT = /\Aprofile::/.freeze

      def call
        defined_keys = collect_defined_keys
        findings     = []

        corpus.code_lookup_calls.each do |lc|
          next if defined_keys.include?(lc.key)
          next if skip_as_module_local?(lc)

          findings << build_finding(
            path:    lc.file,
            line:    lc.line,
            message: "lookup call for #{lc.key.inspect} but no top-level key with " \
                     'that name is defined in any Hiera data file',
            meta:    { lookup_key: lc.key, has_default: lc.has_default },
          )
        end
        findings
      end

      private

      def collect_defined_keys
        keys = Set.new
        corpus.data_files.each { |df| keys.merge(df.top_level_keys.keys) }
        keys
      end

      # Determines whether a lookup call is inside a module doing its own
      # namespace's lookups — the case where the module's own Hiera data
      # (outside driftless's control-repo scope) is expected to resolve it.
      # Role/profile classes are exempt: they're arranged in module layout
      # but conventionally use control-repo Hiera, so their lookups get
      # checked normally.
      def skip_as_module_local?(lc)
        return false unless lc.file
        m = MODULE_FILE_RE.match(lc.file)
        return false unless m
        module_name = m[1]

        class_name = derive_class_name(lc.file)
        return false if class_name && (role_regex.match?(class_name) || profile_regex.match?(class_name))

        key_ns = lc.key.split('::', 2).first
        module_name == key_ns
      end

      # Puppet autoloading convention:
      #   <modulepath>/<module>/manifests/init.pp     → <module>
      #   <modulepath>/<module>/manifests/foo.pp      → <module>::foo
      #   <modulepath>/<module>/manifests/foo/bar.pp  → <module>::foo::bar
      # Returns nil for paths outside this pattern (EPP templates, etc.).
      def derive_class_name(path)
        m = CLASS_PATH_RE.match(path)
        return nil unless m
        module_name, subpath = m[1], m[2]
        return module_name if subpath == 'init'
        ([module_name] + subpath.split('/')).join('::')
      end

      def role_regex;    ROLE_REGEX_DEFAULT;    end
      def profile_regex; PROFILE_REGEX_DEFAULT; end
    end
  end
end
