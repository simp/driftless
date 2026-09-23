# onceover probes

Selective diagnostics for `onceover run spec`, installed from the `before:`
block of `spec/onceover.yaml`. No onceover template override is needed.

Two problems it is written for:

- Finding which module code launches a subprocess during catalog compilation
  (for example the `systemctl` call behind `Failed to get D-Bus connection`
  messages in CI).
- Getting debug-level detail from Puppet for specific lookups, facts, types
  and providers without turning on Puppet's global `debug` level, which is far
  too large for a size-limited CI log.

Tested with onceover (master, 2026-09), openvox 8.29.0, openfact 5.7.0,
rspec-puppet 5.0.0, Ruby 3.2 from Bolt.

## Install

1. Copy `spec/onceover_probes.rb` into the `spec/` directory of the control
   repo.
2. Add the `before:` block from `spec/onceover.yaml.example` to
   `spec/onceover.yaml`, keeping only the probes you want.

The `before:` block runs before every example. Every `OnceoverProbes` method
can be called repeatedly: hooks are installed once per process and only the
patterns are refreshed.

## Output

Messages go through Puppet's logger at `notice` level, so they appear when
onceover runs with `SHOW_PUPPET_OUTPUT=true`. When Puppet has no log
destination (the variable is unset or not the string `true`) they go to
stderr instead. Either way they end up in the onceover output.

`SHOW_PUPPET_OUTPUT` is read when onceover generates `spec_helper.rb`, so it
must be set in the environment of the `onceover run spec` process itself.

## Probes

### `exec_trace(file: nil, only: nil, summary_lines: 20)`

Wraps `Puppet::Util::Execution.execute` and `execpipe`,
`Facter::Core::Execution.execute` and `exec`, and Ruby's backticks, `system`,
`spawn`, `Process.spawn` and `IO.popen`. Anything a function, type, provider
confine, ERB template or fact runs at compile time goes through one of these.

Each launch is appended immediately to the trace file, default
`.onceover/exec_trace.<pid>.log`:

```
20:06:41 execute systemctl is-active onceover-probe.service
  example: role::x using fact set CentOS-7.0-64
  puppet:  etc/puppetlabs/code/environments/production/site/probe/manifests/init.pp:5
  via:     etc/puppetlabs/code/environments/production/site/probe/lib/puppet/functions/probe/run_systemctl.rb:8 in run
  origin:  etc/puppetlabs/code/environments/production/site/probe/lib/puppet/functions/probe/run_systemctl.rb:8 in run
```

- `example` is the rspec example that was running.
- `puppet` is the Puppet file and line being evaluated, when there is one.
- `via` is the immediate Ruby caller.
- `origin` lines are the nearest frames outside the Puppet, Facter, RSpec and
  onceover gems, which is normally the module file.

At process exit a summary goes to stderr, one entry per unique command and
origin, most frequent first, capped at `summary_lines`:

```
[exec-trace] 17 subprocess launches, 13 unique, pid 2365816; details in /.../.onceover/exec_trace.2365816.log
[exec-trace] 3x systemctl is-active onceover-probe.service
[exec-trace]     .../site/probe/lib/puppet/functions/probe/run_systemctl.rb:8 in run
[exec-trace] 1x ip link show
[exec-trace]     spec/classes/role__x_on_CentOS-7.0-64_spec.rb:113 in block (3 levels) in <top (required)> (via openfact-5.7.0/lib/facter/resolvers/linux/networking.rb:45 in interfaces_mtu_and_index)
```

Options:

- `only:` a Regexp or String; record only commands matching it.
- `file:` path of the trace file. The default is per process, so parallel
  workers do not overwrite each other.
- `summary_lines:` cap on the summary.

### `trace_lookups(*patterns, level: :notice, max_lines: 40)`

For `lookup()` calls and automatic parameter lookups whose key matches one of
the patterns (Regexp, or String for an exact match), attaches Puppet's own
explainer and prints the hierarchy walk, the same information as
`puppet lookup --explain`:

