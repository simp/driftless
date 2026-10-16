require 'driftless/role_profile'

module Driftless
  # One Hiera lookup found in the codebase, from a `.pp`/`.epp` function call
  # or a `%{...}` interpolation in a data file.
  #
  # @!attribute [rw] key
  #   @return [String] the Hiera key looked up; always a literal
  # @!attribute [rw] function
  #   @return [String] which function made the call: `lookup`, `hiera`, or
  #     (data files only) `alias`
  # @!attribute [rw] file
  #   @return [String] path of the file holding the call
  # @!attribute [rw] line
  #   @return [Integer] 1-indexed line of the call
  # @!attribute [rw] has_default
  #   @return [Boolean] whether the call supplies a default value. Always
  #     false for data-file interpolations, whose syntax cannot carry one
  LookupCall = Struct.new(
    :key, :function, :file, :line, :has_default,
    keyword_init: true,
  ) do
    alias_method :has_default?, :has_default

    # Matches any file under a Puppet module directory (modules/ or
    # site-modules/), capturing the module name. Includes .pp AND .epp
    # AND any other file inside the module tree. Greedy `.*` at the start
    # implicitly resolves nested cases (a/modules/b/modules/c/x.pp → c).
    MODULE_FILE_RE = %r{/(?:site-)?modules/([^/]+)/}.freeze

    # Matches Puppet manifest files under a module and captures both the
    # module name AND the subpath inside manifests/, for class-name
    # derivation via Puppet's autoloading convention.
    CLASS_PATH_RE = %r{/(?:site-)?modules/([^/]+)/manifests/(.*)\.pp\z}.freeze

    # Whether the call is inside a module and for that module's own
    # namespace: the module reading its own data, which is its concern,
    # not the control repo's. Role and profile classes are arranged in
    # module layout but are the control repo's code, so their calls are
    # not module-local.
    def module_local?
      return false unless file

      m = MODULE_FILE_RE.match(file)
      return false unless m

      name = class_name
      return false if RoleProfile.role?(name) || RoleProfile.profile?(name)

      m[1] == key.split('::', 2).first
    end

    # The class the file defines by Puppet's autoloading convention:
    #   <modulepath>/<module>/manifests/init.pp     → <module>
    #   <modulepath>/<module>/manifests/foo.pp      → <module>::foo
    #   <modulepath>/<module>/manifests/foo/bar.pp  → <module>::foo::bar
    #
    # @return [String, nil] nil for paths outside this pattern (EPP
    #   templates, data files)
    def class_name
      m = CLASS_PATH_RE.match(file.to_s)
      return nil unless m

      module_name, subpath = m.captures
      return module_name if subpath == 'init'

      ([module_name] + subpath.split('/')).join('::')
    end
  end
end
