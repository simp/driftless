require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'spec_helper'
require 'driftless/cli/list/collectors'

RSpec.describe Driftless::CLI::List::Collectors do
  def seed(incoming_dir, query, collector, session, records)
    dir = File.join(incoming_dir, query)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{collector}--#{session}.json"), JSON.generate(records))
  end

  def node(certname)
    { 'certname' => certname, 'catalog_environment' => 'production', 'report_timestamp' => '2026-08-14T00:00:00Z' }
  end

  def summary(summary_dir, collector, session, reports)
    FileUtils.mkdir_p(summary_dir)
    File.write(File.join(summary_dir, "#{collector}--#{session}.json"),
               JSON.generate('collector' => collector, 'session_id' => session, 'reports' => reports))
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

  it 'lists one row per collector with its session, node count, reports, and summary status' do
    Dir.mktmpdir do |tmp|
      incoming = File.join(tmp, 'incoming')
      seed(incoming, 'all-active-nodes', 'east', 'S2', [node('a'), node('b')])
      seed(incoming, 'all-active-nodes', 'east', 'S1', [node('a')])
      seed(incoming, 'all-active-nodes', 'west', 'S1', [node('c')])
      seed(incoming, 'classes-for-all-active-nodes', 'east', 'S2', [])
      summary(File.join(tmp, 'summary'), 'east', 'S2',
              'all-active-nodes' => { 'status' => 'ok' }, 'classes-for-all-active-nodes' => { 'status' => 'failed' })

      lines = run(['--no-config', '-i', incoming]).lines.map(&:rstrip)
      expect(lines[0]).to eq('collector | session | nodes | reports                                       | summary')
      expect(lines[2]).to eq('east      | S2      | 2     | all-active-nodes,classes-for-all-active-nodes | 1 failed')
      expect(lines[3]).to eq('west      | S1      | 1     | all-active-nodes                              | (none)')
    end
  end

  it 'says so when the tree has no reports' do
    Dir.mktmpdir do |tmp|
      expect(run(['--no-config', '-i', tmp])).to eq("(nothing matches)\n")
    end
  end
end
