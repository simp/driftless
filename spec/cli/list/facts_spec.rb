require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'spec_helper'
require 'driftless/cli/list/facts'

RSpec.describe Driftless::CLI::List::Facts do
  def seed(incoming_dir, records)
    dir = File.join(incoming_dir, 'factsets-for-all-active-nodes')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'coll--2026-08-14T00-00-00Z.ndjson'),
               records.map { |r| JSON.generate(r) }.join("\n") + "\n")
  end

  def factset(certname, facts)
    { 'certname' => certname, 'catalog_environment' => 'production',
      'facts' => facts, 'trusted' => {}, 'report_timestamp' => '2026-08-14T00:00:00Z' }
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

  around(:each) do |ex|
    original = Driftless.instance_variable_get(:@config)
    ex.run
  ensure
    Driftless.instance_variable_set(:@config, original)
  end

  before(:each) { silence_driftless_logger }

  let(:records) do
    [
      factset('a', 'kernel' => 'Linux', 'os' => { 'name' => 'Rocky', 'release' => { 'major' => '9' } },
                   'system_uptime' => { 'seconds' => 10 }, 'ips' => %w[10.0.0.1]),
      factset('b', 'kernel' => 'Linux', 'os' => { 'name' => 'Ubuntu' }, 'system_uptime' => { 'seconds' => 20 }),
    ]
  end

  it 'lists every leaf fact path with node and distinct-value counts' do
    Dir.mktmpdir do |tmp|
      seed(tmp, records)
      lines = run(['--no-config', '-i', tmp]).lines.map(&:rstrip)
      expect(lines).to eq([
        'fact                  | nodes | values',
        '----------------------+-------+-------',
        'ips                   | 1     | 1',
        'kernel                | 2     | 1',
        'os.name               | 2     | 2',
        'os.release.major      | 1     | 1',
        'system_uptime.seconds | 2     | 2',
      ])
    end
  end

  it 'omits paths matching --exclude globs' do
    Dir.mktmpdir do |tmp|
      seed(tmp, records)
      out = run(['--no-config', '-i', tmp, '-x', 'system_uptime.*,os.release.*'])
      expect(out).not_to include('system_uptime')
      expect(out).not_to include('os.release')
      expect(out).to include('os.name')
    end
  end

  it 'narrows to selected nodes' do
    Dir.mktmpdir do |tmp|
      seed(tmp, records)
      out = run(['--no-config', '-i', tmp, '--certname', 'b'])
      expect(out).to match(/^kernel +\| 1 +\| 1$/)
      expect(out).not_to include('ips')
    end
  end
end
