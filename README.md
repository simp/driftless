# driftless

A Puppet/OpenVox control-repo linter. Cross-references what a control repo
**declares** (Hiera hierarchy and data, manifests, modules) against what
PuppetDB **reports** (active nodes, classified classes, factsets), and emits
findings for stale, wrong, weird, or impossible configurations.

Not a code linter (that is [`puppet-lint`](https://github.com/puppetlabs/puppet-lint)).
Not a catalog compiler (that is [`onceover`](https://github.com/dylanratcliffe/onceover)).

## Architecture

Two cooperating tools:

- **Analyzer** — pure crunching. Reads reports and repo, no network I/O.
  Ships as this gem.
- **Collector** — talks to PuppetDB, writes normalized reports to an
  `incoming/` tree. Standalone scripts under `scripts/` for now
  (`driftless-collect-puppetdb-reports.rb`,
  `driftless-store-reports-in-git.rb`).

The analyzer reads `incoming/<report-name>/<contributor>--<timestamp>.json`
and merges contributors on the fly (latest-timestamp-wins per certname). No
materialized `reports/` layer.

## Install

Not yet published. From a checkout:

    bundle install
    bundle exec bin/driftless --help

The gem targets AIO Ruby delivered by `openvox-agent` 8.28
(Ruby >= 3.2, < 4.0).

## Usage

    driftless scan --repo-dir=<control-repo> --incoming-dir=<incoming> \
                   --environments=production,staging

`--repo-dir` and `--incoming-dir` auto-detect when run from a control-repo
root that contains `environment.conf`, `hiera.yaml`, and an `incoming/`
directory.

Exit status: `0` no findings, `1` findings, `2` usage error, `3` I/O error.

### Subcommands

    scan             Cross-reference control repo against PuppetDB reports
    import local     Import a collector session from a local directory
    import git       Import collector sessions from a git remote
    import cleanup   Archive superseded sessions, quarantine incomplete ones
    list detectors   List all detector keys and their descriptions
    version          Print the driftless version

Run `driftless help <subcommand>` for full flags.

## Detectors

Run `driftless list detectors` for the current set. Findings are keyed by
subsystem: `hierarchy:*` (Hiera hierarchy shape), `data:*` (Hiera data
content), `code:*` (manifest content).

## Configuration

Optional `driftless.yaml`, searched at system, user, and project scope
(project wins). Keys are grouped by subsystem, not by CLI subcommand:

    puppet:
      environments: [production, staging]
    scan:
      fail_on: any
    detectors:
      skip: [data:legacy-facts]
    output:
      format: text

`--config=PATH` replaces the search chain; `--no-config` skips it entirely.

## License

Apache-2.0. See `LICENSE`.
