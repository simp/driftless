require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'spec_helper'
require 'driftless/cli/export/factsets'

RSpec.describe Driftless::CLI::Export::Factsets do
  def seed(incoming, query, records)
    dir = File.join(incoming, query)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'east--S1.ndjson'), records.map { |r| JSON.generate(r) }.join("\n") + "\n")
  end

  # [exit status, stderr plus log output]
  def run(argv)
    err             = StringIO.new
    original_err    = $stderr
    original_logger = Driftless.logger
    $stderr          = err
    Driftless.logger = Logger.new(err)
    Driftless.logger.formatter = Driftless::Logging.formatter
    status = nil
    begin
      described_class.new.run(argv)
    rescue SystemExit => e
      status = e.status
    ensure
      $stderr          = original_err
      Driftless.logger = original_logger
    end
    [status, err.string]
  end

  around(:each) do |ex|
    original = Driftless.instance_variable_get(:@config)
    ex.run
  ensure
    Driftless.instance_variable_set(:@config, original)
  end

  it 'builds the role tree at the default root under the working directory' do
    Dir.mktmpdir do |tmp|
      incoming = File.join(tmp, 'incoming')
      seed(incoming, 'factsets-for-all-active-nodes',
           [{ 'certname' => 'web1', 'catalog_environment' => 'production', 'facts' => { 'k' => 1 }, 'trusted' => {} }])
      seed(incoming, 'classes-for-all-active-nodes',
           [{ 'certname' => 'web1', 'environment' => 'production', 'title' => 'Role::Web' }])
      Dir.chdir(tmp) do
        status, = run(['--no-config', '-q', '-i', incoming, '--onceover-role-tree'])
        expect(status).to eq(0)
        expect(File).to exist(File.join(tmp, 'spec/factsets/raw/role::web/web1.json'))
      end
    end
  end

  it 'refuses --output-dir with the role tree' do
    status, err = run(['--no-config', '-i', '/tmp/x', '--onceover-role-tree', '-o', '/tmp/y'])
    expect(status).to eq(2)
    expect(err).to include('drop --output-dir')
  end

  it 'refuses a --format other than onceover json with the role tree' do
    status, err = run(['--no-config', '-i', '/tmp/x', '--onceover-role-tree', '-f', 'lookup'])
    expect(status).to eq(2)
    expect(err).to include('implies --format onceover:json')
  end

  it 'refuses --prune together with --ignore-stale-factsets' do
    status, err = run(['--no-config', '-i', '/tmp/x', '--onceover-role-tree', '--prune', '--ignore-stale-factsets'])
    expect(status).to eq(2)
    expect(err).to include('alternatives')
  end

  it 'refuses the role tree flags without the role tree' do
    status, err = run(['--no-config', '-i', '/tmp/x', '-o', '/tmp/y', '--prune'])
    expect(status).to eq(2)
    expect(err).to include('only apply with --onceover-role-tree')
  end
end
