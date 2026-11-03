# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

It's a new gem to help upgrade the module base of large Puppet/OpenVox  control repos without breaking everyone's stuff (or at least having a pretty good idea about what to what out for).  A toolkit to deliver massively multi-tenant brownfield control repos with lots of modules, profiles, and hiera from stdlib-stasis and dependency hell!

### Added

- **`pupgrade check`**` [-d DIR] [--propose PUPPETFILE]`

  Resolves deps, OSes, and requirements between all deployed modules'
  `metadata.json`.  Conflicts are displayed and return an exit code of `1`.

  Notable flags:
  - `--propose` resolves with the info from `PUPPETFILE` overlaid on the
    current entries, fetching `metadata.json` from git for changed modules
    - `--propose` + `--ignore` show every row, marking conflicts introduced
      (`+ NEW`, red) and resolved (`- FIXD`, green); `--changed-only` drops
      the unchanged rows and `--hide-resolved` the resolved ones
    - an introduced row is yellow, a resolved row grey, the kind colored;
      the part of a detail in the way is red; summary zeros are grey
    - `--by-change`: (under a proposal) one table per changed Puppetfile entry
  - `--ignore MODULES` resolves as if those modules were gone (a what-if;
    `modules.exclude_modules` is the standing exclusion)
  - `--exclusion-file FILE` reads exclusions on top of the config's, in the
    config's shape, the one `solve --write-exclusions-file` writes
  - `--summary` displays as a table of modules x conflict types
    - with `--propose`, shows introduced (`+`), resolved (`-`), unchanged (`=`)
  - row filters: `--modules`, `--subjects`, `--conflicts`, `--skip-conflicts`
  - layout flags: `--order`, `--sort-by`
  - one-run exclusions: `--exclude-modules`, `--exclude-deps`,
    `--exclude-requirements`, `--exclude-operatingsystems` (`--exclude-os`)
  - module names match in any spelling: `puppetlabs-stdlib`, `puppetlabs/stdlib`,
    or `stdlib`, in flags, config, and `--ignore`
  - a dependency exclusion may name one edge rather than a module:
    `a-ssh:a-core` ignores ssh's requirement on core, and `a-ssh:a-core < 5.0.0`
    ignores that constraint only, with a warning once ssh's constraint moves on

- **`pupgrade module`**` gitlog [options] MODULE [REF]`

  Displays a deployed module's git log (optionally at `REF`)
  * Given a tracking `--branch` or `--branchfile`, shows what is further along
    the tracking branch, beyond the current checkout/`REF`; `--from-start`
    logs `REF` from its first commit instead
  * A rev expression (`HEAD~3`, `main@{2.weeks.ago}`) goes to git as written;
    a plain name is tried as `origin/<name>` first
  * `--branch` takes a comma-separated list; the first branch the clone has
    wins, and is recorded in the branchfile (flag or `modules.branchfile`)
  * `-t`, `--tags-only` shows tags only (and the branch tip with
    `--include-heads`)
- **`pupgrade module releases MODULE[:REF] [--branch B] [--branchfile FILE] [--fetch]`**:
  every release of a module, past and future: each tag naming a version on
  the branch it follows, newest first (`--order oldest` reverses), with its
  date, the deployed one marked; `--include-heads` adds the branch tip;
  `:REF` starts the list there, leaving out the releases older than the
  version at REF
  - a column per constraint, saying whether each release meets it and which
    way it misses: `--with DEP[=VERSION]` (the dependency range against the
    version, deployed by default), `--puppet VERSION`, `--os NAME[=RELEASE]`
  - `--item GLOBS`: a column per matching item of the API surface (a
    parameter is `CLASS::PARAM`), reading its signature or type where it
    first appears, then `changed: …`, `=`, or `absent`, from the surface
    document of each release
- **`pupgrade module list [GLOBS]`**: every module on the modulepath or in the
  Puppetfile, with what the Puppetfile declares, what is deployed, and whether
  they agree, and whether any compiled catalog uses it (`?` without a compile
  cache; `--compile-cache DIR`)
- **`pupgrade module info MODULE [--branchfile FILE] [--fetch]`**: one module
  in full: names, path, declaration, remote, what the clone sits at, metadata
  (dependencies, requirements, OS support), the branch it follows, and the
  tagged versions it could move to
  - `--surfaces[=KINDS]`: the names on each API surface, from the module's
    surface document, at `MODULE:REF` when a ref is given; `--surfaces='*'`
    lists every kind, the empty ones as `(none)`
  - names on a surface cyan, `(none)` dim, a dependency's or requirement's
    name cyan

