require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'spec_helper'
require 'driftless/cli/modules/gitlog'

RSpec.describe Driftless::CLI::Modules::Gitlog do
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

  # [exit status, stdout]
  def run(argv)
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
    original = Driftless.instance_variable_get(:@config)
    ex.run
  ensure
    Driftless.instance_variable_set(:@config, original)
  end

  before(:each) { silence_driftless_logger }

  it 'shows what a ref has beyond the clone, fetching on request' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, out = run(['--no-config', '-d', dir, 'puppetlabs/stdlib', 'main'])
      expect(status).to eq(0)
      expect(subjects(out)).to match([a_string_matching(/\A\(tag: v2, .*\) two\z/)])

      status, out = run(['--no-config', '-d', dir, 'modules/stdlib', 'main', '--fetch', '-n', '1', '-f'])
      expect(status).to eq(0)
      expect(out.lines.first).to match(%r{\(origin/main, origin/HEAD\) three$})
      expect(out).to include("A\tREADME")
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
      expect(run(['--no-config', '-d', dir, 'stdlib', 'v2', '--branch', 'main']).first).to eq(2)
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
      cfg = File.join(dir, 'driftless.yaml')
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
      expect(run(['--no-config', '-d', dir, 'stdlib', 'v9']).first).to eq(3)
      expect(run(['--no-config', '-d', dir]).first).to eq(2)
    end
  end
end
