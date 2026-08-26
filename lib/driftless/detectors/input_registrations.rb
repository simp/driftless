require 'driftless/detectors/registration'

module Driftless
  module Detectors
    # Conditions {Driftless::Inputs} meets while building the corpus. Each one
    # is registered, so `list detectors` shows it and a config file can disable
    # it or exclude paths from it. None is callable: the loader or parser that
    # meets the condition raises the finding.

    class CodeParseError < Registration
      key   'code:parse-error'
      about 'Puppet manifests and EPP templates driftless could not parse'
      quality :wrong
      severity :warning
    end

    class ControlrepoMissingModulepathsFromEnvconf < Registration
      key     'controlrepo:missing-modulepaths-from-envconf'
      about   'environment.conf declares a $modulepath entry that is not on disk'
      quality :weird
      severity :warning
    end

    class DataJsonParseError < Registration
      key   'data:json-parse-error'
      about 'PuppetDB report files driftless could not parse as JSON'
      quality :wrong
      severity :warning
    end

    class DataYamlParseError < Registration
      key   'data:yaml-parse-error'
      about 'hiera.yaml and Hiera data files driftless could not parse as YAML'
      quality :wrong
      severity :warning
    end

    class HierarchyHieraYamlMissing < Registration
      key      'hierarchy:hiera-yaml-missing'
      about    'the control repo has no hiera.yaml, so there is no hierarchy to scan (stops a scan)'
      quality :impossible
      severity :error
    end

    class HierarchyInterpolatedDatadir < Registration
      key      'hierarchy:interpolated-datadir'
      about    'a tier interpolates its datadir, which driftless does not render, so none of its data files are scanned'
      severity :note
      quality  :weird
    end

    class HierarchyMissingDatadir < Registration
      key      'hierarchy:missing-datadir'
      about    "a tier's datadir is not a directory, so none of its data files are scanned"
      severity :error
      quality  :wrong
    end

    class HierarchyTierMissingPath < Registration
      key      'hierarchy:tier-missing-path'
      about    'a tier declares no path:, paths:, glob:, or globs:, or uses a locator driftless does not scan (uri:, mapped_paths:)'
      severity :note
    end

    class HierarchyUnscannableBackend < Registration
      key      'hierarchy:unscannable-backend'
      about    'a tier uses a data_hash backend driftless does not read'
      severity :note
    end

    class HierarchyUnscannableByDriftlessBackend < Registration
      key      'hierarchy:unscannable-by-driftless-backend'
      about    'a tier uses a lookup_key/data_dig backend, which driftless does not read'
      severity :note
    end

    class HierarchyUnsupportedVersion < Registration
      key   'hierarchy:unsupported-version'
      about 'hiera.yaml is not a Hash with version: 5, so no tier is scanned'
      severity :error
    end
  end
end
