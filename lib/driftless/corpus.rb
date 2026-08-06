module Driftless
  # The result of scanning a control repo — the shared read model every detector
  # queries against. Immutable by construction (Data.define): populated exactly
  # once by {Scan#run} before any detector fires; guaranteed frozen for the
  # scan's duration. Detectors receive this instance and MUST NOT mutate it.
  #
  # If methods (e.g. a unified `#lookup_calls` view combining code + data) are
  # needed later, promote to `class Corpus < Data.define(...)` with instance
  # methods — the Data base preserves the immutability guarantees.
  #
  # @!attribute [r] repo_dir
  #   @return [String, nil] Absolute path to the control-repo environment being
  #     scanned. Populated by {Scan#run} from its own `repo_dir:` argument.
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
  # @!attribute [r] lookup_calls
  #   @return [Array<LookupCall>] All hiera-key references discovered anywhere
  #     in the repo — both Puppet-code lookup(...)/hiera(...) calls AND YAML
  #     value interpolations (%{lookup(...)}, %{alias(...)}, %{hiera(...)}).
  #     Callers cannot currently distinguish the two sources; see the pending
  #     Phase 3 split into code_lookup_calls + data_lookup_calls.
  #
  # @!attribute [r] log
  #   @return [IO, nil] Diagnostic write target. Deprecated slot;
  #     {Driftless.logger} (Phase 2) is the current mechanism. TODO: remove
  #     or repurpose.
  Corpus = Data.define(
    :repo_dir, :hiera_tiers, :puppet_classes, :data_files, :reported,
    :lookup_calls, :log,
  )
end
