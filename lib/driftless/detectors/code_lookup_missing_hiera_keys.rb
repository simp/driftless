require 'set'

require 'driftless/detectors/base'
require 'driftless/role_profile'

module Driftless
  module Detectors
    class CodeLookupMissingHieraKeys < Base
      key      'code:lookup-missing-hiera-keys'
      severity :error
      quality  :wrong
      about '`lookup()` calls for keys not defined anywhere in Hiera'

      # Matches any file under a Puppet module directory (modules/ or
      # site-modules/), capturing the module name. Includes .pp AND .epp
      # AND any other file inside the module tree. Greedy `.*` at the start
      # implicitly resolves nested cases (a/modules/b/modules/c/x.pp → c).
      MODULE_FILE_RE = %r{/(?:site-)?modules/([^/]+)/}.freeze

      # Matches Puppet manifest files under a module and captures both the
      # module name AND the subpath inside manifests/, for class-name
      # derivation via Puppet's autoloading convention.
      CLASS_PATH_RE = %r{/(?:site-)?modules/([^/]+)/manifests/(.*)\.pp\z}.freeze

      config_option :ignore_lookups_with_defaults, type: :boolean, default: false,
        about: 'Skip flagging lookup() calls that provide an explicit default value'

      def call
        defined_keys = collect_defined_keys
        findings     = []

        corpus.code_lookup_calls.each do |lc|
          next if defined_keys.include?(lc.key)
          next if lc.has_default && option(:ignore_lookups_with_defaults)
          next if skip_as_module_local?(lc)

          findings << build_finding(
            path:    lc.file,
            line:    lc.line,
            message: "#{lc.key.inspect} is " \
                     'not defined in any Hiera file',
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
        return false if RoleProfile.role?(class_name) || RoleProfile.profile?(class_name)

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
        module_name = m[1]
        subpath = m[2]
        return module_name if subpath == 'init'
        ([module_name] + subpath.split('/')).join('::')
      end
    end
  end
end
