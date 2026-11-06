require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'json'
require 'open3'
require 'rbconfig'

require 'support/fixture_repo'
require 'pupgrade/cli/catalog'

# `compile` against the fixture control repo and its two factsets.
RSpec.describe Pupgrade::CLI::Catalog::Compile do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    @tmp     = Dir.mktmpdir
    @fixture = Pupgrade::FixtureRepo.build(File.join(@tmp, 'repo'))
  end

  after(:all) { FileUtils.rm_rf(@tmp) } # rubocop:disable RSpec/BeforeAfterAll

  let(:fixture) { @fixture }
  let(:out)     { File.join(@tmp, "out-#{rand(1_000_000)}") }

  # [exit status, stdout]
  def run(argv)
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    status   = nil
    begin
      described_class.new.run(['--no-config', '-d', fixture.dir, '--factsets', 'factsets', '-o', out] + argv)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    [status, captured.string]
  end

  def cells(output)
    output.lines.map(&:rstrip).reject { |l| l.start_with?('--') }.map { |l| l.split('|', -1).map(&:strip) }
  end

  def read(certname, name)
    JSON.parse(File.read(File.join(out, certname, name)))
  end

  around(:each) do |ex|
    original = Pupgrade.instance_variable_get(:@config)
    ex.run
  ensure
    Pupgrade.instance_variable_set(:@config, original)
  end

  before(:each) { silence_logger }

  it 'compiles every factset with the mocks, in both layouts, and writes catalog and probes per node' do
    status, text = run(['--mocks', 'pupgrade/compiler/mocks.yaml'])
    expect(status).to eq(0)
    expect(cells(text)).to eq([
      %w[certname resources classes warnings mocks leaks missing status],
      %w[db01.example.com 12 7 1 1 0 0 ok],
      %w[web01.example.com 12 7 1 1 0 0 ok],
    ])
    expect(Dir.children(out).sort).to eq(%w[db01.example.com web01.example.com])
    expect(Dir.children(File.join(out, 'web01.example.com')).sort).to eq(%w[catalog.json compile.json])
    File.write(File.join(out, 'web01.example.com', 'probes.json'), '{}')
    run(['--mocks', 'pupgrade/compiler/mocks.yaml', '--certname', 'web*'])
    expect(Dir.children(File.join(out, 'web01.example.com')).sort).to eq(%w[catalog.json compile.json])

    catalog = read('web01.example.com', 'catalog.json')
    expect(catalog.keys).to eq(%w[catalog_format classes code_id edges environment name resources tags version])
    expect(catalog['name']).to eq('web01.example.com')
    expect(catalog['version']).to eq(0)
    expect(catalog['resources'].map { |r| "#{r['type']}[#{r['title']}]" }).to eq(
      catalog['resources'].map { |r| "#{r['type']}[#{r['title']}]" }.sort_by { |s| s.split('[', 2) },
    )
    fragment = catalog['resources'].find { |r| r['type'] == 'Notify' }
    expect(fragment['parameters']['message']).to eq('RedHat on web01.example.com: RedHat RedHat HI HI hi mocked.example.com time.example.com default')
    firewall = catalog['resources'].find { |r| r['type'] == 'Firewall' }
    expect(firewall['parameters']).to include('provider' => 'iptables', 'action' => 'accept')

    probes = read('web01.example.com', 'compile.json')
    expect(probes).to include('document' => 'compile', 'schema_version' => 3, 'certname' => 'web01.example.com', 'status' => 'ok', 'environment' => 'production')
    expect(probes['functions'].slice('stdlib::shout', 'legacy_shout', 'stdlib::whisper', 'stdlib::run_hostname').transform_values { |f| f['module'] })
      .to eq('stdlib::shout' => 'stdlib', 'legacy_shout' => 'stdlib', 'stdlib::whisper' => 'stdlib', 'stdlib::run_hostname' => 'stdlib')
    expect(probes['functions']['stdlib::shout']).to include('calls' => 1, 'sites' => ['site-modules/profile/manifests/base.pp:10'])
    expect(probes['functions']['include']['module']).to be_nil
    expect(probes['facts']).to eq('kernel' => 1, 'networking.fqdn' => 1, 'os' => 1, 'os.family' => 2, 'os.release.major' => 1)
    expect(probes['legacy_facts']).to eq('osfamily' => 1)
    expect(probes['type_aliases'].keys).to eq(['Stdlib::Port'])
    expect(probes['type_aliases']['Stdlib::Port']).to include('module' => 'stdlib', 'sites' => ['site-modules/profile/manifests/base.pp:4'])
    expect(probes['type_aliases']['Stdlib::Port']['uses']).to be_positive
    expect(read('db01.example.com', 'compile.json')['type_aliases']['Stdlib::Port']).to include('module' => 'stdlib')
    expect(probes['lookups']).to include(
      'profile::base::ntp_servers' => { 'found' => true, 'automatic' => 1, 'explicit' => 1 },
      'profile::base::banner'      => { 'found' => true, 'automatic' => 1, 'explicit' => 0 },
      'profile::base::absent'      => { 'found' => false, 'automatic' => 0, 'explicit' => 1 },
      'ntp::version'               => { 'found' => false, 'automatic' => 1, 'explicit' => 0 },
    )
    expect(probes['deprecations']).to eq([{ 'message' => 'legacy_shout is deprecated; use stdlib::shout' }])
    expect(probes['warnings']).to eq([]) # the deprecation is not counted twice
    # Puppet's own warnings reach the log as warnings, deprecations as info
    allow(Driftless).to receive(:logger).and_call_original
    log = capture_log(level: :info) { run(['-v', '--mocks', 'pupgrade/compiler/mocks.yaml', '--certname', 'web01*']) }
    expect(log).to include('info: puppet: web01.example.com: deprecation: legacy_shout is deprecated; use stdlib::shout')
    expect(log).not_to include('warning: puppet:')
    code = ['-v', '--mocks', 'pupgrade/compiler/mocks.yaml', '--certname', 'web01*', '--code', 'notify { "x": } warning("from the manifest")']
    log = capture_log(level: :warning) { run(code) }
    expect(log).to include('warning: puppet: web01.example.com: from the manifest')
    expect(log).not_to include('file & line not available')
    expect(probes.values_at('leaks', 'missing')).to eq([[], []])
    expect(probes['mocks']).to eq([{ 'kind' => 'execute', 'command' => 'hostname -f', 'action' => 'mocked',
                                     'location' => 'site-modules/profile/manifests/base.pp:13 via modules/stdlib/lib/puppet/functions/stdlib/run_hostname.rb:4' }])
    expect(probes['classes']).to include('apache' => { 'module' => 'apache', 'sites' => ['site-modules/role/manifests/web.pp:3'] },
                                         'profile::base' => { 'module' => 'profile', 'sites' => ['site-modules/role/manifests/web.pp:2'] },
                                         'role::web' => { 'module' => 'role', 'sites' => ['manifests/site.pp:2'] })
    expect(probes['defined_types']).to eq('concat::fragment' => { 'module' => 'concat', 'resources' => 1 })
    expect(probes['types']).to eq('firewall' => { 'module' => 'firewall', 'resources' => 1 }, 'notify' => { 'module' => nil, 'resources' => 1 })
    expect(probes['providers_named']).to eq('firewall/iptables' => { 'module' => 'firewall', 'resources' => 1 })

    db = read('db01.example.com', 'compile.json')
    expect(db['factset']).to end_with('factsets/db01.example.com.json')
    expect(read('db01.example.com', 'catalog.json')['resources'].find { |r| r['type'] == 'Notify' }['parameters']['message']).to start_with('Debian on db01.example.com')
  end

  it 'removes node directories no factset names after a full run, not after a filtered one or with --keep-stale' do
    gone = File.join(out, 'gone.example.com')
    FileUtils.mkdir_p(gone)
    File.write(File.join(gone, 'compile.json'), "{}\n")
    FileUtils.mkdir_p(File.join(out, 'notes'))
    run(['--mocks', 'pupgrade/compiler/mocks.yaml', '--certname', 'web*'])
    expect(Dir.children(out).sort).to eq(%w[gone.example.com notes web01.example.com])
    run(['--mocks', 'pupgrade/compiler/mocks.yaml', '--keep-stale'])
    expect(Dir.children(out).sort).to eq(%w[db01.example.com gone.example.com notes web01.example.com])
    run(['--mocks', 'pupgrade/compiler/mocks.yaml'])
    expect(Dir.children(out).sort).to eq(%w[db01.example.com notes web01.example.com])
  end

  it 'stops a compile at a command the mocks do not answer, records and logs it, lists it, and exits 1' do
    empty = File.join(@tmp, 'empty-mocks.yaml')
    File.write(empty, "commands: []\n")
    allow(Driftless).to receive(:logger).and_call_original
    status = text = nil
    log = capture_log(level: :warning) do
      status, text = run(['--mocks', empty, '--on-leak', 'fail'])
    end
    expect(status).to eq(1)
    rows = cells(text)
    expect(rows.drop(1).take(2).map { |r| r.values_at(4, 5, 6, 7) }).to eq([%w[0 1 0 failed], %w[0 1 0 failed]])
    expect(text).to include('web01.example.com: Evaluation Error')
    expect(log.lines.grep(/\Awarning: guard:/).size).to eq(2)
    expect(log).to include('warning: guard: web01.example.com: execute: "hostname -f" is not mocked at')
    expect(log).to include('warning: compile: web01.example.com failed in')
    expect(Dir.children(File.join(out, 'web01.example.com')).sort).to eq(%w[compile.json error.txt])
    expect(File.read(File.join(out, 'web01.example.com/error.txt'))).to include('execute: "hostname -f" is not mocked')
    probes = read('web01.example.com', 'compile.json')
    expect(probes['status']).to eq('failed')
    expect(probes['leaks'].first).to include('action' => 'raised')
    expect(probes).not_to have_key('classes')

    status, text = run(['--mocks', empty, '--fail-fast'])
    expect(status).to eq(1)
    expect(cells(text).drop(1).select { |r| r.size > 1 }.map(&:first)).to eq(%w[db01.example.com])
  end

  it 'shows progress on request, logs mocked answers at the level asked, and prints the default mocks' do
    allow(Driftless).to receive(:logger).and_call_original
    text = nil
    log = capture_log(level: :debug) do
      _, text = run(['-v', '--progress', '--on-mock', 'notice', '--certname', 'web*'])
    end
    expect(text).to start_with("P\n")
    expect(log).to include('notice: guard: web01.example.com: execute: "hostname -f": mocked at')
    expect(log).to include('info: compile: mocks from ')
    # a filter traces one node, or the nodes with a fact, and leaves the rest at the default
    log = capture_log(level: :debug) { run(['-vv', '--on-mock', 'certname=web*:notice', '--on-mock', 'facts.os.family=Debian:info']) }
    expect(log).to include('notice: guard: web01.example.com: execute: "hostname -f": mocked at', 'info: guard: db01.example.com: execute: "hostname -f": mocked at')
    expect(run(['--on-mock', 'node=web*:info']).first).to eq(3)

    status, text = run(['--show-default-mocks'])
    expect(status).to eq(0)
    expect(text).to include('rpm --version')
  end

  it 'gives each node the variables and classes the ENC stand-in decides, from the files found beside the config' do
    status, out_text = run(['--certname', 'web*', '--prepend', 'notify { "${site} ${tenant} ${pkg_manager}": }'])
    expect(status).to eq(0)
    expect(out_text).to include('web01.example.com')
    catalog = read('web01.example.com', 'catalog.json')
    expect(catalog['resources'].find { |r| r['type'] == 'Notify' }['title']).to eq('example blue dnf')
    probes = read('web01.example.com', 'compile.json')
    expect(probes['enc']).to eq('variables' => { 'site' => 'example', 'pkg_manager' => 'dnf', 'tenant' => 'blue' }, 'classes' => [])
    # the Ruby mock declines, so the YAML mock answers hostname
    expect(probes['mocks'].map { |l| l['action'] }).to eq(['mocked'])

    File.write(File.join(@tmp, 'other.rb'), "variable(:tenant) { |_n| 'green' }\nclasses { |_n| ['stdlib'] }\nmock(/\\Ahostname/) { |_n, _m| \"ruby.example.com\\n\" }\n")
    _, _ = run(['--certname', 'web*', '--ruby', File.join(@tmp, 'other.rb'), '--prepend', 'notify { "${tenant}": }'])
    catalog = read('web01.example.com', 'catalog.json')
    expect(catalog['resources'].find { |r| r['type'] == 'Notify' && r['title'] == 'green' }).not_to be_nil
    expect(catalog['resources'].find { |r| r['type'] == 'Notify' && r['title'] != 'green' }['parameters']['message']).to include('ruby.example.com')
    expect(catalog['classes']).to include('stdlib')
    expect(read('web01.example.com', 'compile.json')['enc']['classes']).to eq(['stdlib'])
    expect(read('web01.example.com', 'compile.json')['classes']['stdlib']).to eq('module' => 'stdlib', 'sites' => ['enc'])
    # a named file that is not there is warned about, not required
    allow(Driftless).to receive(:logger).and_call_original
    status = nil
    log = capture_log(level: :warning) { status, = run(['--enc', File.join(@tmp, 'nope.yaml'), '--ruby', File.join(@tmp, 'nope.rb'), '--certname', 'web*']) }
    expect(status).to eq(0)
    expect(log).to include("warning: compile: enc #{File.join(@tmp, 'nope.yaml')} is not there; going on without it")
    expect(log).to include("warning: compile: ruby #{File.join(@tmp, 'nope.rb')} is not there; going on without it")
  end

  it 'answers function calls from the mocks, from Puppet code and from Ruby, and records them' do
    mocks = File.join(@tmp, 'function-mocks.yaml')
    File.write(mocks, "functions:\n  - name: stdlib::run_hostname\n    returns: from-the-mock\n")
    ruby = File.join(@tmp, 'function-mocks.rb')
    File.write(ruby, "function('stdlib::shout') { |node, text| \"\#{text} to \#{node.certname}\" }\n")
    functions = File.join(fixture.dir, 'site-modules/fmock/lib/puppet/functions/fmock')
    FileUtils.mkdir_p(functions)
    File.write(File.join(functions, 'outer.rb'),
               "Puppet::Functions.create_function(:'fmock::outer') do\n  def outer\n    call_function('stdlib::run_hostname')\n  end\nend\n")

    # no command mock answers hostname -f: the compile passes only if the function never runs
    status, = run(['--mocks', mocks, '--no-default-mocks', '--ruby', ruby, '--certname', 'web*'])
    expect(status).to eq(0)
    fragment = read('web01.example.com', 'catalog.json')['resources'].find { |r| r['type'] == 'Concat::Fragment' }
    expect(fragment['parameters']['content']).to include('hi to web01.example.com', 'from-the-mock')
    expect(read('web01.example.com', 'compile.json')['mocks'].map { |m| m.values_at('kind', 'command', 'location') })
      .to include(%w[function stdlib::run_hostname site-modules/profile/manifests/base.pp:13], %w[function stdlib::shout site-modules/profile/manifests/base.pp:10])

    status, = run(['--mocks', mocks, '--no-default-mocks', '--certname', 'web*', '--code', 'notify { fmock::outer(): }'])
    expect(status).to eq(0)
    expect(read('web01.example.com', 'catalog.json')['resources'].map { |r| r['title'] }).to include('from-the-mock')
  ensure
    FileUtils.rm_rf(File.join(fixture.dir, 'site-modules/fmock'))
  end

  it 'loads PSON for code written before Puppet 8 with --pson, and fails without it' do
    functions = File.join(fixture.dir, 'site-modules/psonfix/lib/puppet/parser/functions')
    FileUtils.mkdir_p(functions)
    File.write(File.join(functions, 'pson_name.rb'),
               "module Puppet::Parser::Functions\n  newfunction(:pson_name, type: :rvalue) { |args| PSON.load(args[0])['name'] }\nend\n")
    code = ['--mocks', 'pupgrade/compiler/mocks.yaml', '--certname', 'web*', '--code', %q(notify { pson_name('{"name":"from pson"}'): })]
    # without it first: once loaded, PSON stays for the process
    expect(run(code).first).to eq(1) unless defined?(::PSON)
    expect(File.read(File.join(out, 'web01.example.com/error.txt'))).to include('uninitialized constant Puppet::Parser::Functions::PSON') unless defined?(::PSON)
    expect(run(code + ['--pson']).first).to eq(0)
    expect(read('web01.example.com', 'catalog.json')['resources'].map { |r| r['title'] }).to include('from pson')
  ensure
    FileUtils.rm_rf(File.join(fixture.dir, 'site-modules/psonfix'))
  end

  it 'compiles code in place of the manifest, with top-scope variables and a certname filter, --prepend before it' do
    status, text = run(['--mocks', 'pupgrade/compiler/mocks.yaml', '--certname', 'web*', '--code', 'notify { "hello ${role}": }', '--var', 'role=db'])
    expect(status).to eq(0)
    expect(cells(text).drop(1).map(&:first)).to eq(['web01.example.com'])
    catalog = read('web01.example.com', 'catalog.json')
    expect(catalog['resources'].map { |r| r['title'] }).to include('hello db')
    expect(catalog['classes']).to eq(%w[settings])
    status, = run(['--mocks', 'pupgrade/compiler/mocks.yaml', '--certname', 'web*', '--prepend', '$greeting = "hi"', '--code', 'notify { "${greeting} ${role}": }', '--var', 'role=db'])
    expect(status).to eq(0)
    catalog = read('web01.example.com', 'catalog.json')
    expect(catalog['resources'].map { |r| r['title'] }).to include('hi db')
    expect(catalog['classes']).to eq(%w[settings])
  end

  it 'records where each class was added: a declaration at its file and line, --prepend and --code by the flag, the manifest keeping its file' do
    File.write(File.join(fixture.dir, 'pre.pp'), "class { 'timezone': }\n")
    status, = run(['--mocks', 'pupgrade/compiler/mocks.yaml', '--certname', 'web*', '--prepend', '@pre.pp'])
    expect(status).to eq(0)
    classes = read('web01.example.com', 'compile.json')['classes']
    expect(classes['timezone']['sites']).to eq(['pre.pp:1', 'site-modules/profile/manifests/base.pp:7'])
    expect(classes['role::web']['sites']).to eq(['manifests/site.pp:2'])

    code = "class { 'role::web': }\ninclude ntp"
    status, = run(['--mocks', 'pupgrade/compiler/mocks.yaml', '--certname', 'web*', '--prepend', 'include ntp', '--code', code])
    expect(status).to eq(0)
    classes = read('web01.example.com', 'compile.json')['classes']
    expect(classes['role::web']['sites']).to eq(['--code:1'])
    expect(classes['ntp']['sites']).to eq(['--prepend:1', 'site-modules/profile/manifests/base.pp:6', '--code:2'])
    # what role::web adds while the declaration evaluates it keeps its own sites
    expect(classes['apache']['sites']).to eq(['site-modules/role/manifests/web.pp:3'])
  ensure
    FileUtils.rm_f(File.join(fixture.dir, 'pre.pp'))
  end

  it 'takes the manifest, the prepended file, the mocks, and the factsets from the config file' do
    File.write(File.join(fixture.dir, 'before.pp'), "notify { 'from before': }\n")
    File.write(File.join(fixture.dir, 'alt.pp'), "notify { 'from alt': }\n")
    cfg = File.join(@tmp, 'pupgrade.yaml')
    File.write(cfg, <<~YAML)
      compile:
        factsets: [factsets]
        manifest: alt.pp
        prepend_file: before.pp
        mocks: pupgrade/compiler/mocks.yaml
        cache_dir: #{out}
        vars:
          role: db
      logging:
        file: #{File.join(@tmp, 'cfg.log')}
        file_level: notice
    YAML
    allow(Driftless).to receive(:logger).and_call_original
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    status   = nil
    begin
      described_class.new.run(['-c', cfg, '-d', fixture.dir, '--certname', 'web01*'])
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    expect(status).to eq(0)
    titles = read('web01.example.com', 'catalog.json')['resources'].select { |r| r['type'] == 'Notify' }.map { |r| r['title'] }
    expect(titles).to eq(['from alt', 'from before'])
    # logging.file at logging.file_level, whatever the terminal shows
    log = File.read(File.join(@tmp, 'cfg.log'))
    expect(log).to include('notice: compile: 1 compiled, 0 failed')
    expect(log).not_to include('info: ')
  end

  it 'writes the log to --log-file under a header, debug lines and no escape codes, the runs before kept as .1, .2; the compile log by default' do
    allow(Driftless).to receive(:logger).and_call_original
    # the compile's own log, with nothing asked for
    default = File.join(fixture.dir, 'pupgrade/logs/pupgrade-compile.log')
    FileUtils.rm_f(default)
    capture_log(level: :notice) { expect(run(['--certname', 'web*']).first).to eq(0) }
    expect(File.read(default)).to include('--- pupgrade --no-config ', 'notice: compile: 1 compiled, 0 failed', 'debug: ')
    path = File.join(@tmp, 'log', 'run.log')
    # a missing --ruby file is warned about, and a warning's label is colored
    args = ['--log-file', path, '--certname', 'web*', '--color', '--mocks', 'pupgrade/compiler/mocks.yaml', '--ruby', File.join(@tmp, 'nope.rb')]
    terminal = capture_log(level: :notice) { expect(run(args).first).to eq(0) }
    expect(terminal).to include("\e[", 'warning:', 'compile: 1 compiled')
    expect(terminal).not_to include('debug: ')
    log = File.read(path)
    expect(log.lines.first).to start_with('--- pupgrade --no-config ').and include('--log-file ', ' at 20')
    expect(log).to include('warning: compile: ruby ', 'notice: compile: 1 compiled, 0 failed', 'debug: ')
    expect(log).not_to include("\e[")

    # the next run overwrites, the run before moving to .1, then .2
    capture_log(level: :notice) { run(['--log-file', path, '--certname', 'web*', '--mocks', 'pupgrade/compiler/mocks.yaml']) }
    expect(File.read(path).scan(/^--- pupgrade /).size).to eq(1)
    expect(File.read(path)).not_to include('--ruby')
    expect(File.read("#{path}.1")).to include('--ruby')
    capture_log(level: :notice) { run(['--log-file', path, '--certname', 'web*', '--mocks', 'pupgrade/compiler/mocks.yaml']) }
    expect(File.read("#{path}.2")).to include('--ruby')
    # logging.file_mode append keeps every run in the file; file_keep 0 keeps nothing beside it; a mode that is not one is a config error
    cfg = File.join(@tmp, 'log-mode.yaml')
    appended = File.join(@tmp, 'log', 'appended.log')
    File.write(cfg, "compile:\n  factsets: [factsets]\n  cache_dir: #{out}\n  log_file: ''\nlogging:\n  file: #{appended}\n  file_mode: append\n")
    FileUtils.rm_f(default)
    2.times { capture_log(level: :notice) { expect { described_class.new.run(['-c', cfg, '-d', fixture.dir, '--certname', 'web*']) }.to raise_error(SystemExit) } }
    expect(File.read(appended).scan(/^--- pupgrade /).size).to eq(2)
    expect(File.exist?(default)).to be(false)
    File.write(cfg, "compile:\n  factsets: [factsets]\n  cache_dir: #{out}\nlogging:\n  file: #{path}\n  file_keep: 0\n")
    FileUtils.rm_f(["#{path}.1", "#{path}.2"])
    capture_log(level: :notice) { expect { described_class.new.run(['-c', cfg, '-d', fixture.dir, '--certname', 'web*']) }.to raise_error(SystemExit) }
    expect(File.exist?("#{path}.1")).to be(false)
    File.write(cfg, "compile:\n  factsets: [factsets]\nlogging:\n  file: #{path}\n  file_mode: sideways\n")
    log = capture_log(level: :fatal) { expect { described_class.new.run(['-c', cfg, '-d', fixture.dir]) }.to raise_error(SystemExit) { |e| expect(e.status).to eq(2) } }
    expect(log).to include('FATAL: config error: logging.file_mode: "sideways" is not overwrite or append')

    # a file that cannot be opened stops the command before it runs
    File.write(File.join(@tmp, 'not-a-dir'), '')
    log = capture_log(level: :fatal) { expect(run(['--log-file', File.join(@tmp, 'not-a-dir', 'x.log')]).first).to eq(2) }
    expect(log).to include('FATAL: log file ')
  end

  it 'applies Puppet settings from the flag and the config, and refuses one Puppet does not know' do
    # Puppet 8 is strict about unknown variables unless told otherwise,
    # twice: strict_variables makes one an error, and strict=error raises
    # the warning it is otherwise
    code = ['--mocks', 'pupgrade/compiler/mocks.yaml', '--certname', 'web*', '--code', 'notify { "x${nope}": }']
    status, text = run(code)
    expect(status).to eq(1)
    expect(text).to include('Unknown variable')
    expect(run(code + ['--setting', 'strict_variables=false']).first).to eq(1)
    expect(run(code + ['--setting', 'strict_variables=false', '--setting', 'strict=warning']).first).to eq(0)
    # the session puts the process's settings back when it closes
    expect([Puppet[:strict_variables], Puppet[:strict]]).to eq([true, :error])
    expect(run(code + ['--setting', 'no_such_setting=1']).first).to eq(3)

    cfg = File.join(@tmp, 'settings.yaml')
    File.write(cfg, "compile:\n  factsets: [factsets]\n  cache_dir: #{out}\n  settings:\n    strict_variables: false\n    strict: warning\n  on_mock: ['certname=web*:notice']\n")
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    status   = nil
    allow(Driftless).to receive(:logger).and_call_original
    log = capture_log(level: :notice) do
      described_class.new.run(['-c', cfg, '-d', fixture.dir, '--mocks', 'pupgrade/compiler/mocks.yaml', '--certname', 'web*', '--code', 'notify { "x${nope}": }'])
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    expect(status).to eq(0)
    expect(log).not_to include(': execute:') # --code compiles no module code that runs a command
    expect(log).to include('notice: guard: web01.example.com: fact simplib_fips: mocked') # on_mock names notice for web*
    # compile.on_mock holds standing rules for the site manifest's compile
    $stdout = captured
    log = capture_log(level: :notice) do
      described_class.new.run(['-c', cfg, '-d', fixture.dir, '--mocks', 'pupgrade/compiler/mocks.yaml', '--certname', 'web*'])
    rescue SystemExit
      nil
    ensure
      $stdout = original
    end
    expect(log).to include('notice: guard: web01.example.com: execute: "hostname -f": mocked at')
  end

  it 'keeps the warnings the config calls ignorable off the terminal, in the record all the same' do
    cfg = File.join(@tmp, 'ignorable.yaml')
    File.write(cfg, "compile:\n  factsets: [factsets]\n  cache_dir: #{out}\n  ignorable_puppet_compile_messages: ['\\Afrom the', 'nothing else']\n" \
                    "  suppress_ignorable_puppet_compile_messages: debug\n")
    allow(Driftless).to receive(:logger).and_call_original
    code = ['-vv', '-c', cfg, '-d', fixture.dir, '--mocks', 'pupgrade/compiler/mocks.yaml', '--certname', 'web*', '--code', 'notify { "x": } warning("from the manifest") warning("kept")']
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    text = nil
    log = capture_log(level: :debug) do
      described_class.new.run(code)
    rescue SystemExit
      text = captured.string
    ensure
      $stdout = original
    end
    expect(log).to include('debug: puppet: web01.example.com: from the manifest (ignorable)', 'warning: puppet: web01.example.com: kept')
    expect(log).not_to include('warning: puppet: web01.example.com: from the manifest')
    expect(cells(text)[1].values_at(0, 3)).to eq(%w[web01.example.com 2])
    expect(read('web01.example.com', 'compile.json')['warnings'].map { |w| w['message'] }).to eq(['from the manifest', 'kept'])
    # off by default: the list alone changes nothing; -Q turns it on, -QQ drops the line from debug too
    File.write(cfg, "compile:\n  factsets: [factsets]\n  cache_dir: #{out}\n  ignorable_puppet_compile_messages: ['\\Afrom the']\n")
    $stdout = captured
    log = capture_log(level: :warning) do
      described_class.new.run(code)
    rescue SystemExit
      nil
    ensure
      $stdout = original
    end
    expect(log).to include('warning: puppet: web01.example.com: from the manifest')
    # the key's true is -QQ: gone from the log
    File.write(cfg, "compile:\n  factsets: [factsets]\n  cache_dir: #{out}\n  ignorable_puppet_compile_messages: ['\\Afrom the']\n  suppress_ignorable_puppet_compile_messages: true\n")
    $stdout = captured
    log = capture_log(level: :debug) do
      described_class.new.run(code)
    rescue SystemExit
      nil
    ensure
      $stdout = original
    end
    expect(log).not_to include('from the manifest')
    expect(log).to include('warning: puppet: web01.example.com: kept')
    File.write(cfg, "compile:\n  factsets: [factsets]\n  cache_dir: #{out}\n  ignorable_puppet_compile_messages: ['\\Afrom the']\n")
    [['-Q'], ['-QQ']].each do |flags|
      $stdout = captured
      log = capture_log(level: :debug) do
        described_class.new.run(code + flags)
      rescue SystemExit
        nil
      ensure
        $stdout = original
      end
      expect(log).not_to include('warning: puppet: web01.example.com: from the manifest')
      expect(log.include?('debug: puppet: web01.example.com: from the manifest (ignorable)')).to be(flags == ['-Q'])
      expect(log).to include('warning: puppet: web01.example.com: kept')
    end
    File.write(cfg, "compile:\n  factsets: [factsets]\n  cache_dir: #{out}\n  ignorable_puppet_compile_messages: ['(']\n  suppress_ignorable_puppet_compile_messages: true\n")
    $stdout = captured
    status = nil
    begin
      described_class.new.run(code)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    expect(status).to eq(3)
  end

  it 'reads the compiler files from their former places with a warning, and pupgrade/compiler/before.pp by default' do
    dir = File.join(fixture.dir, 'pupgrade')
    FileUtils.mv(File.join(dir, 'compiler/mocks.rb'), File.join(dir, 'compiler.rb'))
    FileUtils.mv(File.join(dir, 'compiler/enc.yaml'), File.join(dir, 'enc.yaml'))
    File.write(File.join(dir, 'compiler/before.pp'), "\$from_before = 'set before'\n")
    allow(Driftless).to receive(:logger).and_call_original
    status = nil
    log = capture_log(level: :info) { status, = run(['-v', '--certname', 'web*', '--code', 'notify { $from_before: }']) }
    expect(status).to eq(0)
    expect(read('web01.example.com', 'catalog.json')['resources'].map { |r| r['title'] }).to include('set before')
    expect(log).to include('warning: compile: pupgrade/compiler.rb is read from its old place; move it to pupgrade/compiler/mocks.rb',
                           'warning: compile: pupgrade/enc.yaml is read from its old place; move it to pupgrade/compiler/enc.yaml',
                           "info: enc: 2 rule(s) from #{dir}/enc.yaml")
    expect(log).not_to include('compiler-mocks.yaml is read')
  ensure
    FileUtils.mv(File.join(dir, 'compiler.rb'), File.join(dir, 'compiler/mocks.rb'))
    FileUtils.mv(File.join(dir, 'enc.yaml'), File.join(dir, 'compiler/enc.yaml'))
    FileUtils.rm_f(File.join(dir, 'compiler/before.pp'))
  end

  it 'merges the fact mocks into the node, an override noticed, and records the reads under mocks' do
    mocks = File.join(@tmp, 'fact-mocks.yaml')
    File.write(mocks, "facts:\n  operatingsystem: '${facts.os.name}'\n  kernel: Mocked\n  os:\n    extra: 'yes'\n    family: RedHat\n  unread: 1\n")
    allow(Driftless).to receive(:logger).and_call_original
    status = text = nil
    log = capture_log(level: :debug) do
      status, text = run(['-vv', '--mocks', mocks, '--certname', 'web*', '--code',
                          'notify { "${facts[\'operatingsystem\']} ${facts[\'kernel\']} ${facts[\'os\'][\'extra\']} ${facts[\'os\'][\'family\']} ${operatingsystem}": }'])
    end
    expect(status).to eq(0)
    expect(read('web01.example.com', 'catalog.json')['resources'].map { |r| r['title'] }).to include('Rocky Mocked yes RedHat Rocky')
    expect(log).to include('notice: guard: web01.example.com: fact kernel: mocked, overriding the factset\'s "Linux" with "Mocked"',
                           'debug: guard: web01.example.com: fact operatingsystem: mocked', 'debug: guard: web01.example.com: fact os.extra: mocked',
                           'debug: guard: web01.example.com: fact os.family: mocked, identical to the factset\'s "RedHat"')
    expect(log).to include('4 commands and 4 facts')
    # a count before each node's compile, at info
    expect(log).to include('info: compile: [1/1] web01.example.com')
    record = read('web01.example.com', 'compile.json')
    expect(record['mocks'].map { |m| m.values_at('kind', 'command', 'action') }).to contain_exactly(
      ['fact', 'operatingsystem', 'mocked'], ['fact', 'kernel', 'mocked (overrides factset)'], ['fact', 'os.extra', 'mocked'],
      ['fact', 'os.family', 'mocked (same as factset)'],
    )
    expect(record['facts']).to include('operatingsystem' => 1, 'kernel' => 1, 'os.extra' => 1, 'os.family' => 1)
    expect(record['legacy_facts']).to include('operatingsystem' => 1)
    expect(cells(text)[1].values_at(0, 4)).to eq(%w[web01.example.com 4])
    # a Ruby fact block answers first, from the facts as read; nil declines; the YAML mock at its path is passed over
    rb = File.join(@tmp, 'fact-blocks.rb')
    File.write(rb, "fact('kernel') { |node| 'FromRuby' if node.fact('kernel') == 'Linux' }\nfact('os.extra') { |_node| nil }\nfact('os.added') { |node| node.certname }\n")
    log = capture_log(level: :debug) do
      status, = run(['-vv', '--mocks', mocks, '--ruby', rb, '--certname', 'web*', '--code', 'notify { "${facts[\'kernel\']} ${facts[\'os\'][\'extra\']} ${facts[\'os\'][\'added\']}": }'])
    end
    expect(status).to eq(0)
    expect(read('web01.example.com', 'catalog.json')['resources'].map { |r| r['title'] }).to include('FromRuby yes web01.example.com')
    expect(log).to include('notice: guard: web01.example.com: fact kernel: mocked, overriding the factset\'s "Linux" with "FromRuby"',
                           'debug: guard: web01.example.com: fact kernel: answered by a fact block; the facts: mock is passed over',
                           'debug: guard: web01.example.com: fact os.added: mocked', '3 fact block(s)')
    # -Q quiets the mocked answers too, an override still noticed; --on-mock asks for them back
    log = capture_log(level: :debug) { run(['-vv', '--mocks', mocks, '--certname', 'web*', '-Q', '--code', 'notify { "x": }']) }
    expect(log).to include('notice: guard: web01.example.com: fact kernel: mocked, overriding')
    expect(log).not_to include('fact operatingsystem: mocked', 'fact os.family: mocked')
    log = capture_log(level: :debug) { run(['-vv', '--mocks', mocks, '--certname', 'web*', '-Q', '--on-mock', 'debug', '--code', 'notify { "x": }']) }
    expect(log).to include('debug: guard: web01.example.com: fact operatingsystem: mocked')
  end

  it 'logs a multi-line deprecation once, on one line, and keeps an ignorable one off the terminal' do
    functions = File.join(fixture.dir, 'site-modules/depr/lib/puppet/parser/functions')
    FileUtils.mkdir_p(functions)
    File.write(File.join(functions, 'old_way.rb'),
               "Puppet::Parser::Functions.newfunction(:old_way, type: :rvalue) do |_args|\n  Puppet.deprecation_warning(\"old_way is deprecated,\\n   use new_way. at [\\\"x.pp\\\", 1]\", 'old_way')\n  'x'\nend\n")
    allow(Driftless).to receive(:logger).and_call_original
    code = ['-vv', '--mocks', 'pupgrade/compiler/mocks.yaml', '--certname', 'web*', '--code', 'notify { old_way(): }']
    log = capture_log(level: :debug) { run(code) }
    expect(log.lines.grep(/old_way is deprecated/)).to eq(["info: puppet: web01.example.com: deprecation: old_way is deprecated, use new_way. at [\"x.pp\", 1]\n"])
    expect(read('web01.example.com', 'compile.json')['deprecations']).to eq([{ 'message' => "old_way is deprecated,\n   use new_way. at [\"x.pp\", 1]" }])
    expect(read('web01.example.com', 'compile.json')['warnings']).to eq([])

    cfg = File.join(@tmp, 'ignorable-depr.yaml')
    File.write(cfg, "compile:\n  factsets: [factsets]\n  cache_dir: #{out}\n  ignorable_puppet_compile_messages: ['deprecated, use new_way']\n  suppress_ignorable_puppet_compile_messages: debug\n")
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    log = capture_log(level: :debug) do
      described_class.new.run(['-vv', '-c', cfg, '-d', fixture.dir, '--mocks', 'pupgrade/compiler/mocks.yaml', '--certname', 'web*', '--code', 'notify { old_way(): }'])
    rescue SystemExit
      nil
    ensure
      $stdout = original
    end
    expect(log.lines.grep(/old_way is deprecated/)).to eq(["debug: puppet: web01.example.com: deprecation: old_way is deprecated, use new_way. at [\"x.pp\", 1] (ignorable)\n"])
    expect(read('web01.example.com', 'compile.json')['deprecations'].size).to eq(1)
  ensure
    FileUtils.rm_rf(File.join(fixture.dir, 'site-modules/depr'))
  end

  it 'compiles a certname once when two factset files carry it, warning which file is read' do
    dup = File.join(@tmp, 'dup-factsets')
    FileUtils.mkdir_p(dup)
    FileUtils.cp(File.join(fixture.dir, 'factsets/web01.example.com.json'), File.join(dup, 'web01-again.json'))
    allow(Driftless).to receive(:logger).and_call_original
    status = text = nil
    log = capture_log(level: :warning) { status, text = run(['--factsets', dup, '--mocks', 'pupgrade/compiler/mocks.yaml', '--certname', 'web*']) }
    expect(status).to eq(0)
    expect(cells(text).drop(1).map(&:first)).to eq(['web01.example.com'])
    expect(log).to include("warning: compile: web01.example.com: 2 factsets carry this certname; compiling #{File.join(fixture.dir, 'factsets/web01.example.com.json')}, not #{File.join(dup, 'web01-again.json')}")
  end

  it 'compiles each node in the environment a fact names, production with a warning when the fact is unset' do
    dir = File.join(@tmp, 'env-factsets')
    FileUtils.mkdir_p(dir)
    # the fixture's factsets dir is always given too, so these are new certnames
    { 'stg01' => 'staging', 'plain01' => nil, 'bad01' => 'Not-Valid' }.each do |host, env|
      data = JSON.parse(File.read(File.join(fixture.dir, 'factsets/web01.example.com.json')))
      data['name'] = "#{host}.example.com"
      data['trusted']['certname'] = data['name'] if data['trusted'].is_a?(Hash)
      data['values']['agent_specified_environment'] = env if env
      File.write(File.join(dir, "#{host}.example.com.json"), JSON.generate(data))
    end
    allow(Driftless).to receive(:logger).and_call_original
    status = text = nil
    log = capture_log(level: :warning) do
      status, text = run(['--factsets', dir, '--mocks', 'pupgrade/compiler/mocks.yaml', '--certname', 'stg*,plain*,bad*', '--environment', '${facts.agent_specified_environment}'])
    end
    expect(status).to eq(1)
    rows = cells(text).drop(1).select { |r| r.size > 1 }.to_h { |r| [r[0], r.last] }
    expect(rows).to eq('stg01.example.com' => 'ok', 'plain01.example.com' => 'ok', 'bad01.example.com' => 'failed')
    expect(read('stg01.example.com', 'compile.json')['environment']).to eq('staging')
    expect(read('stg01.example.com', 'catalog.json')['environment']).to eq('staging')
    expect(read('plain01.example.com', 'compile.json')['environment']).to eq('production')
    expect(log).to include('warning: compile: plain01.example.com: ${facts.agent_specified_environment} is empty for this node; compiling in production')
    expect(File.read(File.join(out, 'bad01.example.com/error.txt'))).to include('environment name "Not-Valid" (from ${facts.agent_specified_environment}) must be lowercase')
  end

  it 'counts a fact read with no value under missing, not leaks' do
    factset = JSON.parse(File.read(File.join(fixture.dir, 'factsets/web01.example.com.json')))
    factset['values'].delete('kernel')
    dir = File.join(@tmp, 'no-kernel')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'web01.example.com.json'), JSON.generate(factset))
    # the provider reads the fact as its file loads, once per process, so a process of its own
    out, status = Open3.capture2(RbConfig.ruby, '-I', File.expand_path('../../../lib', __dir__), File.expand_path('../../../bin/pupgrade', __dir__),
                                 '--no-config', '--no-color', 'catalog', 'compile', '-d', fixture.dir, '--factsets', dir, '-o', File.join(@tmp, 'no-kernel-out'),
                                 '--mocks', 'pupgrade/compiler/mocks.yaml', '--code', 'firewall { "x": action => "accept" }', err: File::NULL)
    expect(status.exitstatus).to eq(0)
    expect(cells(out)[1].values_at(0, 5, 6, 7)).to eq(%w[web01.example.com 0 1 ok])
  end

  it 'refuses missing factsets, a bad mock file, and an unknown leak policy' do
    expect(run(['--factsets', 'nope']).first).to eq(3)
    expect(run(['--mocks', 'nope.yaml']).first).to eq(1)
    expect(run(['--on-leak', 'ignore']).first).to eq(2)
    expect(run(['--on-leak', 'raise', '--mocks', File.join(@tmp, 'empty-mocks.yaml')]).first).to eq(1) # the old name of fail
    expect(run(['--certname', 'nothing']).first).to eq(3)
  end
end
