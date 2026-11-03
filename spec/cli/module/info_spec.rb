require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'yaml'

require 'support/fixture_repo'
require 'pupgrade/cli/module/info'

RSpec.describe Pupgrade::CLI::ModuleCommand::Info do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    @tmp     = Dir.mktmpdir
    @fixture = Pupgrade::FixtureRepo.build(File.join(@tmp, 'repo'))
  end

  after(:all) { FileUtils.rm_rf(@tmp) } # rubocop:disable RSpec/BeforeAfterAll

  let(:fixture) { @fixture }

  # [exit status, {label => value}]
  def run(argv)
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    status   = nil
    begin
      described_class.new.run(['--no-config', '-d', fixture.dir] + argv)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    [status, captured.string.lines.to_h { |l| l.split(':', 2).map(&:strip) }]
  end

  before(:each) { silence_logger }

  it 'shows a git module: names, declaration, clone, metadata, and candidates past the current tag' do
    status, info = run(['stdlib'])
    expect(status).to eq(0)
    expect(info).to include(
      'name'         => 'puppetlabs-stdlib',
      'path'         => 'modules/stdlib',
      'declared'     => 'tag v8.6.0',
      'remote'       => File.join(fixture.remotes_dir, 'puppetlabs-stdlib.git'),
      'deployed'     => 'match',
      'version'      => '8.6.0',
      'requirements' => 'puppet >= 7.0.0 < 9.0.0',
      'candidates'   => 'v9.0.0, v9.4.0, v9.6.0',
    )
    expect(info['clone']).to match(/\Atag v8\.6\.0, [0-9a-f]{12}\z/)
    expect(info['OS support']).to start_with('RedHat 7/8')
    expect(info).not_to have_key('branch')

    _, info = run(['puppetlabs/firewall'])
    expect(info['dependencies']).to eq('puppetlabs/stdlib >= 4.13.1 < 9.0.0')
  end

  it 'reads the metadata at a ref of the clone with MODULE:REF, the deployment as it is' do
    status, info = run(['stdlib:v9.6.0'])
    expect(status).to eq(0)
    expect(info).to include('declared' => 'tag v8.6.0', 'deployed' => 'match', 'version' => '9.6.0')
    expect(info['read at']).to match(/\Av9\.6\.0 \([0-9a-f]{12}\)\z/)
    expect(info['clone']).to start_with('tag v8.6.0')
    expect(run(['stdlib']).last).not_to have_key('read at')
    expect(run(['stdlib:v99.0.0']).first).to eq(3)
    expect(run(['facts:v1.0.0']).first).to eq(3)
  end

  it 'lists the names on each API surface with --surfaces, at the ref read, or only the kinds named' do
    status, info = run(['stdlib', '--surfaces'])
    expect(status).to eq(0)
    expect(info).to include(
      'classes'      => 'stdlib',
      'functions'    => 'legacy_shout, stdlib::run_hostname, stdlib::shout, stdlib::whisper',
      'type aliases' => 'Stdlib::Port',
    )
    expect(info).not_to have_key('facts')
    expect(run(['stdlib']).last).not_to have_key('classes')

    _, info = run(['stdlib:v9.6.0', '--surfaces=functions,facts'])
    expect(info).to include('functions' => 'stdlib::run_hostname, stdlib::shout, stdlib::whisper', 'facts' => '(none)')
    expect(info).not_to have_key('classes')
    expect(run(['stdlib', '--surfaces=bogus']).first).to eq(2)
    # * is every kind, the empty ones as (none)
    _, info = run(['stdlib', '--surfaces=*'])
    expect(info).to include('classes' => 'stdlib', 'facts' => '(none)', 'providers' => '(none)', 'defined types' => '(none)')
    # names cyan, (none) dim, a requirement's name cyan
    _, info = run(['stdlib', '--surfaces=classes,facts', '--color'])
    expect(info).to include('classes' => "\e[0;36mstdlib\e[0m", 'facts' => "\e[2m(none)\e[0m", 'requirements' => "\e[0;36mpuppet\e[0m >= 7.0.0 < 9.0.0")
  end

  it 'follows the first --branch the clone has, its tags the candidates, and records it in a branchfile' do
    system('git', '-C', File.join(fixture.dir, 'modules/stdlib'), 'branch', '-q', 'old', 'v8.6.0', exception: true)
    # old ends at the current tag: no tag past it, only the branch tip
    _, info = run(['stdlib', '--branch', 'nope,old'])
    expect(info).to include('branch' => 'old', 'candidates' => 'old')
    expect(run(['stdlib', '--branch', 'main']).last).to include('branch' => 'main', 'candidates' => 'v9.0.0, v9.4.0, v9.6.0, main')

    branchfile = File.join(@tmp, 'recorded.yaml')
    run(['stdlib', '--branch', 'old', '--branchfile', branchfile])
    expect(YAML.safe_load(File.read(branchfile))).to eq('puppetlabs-stdlib' => 'old')
    expect(run(['stdlib', '--branch', 'nope']).first).to eq(3)
    expect(run(['facts', '--branch', 'main']).first).to eq(3)
  end

  it 'reads a tag\'s version after any prefix, and not from inside a longer number' do
    clone = File.join(fixture.dir, 'modules/stdlib')
    system('git', '-C', clone, 'tag', 'release-9.7.0', 'v9.6.0', exception: true)
    system('git', '-C', clone, 'tag', 'v9.6.0.1', 'v9.6.0', exception: true)
    expect(run(['stdlib']).last['candidates']).to eq('v9.0.0, v9.4.0, v9.6.0, release-9.7.0')
  ensure
    system('git', '-C', clone, 'tag', '-d', 'release-9.7.0', 'v9.6.0.1', out: File::NULL, err: File::NULL)
  end

  it 'names the branch followed, and says why a module has no candidates' do
    File.write(File.join(fixture.dir, 'branches.yaml'), YAML.dump('puppetlabs-stdlib' => 'main'))
    _, info = run(['stdlib', '--branchfile', 'branches.yaml'])
    expect(info['branch']).to eq('main')
    expect(run(['facts']).last['candidates']).to eq('none (Forge module)')
    expect(run(['profile']).last).to include('declared' => 'not in the Puppetfile', 'candidates' => 'none (not in the Puppetfile)')
    puppetfile = File.join(fixture.dir, 'Puppetfile')
    original   = File.read(puppetfile)
    File.write(puppetfile, "#{original}mod 'profile', :local => true, :install_path => 'site-modules'\n")
    expect(run(['profile']).last).to include('declared' => '(no version) (local)', 'deployed' => 'match', 'candidates' => 'none (local module)')
    File.write(puppetfile, original)
    expect(run(['nope']).first).to eq(3)
    expect(run([]).first).to eq(2)
  end
end
