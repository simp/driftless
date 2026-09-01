# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-08-31

### Added

- New subcommand: `driftless site`
  - Builds a self-contained static site (`index.html` + `data.json`)
    - `index.html` opens from `file://` or any static hosting (e.g., GitLab Pages)
        - vanilla HTML/CSS/JS with no external assets
    - Displays scan findings, with filters for various things
      - When generated with `--repo-url`, links in the findings will open the
        indicated path:line in the control repo's web interface
        - Template variables for these links: `{branch}`, `{sha}`, `{path}`, `{line}`
  - The site build requires data file created by `driftless scan --data-file`
- New `driftless scan` option: `--data-file[=PATH]` 
  - writes data file (`public/scan.json`) that `driftless site` uses
- Support for expanding + scanning `glob`/`globs`in `hiera.yaml` tiers
- DB report collector script (`scripts/driftless-collect-puppetdb-reports.rb`) features:
  - Now honors `DRIFTLESS_COLLECTOR_REPORTS_DIR` environment variable
  - Sessions now record SHA256 checksums for all collector script report files 
    - Added `file_checksum` and `file_checksum_type` to `_summary.json` format
    - Bumped `_summary.json` format's `collector_version` to `0.2.0`
- CLI-wide ANSI color output (options)
  - Colors `scan` findings, `list detectors`, important logger statuses
  - Related config file option: `output.color` (Default: `true`)
- `driftless scan` now displays a tabularized findings summary at the end of a scan
- New detectors:
  - `hierarchy:tiers-interpolating-bare-variables` (`warning`/`weird`)
      - Finds hierarchy tiers that interpolate bare variables (`$var` instead of `$::var` or `$facts['var']`
      - These can resolve to local variables uding the compile instead of the intended value
      - (AFAIK bare vars are only useful in Bolt projects' `plan_hierarchy` tiers)
  - `hierarchy:missing-datadir` (`error`/`wrong`)
      - Something has gone _seriously_ wrong if your `datadir` doesn't exist
  - `hierarchy:interpolated-datadir` (`note`/`weird`)
    - It's technically possible to interpolate inside `datadir`, but
      there's no known legitimate use (or documentation) for it
- New detector features:
  - Config `allow_role_profile_keys` for detector `data:codebase_missing_class_param`
    - Permits `lookup()` calls for Hiera-only keys under role or profile namespaces (default: `false`) 
  - Findings for `hierarchy:files-missed-by-reported-fact-values` now name the fact(s) that didn't match a missed file

### Changed

- Hiera data files are parsed + memoize scalars w/line-numbers
  - Improves detector performance + allows findings to report problems' locations
  - Side-benefit: excludes commented-out `"%{lookup()}"`calls and the like
- Issues detected while loading files are now first-class findings
  - Configurable in `driftless.yaml`, display in `list detectors`, and include severity/quality
- Simplified/improved readibility of finding messages and help text
- Lots o' linting

### Fixed:

- `hierarchy:files-missed-by-reported-fact-values` now only reports files missed _by reported fact values_ (and not for any other reason)
- `driftless --config FILE`/`-c` option now works from any CLI position
- `driftless import git`: branch checkouts use the same env vars as repo clones
- Bugs in detecting legacy facts vs bare variables vs top-scope variables

## [0.2.0] - 2026-08-20

### Added

- New subcommand: `driftless config new`
  - Generates a new `driftless.yaml` config file, with all available options
    commented out and documented
- New internal config keys registry
  - Provides every config setting a registered home in `driftless.yaml`
  - New config subsystems: controlrepo and outputs
- Reported nodes now keep track of their collectors
- (maintenance) Added rubocop rules and inline hints

### Changed

- Lots of plumbing to support DSL-defined ConfigKeys subsystems
- Linted codebase with rubocop

## [0.1.0] - 2026-08-20

- Initial MVP

[unreleased]: https://github.com/op-ct/driftless/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/op-ct/driftless/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/op-ct/driftless/releases/tag/v0.1.0