- **`pupgrade module usage MODULE [--params]`**: what the site uses of one
  deployed module: one row per item of its API surface, whether the
  compiled catalogs show it used, and where (`nodes:`, `resources:`,
  `code:` for call sites, each file cyan with its line dimmed); `--params`
  adds each class parameter with the nodes setting it and those leaving
  its default; exits 1 when nothing uses the module
  - row filters: `--[un]used`, `--surfaces KINDS`, `--item GLOBS`
    (a parameter as `CLASS::PARAM`), `--site GLOBS` (a call site's file),
    and `--used-by GLOBS` (any use, or one kind with a `node:`,
    `resource:`, `code:`, or `path:` prefix)
  - `--render-as json|yaml`: the rows as data, every use item listed
  - a class row's where lists the sites that added the class (`code:`)
    beside the nodes including it
  - `--list nodes|modules`: one per line instead of the table, the nodes
    with a use, or the modules whose code adds a class, calls a function,
    or declares a resource of the module (a site in no module by its path,
    the ENC as `enc`)

- **`pupgrade module update`**` MODULE REF [--dry-run] [--force]`

  Check out `REF` in the deployed git `MODULE`, in place; `--force` goes
  ahead over uncommitted changes; a deleted `spec/`, which r10k removes
  from every module it deploys, is not one
- **`pupgrade module diff FROM TO`**

  Show what changed between two versions of a module:
  * metadata (dependencies, requirements, operating systems)
  * API surfaces (classes, defines, params, facts, functions, etc)
  - `FROM` and `TO` can be a module name (`stdlib`), name:ref
    (`stdlib:v9.7.0`), module dir, or `surface` json API document.
  - rows read `item | difference | detail`
    - the kind of each item is cyan, its namespace grey
    - a parameter reads `Boolean $x = $is_slave`; signatures as `(a, b)`
    - only Variant, Enum, Pattern, Struct, Tuple, Hash, Array, Regexp fold
      to `[…]`; two sides that still read alike get `[…¹] -> […²]`
  - `--full` prints each change as a block with its values whole
  - `--surfaces`, `--names`, `--changes` filters, `--summary`
  - exits `1` when the two differ

- Config subsystem `modules` in `pupgrade.yaml`:
  - `operatingsystems`, `requirements`, `exclude_modules`,
    `exclude_dependencies`, `exclude_requirements`,
    `exclude_operatingsystems`, `branchfile`, `check_order`, `check_sort`

- **`pupgrade catalog compile`**` [options]`

  compiles one catalog per factset, deployed environment directory using
  Puppet's compiler (like onceover, but much faster without rspec-puppet)

  * prints a green P or red F per factset as it goes (disable with
    `--no-progress`)
  * `--fail-fast` stops at the first failure
  * `--show-default-mocks` prints the shipped mocks
  * in the post-compile summary table:
    - `mocks` column counts answered commands
    - `leaks` counts unmocked commands (red = one failed the compile)
    - `missing` counts fact reads with no value in the factset or the mocks
    - failures are displayed under the table
  * unmocked commands log at warning, mocked ones at `--on-mock LEVEL`;
    `--on-mock 'certname=web*:notice'` or `'facts.os.family=RedHat:info'`
    sets the level for the nodes matching, so one node or one OS can be
    traced in a full run (filters joined by `;`, the flag repeatable;
    `compile.on_mock` holds standing rules, the flag's coming after);
    Puppet's own warnings log at warning with the certname, one line
    each, deprecations at info
  * `pupgrade/compiler-mocks.yaml` is read by default when present
  * `--setting NAME=VALUE` and `compile.settings` set Puppet settings for
    the compile, such as `strict=error` and `strict_variables=true`
  * dynamic ENC and execution guard mocks: rules can return results based
    on a node's certname + facts, using YAML rules and/or Ruby logic
    - YAML rules in `enc.yaml` + `compiler-mocks.yaml` can reference the
      node's `${certname}` and `${facts.a.b}`, and transform them with
      regex + capture groups
    - `pupgrade/compiler.rb` defines rule logic for both as Ruby blocks:
      `variable` & `classes` for the ENC, `mock` for the exec guard
    - ENC classes from `enc.yaml` and `compiler.rb` are merged; other
      `compiler.rb` rules override their YAML counterparts
    - config keys `compile.enc` + `compile.ruby`, flags `--enc` and `--ruby`
    - `compile.json` records what each node was given under `enc`

  * records usage information per factset, used by `solve`:
    - full Puppet catalog
    - records functions, facts, and data types used during the compile
  * factsets can be:
    - in onceover's layout (`name`, `values`, `trusted`)
    - in `puppet lookup` format (a plain facts hash).  
    - exported by `driftless export factsets`
  * `OUT/<certname>/catalog.json`: Puppet's catalog data hash
  * `OUT/<certname>/compile.json`: the compile's record (schema 3): its
    outcome, each class with the sites that added it (`include`, `require`,
    `contain`, a `class { }` declaration, or `enc`), functions and their
    call sites, facts, lookups, types, providers, warnings, mocks, leaks
  * `--environment`, `--manifest PATH`, `--code CODE` (in place of the
    manifest), `--prepend CODE|@FILE` (before the manifest, or before
    `--code`), `--var NAME=VALUE`, `--server-fact NAME=VALUE`
  * Comes with an execution guard/mocking system to stub server-side functions
    (aka execution leaks) and direct calls to Facter's execution helpers
    - mocks are defined in `--mocks FILE`
    - an unmocked command stops that node's compile (`--on-leak fail`, the
      default) or runs and is recorded (`--on-leak allow`)
    - interception is in the probe record
  * default mocks ship with pupgrade (`--[no-]default-mocks`)
    - package queries such as `rpm -q` answer per OS family, so code compiled
      against factsets from another OS behave the way it would there
  * a full factset run (no `--certname`) removes `OUT/<certname>/` directories
    that don't match any of the compiled factset names
    - `--keep-stale` leaves them be

- **`pupgrade lookup`**` [options] KEY... --node CERTNAME`

  Locally simulate an operational puppet lookup, using pupgrade's config and
  factsets, allowing you to model lookups `puppet lookup` can't handle, like
  using the mock ENC to set top-scope variables (even without compiling), and
  injecting puppet language preconditions.
  * Mimics puppet lookup options `--explain` and `--explain-options`
  * `--compile` evaluates manifests first, using pupguard's mocks and guards
  * `--list` displays all factset nodes, alongside important facts and
    variables (config: `lookup.columns`)
  * a `%{module_name}` tier applies as in a class of the key's module;
    `--module-name NAME` names another, `""` none
  * exits `1` when the key is not found, `3` when the lookup fails (a
    backend error is printed, not swallowed)

- **`pupgrade catalog list`**

  Lists the compiled catalogs in the cache: one row per node with its
  status and counts, from the probes record and catalog each compile wrote.

- **`pupgrade catalog resources`**` [TYPE [TITLE] | Type[title]] CERTGLOB[,…]`

  Lists the resources of compiled catalogs, with each resource's source file
  and line. `--full` prints the matches whole, `--params` their parameter names.
  Exits 1 when nothing matches.
  * certname magenta, type cyan (`Class`, `Stage`, `Node` dim), source file
    cyan with its line dim

- **`pupgrade catalog show`**` [-p] [-k] [KEYPATH] CERTGLOB[,…]`

  Prints a compiled catalog, or its probes with `-p`, from the cache: the whole
  data structure or the part a key path names (`resources[0].title`,
  `classes`). `-k` lists the keys there.

- **`pupgrade catalog diff`**` FROM TO`

  Shows what changed between two `catalog compile` runs, node by node: resources,
  parameters, classes, and relationship edges added, removed, or changed.
  * `--group` folds identical changes across nodes into one row
  * `--summary` counts changes per node
  * exits `1` when the catalogs differ

- **`pupgrade surface`**` [options] [MODULE[:REF] ...]`

  Reads a module's API surfaces (classes, defines, functions, types,
  providers, facts, type aliases) and its `metadata.json` into a JSON
  document under `pupgrade/cache/api_surfaces/`, for `module diff` and
  `impact`.
  * `MODULE` is a name on the modulepath or a directory; `stdlib:v9.7.0`
    reads the clone at a ref; `--all` reads every module
  * cached API surface files are named `<module>-<version>--<tag>__<sha>.json`
    - pupgrade matches on the `<sha>`; the `<tag>` is a convenience for users
      listing files
  * documents are reused until `--refresh`
  * nothing goes to stdout but `-o -`; the document's path is logged at
    debug
  * Ruby surfaces are read in a process of its own, with the control repo's
    modulepath in reach
  * types and providers are read as Puppet loads them: the extractor asks
    Puppet for each type and records what `provide` is called with, so no
    file loads twice; a file in `lib/puppet/provider/` that defines no
    provider is skipped as a helper
  * a cached surface using an older schema is refreshed automatically;
    `--refresh[=schema]` refreshes only stale schemas

