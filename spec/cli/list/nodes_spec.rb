require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'spec_helper'
require 'driftless/cli/list/nodes'

RSpec.describe Driftless::CLI::List::Nodes do
  def seed(incoming_dir, query, records)
    dir = File.join(incoming_dir, query)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'coll--2026-08-14T00-00-00Z.ndjson'),
               records.map { |r| JSON.generate(r) }.join("\n") + "\n")
  end

  def node(certname, environment: 'production')
    { 'certname' => certname, 'catalog_environment' => environment, 'report_timestamp' => '2026-08-14T00:00:00Z' }
  end

  def classes(certname, names)
    names.map { |title| { 'certname' => certname, 'environment' => 'production', 'title' => title } }
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

  it 'lists one row per active node with environment, collector, and roles' do
    Dir.mktmpdir do |tmp|
      seed(tmp, 'all-active-nodes', [node('web01.example.com'), node('db01.example.com', environment: 'dev')])
      seed(tmp, 'classes-for-all-active-nodes',
           classes('web01.example.com', %w[Role::Web]) + classes('db01.example.com', %w[Role::Db Profile::Base]))

      lines = run(['--no-config', '-i', tmp]).lines.map(&:rstrip)
      expect(lines[0]).to eq('certname          | environment | collector | roles')
      expect(lines[2]).to eq('db01.example.com  | dev         | coll      | role::db')
      expect(lines[3]).to eq('web01.example.com | production  | coll      | role::web')
    end
  end

  it 'narrows by --role' do
    Dir.mktmpdir do |tmp|
      seed(tmp, 'all-active-nodes', [node('web01.example.com'), node('db01.example.com')])
      seed(tmp, 'classes-for-all-active-nodes',
           classes('web01.example.com', %w[Role::Web]) + classes('db01.example.com', %w[Role::Db]))
      out = run(['--no-config', '-i', tmp, '--role', 'role::db'])
      expect(out).to include('db01.example.com')
      expect(out).not_to include('web01.example.com')
    end
  end

  it 'reads the inventory even without a factsets report' do
    Dir.mktmpdir do |tmp|
      seed(tmp, 'all-active-nodes', [node('web01.example.com')])
      expect(run(['--no-config', '-i', tmp])).to include('web01.example.com')
    end
  end
end
