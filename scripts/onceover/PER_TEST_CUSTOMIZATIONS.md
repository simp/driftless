# Onceover: running Ruby before the spec matrix, `before:` block behaviour, and the trusted certname

Findings from 2026-09-24, verified against this checkout (v5.0.2-28-g9f64a2b, openvox 8.29.0,
rspec-puppet 5.0.0, voxpupuli-test 14.0.0) and against onceover 3.22.0 and 4.0.0
(puppet 8.10.0, rspec-puppet 4.0.2, puppetlabs_spec_helper 7.3.1). Line references are to
this checkout unless stated.

## 1. The plugin system does not reach the RSpec process

- `lib/onceover/cli/plugins.rb` requires every installed gem named `onceover-*` when the CLI
  loads. There is no hook API; a plugin can add Cri subcommands or monkey-patch
  `Onceover::Runner`, `Onceover::TestConfig`, etc.
- That code runs in the onceover CLI process. The tests run in a child process spawned by
  `Runner#run_spec!` as `rake spec:standalone` (`lib/onceover/runner.rb:96`). Nothing in the
  generated spec directory requires the plugin, so plugin code is never loaded where the
  examples run.

## 2. Ways to load Ruby in the RSpec process before any example runs

| Mechanism | Where | Notes |
|---|---|---|
| Custom `spec/templates/spec_helper.rb.erb` in the control repo | `Controlrepo.evaluate_template` (`lib/onceover/controlrepo.rb:592`) prefers `spec/templates/<name>` | Documented (README "Templates"), since v3.5.0. You own the whole template. |
| A spec file under `spec/classes/` | `TestConfig#copy_spec_files` copies `spec/**` into `.onceover/spec/` (`lib/onceover/testconfig.rb:242`); the rake pattern picks up `spec/classes/**/*_spec.rb` | E.g. `spec/classes/00_onceover_setup_spec.rb` containing only `RSpec.configure { \|c\| c.before(:suite) { ... } }` and monkey-patches. No template ownership. A control-repo `spec/spec_helper.rb` does not work: `write_spec_helper` overwrites it after the copy. |
| `CI_SPEC_OPTIONS` env var | Runner appends to it (`runner.rb:87`); voxpupuli-test and puppetlabs_spec_helper pass it to rspec | `CI_SPEC_OPTIONS='--require ./spec/onceover_probes'`. Environment only. |
| `before:` blocks in `onceover.yaml` | Pasted verbatim into a `before :each` inside every generated `context` (`templates/test_spec.rb.erb:21-27`) | Per example, not before the matrix. See section 3. |

## 3. `before:` blocks are not lazy; they run once per matrix cell

Each generated file is `describe <class>` / `context "using fact set <node>"` /
`it { should compile }`, and the `before:` text is emitted as a `before :each` inside each
context. One example per context, so the block runs once per (class, node) pair.

Evidence: `run17.log` has the lookup and fact-read notices for all three nodes, and
`exec_trace.2366733.log` tags records with all three examples.

Things that appear only once are once-only events, not a once-only block:

- "Type loaded" / "Provider loaded": `Puppet::Type` caches types per Ruby process and
  `Puppet::Test::TestHelper.after_each_test` does not unload them.
- "Provider used": the probe deduplicates it on purpose.

## 4. Why `Puppet.warning` output appeared only for the first test (onceover < 5.0.0)

`Puppet.warning` does not cache. Onceover before 5.0.0 generates a spec_helper that requires
`puppetlabs_spec_helper/module_spec_helper`. That registers a config-level `after :each`
calling `Puppet::Util::Log.close_all`
(`puppetlabs_spec_helper-7.3.1/lib/puppetlabs_spec_helper/puppet_spec_helper.rb:89`).
The `:console` destination that `SHOW_PUPPET_OUTPUT=true` adds once at spec_helper load is
closed after the first example. From then on the only destination is the per-example
`LogCollector` that the same file adds in its `before :each`, so messages go into an array
that is never printed.

Onceover 5.0.0 switched to voxpupuli-test (commit 2b7179b), which has no such hook, so on
5.x the warning prints for every example.

Without any log destination (no `SHOW_PUPPET_OUTPUT`), Puppet queues messages
(`Puppet::Util::Log.newmessage` -> `queuemessage`) and nothing ever flushes them, so on this
checkout a quiet run prints zero warnings.

Fix without templates: re-add the destination in the `before:` block. `newdestination`
returns early if a destination of that name already exists, so it is safe per example.

## 5. `trusted.certname` is the host fqdn unless `node` is set

