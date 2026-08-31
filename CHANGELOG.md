# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-08-31

### Added

- New subcommand: `driftless site`
  - Builds a self-contained static page (`index.html` + `data.json`) from
    the scan data document; no external assets, opens from `file://` or any
    static hosting (e.g., GitLab Pages).
  - The site currently displays findings, with filters for various things.
  - When generated with `--repo-url`, links in the findings will link to the
    path:line into the control repo's web interface
    - Template variables for these links: `{branch}`, `{sha}`, `{path}`, `{line}`
- `driftless scan --data-file[=PATH]` writes the scan data document
  (`public/scan.json`) that `driftless site` uses to build from

### Fixed:

- Bugs in design legacy fact vs bare var vs top-scope detection

## [0.2.0] - 2026-08-20

### Added

- New subcommand: `driftless config new`
  - Generates a new `driftless.yaml` config file with all available options
    commented out and documented
- New internal config keys registry
  - New subsystems: controlrepo and outputs
- Nodes now keep track of their collectors
- (maintenance) Added rubocop rules and inline hints

### Changed

- Lots of plumbing to support DSL-defined ConfigKeys subsystems
- Linted codebase with rubocop

## [0.1.0] - 2026-08-20

- Initial MVP

[unreleased]: https://github.com/op-ct/driftless/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/op-ct/driftless/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/op-ct/driftless/releases/tag/v0.1.0
