require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'spec_helper'
require 'driftless/cli/list/factsets'

RSpec.describe Driftless::CLI::List::Factsets do
  def seed(incoming_dir, query, records)
    dir = File.join(incoming_dir, query)
    FileUtils.mkdir_p(dir)
    File.write(
      File.join(dir, 'coll--2026-08-14T00-00-00Z.ndjson'),
      records.map { |r| JSON.generate(r) }.join("\n") + "\n",
    )
  end

  def factset(certname, environment: 'production', os: {})
    { 'certname' => certname, 'catalog_environment' => environment,
      'facts' => { 'os' => os }, 'trusted' => {}, 'report_timestamp' => '2026-08-14T00:00:00Z' }
  end

  # One row per certname and class, as the classes report is shaped.
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

  it 'lists one row per factset with environment, collector, os, and roles' do
    Dir.mktmpdir do |tmp|
      seed(tmp, 'factsets-for-all-active-nodes', [
        factset('web01.example.com', os: { 'name' => 'Rocky' }),
        factset('db01.example.com', environment: 'dev', os: { 'name' => 'Ubuntu' }),
      ])
      seed(tmp, 'classes-for-all-active-nodes',
           classes('web01.example.com', %w[Role::Web Profile::Base]) + classes('db01.example.com', %w[Role::Db]))

      lines = run(['--no-config', '-i', tmp]).lines.map(&:rstrip)
      expect(lines[0]).to eq('certname          | environment | collector | os     | roles')
      expect(lines[2]).to eq('db01.example.com  | dev         | coll      | Ubuntu | role::db')
      expect(lines[3]).to eq('web01.example.com | production  | coll      | Rocky  | role::web')
    end
  end

  it 'narrows by --role' do
    Dir.mktmpdir do |tmp|
      seed(tmp, 'factsets-for-all-active-nodes', [factset('web01.example.com'), factset('db01.example.com')])
      seed(tmp, 'classes-for-all-active-nodes',
           classes('web01.example.com', %w[Role::Web]) + classes('db01.example.com', %w[Role::Db]))
      out = run(['--no-config', '-i', tmp, '--role', 'role::web'])
      expect(out).to include('web01.example.com')
      expect(out).not_to include('db01.example.com')
    end
  end

  it 'says so when nothing matches' do
    Dir.mktmpdir do |tmp|
      seed(tmp, 'factsets-for-all-active-nodes', [factset('web01.example.com')])
      expect(run(['--no-config', '-i', tmp, '--certname', 'nope*'])).to eq("(nothing matches)\n")
    end
  end
end
