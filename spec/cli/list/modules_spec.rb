require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'spec_helper'
require 'driftless/cli/list/modules'

RSpec.describe Driftless::CLI::List::Modules do
  def git(dir, *args)
    system('git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.com', *args, exception: true)
  end

  # stdlib cloned at its declared tag; profile on disk with no Puppetfile entry.
  def control_repo(dir)
    File.write(File.join(dir, 'hiera.yaml'), "---\nversion: 5\nhierarchy: []\n")
    File.write(File.join(dir, 'environment.conf'), "modulepath = site-modules:modules\n")
    up = File.join(dir, 'up/stdlib')
    FileUtils.mkdir_p(up)
    File.write(File.join(up, 'metadata.json'), JSON.generate(
      'name' => 'puppetlabs-stdlib', 'version' => '9.0.0',
      'requirements' => [{ 'name' => 'puppet', 'version_requirement' => '>= 7.0.0 < 9.0.0' }],
    ))
    git(up, 'init', '-q', '-b', 'main')
    git(up, 'add', '.')
    git(up, 'commit', '-q', '-m', 'one')
    git(up, 'tag', 'v9.0.0')
    FileUtils.mkdir_p(File.join(dir, 'modules'))
    git(File.join(dir, 'modules'), 'clone', '-q', up, File.join(dir, 'modules/stdlib'))
    FileUtils.mkdir_p(File.join(dir, 'site-modules/profile'))
    File.write(File.join(dir, 'Puppetfile'), "mod 'puppetlabs-stdlib', git: '#{up}', tag: 'v9.0.0'\n")
  end

  def run(argv)
    out      = StringIO.new
    original = $stdout
    $stdout  = out
    begin
      described_class.new.run(argv)
    rescue SystemExit
      nil
    ensure
      $stdout = original
    end
    out.string
  end

  def cells(output)
    output.lines.map(&:rstrip).reject { |l| l.start_with?('-') }.map { |l| l.split('|', -1).map(&:strip) }
  end

  around(:each) do |ex|
    original = Driftless.instance_variable_get(:@config)
    ex.run
  ensure
    Driftless.instance_variable_set(:@config, original)
  end

  before(:each) { silence_driftless_logger }

  it 'lists each module with its metadata and how the clone compares to the declared ref' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      expect(cells(run(['--no-config', '-d', dir]))).to eq([
        %w[path name ref version pupver],
        ['modules/stdlib', 'puppetlabs-stdlib', '=v9.0.0', '9.0.0', '>= 7.0.0 < 9.0.0'],
        ['site-modules/profile', '', '', '', ''],
      ])
    end
  end

  it 'keeps only the git-deployed modules with --git' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      expect(cells(run(['--no-config', '-d', dir, '--git'])).map(&:first)).to eq(%w[path modules/stdlib])
    end
  end
end
