require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'spec_helper'
require 'pupgrade/cli/module/gitlog'

RSpec.describe Pupgrade::CLI::ModuleCommand::Gitlog do
  def git(dir, *args)
    system('git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.com', *args, exception: true)
  end

  # stdlib cloned at v1 while upstream main has two more commits, one
  # tagged v2 and the last one made after the clone.
  def control_repo(dir)
    File.write(File.join(dir, 'hiera.yaml'), "---\nversion: 5\nhierarchy: []\n")
    File.write(File.join(dir, 'environment.conf'), "modulepath = modules\n")
    up = File.join(dir, 'up/stdlib')
    FileUtils.mkdir_p(up)
    File.write(File.join(up, 'metadata.json'), JSON.generate('name' => 'puppetlabs-stdlib', 'version' => '1.0.0'))
    git(up, 'init', '-q', '-b', 'main')
    git(up, 'add', '.')
    git(up, 'commit', '-q', '-m', 'one')
    git(up, 'tag', 'v1')
    git(up, 'commit', '-q', '--allow-empty', '-m', 'two')
    git(up, 'tag', 'v2')
    FileUtils.mkdir_p(File.join(dir, 'modules'))
    git(File.join(dir, 'modules'), 'clone', '-q', up, File.join(dir, 'modules/stdlib'))
    git(File.join(dir, 'modules/stdlib'), 'checkout', '-q', '--detach', 'v1')
    File.write(File.join(up, 'README'), "x\n")
    git(up, 'add', '.')
    git(up, 'commit', '-q', '-m', 'three')
    File.write(File.join(dir, 'Puppetfile'), "mod 'puppetlabs-stdlib', git: '#{up}', tag: 'v1'\nmod 'org-forge', '1.0.0'\n")
    up
  end

  # [exit status, stdout]; the date is off unless the arguments say
  # otherwise, so the subject checks stay readable
  def run(argv)
    argv = ['--no-date'] + argv unless argv.include?('--date')
    out      = StringIO.new
    original = $stdout
    $stdout  = out
    status   = nil
    begin
      described_class.new.run(argv)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    [status, out.string]
  end

  def subjects(out)
    out.lines.map { |l| l.split(' ', 2).last.strip }
  end

  around(:each) do |ex|
    original = Pupgrade.instance_variable_get(:@config)
    color    = Pupgrade::Ansi.preference
    ex.run
  ensure
    Pupgrade.instance_variable_set(:@config, original)
    Pupgrade::Ansi.preference = color
  end

  before(:each) { silence_logger }

  it 'shows what a ref has beyond the clone, fetching on request' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, out = run(['--no-config', '-d', dir, 'puppetlabs/stdlib:main'])
      expect(status).to eq(0)
      expect(subjects(out)).to match([a_string_matching(/\A\(tag: v2, .*\) two\z/)])

      status, out = run(['--no-config', '-d', dir, 'modules/stdlib:main', '--fetch', '-n', '1', '-f'])
      expect(status).to eq(0)
      expect(out.lines.first).to match(%r{\(origin/main, origin/HEAD\) three$})
      expect(out).to include("A\tREADME")
    end
  end

  it 'logs what the clone has past a ref behind HEAD, and says when the ref is HEAD' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      git(File.join(dir, 'modules/stdlib'), 'checkout', '-q', '--detach', 'v2')
      allow(Driftless).to receive(:logger).and_call_original
      out = nil
      log = capture_log(level: :notice) { _, out = run(['--no-config', '-d', dir, 'stdlib:v1']) }
      expect(subjects(out)).to match([a_string_matching(/\A\(HEAD, tag: v2, .*\) two\z/)])
      expect(log).to include('notice: module gitlog: v1 is behind HEAD in modules/stdlib; logging the commits since v1 (v1..HEAD)')

      log = capture_log(level: :notice) { _, out = run(['--no-config', '-d', dir, 'stdlib:v2']) }
      expect(out).to eq('')
      expect(log).to include("notice: module gitlog: v2 is HEAD in modules/stdlib; there's nothing past it")
    end
  end

  it 'passes a rev expression to git as written, and logs a ref from its start on request' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, out = run(['--no-config', '-d', dir, 'stdlib:main~0'])
      expect(status).to eq(0)
      expect(subjects(out)).to match([a_string_matching(/ two\z/)])
      expect(run(['--no-config', '-d', dir, 'stdlib:main~9']).first).to eq(3)

      status, out = run(['--no-config', '-d', dir, 'stdlib:main', '--from-start'])
      expect(status).to eq(0)
      expect(subjects(out).map { |s| s.split.last }).to eq(%w[two one])
      _, out = run(['--no-config', '-d', dir, 'stdlib:main~1', '--from-start'])
      expect(subjects(out).map { |s| s.split.last }).to eq(%w[one])
    end
  end

  it 'follows --branch, recording it when a branchfile is named on the command line' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, out = run(['--no-config', '-d', dir, 'stdlib', '--branch', 'main'])
      expect(status).to eq(0)
      expect(subjects(out)).to match([a_string_matching(/ two\z/)])
      expect(File).not_to exist(File.join(dir, 'branches.yaml'))

      status, = run(['--no-config', '-d', dir, 'stdlib', '--branch', 'main', '--branchfile', 'branches.yaml'])
      expect(status).to eq(0)
      expect(File.read(File.join(dir, 'branches.yaml'))).to eq("---\npuppetlabs-stdlib: main\n")
      expect(run(['--no-config', '-d', dir, 'stdlib:v2', '--branch', 'main']).first).to eq(2)
    end
  end

  it 'follows the branch a branchfile names when no ref is given' do
    Dir.mktmpdir do |dir|
      up = control_repo(dir)
      File.write(File.join(dir, 'branches.yaml'), "puppetlabs/stdlib: main\n")
      status, out = run(['--no-config', '-d', dir, 'stdlib', '--branchfile', 'branches.yaml'])
      expect(status).to eq(0)
      expect(subjects(out)).to match([a_string_matching(/ two\z/)])

      File.write(File.join(dir, 'Branchfile'), "mod 'puppetlabs-stdlib', git: '#{up}', branch: 'main'\nmod 'org-forge', '1.0.0'\n")
      cfg = File.join(dir, 'pupgrade.yaml')
      File.write(cfg, "modules:\n  branchfile: Branchfile\n")
      status, out = run(['-c', cfg, '-d', dir, 'stdlib'])
      expect(status).to eq(0)
      expect(subjects(out)).to match([a_string_matching(/ two\z/)])

      File.write(File.join(dir, 'branches.yaml'), "other: main\n")
      status, out = run(['--no-config', '-d', dir, 'stdlib', '--branchfile', 'branches.yaml'])
      expect(status).to eq(0)
      expect(subjects(out)).to match([a_string_matching(/ one\z/)])
      expect(run(['--no-config', '-d', dir, 'stdlib', '--branchfile', 'nope.yaml']).first).to eq(3)
    end
  end

  it 'shows the commit date unless told not to, and colours when colour is on' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, out = run(['--no-config', '--no-color', '-d', dir, 'stdlib', '--date'])
      expect(status).to eq(0)
      expect(out).to match(/\A[0-9a-f]+  \d{4}-\d\d-\d\d \d\d:\d\d:\d\d \(HEAD, tag: v1\) one\n\z/)
      _, out = run(['--no-config', '--no-color', '-d', dir, 'stdlib', '--no-date'])
      expect(out).to match(/\A[0-9a-f]+ \(HEAD, tag: v1\) one\n\z/)

      _, out = run(['--no-config', '--color', '-d', dir, 'stdlib'])
      expect(out).to include("\e[")
      _, out = run(['--no-config', '--no-color', '-d', dir, 'stdlib'])
      expect(out).not_to include("\e[")
    end
  end

  it 'logs what a ref of another repo has beyond the clone with --repo' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      alt = File.join(dir, 'alt/stdlib')
      FileUtils.mkdir_p(alt)
      File.write(File.join(alt, 'metadata.json'), JSON.generate('name' => 'acme-stdlib', 'version' => '3.0.0'))
      git(alt, 'init', '-q', '-b', 'main')
      git(alt, 'add', '.')
      git(alt, 'commit', '-q', '-m', 'alt-three')
      git(alt, 'tag', 'v3')
      status, out = run(['--no-config', '-d', dir, 'stdlib:v3', '--repo', alt])
      expect(status).to eq(0)
      expect(subjects(out)).to eq(['alt-three'])
      expect(run(['--no-config', '-d', dir, 'stdlib', '--repo', alt]).first).to eq(2)
      expect(run(['--no-config', '-d', dir, 'stdlib:v9', '--repo', alt]).first).to eq(3)
    end
  end

  it 'shows the clone\'s own history without a ref' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, out = run(['--no-config', '-d', dir, 'stdlib'])
      expect(status).to eq(0)
      expect(subjects(out)).to match([a_string_matching(/\A\(HEAD, tag: v1\) one\z/)])
    end
  end

  it 'refuses an unknown module, a Forge module, and a ref the clone does not know' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      expect(run(['--no-config', '-d', dir, 'nope']).first).to eq(3)
      expect(run(['--no-config', '-d', dir, 'org-forge']).first).to eq(3)
      expect(run(['--no-config', '-d', dir, 'stdlib:v9']).first).to eq(3)
      expect(run(['--no-config', '-d', dir, 'stdlib', 'main']).first).to eq(2)
      expect(run(['--no-config', '-d', dir]).first).to eq(2)
    end
  end

  it 'tries branches in order, records into the configured branchfile, and shows tags only' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, out = run(['--no-config', '-d', dir, 'stdlib', '--branch', 'nope,main'])
      expect(status).to eq(0)
      expect(subjects(out)).to match([a_string_matching(/ two\z/)])
      expect(run(['--no-config', '-d', dir, 'stdlib', '--branch', 'nope,none']).first).to eq(3)

      cfg = File.join(dir, 'pupgrade.yaml')
      File.write(cfg, "modules:\n  branchfile: branches.yaml\n")
      status, = run(['-c', cfg, '-d', dir, 'stdlib', '--branch', 'nope,main'])
      expect(status).to eq(0)
      expect(File.read(File.join(dir, 'branches.yaml'))).to eq("---\npuppetlabs-stdlib: main\n")

      _, out = run(['--no-config', '-d', dir, 'stdlib:main', '--fetch', '-t'])
      expect(subjects(out)).to match([a_string_matching(/\(tag: v2.*\) two\z/)])
      _, out = run(['--no-config', '-d', dir, 'stdlib:main', '-t', '--include-heads'])
      expect(out.lines.size).to eq(2)
      expect(out.lines.first).to match(/ three$/)
    end
  end
end
