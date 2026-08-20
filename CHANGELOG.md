# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
