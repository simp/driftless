# pupgrade

A toolkit for helping Puppet/OpenVox control repositories escape from [dependency hell]

## Table of Contents

  - [Overview](#overview)
  - [Quick Start](#quick-start)
  - [Configuration](#configuration)
    - [pupgrade.yaml](#pupgradeyaml)
    - [Factsets](#factsets)
    - [Mocks](#mocks)
    - [ENC rules](#enc-rules)
  - [The commands](#the-commands)
    - [check](#check)
    - [catalog](#catalog)
    - [solve](#solve)
    - [impact](#impact)
    - [module](#module)
    - [surface](#surface)
    - [lookup](#lookup)
  - [Scenarios](#scenarios)
    - [stdlib 8 to stdlib 9](#stdlib-8-to-stdlib-9)
    - [Puppet 7 to OpenVox 8](#puppet-7-to-openvox-8)
    - [A stubborn dependency](#a-stubborn-dependency)
    - [Finding and fixing compile leaks](#finding-and-fixing-compile-leaks)
    - [Comparing two control repo versions](#comparing-two-control-repo-versions)
  - [Installation](#installation)
    - [With the Bolt AIO](#with-the-bolt-aio)
    - [On an airgapped host](#on-an-airgapped-host)
    - [With the openvox-agent AIO](#with-the-openvox-agent-aio)
  - [Logging and colour](#logging-and-colour)
  - [Developing pupgrade](#developing-pupgrade)


## Overview

pupgrade is designed to help brownfield control repos upgrade

### Control repo Dependency Hades

Upgrading many Puppet modules across major versions in a big control repo generally hits problems in three places:

1. Compatibility between all the upgraded modules' dependencies
2. Alignment of your control repo's code and Hiera and the new API surface of upgraded modules
3. Catalogs compiled from updated modules might manage things differently, or manage different things

pupgrade has a command for each:

| Question                                                                                      | Command              |
|-----------------------------------------------------------------------------------------------|----------------------|
| Do all modules' dependencies agree?  What conflicts will a proposed change resolve/introduce? | `check`              |
| Which version could every module move to, within constraints and what the site uses?          | `solve`              |
| What API surfaces _actually_ change between any two versions of a module?                     | `module diff`        |
| Which of _our_ nodes/resources/code/Hiera keys would be affected by these changes?            | `impact`             |
| Does anything change in the catalogs change ?                                                 | `catalog diff`       |
| What bits of each module are we _actually_ using?                                             | `surface`, `catalog compile` |
| What would a node get from Hiera, given its facts and ENC variables?                          | `lookup`             |

Every command runs from your  deployed control repo (the directory holding
`environment.conf`, `hiera.yaml`, and the Puppetfile, with the modules deployed
under it), or against one named with `-d DIR`. pupgrade needs `git` on the host
and otherwise only what the OpenVox AIO ships; it never writes under
`/opt/puppetlabs` and never deploys anything.

### What pupgrade does

pupgrade is a suite of tools to help safely upgrade the entire module base
of a large Puppet/OpenVox control repository without breaking everyone's stuff―
or at least knowing what to expect before it does.

It reads the deployed control repo, the modules' own `metadata.json` and git
history, and catalogs it compiles itself from your factsets, to answer: which
module versions can move together, what each move changes in a module's API,
and which of your nodes, resources, and Hiera keys would feel it.

It is the companion to [driftless](https://github.com/op-ct/driftless), the
control-repo linter. driftless reports "what is"; pupgrade asks "what if".




## Quick Start

**Note:** this assumes you are inside the root of your deployed control repo
and pupgrade is [installed](#installation).

1. Write a config and a directory of factsets:

    ```shell
    pupgrade config new            # pupgrade/pupgrade.yaml, every key commented out
    mkdir -p pupgrade/factsets     # one JSON file per node; see Factsets below
    ```

1. See what the deployed modules say about each other today:

    ```shell
    pupgrade check --summary
    ```

1. Compile a catalog per factset. A command a module runs during the compile
   stops the node until it is mocked:

    ```shell
    pupgrade catalog compile --factsets pupgrade/factsets
    ```

1. Let the solver propose a Puppetfile, then see what the proposal would do:

    ```shell
    pupgrade solve --prune-unused -o Puppetfile.proposed
    pupgrade check --propose Puppetfile.proposed --by-change
    pupgrade impact Puppetfile.proposed
    ```

## Configuration

### pupgrade.yaml

Lives at `pupgrade/pupgrade.yaml` in the control repo (or `./pupgrade.yaml`,
not both). `pupgrade config new` writes it with every key commented out and
described, and `pupgrade config print -d` shows what is in effect. Keys can
also be given as `--config PATH`, or from `~/.config/pupgrade/config.yaml`.

The keys most sites set:

```yaml
---
modules:
  operatingsystems:                 # what every module must declare support for
    RedHat: ['8', '9']
  requirements:
    puppet: '>= 8.0.0 < 9.0.0'      # the Puppet you run, or are moving to
  exclude_dependencies: []          # edges you have decided to ignore (see solve)
compile:
  factsets: [pupgrade/factsets]
```

Everything else pupgrade reads or writes of its own sits under `pupgrade/`
and is found when present:

| Path | What |
|---|---|
| `pupgrade/factsets/` | the nodes to compile for |
| `pupgrade/compiler-mocks.yaml` | answers for commands and facts module code asks for while compiling |
| `pupgrade/enc.yaml` | rules deciding each node's top-scope variables and classes, as an ENC would |
| `pupgrade/compiler.rb` | Ruby blocks for what the rules cannot say |
| `pupgrade/cache/catalogs/` | what `compile` wrote; what `solve` and `impact` read |
| `pupgrade/cache/api_surfaces/` | the module API documents `module diff` and `impact` compare |

### Factsets

One file per node, in either of two layouts: onceover's (`name`, `values`,
`trusted`) or a plain facts hash named by its file (what `puppet facts` and
`driftless export factsets` write). Trusted facts come from the `trusted`
hash when the file has one, else they are built from the certname.

The smallest set worth having is one node per role. driftless can pick them
from PuppetDB's reports:

```shell
driftless export factsets --onceover-role-tree pupgrade/factsets   # one per role
driftless export factsets -o pupgrade/factsets --role 'role::web*' # or by selection
```

Or, on a node that has the agent:

```shell
puppet facts > pupgrade/factsets/$(hostname -f).json
```

`pupgrade lookup --list` shows every factset with the facts and variables
that place it in your hierarchy, which is the quickest check that the set
covers what the hierarchy keys on.

### Mocks

A compile runs module code, and some of it runs commands: `hostname -f`,
`rpm -q`, a `systemctl` in a custom function. pupgrade's execution guard
catches the commands that go through Puppet's and Facter's execution
helpers, and every `Facter.value` read. A command that is not mocked stops
that node's compile (`--on-leak fail`, the default), so you find them one at
a time, or all at once with `--on-leak allow`.

`pupgrade/compiler-mocks.yaml` answers them:

```yaml
---
commands:
  - match: '^hostname'                  # a regexp against the command line
    stdout: "${facts.networking.fqdn}\n" # may reference the node's facts
  - match: '\A/usr/bin/getent '
    stdout: ''
  - match: '\Asystemctl is-active '
    exit: 3                             # a mocked exit status
    when:                               # only on nodes whose facts match
      os.family: [RedHat, Debian]
  - match: 'systemctl list-unit-files'
    action: allow                       # run it for real, but record it
facts:                                  # merged over the factset's facts, per node
  fips_enabled: false
functions:                              # Puppet functions answered without running
  - name: puppetdb_query
    returns: []
    when:
      os.family: RedHat
```

The first entry whose `match` fits and whose `when` holds is used. pupgrade
applies its own mocks after yours, for the probes package providers make as
they load (`pupgrade catalog compile --show-default-mocks` prints them).
A function mock covers every call to that function, from manifests and
templates and from Ruby functions calling it, whatever the arguments.

Every interception is in the node's `compile.json`, and the compile table
counts each list: what was mocked under `mocks`, unmocked commands under
`leaks`, and fact reads with no value in the factset or the mocks under
`missing`. A missing fact runs nothing: Puppet gets no value, and the catalog
may differ for it.

### ENC rules

Hierarchies usually key on something an ENC sets: `$role`, `$site`, a
tenant. `pupgrade/enc.yaml` stands in for the ENC, with rules applied in
order, later assignments winning:

```yaml
---
rules:
  - set:                              # every node
      role: role::base
  - when:
      certname: 'pup*'                # a glob on the certname
    set:
      role: role::puppetserver
    classes: [profile::puppetserver]
  - when:
      facts.os.family: [RedHat]       # a fact, any of the values
    set:
      pkg_manager: dnf
  - set:
      site: '${certname[/\A[^.]+\.([^.]+)\./, 1]}'   # a regexp capture
      family: '${facts.os.family}'
```

For what YAML cannot say, `pupgrade/compiler.rb` is plain Ruby, loaded after
the rules; each block gets the node as resolved so far:

```ruby
variable(:tenant) { |node| node['site'] == 'b' ? 'blue' : 'green' }
classes  { |node| ['profile::el'] if node.fact('os.family') == 'RedHat' }
mock(/\Arpm -q (\S+)\z/) { |node, m| "#{m[1]}-1.0-1.el9\n" }   # a mock answer, too
function('puppetdb_query') { |node, query| [] if node.certname.start_with?('db') }
```

A `variable` block returning nil leaves what the rules set; a `mock` or
`function` block returning nil declines, and the YAML mocks are tried, then
the function itself. `--var NAME=VALUE`
sets a variable on every node from the command line. What each node was
given is in its `compile.json` under `enc`, and `pupgrade lookup --list`
shows it for every node at once.

## The commands

`pupgrade help` lists them and `pupgrade COMMAND --help` explains each. All of
them take `-d DIR` for a control repo other than the current directory.

### check

Resolves the dependency ranges, Puppet requirements, and operating systems
every deployed module declares against every other, and lists the
conflicts. Exits 1 while any remain.

```shell
pupgrade check                                 # every conflict
pupgrade check --summary                       # one row per module
pupgrade check --conflicts puppet-version      # one kind
pupgrade check --propose Puppetfile.proposed   # what a proposal introduces (+ NEW) and resolves (- FIXD)
pupgrade check --propose Puppetfile.proposed --by-change   # grouped by the entry that caused each
pupgrade check --ignore puppetlabs-translate   # as if a module were gone
```

The `--propose`d Puppetfile is an overlay containing just the new/updated `mod`
entries, which completely replace and `mod` entries they override.
- [`solve -o PUPPETFILE`](#solve) writes its dep-solved changes as a Puppetfile proposal overlay, which can be verified with `check --propose`
- An entry without `git:` is taken for a Forge module, so a `tag:` alone gives a module with no version.

### catalog

`catalog compile` compiles a catalog per factset through Puppet's own
compiler, in the deployed environment, and records what each compile used:
classes and where each was added, functions and their call sites, facts
read, lookups made, types, providers,
type aliases, warnings, deprecations, and the commands the guard
intercepted. The catalogs and `compile.json` records land under
`pupgrade/cache/catalogs/`, where `catalog list` and `catalog show` read
them and `catalog diff` compares two runs.

```shell
pupgrade catalog compile                              # compile all factsets

pupgrade catalog compile --certname 'web*' -vv        # compile selected factsets
pupgrade catalog compile --fail-fast                  # stop at the first failure
pupgrade catalog compile --code 'notify { "${site}": }' --certname web01.example.com   # try something
pupgrade catalog diff /tmp/before /tmp/after          # compare catalogs of two runs
pupgrade catalog list                                 # display catalogs in cache
pupgrade catalog resources file '/etc/ssh/*' 'web*'   # resources by type and title
pupgrade catalog resources 'File[/etc/ssh/sshd_config]' web01.example.com --full
pupgrade catalog show -p leaks 'web*'      # display a catalog's compile-time leaks
pupgrade catalog show -p mocks 'web*'      # what was mocked
```

`--prepend CODE|@FILE` evaluates Puppet code before the manifest, for the
resources only production has, and before `--code` when that stands in for
the manifest (a configured `compile.prepend_file` too). Each is its own
source: a site, warning, or error in prepended code reads `--prepend:LINE`,
or `FILE:LINE` for `@FILE`; in `--code`, `--code:LINE`; the manifest's name
its files. `--hiera FILE` reads the environment's Hiera
layer from FILE in place of the repo's `hiera.yaml`, its `datadir` relative to
FILE's directory. `--pson` loads the `puppet-pson` gem, which defines the
`PSON` that Puppet 8 dropped. Code written for Puppet 7 that calls `PSON.load`,
such as some stdlib 8 functions, then compiles.

### solve

Picks a version for every deployed git module from the tags its clone holds:
a set in which every dependency range, your Puppet requirement, and your
operating systems hold, each module as far along its candidates as the set
allows. The search is PubGrub's, the solver Bundler uses; what to feed it is
pupgrade's.

```shell
pupgrade solve                                 # the newest set that fits
pupgrade solve --bump puppetlabs-stdlib        # stdlib to its newest, whatever that breaks
pupgrade solve --order nearest --bump puppetlabs-stdlib=v9.6.0  # move stdlib, drag the rest the least
pupgrade solve --hold puppetlabs-apache        # keep one where it is
pupgrade solve --prune-unused -o Puppetfile.proposed   # ignore edges to and from modules no catalog used
pupgrade solve --explain stdlib,baseline       # the solver's reasoning in full
pupgrade solve --explain stdlib -g stdlib.mmd  # the same as a mermaid flowchart
```

A module short of its newest candidate is `solved`, and its note says which
of its constraints is in the way and what stands against it: `solved: apache >=
11.0.0 depends on stdlib >= 9.0.0, < 10.0.0; every version of baseline
depends on stdlib >= 4.13.1, < 9.0.0`. That is the site module `baseline`
holding stdlib, and everything behind stdlib, back: fix its range, exclude
the edge, or `--bump puppetlabs-stdlib` and read what breaks. A hold or a
bump is a fact the solver cannot overrule, so a module no version of which
fits the facts is `unresolved`, kept at the candidate breaking the least.
A constraint broken at the current versions stays in force when a move of
either module would meet it. One no move meets is `unresolvable`: kept from
the solver, and on the row until an exclusion covers it. Exits 1 when any
module is unresolved, or any unresolvable constraint is not excluded.

Exclusions are decided in `pupgrade.yaml`, but trying a set first is a loop
of two flags, with the config read as usual on both runs:

```shell
pupgrade solve --write-exclusions-file try.yaml   # what the result relies on
$EDITOR try.yaml                                  # keep what you mean
pupgrade solve --exclusion-file try.yaml          # exit 0 once the file covers it
pupgrade check --propose Puppetfile.proposed --exclusion-file try.yaml
```

Then paste the lists into `pupgrade.yaml`, or `.include` the file.

### impact

For every module a proposal moves, the API changes between the deployed
version and the proposed ref, each mapped to what uses it in the catalogs
and data: a parameter removed to the nodes setting it and the Hiera keys
naming it, a function removed to its call sites, a type attribute changed to
the resources declaring it. A removed parameter whose key some `lookup()`
still reads is `class-param-hiera-only`: the data lives on, the class no
longer takes it; one nothing reads leaves dead data, `class-param-removed`.

```shell
pupgrade impact Puppetfile.proposed
pupgrade impact Puppetfile.proposed --summary                     # one row per module
pupgrade impact Puppetfile.proposed --modules puppetlabs-stdlib --changelog   # with the versions' CHANGELOG sections
```

Exits 1 when any finding has a use. A finding reads `use unknown` when there
are no catalogs to check it against.

### module

```shell
pupgrade module list                           # every module: declared, deployed, and whether they agree
pupgrade module info stdlib                    # one module: names, clone, metadata, candidates
pupgrade module diff stdlib stdlib:v9.6.0      # what changes between two versions
pupgrade module diff stdlib stdlib:v9.6.0 --full   # every value whole, as blocks
pupgrade module gitlog stdlib:v9.6.0           # what a ref has beyond the clone
pupgrade module update stdlib v9.6.0           # check the ref out, in place
```

`module diff` compares metadata (dependencies, requirements, operating
systems) and then every API surface: classes and defined types with their
parameters, functions, type aliases, resource types, providers, facts. A
side is a module name, `name:ref` for a ref of its clone, a directory, or a
document `surface` wrote. Module names match by their short name, whoever
owns them: `puppetlabs-stdlib`, `puppet/stdlib`, and `stdlib` are one module.

### surface

Extracts a module's API into a JSON document under
`pupgrade/cache/api_surfaces/`, which `module diff` and `impact` read.

```shell
pupgrade surface stdlib -o -                   # the document, to stdout
pupgrade surface --all                         # every module, into the cache
pupgrade surface --all --future-tags --fetch   # and every tag past each deployed version
pupgrade surface --git https://git.example.com/puppetlabs-stdlib.git --ref v9.6.0
```

### lookup

A Hiera lookup as a node would see it: the node from a factset, its
variables and classes from the ENC rules, the hierarchy from the repo.

```shell
pupgrade lookup profile::base::ntp_servers --node web01.example.com
pupgrade lookup profile::base::ntp_servers --node web01.example.com --explain
pupgrade lookup --list                         # every node with the facts and variables that place it
```

`--compile` evaluates the manifests first, for a hierarchy that keys on a
variable the manifests set. A `%{module_name}` tier applies as it would in
a class of the key's module, `profile` for `profile::ssh::banner`;
`--module-name` names another, or none. Exit 1 is a key not found; 3 is a
lookup that failed, a backend that could not decrypt or parse, with the
error printed.

## Scenarios

Each sequence runs from the deployed control repo, with `compile.factsets`
set and a mock file in place. The baseline for all of them is the Quick
Start: `check --summary` to see where you stand, `compile` to have catalogs.

### stdlib 8 to stdlib 9

The knot: almost every module depends on stdlib, old releases declare
`< 9.0.0`, and the modules that accept 9 need their own major bumps.

```shell
# 1. what moving stdlib alone would do: every dependent whose range excludes 9
cat > Puppetfile.stdlib <<'EOF'
mod 'puppetlabs-stdlib',
  git: 'https://git.example.com/mirrors/puppetlabs-stdlib.git',
  tag: 'v9.6.0'
EOF
pupgrade check --propose Puppetfile.stdlib --by-change

# 2. let the solver move the dependents with it: stdlib first, everything
#    else to the first release that accepts it
pupgrade solve --order nearest --bump puppetlabs-stdlib=v9.6.0 -o Puppetfile.proposed

# 3. what the proposal leaves unresolved, and what pushed each module off its version
pupgrade check --propose Puppetfile.proposed --summary
pupgrade solve --order nearest --bump puppetlabs-stdlib=v9.6.0 --explain apache

# 4. what the site would feel: removed functions at their call sites,
#    parameters removed or retyped against the nodes and Hiera keys setting them
pupgrade impact Puppetfile.proposed
pupgrade impact Puppetfile.proposed --modules puppetlabs-stdlib --changelog

# 5. the full API delta of one module, when a finding is not enough
pupgrade module diff stdlib stdlib:v9.6.0 --surfaces functions --changes removed
```

Then move the modules (`module update`, or deploy the proposed Puppetfile
with r10k), compile again, and diff the catalogs.

### Puppet 7 to OpenVox 8

pupgrade runs on OpenVox 8, so modules are assessed and catalogs compiled
under the target. Set the requirement to where you are going:

```yaml
modules:
  requirements:
    puppet: '>= 8.0.0 < 9.0.0'
```

```shell
# 1. modules whose declared Puppet range excludes 8
pupgrade check --conflicts puppet-version
# one that declares '< 8' but is known to work: ignore its claim
pupgrade check --conflicts puppet-version --exclude-requirements puppetlabs-translate

# 2. move what has a release supporting 8; what stops short has none
pupgrade solve -o Puppetfile.proposed

# 3. compile every factset under OpenVox 8; the deprecations and warnings
#    each compile raised are in its record
pupgrade catalog compile
jq '.deprecations, .warnings' pupgrade/cache/catalogs/*/compile.json

# 4. the module moves' impact, then catalogs before and after
pupgrade impact Puppetfile.proposed --summary
```

The facts in the factsets are whatever the exporting nodes reported, so
facts that moved between Facter versions show up as missing fact reads in
`compile.json` (`facts`, `legacy_facts`, and `missing`).

### A stubborn dependency

A module declares every dependency any of its code paths could need; a site
uses a few. `solve` stops a module short whenever a declared range blocks it:

```text
voxpupuli-firewalld | tag v5.1.0 | (current) | 1 | solved: firewalld >= 6.0.0 depends on augeas_core >= 3.0.0, < 4.0.0; augeas_core is kept at 2.0.1 (no version fits)
```

Four ways out, from least to most hands-on:

```shell
# 1. read the solver's derivation: what does each version of firewalld ask of augeas_core?
pupgrade solve --explain firewalld

# 2. let the catalogs decide: an edge to or from a module nothing uses is not a
#    constraint, and the edges the result still violates are written as exclusions to adopt
pupgrade solve --prune-unused --write-exclusions-file try.yaml -o Puppetfile.proposed
cat try.yaml        # modules: exclude_dependencies: ['voxpupuli-firewalld:puppetlabs/augeas_core >= 3.0.0']

# 3. force it: a bump moves the module whatever it breaks, and shows what that is
pupgrade solve --bump firewalld=v6.0.0

# 4. ignore the one edge for good, keeping the version constraint so pupgrade
#    warns when firewalld's own requirement moves on
```

```yaml
modules:
  exclude_dependencies:
    - 'voxpupuli-firewalld:puppetlabs/augeas_core >= 3.0.0'
```

`solve` also warns about the opposite case: a module whose code calls
another module's functions without declaring it (`used, but not a declared
dependency`), an edge the solver cannot see in metadata.

### Finding and fixing compile leaks

A command run during a compile ties the catalog to the compiling host; in a
container it fails. The guard sees commands run through Puppet's and
Facter's execution helpers and every `Facter.value` read (not raw Ruby
backticks, and no provider confines, since the catalog is never applied).

```shell
# 1. find them: a compile stops at the first command that is not mocked, and
#    the warning says what asked and from where
pupgrade catalog compile
#   warning: guard: web01.example.com: execute: "hostname -f" is not mocked at
#   site-modules/profile/manifests/base.pp:13 via modules/stdlib/lib/puppet/functions/stdlib/run_hostname.rb:4

# 2. or find them all at once: every command runs for real, and is recorded
pupgrade catalog compile --on-leak allow
jq '.leaks[] | select(.action == "allowed")' pupgrade/cache/catalogs/*/compile.json

# 3. answer each one in pupgrade/compiler-mocks.yaml (see Mocks), then
pupgrade catalog compile -vv          # each mocked answer logged, with its call site
pupgrade catalog compile -v --on-mock 'certname=web01*:info'   # one node's answers, in a full run
```

### Comparing two control repo versions

Two deployed directories, compiled with the same factsets, diffed catalog by
catalog. Worktrees keep both checkouts side by side; each needs its modules
deployed.

```shell
git worktree add ../control-next upgrade/stdlib-9
(cd ../control-next && r10k puppetfile install)

pupgrade catalog compile -d . -o /tmp/cat-now
pupgrade catalog compile -d ../control-next --factsets ../control/pupgrade/factsets -o /tmp/cat-next

pupgrade catalog diff /tmp/cat-now /tmp/cat-next            # per node
pupgrade catalog diff /tmp/cat-now /tmp/cat-next --group    # identical changes folded across nodes
pupgrade catalog diff /tmp/cat-now /tmp/cat-next --changes param-changed --resources 'File*'
pupgrade catalog diff /tmp/cat-now /tmp/cat-next --resources 'Class[profile::base]' --params ntp_servers --full
pupgrade module diff -d . --other ../control-next stdlib    # one module's API across the two
```

Catalog documents are sorted and carry repo-relative paths, so two checkouts
of the same code produce identical files and the diff shows only what the
code change did. A module's changed Hiera default shows here as a
`param-changed` row, which is the one kind of change `impact` cannot see.

## Installation

pupgrade is two gems, `driftless` and `pupgrade`, both pure Ruby. Everything
else they need (Puppet, Facter, `semantic_puppet`, `deep_merge`) ships with
the OpenVox AIO packages. `git` must be on the host.

### With the Bolt AIO

The OpenBolt AIO ships a real `openvox` gem that RubyGems can resolve by
name, so the two gems install into the user gem directory with no network
access and nothing written under `/opt/puppetlabs`:

```shell
G=/opt/puppetlabs/bolt/bin/gem
$G install --user-install --local driftless-*.gem pupgrade-*.gem
~/.local/share/gem/ruby/3.2.0/bin/pupgrade --version
```

Put that `bin` directory on `PATH`, or call the binstub by path. Its shebang
is the AIO Ruby, so the second Ruby that `compile` and `surface` start is
the same one. Bolt's AIO also ships r10k, for deploying a proposed
Puppetfile.

### On an airgapped host

Build the two `.gem` files on a connected host and carry them over:

```shell
(cd driftless && /opt/puppetlabs/bolt/bin/gem build driftless.gemspec)
(cd pupgrade  && /opt/puppetlabs/bolt/bin/gem build pupgrade.gemspec)
```

Then install as above; `gem install --local` resolves dependencies against
what is already installed and touches no network. What else to bring:

- **Factsets**, exported where PuppetDB is reachable (`driftless export
  factsets --onceover-role-tree`), carried with the control repo.
- **The mock and ENC files**, which are site knowledge and belong in the
  control repo under `pupgrade/`.
- **Reachable module remotes**: `check --propose`, `solve --fetch`, and
  `impact` fetch a module's metadata or surface from its remote when the
  clone does not have the ref. On an isolated network these are the mirrors
  the Puppetfile already names; without them, `solve` reads the deployed
  clones' tags only.

Bundler is not run, but its library is: `solve` uses the PubGrub solver that
Bundler 2.4 and later vendor, which every Ruby 3.2 and the Bolt AIO carry.
pupgrade has no native extensions.

### With the openvox-agent AIO

The agent AIO carries Puppet as code under `vendor_ruby`, not as a gem
RubyGems can resolve, so `gem install driftless` is refused there over its
`openvox` dependency. Two ways around it:

- Install the Bolt AIO beside the agent and run pupgrade from it. This is the
  path with the fewest moving parts.
- Build driftless from a branch that drops the gemspec's `openvox`
  dependency and lets the host supply Puppet (`openvox-provided-by-host` in
  driftless's repo), then install both gems into a `GEM_HOME` of your own
  with `--ignore-dependencies` off. Puppet is then whatever the agent ships.

Either way, note that the wrappers `/opt/puppetlabs/bin/puppet` and
`/usr/local/bin/bolt` unset `GEM_HOME`, `GEM_PATH`, and `RUBYLIB`; pupgrade's
own binstub is not wrapped, so this only matters when running it through one
of those.

## Logging and colour

Commands say what stage they are at. `-v` adds a line per item worked on,
`-vv` each decision, file, and mock answer, `-vvv` every command run with its
purpose. `-q` keeps errors only. `--[no-]color` overrides the terminal
detection, `--width N` wraps tables to a width, and `logging.level` in the
config takes the same names as Puppet's levels.

## Developing pupgrade

```shell
git clone https://github.com/op-ct/driftless ../driftless   # the Gemfile points at it by path
/opt/puppetlabs/bolt/bin/bundle install
/opt/puppetlabs/bolt/bin/bundle exec rspec
/opt/puppetlabs/bolt/bin/bundle exec rake fixture[/tmp/fixture]   # a control repo to try things on
```

The fixture holds 32 git modules with tagged releases, two Forge modules,
factsets, mocks, ENC rules, and a `Puppetfile.proposed` that bumps stdlib a
major version, so every command above runs against it.

## Licence

Apache 2.0; see `LICENSE`.

[dependency hell]: https://en.wikipedia.org/wiki/Dependency_hell
