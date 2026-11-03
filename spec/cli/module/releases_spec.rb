require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'yaml'

require 'support/fixture_repo'
require 'pupgrade/cli/module/releases'

RSpec.describe Pupgrade::CLI::ModuleCommand::Releases do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    @tmp     = Dir.mktmpdir
    @fixture = Pupgrade::FixtureRepo.build(File.join(@tmp, 'repo'))
  end

  after(:all) { FileUtils.rm_rf(@tmp) } # rubocop:disable RSpec/BeforeAfterAll

  let(:fixture) { @fixture }

  # [exit status, stdout]
  def run(argv)
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    status   = nil
    begin
      described_class.new.run(['--no-config', '--no-color', '-d', fixture.dir] + argv)
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

  before(:each) { silence_logger }

  it 'lists every tagged release newest first with its date, the deployed one marked; --order oldest reverses' do
    status, out = run(['stdlib'])
    expect(status).to eq(0)
    expect(cells(out)).to eq([
      ['version', 'tag', 'released', ''],
      ['9.6.0', 'v9.6.0', '2024-01-05', ''],
      ['9.4.0', 'v9.4.0', '2024-01-04', ''],
      ['9.0.0', 'v9.0.0', '2024-01-03', ''],
      ['8.6.0', 'v8.6.0', '2024-01-02', '(deployed)'],
    ])
    expect(cells(run(['stdlib', '--order', 'oldest']).last).drop(1).map(&:first)).to eq(%w[8.6.0 9.0.0 9.4.0 9.6.0])
    expect(run(['stdlib', '--order', 'latest']).first).to eq(2)
    # a branch-pinned module sits past its last tag: no tag is deployed, the tip is
    expect(cells(run(['baseline']).last).drop(1)).to eq([['0.1.0', 'v0.1.0', '2024-03-28', '']])
    expect(cells(run(['baseline', '--include-heads']).last)[1]).to eq(['0.1.0', 'main', '2024-03-29', '(deployed)'])
    # `module release` still reaches it, as a prefix
    expect(Pupgrade::CLI::ModuleCommand.find_subcommand('release')).to eq(described_class)
  end

  it 'starts the list at MODULE:REF, leaving out the releases older than its version' do
    status, out = run(['stdlib:v9.0.0'])
    expect(status).to eq(0)
    expect(cells(out).drop(1).map(&:first)).to eq(%w[9.6.0 9.4.0 9.0.0])
    expect(cells(run(['stdlib:v9.4.0', '--order', 'oldest']).last).drop(1).map(&:first)).to eq(%w[9.4.0 9.6.0])
    expect(cells(run(['stdlib:v9.6.0', '--include-heads', '--branch', 'main']).last).drop(1).map { |r| r[1] }).to eq(%w[main v9.6.0])
    expect(run(['stdlib:v99.0.0']).first).to eq(3)
  end

  it 'follows --branch or the branchfile, with the tip as a last row on request' do
    clone = File.join(fixture.dir, 'modules/stdlib')
    system('git', '-C', clone, 'branch', '-q', 'old', 'v9.0.0', exception: true)
    _, out = run(['stdlib', '--branch', 'nope,old'])
    expect(cells(out).drop(1).map(&:first)).to eq(%w[9.0.0 8.6.0])
    _, out = run(['stdlib', '--branch', 'old', '--include-heads'])
    expect(cells(out).drop(1).map { |r| r[1] }).to eq(%w[old v9.0.0 v8.6.0])

    branchfile = File.join(@tmp, 'recorded.yaml')
    run(['stdlib', '--branch', 'old', '--branchfile', branchfile])
    expect(YAML.safe_load(File.read(branchfile))).to eq('puppetlabs-stdlib' => 'old')
    expect(cells(run(['stdlib', '--branchfile', branchfile]).last).drop(1).map(&:first)).to eq(%w[9.0.0 8.6.0])
    expect(run(['stdlib', '--branch', 'nope']).first).to eq(3)
  ensure
    system('git', '-C', clone, 'branch', '-q', '-D', 'old', out: File::NULL, err: File::NULL)
  end

  it 'holds each release against a dependency version, a Puppet version, and an OS release, a column each' do
    status, out = run(['concat', '--with', 'stdlib', '--puppet', '8', '--os', 'RedHat=9'])
    expect(status).to eq(0)
    expect(cells(out)).to eq([
      ['version', 'tag', 'released', 'stdlib 8.6.0', 'puppet 8.0.0', 'RedHat 9', ''],
      ['9.1.0', 'v9.1.0', '2024-01-08', 'needs >= 9.0.0 < 10.0.0 (newer)', 'ok', 'ok', ''],
      ['9.0.0', 'v9.0.0', '2024-01-07', 'needs >= 9.0.0 < 10.0.0 (newer)', 'ok', 'ok', ''],
      ['7.3.0', 'v7.3.0', '2024-01-06', 'ok', 'ok', 'missing (has 7, 8)', '(deployed)'],
    ])
    _, out = run(['stdlib', '--order', 'oldest', '--with', 'stdlib=1.0.0', '--puppet', '6', '--os', 'CentOS,Windows=10,Debian=12.1'])
    rows = cells(out)
    expect(rows.first.drop(3)).to eq(['stdlib 1.0.0', 'puppet 6.0.0', 'CentOS', 'Windows 10', 'Debian 12.1', ''])
    expect(rows[1].drop(3)).to eq(['none', 'needs >= 7.0.0 < 9.0.0 (newer)', 'ok', 'missing', 'missing (has 10, 11)', '(deployed)'])
    expect(rows[2].drop(3)).to eq(['none', 'needs >= 7.0.0 < 9.0.0 (newer)', 'missing', 'missing', 'ok', ''])
    expect(cells(run(['concat', '--with', 'stdlib=10.0.0']).last).drop(1).map { |r| r[3] })
      .to eq(['needs >= 9.0.0 < 10.0.0 (older)', 'needs >= 9.0.0 < 10.0.0 (older)', 'needs >= 4.13.1 < 9.0.0 (older)'])
    expect(run(['concat', '--with', 'nope']).first).to eq(3)
    expect(run(['concat', '--with', 'stdlib=x']).first).to eq(2)
    expect(run(['concat', '--puppet', 'eight']).first).to eq(2)
  end

  it 'shows how each --item of the API surface reads per release: first text, then changed, =, or absent' do
    status, out = run(['stdlib', '--order', 'oldest', '--item', 'stdlib::shout', '--item', 'Stdlib::Port,legacy_shout,stdlib::version'])
    expect(status).to eq(0)
    rows = cells(out)
    expect(rows.first.drop(3)).to eq(['param stdlib::version', 'function legacy_shout', 'function stdlib::shout', 'type alias Stdlib::Port', ''])
    expect(rows.drop(1).map { |r| r.drop(3) }).to eq([
      ["String $version = '8.6.0'", 'ruby3x, in lib/puppet/parser/functions/legacy_shout.rb', '(text)', 'Integer[0, 65535]', '(deployed)'],
      ["changed: String $version = '9.0.0'", 'absent', 'changed: (text, times)', 'changed: Integer[1, 65535]', ''],
      ["changed: String $version = '9.4.0'", 'absent', '=', '=', ''],
      ["changed: String $version = '9.6.0'", 'absent', '=', '=', ''],
    ])
    _, out = run(['apache', '--with', 'stdlib', '--item', 'apache::dead_opt,stdlib::whisper'])
    rows = cells(out)
    expect(rows.first.drop(3)).to eq(['stdlib 8.6.0', 'param apache::dead_opt', ''])
    expect(rows.drop(1).map { |r| r[4] }).to eq(['absent', '=', "String $dead_opt = 'builtin'"])
    expect(Dir.children(File.join(fixture.dir, 'pupgrade/cache/api_surfaces'))).to include(fixture.surface_file('apache', '12.0.0', 'v12.0.0'))
    _, out = run(['stdlib', '--include-heads', '--branch', 'main', '--item', 'stdlib::whisper'])
    expect(cells(out).drop(1).map { |r| r[3] }).to eq(['=', '=', '=', '=', '(String $text) -> String'])
    expect(cells(run(['stdlib', '--item', 'nope']).last).first).to eq(['version', 'tag', 'released', ''])
  end

  it 'stops for a module with no git releases' do
    expect(run(['facts']).first).to eq(3)
    expect(run(['profile']).first).to eq(3)
    expect(run(['nope']).first).to eq(3)
    expect(run([]).first).to eq(2)
  end
end
