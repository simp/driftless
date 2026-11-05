require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'

require 'support/fixture_repo'
require 'pupgrade/cli/module/list'
require 'pupgrade/cli/catalog'

RSpec.describe Pupgrade::CLI::ModuleCommand::List do
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
      described_class.new.run(['--no-config', '-d', fixture.dir] + argv)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    [status, captured.string]
  end

  # A compile of both factsets into dir, its table swallowed.
  def compile(dir)
    original = $stdout
    $stdout  = StringIO.new
    Pupgrade::CLI::Catalog::Compile.new.run(['--no-config', '-d', fixture.dir, '--factsets', 'factsets', '-o', dir, '--mocks', 'pupgrade/compiler/mocks.yaml'])
  rescue SystemExit
    nil
  ensure
    $stdout = original
  end

  def cells(output)
    output.lines.map(&:rstrip).reject { |l| l.start_with?('--') }.map { |l| l.split('|', -1).map(&:strip) }
  end

  before(:each) { silence_logger }

  around(:each) do |ex|
    color = Pupgrade::Ansi.preference
    ex.run
  ensure
    Pupgrade::Ansi.preference = color
  end

  it 'lists every module as declared and as deployed, narrowed by any spelling of a name' do
    status, out = run([])
    expect(status).to eq(0)
    rows = cells(out)
    expect(rows.first).to eq(%w[path name declared deployed version used])
    expect(rows.size).to eq(Pupgrade::FixtureRepo::CATALOGUE.size + 3)
    expect(rows.find { |r| r.first == 'modules/stdlib' }).to eq(['modules/stdlib', 'puppetlabs-stdlib', 'tag v8.6.0', 'match', '8.6.0', '?'])
    expect(rows.find { |r| r.first == 'modules/facts' }).to eq(['modules/facts', 'puppetlabs-facts', '1.4.0 (forge)', 'match', '1.4.0', '?'])
    expect(rows.find { |r| r.first == 'site-modules/profile' }).to eq(['site-modules/profile', '', '(not in the Puppetfile)', 'unknown', '', '?'])

    _, out = run(['puppetlabs/std*,concat'])
    expect(cells(out).drop(1).map(&:first)).to eq(%w[modules/concat modules/stdlib])
    _, out = run(['modules/stdlib/'])
    expect(cells(out).drop(1).map(&:first)).to eq(%w[modules/stdlib])

    system('git', '-C', File.join(fixture.dir, 'modules/concat'), 'checkout', '-q', '--detach', 'v9.0.0')
    _, out = run(['concat'])
    expect(cells(out).drop(1)).to eq([['modules/concat', 'puppetlabs-concat', 'tag v7.3.0', 'differ (v9.0.0)', '9.0.0', '?']])
    expect(run(%w[a b]).first).to eq(2)
  end

  it 'prints one name per line with -1, the directory name for a module with none' do
    status, out = run(['-1', 'stdlib,profile'])
    expect([status, out]).to eq([0, "puppetlabs-stdlib\nprofile\n"])
    expect(run(['--names-only']).last.lines.size).to eq(Pupgrade::FixtureRepo::CATALOGUE.size + 2)
  end

  it 'shows a :control_branch as the branch the clone is on, and which declaration chose it' do
    puppetfile = File.join(fixture.dir, 'Puppetfile')
    original   = File.read(puppetfile)
    File.write(puppetfile, original.sub(/(mod 'acme-baseline',\n  git: '[^']+',\n)  branch: 'main'/, "\\1  branch: :control_branch,\n  default_branch: 'main'"))
    clone = File.join(fixture.dir, 'modules/baseline')
    # the control repo's branch unknown: the clone is on the default_branch
    expect(cells(run(['baseline']).last)[1][2]).to eq('branch main (default_branch)')

    git = ->(dir, *args) { system('git', '-C', dir, *args, exception: true, out: File::NULL, err: File::NULL) }
    git.call(fixture.dir, 'init', '-q', '-b', 'production')
    git.call(fixture.dir, '-c', 'user.name=t', '-c', 'user.email=t@example.com', 'commit', '-q', '--allow-empty', '-m', 'x')
    git.call(clone, 'branch', 'production')
    expect(cells(run(['baseline']).last)[1][2]).to eq('branch production (control_branch)')
  ensure
    File.write(puppetfile, original)
    FileUtils.rm_rf(File.join(fixture.dir, '.git'))
    system('git', '-C', clone, 'branch', '-q', '-D', 'production', err: File::NULL)
  end

  it 'shows a :local entry as local, deployed while its directory is there' do
    puppetfile = File.join(fixture.dir, 'Puppetfile')
    original   = File.read(puppetfile)
    File.write(puppetfile, "#{original}mod 'profile', :local => true, :install_path => 'site-modules'\n")
    expect(cells(run(['profile']).last)[1]).to eq(['site-modules/profile', 'profile', '(no version) (local)', 'match', '', '?'])
  ensure
    File.write(puppetfile, original)
  end

  it 'says whether the compiled catalogs use each module, from a compile cache' do
    catalogs = File.join(@tmp, 'catalogs')
    compile(catalogs)
    _, out = run(['--compile-cache', catalogs, 'stdlib,apt,profile'])
    expect(cells(out).drop(1).map { |r| [r.first, r.last] }).to eq([['modules/apt', 'no'], ['modules/stdlib', 'yes'], ['site-modules/profile', 'yes']])
    expect(cells(run(['--compile-cache', File.join(@tmp, 'none'), 'stdlib']).last)[1].last).to eq('?')
  end

  it 'colors the declared cell by kind and the deployed cell by state' do
    _, out = run(['--color', 'stdlib,profile'])
    expect(out).to include("\e[0;36mtag v8.6.0\e[0m", "\e[0;32mmatch\e[0m", "\e[0;33m(not in the Puppetfile)\e[0m", "\e[0;33munknown\e[0m")
  end
end
