require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'spec_helper'
require 'driftless/cli/modules/resolve'

RSpec.describe Driftless::CLI::Modules::Resolve do
  def metadata(dir, data)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'metadata.json'), JSON.generate(data))
  end

  # apache needs stdlib < 9 and concat; stdlib is 9.4.0 and concat is absent.
  def control_repo(dir)
    File.write(File.join(dir, 'hiera.yaml'), "---\nversion: 5\nhierarchy: []\n")
    File.write(File.join(dir, 'environment.conf'), "modulepath = modules\n")
    metadata(File.join(dir, 'modules/apache'),
             'name' => 'puppetlabs-apache', 'version' => '10.0.0',
             'dependencies' => [{ 'name' => 'puppetlabs/stdlib', 'version_requirement' => '>= 4.0.0 < 9.0.0' },
                                { 'name' => 'puppetlabs/concat', 'version_requirement' => '>= 2.0.0' }])
    metadata(File.join(dir, 'modules/stdlib'), 'name' => 'puppetlabs-stdlib', 'version' => '9.4.0')
    File.write(File.join(dir, 'Puppetfile'), "mod 'puppetlabs-apache', '10.0.0'\nmod 'puppetlabs-stdlib', '9.4.0'\n")
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

  def cells(output)
    output.lines.map(&:rstrip).reject { |l| l.start_with?('--') }.map { |l| l.split('|', -1).map(&:strip) }
  end

  around(:each) do |ex|
    original = Driftless.instance_variable_get(:@config)
    ex.run
  ensure
    Driftless.instance_variable_set(:@config, original)
  end

  before(:each) { silence_driftless_logger }

  it 'tabulates the conflicts and exits 1' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, out = run(['--no-config', '-d', dir])
      expect(status).to eq(1)
      expect(cells(out)).to eq([
        %w[conflict module subject detail],
        ['missing-dependency', 'puppetlabs-apache', 'puppetlabs/concat', 'needs puppetlabs/concat >= 2.0.0; not on the modulepath'],
        ['dependency-version', 'puppetlabs-apache', 'puppetlabs/stdlib', 'needs puppetlabs/stdlib >= 4.0.0 < 9.0.0; modules/stdlib is 9.4.0'],
      ])
    end
  end

  it 'exits 0 when the config excludes every conflict' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      cfg = File.join(dir, 'driftless.yaml')
      File.write(cfg, "modules:\n  exclude_dependencies:\n    - puppetlabs-apache\n")
      status, out = run(['-c', cfg, '-d', dir])
      expect(status).to eq(0)
      expect(out).to eq("(nothing matches)\n")
    end
  end

  it 'marks what a proposed Puppetfile changes' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      proposed = File.join(dir, 'Puppetfile.new')
      File.write(proposed, "mod 'puppetlabs-stdlib', '8.6.0'\nmod 'puppetlabs-concat', '9.0.0'\nmod 'org-new', '1.0.0'\n")
      status, out = run(['--no-config', '-d', dir, '--propose', proposed])
      expect(status).to eq(0)
      expect(cells(out)).to eq([
        %w[change conflict module subject detail],
        ['-', 'missing-dependency', 'puppetlabs-apache', 'puppetlabs/concat', 'needs puppetlabs/concat >= 2.0.0; not on the modulepath'],
        ['-', 'dependency-version', 'puppetlabs-apache', 'puppetlabs/stdlib', 'needs puppetlabs/stdlib >= 4.0.0 < 9.0.0; modules/stdlib is 9.4.0'],
      ])
    end
  end

  it 'fails on a proposed Puppetfile that cannot be read' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, = run(['--no-config', '-d', dir, '--propose', File.join(dir, 'nope')])
      expect(status).to eq(2)
    end
  end
end