- **`pupgrade solve`**` [options] [-o PUPPETFILE]`

  Picks a version for every deployed git module from the tags its clone
  holds: a set in which every dependency range, the Puppet requirement
  (`modules.requirements`), and the operating systems of interest
  (`modules.operatingsystems`) hold, found by the PubGrub solver Bundler
  vendors, each module as far along its candidates as the set allows.
  * `-o` writes the moves as a Puppetfile overlay for `check --propose` and
    `impact`
  * `--order newest` (default) prefers the newest fitting candidate;
    `nearest` the one nearest the current version, driven by
    `--bump MODULE[=REF]`; `oldest` is still taken for `nearest`
  * `--hold MODULES` and `--bump` are facts the solver cannot overrule;
    `--ignore MODULES` drops modules for the run
  * a module short of its newest candidate is `solved`, and the note says
    which of its constraints is in the way and what stands against it:
    `solved: apache >= 11.0.0 depends on stdlib >= 9.0.0, < 10.0.0; every
    version of baseline depends on stdlib >= 4.13.1, < 9.0.0`
  * a module no version of which fits is `unresolved`: kept at the
    candidate breaking the least, its constraints set aside
  * a constraint broken at the current versions stays in force when a
    move of either module would meet it; one no move meets is
    `unresolvable`: kept from the solver, and on the row until an
    exclusion covers it
  * when nothing fits, a module already broken that cannot mend itself by
    moving is pinned before one that was intact
  * under `--order nearest` a moved module's note says what pushed it off
    its current version
  * `--explain MODULES` prints the solver's whole derivation for a solved,
    nearest, or unresolved module
  * `--prune-unused` ignores dependency edges to, and from, modules no
    compile used (needs `compile` output)
  * `--write-exclusions-file FILE` records what the result relies on, as
    the config's `modules.exclude_*` lists: the pruned edges it violates
    and the unresolvable constraints;
    `--exclusion-file FILE` reads such a file on top of the config, so a
    set of exclusions can be tried before the config adopts it
  * exits `1` when any module is unresolved, or an unresolvable constraint
    is not excluded
  * config subsystem `solve`: `order`, `include_heads`, `compile_cache`