```
Notice: Automatic Parameter Lookup of 'role::x::apl_param' at test manifest:15
  Searching for "role::x::apl_param"
    Global Data Provider (hiera configuration version 5)
      Hierarchy entry "common"
        Path ".../data/common.yaml"
          Found key: "role::x::apl_param" value: "apl_from_common"
```

Multi-line value dumps are collapsed to one line, so an interpolation over
`%{facts.os.family}` prints `Found key: "facts" value: {...346 lines...}`
instead of the whole facts hash. `max_lines` caps the rest of the
explanation.

### `trace_facts(*patterns, level: :notice)`

Reports reads of matching facts through `$facts['name']`, `%{facts.name}`
interpolation in `hiera.yaml` and data files, and top-scope variables such as
`$::kernel`. Only the top-level fact name is matched (`os`, not `os.family`).
Each key is reported once per location per example.

```
Notice: Read of fact 'os' at .../site/role/manifests/x.pp:7
Notice: Read of variable 'kernel' at test manifest:15 in role::x
```

### `trace_types(level: :notice, per_example: false)`

Reports each Puppet type and provider as its Ruby file is loaded, and the
provider each resource type ends up with when rspec-puppet converts the
catalog to RAL resources for the `compile` matcher:

```
Notice: Type loaded: probe_svc (.../site/probe/lib/puppet/type/probe_svc.rb)
Notice: Provider loaded: probe_svc/systemd (.../site/probe/lib/puppet/provider/probe_svc/systemd.rb)
Notice: Provider used: probe_svc/systemd (first on Probe_svc[onceover-probe] in role::x using fact set CentOS-7.0-64)
```

"Provider used" is reported once per type/provider pair per process by
default; `per_example: true` repeats it in every example.

## Using it in GitLab CI

The console output is kept short on purpose. Keep the full record as a job
artifact:

```yaml
artifacts:
  when: always
  paths:
    - .onceover/exec_trace.*.log
```

For a focused run, restrict the tracer to the commands of interest and lower
the summary cap:

```ruby
OnceoverProbes.exec_trace(only: /systemctl|dbus/, summary_lines: 10)
```

## What the reproduction showed

Findings from the scratch control repo in `_tmp/repro/cr` (onceover repo),
which has a `site/probe` module that runs `systemctl` from a function, a
provider confine and a custom fact:

- Module custom-fact files (`lib/facter/*.rb`) are never loaded during an
  onceover run, not even their load-time code. Facts come only from the
  factset. Custom facts are not a candidate for compile-time commands.
- Provider confines and `defaultfor` blocks run once per process per type,
  because `Puppet::Type.defaultprovider` memoizes its result. Type and
  provider files also load once. This is the only once-per-process mechanism
  on the compile path, so a command that appears only in the first example is
  likely to come from a provider or type file.
- Functions and ERB templates run in every example.
- rspec-puppet resolves the server facts through real Facter in every
  example, which runs `ip link show` and `ip route show`. Nothing in openvox
  or openfact runs `systemctl` at compile time.
- `Failed to get D-Bus connection: Operation not permitted` is the wording of
  the `systemctl` shipped with EL7-era systemd when run inside an
  unprivileged container. Newer systemd wording differs.

## Limitations

- The Puppet location is the innermost Puppet function call in progress,
  because that is all Puppet keeps on its stack. A read inside a class body
  is reported at the surrounding `include`, `notice` or similar call. Code
  from the generated test manifest shows as `test manifest:<line>`.
- Commands run by a child process (for example a script launched by a
  function) are not seen; only the launch of the child is.
- The tracer hooks are process-wide. Anything else in the rspec process that
  launches a command is recorded too, which is why Facter's `ip` calls appear.
- The `before:` block cannot change rspec-puppet's `facter_implementation`;
  that is fixed before the first example runs.
