require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'

require 'support/fixture_repo'
require 'pupgrade/cli/module/usage'
require 'pupgrade/cli/catalog'

# `module usage` on the fixture, with evidence from a compile of both
# factsets.
RSpec.describe Pupgrade::CLI::ModuleCommand::Usage do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    @tmp      = Dir.mktmpdir
    @fixture  = Pupgrade::FixtureRepo.build(File.join(@tmp, 'repo'))
    @catalogs = File.join(@tmp, 'catalogs')
    silently { Pupgrade::CLI::Catalog::Compile.new.run(['--no-config', '-d', @fixture.dir, '--factsets', 'factsets', '-o', @catalogs, '--mocks', 'pupgrade/compiler-mocks.yaml']) }
  end

  after(:all) { FileUtils.rm_rf(@tmp) } # rubocop:disable RSpec/BeforeAfterAll

  let(:fixture)  { @fixture }
  let(:catalogs) { @catalogs }

  # [exit status, stdout]
  def run(argv, cache: catalogs)
    status = nil
    out = silently do
      described_class.new.run(['--no-config', '--no-color', '-d', fixture.dir, '--compile-cache', cache] + argv)
    rescue SystemExit => e
      status = e.status
    end
    [status, out]
  end

  def silently
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    yield
    captured.string
  rescue SystemExit
    captured.string
  ensure
    $stdout = original
  end

  def cells(output)
    output.lines.map(&:rstrip).reject { |l| l.start_with?('--') }.map { |l| l.split('|', -1).map(&:strip) }
  end

  before(:each) { silence_logger }

  it 'lists every item of the deployed surface with where the catalogs use it' do
    status, out = run(['stdlib'])
    expect(status).to eq(0)
    expect(cells(out)).to eq([
      %w[item used where],
      ['class stdlib', 'no', ''],
      ['function legacy_shout', 'yes', 'code: site-modules/profile/manifests/base.pp:11'],
      ['function stdlib::run_hostname', 'yes', 'code: site-modules/profile/manifests/base.pp:13'],
      ['function stdlib::shout', 'yes', 'code: site-modules/profile/manifests/base.pp:10'],
      ['function stdlib::whisper', 'yes', 'code: site-modules/profile/manifests/base.pp:12'],
      ['type alias Stdlib::Port', 'yes', 'nodes: db01.example.com, web01.example.com'],
    ])
    _, out = run(['firewall'])
    expect(cells(out).drop(1)).to include(
      ['type firewall', 'yes', 'resources: firewall[100 allow ntp 123] on db01.example.com, firewall[100 allow ntp 123] on web01.example.com'],
      ['provider firewall/iptables', 'yes', 'nodes: db01.example.com, web01.example.com'],
      ['provider firewall/ipv6', 'no', ''],
    )
    expect(cells(run(['concat']).last).drop(1).map(&:first)).to eq(['class concat', 'defined type concat::fragment'])
  end

  it 'adds class parameter rows with --params: a parameter is used when some node sets it' do
    status, out = run(['apache', '--params'])
    expect(status).to eq(0)
    expect(cells(out).drop(1)).to eq([
      ['class apache', 'yes', 'nodes: db01.example.com, web01.example.com'],
      ['param apache::dead_opt', 'yes', 'set: db01.example.com, web01.example.com'],
      ['param apache::legacy_opt', 'yes', 'set: db01.example.com, web01.example.com'],
      ['param apache::version', 'no', 'default: db01.example.com, web01.example.com'],
    ])
    expect(cells(run(['apache', '--params', '--unused']).last).drop(1).map(&:first)).to eq(['param apache::version'])
    # a parameter row matches --item as CLASS::PARAM
    expect(cells(run(['apache', '--params', '--item', '*dead*']).last).drop(1).map(&:first)).to eq(['param apache::dead_opt'])
    expect(cells(run(['apache', '--params', '--item', 'apache::*']).last).drop(1).map(&:first)).to eq(['param apache::dead_opt', 'param apache::legacy_opt', 'param apache::version'])
  end

  it 'renders the rows as json or yaml with --render-as, the filters applied, every use item listed' do
    require 'json'
    require 'yaml'
    status, out = run(['firewall', '--render-as', 'json', '--item', 'firewall', '--surfaces', 'types'])
    expect(status).to eq(0)
    expect(JSON.parse(out)).to eq([{
      'item' => 'type firewall', 'kind' => 'type', 'name' => 'firewall', 'used' => true,
      'uses' => [{ 'label' => 'resources', 'items' => [{ 'name' => 'firewall[100 allow ntp 123]', 'certname' => 'db01.example.com' },
                                                       { 'name' => 'firewall[100 allow ntp 123]', 'certname' => 'web01.example.com' }] }],
    }])
    _, out = run(['apache', '--render-as', 'yaml', '--params', '--item', 'apache::version'])
    expect(YAML.safe_load(out)).to eq([{
      'item' => 'param apache::version', 'kind' => 'param', 'name' => 'apache', 'param' => 'version', 'used' => false,
      'uses' => [{ 'label' => 'default', 'items' => [{ 'certname' => 'db01.example.com' }, { 'certname' => 'web01.example.com' }] }],
    }])
    expect(JSON.parse(run(['stdlib', '--render-as', 'json', '--item', 'legacy_shout']).last).first['uses'])
      .to eq([{ 'label' => 'code', 'items' => [{ 'name' => 'site-modules/profile/manifests/base.pp:11' }] }])
    expect(run(['stdlib', '--render-as', 'xml']).first).to eq(2)
  end

  it 'filters rows with --used, --unused, --surfaces, --item, --site, and --used-by, and exits 1 when nothing uses the module' do
    expect(cells(run(['stdlib', '--unused']).last).drop(1).map(&:first)).to eq(['class stdlib'])
    expect(cells(run(['stdlib', '--used']).last).drop(1).map(&:first)).not_to include('class stdlib')
    _, out = run(['stdlib', '--surfaces', 'functions', '--item', 'stdlib::*'])
    expect(cells(out).drop(1).map(&:first)).to eq(['function stdlib::run_hostname', 'function stdlib::shout', 'function stdlib::whisper'])
    # --site is a call site's file; --used-by any use, or one kind of use by prefix
    expect(cells(run(['stdlib', '--site', 'site-modules/profile/*']).last).drop(1).map(&:first)).to all(start_with('function '))
    expect(run(['stdlib', '--site', 'modules/*']).last).to eq("(nothing matches)\n")
    expect(cells(run(['stdlib', '--used-by', 'code:*/base.pp:11']).last).drop(1).map(&:first)).to eq(['function legacy_shout'])
    expect(run(['stdlib', '--used-by', 'path:*/base.pp:11']).last).to eq("(nothing matches)\n")
    expect(cells(run(['stdlib', '--used-by', 'node:db01*']).last).drop(1).map(&:first)).to eq(['type alias Stdlib::Port'])
    expect(cells(run(['firewall', '--used-by', 'resource:firewall[100*']).last).drop(1).map(&:first)).to eq(['type firewall'])
    expect(cells(run(['firewall', '--used-by', 'db01.example.com']).last).drop(1).map(&:first)).to eq(['type firewall', 'provider firewall/iptables'])
    expect(cells(run(['apache', '--params', '--used-by', 'node:web01*']).last).drop(1).map(&:first)).to include('param apache::version')
    status, out = run(['simplib'])
    expect(status).to eq(1)
    expect(cells(out).drop(1).map { |r| r[1] }).to eq(%w[no no])
    expect(run(['stdlib', '--surfaces', 'bogus']).first).to eq(2)
    expect(run(['nope']).first).to eq(3)
    expect(run([]).first).to eq(2)
    expect(run(['stdlib'], cache: File.join(@tmp, 'none')).first).to eq(3)
  end
end