- **`pupgrade impact`**` [options] PUPPETFILE`

  Shows what the site would feel from a proposed Puppetfile: every API change
  between the deployed version and the proposed ref of each module it moves,
  mapped to the nodes, resources, call sites, and Hiera keys that use it,
  from the `compile` output.
  * a finding nothing is known to use reads `use unknown`; `--no-catalogs`
    reads no compile output at all
  * a removed class parameter whose key some `lookup()` still reads is
    `class-param-hiera-only` (the data lives on as plain Hiera data), with
    the call sites; one nothing reads is `class-param-removed`, dead data;
    Hiera keys and lookups come from the repo's data and code, not from
    driftless's params validator and its role/profile exemptions
  * `--summary` gives one row per module; `--gitlog` and `--changelog` add
    each module's commits and CHANGELOG sections for the versions crossed
  * `--modules`, `--impacts`, `--all` filters
  * `use unknown` and `no catalogs` red, detail verbs colored; in the
    where column, certnames magenta, a resource in its verb's color, a
    call site's file (`code:`) or Hiera file (`hiera:`) cyan with its
    line dimmed
  * exits `1` when any finding has a use
  * config subsystem `impact`: `compile_cache`

- **`pupgrade config`**` new|print`

  * `new` writes a `pupgrade.yaml` with every key commented out, or set by
    `key=value` arguments
  * `print [KEY]` shows the config as this run resolves it; `-d` adds the
    unset defaults
  * the project config is `pupgrade/pupgrade.yaml` (or `./pupgrade.yaml`)

- Module names match by short name wherever one is given:
  `voxpupuli-firewalld`, `puppet/firewalld`, and `firewalld` name the same
  module. `puppet-*` is the one way to say "owned by".
- Logging levels follow Puppet's, `notice` the default; `-v` (info), `-vv`
  (debug), and `-vvv` (trace) show progressively more of what a command is
  doing, wherever they sit on the command line.
- Tables wrap to the terminal width (`--width N` overrides; `0` for none);
  a colored cell keeps its colors across the wrap.
- `--help` prints the command's desc; subcommands sort by name
- commands log their stages at notice before slow work; every git trace
  line names its purpose, e.g. `(resolving v9.6.0)`
- removed the `params` command (moved `params compare` to driftless)
- `rake fixture[DIR]` builds a fixture control repo to try pupgrade against:
  32 git modules with tagged releases, two Forge modules, factsets, mocks,
  and a `Puppetfile.proposed`.

[unreleased]: https://github.com/op-ct/pupgrade
