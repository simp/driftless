# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- New subcommand: `driftless site`
  - Builds a self-contained static page (`index.html` + `data.json`) from
    the scan data document; no external assets, opens from `file://` or any
    static host. Findings with filters, grouping, a count-table sidebar,
    URL-hash state, Back/ESC and k/p/g shortcuts; a hierarchy view of the
    declared tiers with findings attached per variable; a utilization view
    that waits on `driftless report`
  - `--repo-url` links each path:line into the repo's web interface
    (`{branch}`, `{sha}`, `{path}`, `{line}` template variables)
  - Exit status says only whether the site was written; findings never
    fail it
- `driftless scan --data-file[=PATH]` writes the scan data document
  (`public/scan.json`) the site builds from: findings plus the sessions
  read, node tallies, declared hierarchy, repo revision, relaxed acceptance
  rules, and run warnings
- `Reported#sessions`: the loader records which `(collector, session-id)`
  files it read; `site` refuses to combine documents that read different
  sessions
- `Scan#corpus` exposes the read model after a run

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
