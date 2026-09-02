module Driftless
  # The result of scanning a control repo — the shared read model every
  # detector queries against. Immutable (Data.define), populated once by
  # {Scan#run} before any detector fires.
  #
  # @!attribute [r] repo_dir
  #   @return [String, nil] Absolute path to the control-repo environment
  #     being scanned. Populated by {Scan#run} from its own `repo_dir:` arg.
  #
  # @!attribute [r] hiera_tiers
  #   @return [Array<HieraTier>] Parsed from hiera.yaml, in declared tier
  #     order. Each tier carries datadir, path_templates, interpolation_vars,
  #     backend.
  #
  # @!attribute [r] puppet_classes
  #   @return [Hash{String => PuppetClass}] Indexed by fully-qualified class
  #     name. Populated by extracting class definitions from every .pp file
  #     under the environment's modulepath.
  #
  # @!attribute [r] data_files
  #   @return [Array<HieraDataFileInfo>] One per YAML file discovered under
  #     any tier's datadir. Carries top_level_keys plus a memoized #source
  #     accessor for on-demand raw text.
  #
  # @!attribute [r] reported
  #   @return [Reported] Wrapper around whatever PuppetDB report data was
  #     loaded from incoming_dir. Detectors query via #missing?(name) /
  #     #report(name).
  #
  # @!attribute [r] code_lookup_calls
  #   @return [Array<LookupCall>] Extracted from Puppet AST — i.e., lookup(...)
  #     / hiera(...) function calls in .pp and .epp files. `has_default` is
  #     meaningful for these (it captures whether the call site provided one).
  #
  # @!attribute [r] data_lookup_calls
  #   @return [Array<LookupCall>] Extracted from Hiera YAML value
  #     interpolations — %{lookup(...)}, %{alias(...)}, %{hiera(...)}.
  #     `has_default` is always false (the interpolation syntax cannot carry
  #     a default). Kept separate from code_lookup_calls because the code:*
  #     and data:* detector namespaces analyze different artifact domains.
  #
  # @!attribute [r] puppetfile
  #   @return [Inputs::Puppetfile::Result, nil] What the control repo's
  #     Puppetfile declares: each module's deploy path, remote, and ref.
  #     nil when not loaded (a corpus built without one).
  #
  Corpus = Data.define(
    :repo_dir, :hiera_tiers, :puppet_classes, :data_files, :reported,
    :code_lookup_calls, :data_lookup_calls, :puppetfile,
  ) do
    def initialize(puppetfile: nil, **rest)
      super
    end
  end
end