rspec-puppet's `nodename` returns `node` when a `let(:node)` exists, otherwise
`Puppet[:certname]`, the fqdn of the machine running the tests
(`rspec-puppet-5.0.0/lib/rspec-puppet/support.rb:171`; identical in 4.0.2 and 6.0.0).

- Onceover emits `let(:node)` only since commit 952ff48 (released in v3.22.0), and only when
  the factset's trusted hash contains `certname`.
- So on 3.22.0, 4.0.0 and this checkout, factsets without trusted data still get the host
  fqdn (two of the three repro nodes). Before 3.22.0, every factset does.

Fix without templates: set the Puppet setting in the `before:` block. rspec-puppet builds
the catalog lazily inside the example, after the before hooks, and
`Puppet::Test::TestHelper.after_each_test` clears settings so it does not leak. The value
must be lowercase (Puppet's certname setting raises otherwise).

## 6. `warn` inside a `before:` block prints nothing

`Runner#run_spec!` appends `-W0` to `RUBYOPT` unless onceover runs with `--debug`
(`lib/onceover/runner.rb:82`, same in 3.22.0 and 4.0.0). `Kernel#warn` is silent when
`$VERBOSE` is nil. Use `$stderr.puts`.

## 7. Recommended `before:` block

```yaml
before:
  - |
    certname = trusted_facts['certname'] || node_facts['clientcert'] || node_facts['fqdn']
    Puppet[:certname] = certname.downcase
    Puppet::Util::Log.newdestination(:console)
    # Puppet::Util::Log.level = :debug   # if you need more than notice/warning;
    #                                    # puppetlabs_spec_helper resets the level after
    #                                    # each example, so it must be set here every time
    RSpec.configuration.default_node_params = {
      'site'   => certname[0, 4],
      'tenant' => certname.split('.')[1],
    }
```

## 8. Run results

`trusted.certname` reported by `site.pp` (run17 = before the fix, this checkout):

| node | before | with `Puppet[:certname]` (HEAD, 3.22.0, 4.0.0) |
|---|---|---|
| CentOS-7.0-64 | bliptop.cust.blueprintrf.com | centos7b.syd.puppetlabs.demo |
| with-clientcert | bliptop.cust.blueprintrf.com | cc01.fromclientcert.example.com |
| with-trusted | tr01.fromtrusted.example.com | tr01.fromtrusted.example.com |

Number of examples (of 3) whose `Puppet.warning` from the `before:` block was printed:

| onceover | SHOW_PUPPET_OUTPUT | without `newdestination` | with `newdestination` |
|---|---|---|---|
| 3.22.0 | true | 1 | 3 |
| 3.22.0 | false | not run | 3 |
| 4.0.0 | true | 1 | 3 |
| 4.0.0 | false | not run | 3 |
| this checkout | true | 3 | not needed |
| this checkout | false | 0 | not run |

`warn` output: 0 lines in every run.

## 9. Files

- Probe configs (passed via `ONCEOVER_YAML=...`, so `cr/spec/onceover.yaml` is untouched):
  `_tmp/repro/onceover.certname-probe.yaml`, `_tmp/repro/onceover.certname-probe.console.yaml`
- Logs: `_tmp/repro/run18.certname-probe.log`, `run19.head.show-output.log`,
  `run20.head.quiet.log`, `run.v3.22.0.{base.show,console.show,console.quiet}.log`,
  `run.v4.0.0.{base.show,console.show,console.quiet}.log`
- Old-version worktrees: `_tmp/repro/onceover-v3.22.0`, `_tmp/repro/onceover-v4.0.0`
- Old-version bundles: `_tmp/repro/bundle-<tag>/Gemfile` with `BUNDLE_PATH=_scratchpads/vendor-<tag>`.
  rspec-puppet must be `< 5` there: the old generated spec_helper's
  `puppetlabs_spec_helper/module_spec_helper` calls `manifest_dir=`, removed in rspec-puppet 5.

Example run of an old version:

```sh
cd _tmp/repro/cr
export PATH=/opt/puppetlabs/bolt/bin:$PATH
export BUNDLE_GEMFILE=$PWD/../bundle-v4.0.0/Gemfile BUNDLE_PATH=$PWD/../../../_scratchpads/vendor-v4.0.0
SHOW_PUPPET_OUTPUT=true ONCEOVER_YAML=$PWD/../onceover.certname-probe.console.yaml \
  bundle exec onceover run spec --tempdir $PWD/.onceover-v4.0.0
```

Do not run two versions concurrently from the same control repo: the deploy step copies the
control repo, including the other run's `.onceover-*` directory, and races on it.
