require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'spec_helper'
require 'pupgrade/cli/module/update'
require 'driftless/git_clone'

RSpec.describe Pupgrade::CLI::ModuleCommand::Update do
  def git(dir, *args)
    system('git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.com', *args, exception: true)
  end

  # stdlib cloned at v1 and declared at v1; upstream main then gains v2 and
  # one more commit, neither of which the clone has seen.
  def control_repo(dir)
    File.write(File.join(dir, 'hiera.yaml'), "---\nversion: 5\nhierarchy: []\n")
    File.write(File.join(dir, 'environment.conf'), "modulepath = modules\n")
    up = File.join(dir, 'up/stdlib')
    FileUtils.mkdir_p(up)
    File.write(File.join(up, 'metadata.json'), JSON.generate('name' => 'puppetlabs-stdlib', 'version' => '1.0.0'))
    FileUtils.mkdir_p(File.join(up, 'spec'))
    File.write(File.join(up, 'spec/a_spec.rb'), "# one\n")
    git(up, 'init', '-q', '-b', 'main')
    git(up, 'add', '.')
    git(up, 'commit', '-q', '-m', 'one')
    git(up, 'tag', 'v1')
    FileUtils.mkdir_p(File.join(dir, 'modules'))
    git(File.join(dir, 'modules'), 'clone', '-q', up, File.join(dir, 'modules/stdlib'))
    git(File.join(dir, 'modules/stdlib'), 'checkout', '-q', '--detach', 'v1')
    File.write(File.join(up, 'spec/a_spec.rb'), "# two\n")
    git(up, 'commit', '-q', '-a', '-m', 'two')
    git(up, 'tag', 'v2')
    git(up, 'commit', '-q', '--allow-empty', '-m', 'three')
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

  def head(dir)
    Driftless::GitClone.new(File.join(dir, 'modules/stdlib'))
  end

  around(:each) do |ex|
    original = Pupgrade.instance_variable_get(:@config)
    ex.run
  ensure
    Pupgrade.instance_variable_set(:@config, original)
  end

  it 'moves the clone to a tag it had not fetched, and warns that the Puppetfile disagrees' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      log = capture_log do
        status, out = run(['--no-config', '-d', dir, 'stdlib', 'v2'])
        expect(status).to eq(0)
        expect(out).to match(%r{\Amodules/stdlib: v1 -> v2 \([0-9a-f]{12}\)\n\z})
      end
      expect(head(dir).tag_at_head).to eq('v2')
      expect(log).to include('the Puppetfile still declares tag v1 for modules/stdlib')

      status, out = run(['--no-config', '-d', dir, 'stdlib', 'v2'])
      expect([status, out]).to match([0, /already at v2/])
    end
  end

  it 'moves to the tip of a branch, preferring the remote-tracking ref' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, out = run(['--no-config', '-d', dir, 'puppetlabs-stdlib', 'main'])
      expect(status).to eq(0)
      expect(out).to match(%r{\Amodules/stdlib: v1 -> main})
      expect(head(dir).log('--oneline', '-n', '1', 'HEAD')).to match(/ three\z/)
    end
  end

  it 'only reports under --dry-run' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, out = run(['--no-config', '-d', dir, 'stdlib', 'v2', '--dry-run'])
      expect([status, out]).to match([0, /would move v1 -> v2/])
      expect(head(dir).tag_at_head).to eq('v1')
    end
  end

  it 'moves a clone whose spec/ r10k removed, as that is not a local change' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      FileUtils.rm_rf(File.join(dir, 'modules/stdlib/spec'))
      expect(head(dir).dirty?).to be true
      silence_logger
      status, out = run(['--no-config', '-d', dir, 'stdlib', 'v2'])
      expect([status, out]).to match([0, %r{\Amodules/stdlib: v1 -> v2}])
      expect(head(dir).tag_at_head).to eq('v2')
    end
  end

  it 'refuses a Forge module, an unknown ref, and a dirty clone, unless forced' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      silence_logger
      expect(run(['--no-config', '-d', dir, 'org-forge', 'v2']).first).to eq(3)
      expect(run(['--no-config', '-d', dir, 'stdlib', 'v9']).first).to eq(3)
      File.write(File.join(dir, 'modules/stdlib/metadata.json'), "{}\n")
      expect(run(['--no-config', '-d', dir, 'stdlib', 'v2']).first).to eq(3)
      expect(head(dir).tag_at_head).to eq('v1')
      expect(run(['--no-config', '-d', dir, 'stdlib']).first).to eq(2)

      status, out = run(['--no-config', '-d', dir, 'stdlib', 'v2', '--force'])
      expect([status, out]).to match([0, %r{\Amodules/stdlib: v1 -> v2}])
      expect(head(dir).tag_at_head).to eq('v2')
      expect(head(dir).dirty?).to be(false)
    end
  end

  it 'takes a rev expression as written' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      silence_logger
      status, out = run(['--no-config', '-d', dir, 'stdlib', 'main~1'])
      expect([status, out]).to match([0, %r{\Amodules/stdlib: v1 -> main~1}])
      expect(head(dir).tag_at_head).to eq('v2')
    end
  end
end
