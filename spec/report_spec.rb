require 'fileutils'
require 'json'
require 'tmpdir'

require 'spec_helper'
require 'driftless/report'

RSpec.describe Driftless::Report do
  before(:each) { Driftless.config = Driftless::Config.new(merged: {}) }

  def write_report(dir, report, collector, session, rows)
    report_dir = File.join(dir, report)
    FileUtils.mkdir_p(report_dir)
    File.write(File.join(report_dir, "#{collector}--#{session}.json"), JSON.generate(rows))
  end

  def nodes_row(certname, env: 'production')
    { 'certname' => certname, 'catalog_environment' => env }
  end

  def class_row(certname, title, env: 'production')
    { 'certname' => certname, 'title' => title, 'environment' => env }
  end

  def populated_tree(dir)
    write_report(dir, 'all-active-nodes', 'east', 'T01',
                 [nodes_row('web1'), nodes_row('web2')])
    write_report(dir, 'classes-for-all-active-nodes', 'east', 'T01',
                 [class_row('web1', 'Profile::Web'), class_row('web2', 'Profile::Web'),
                  class_row('web2', 'Role::Web')])
  end

  it 'computes utilization from the classes report' do
    Dir.mktmpdir do |dir|
      populated_tree(dir)
      util = described_class.new(incoming_dir: dir).run
      expect(util['profiles']).to contain_exactly(hash_including('name' => 'profile::web', 'nodes' => 2))
      expect(util['roles']).to contain_exactly(hash_including('name' => 'role::web', 'nodes' => 1))
    end
  end

  it 'exposes the reported view and its sessions after the run' do
    Dir.mktmpdir do |dir|
      populated_tree(dir)
      report = described_class.new(incoming_dir: dir)
      report.run
      expect(report.reported.sessions.map(&:collector)).to eq(['east'])
      expect(report.reported.sessions.first.reports)
        .to eq(%w[all-active-nodes classes-for-all-active-nodes])
    end
  end

  it 'raises ScanError when the classes report is missing' do
    Dir.mktmpdir do |dir|
      write_report(dir, 'all-active-nodes', 'east', 'T01', [nodes_row('web1')])
      expect { described_class.new(incoming_dir: dir).run }
        .to raise_error(Driftless::ScanError, /classes-for-all-active-nodes/)
    end
  end

  it 'raises ScanError on a certname reported by two collectors' do
    Dir.mktmpdir do |dir|
      populated_tree(dir)
      write_report(dir, 'all-active-nodes', 'west', 'T02', [nodes_row('web1')])
      expect { described_class.new(incoming_dir: dir).run }
        .to raise_error(Driftless::ScanError, /more than one collector/)
    end
  end

  it 'warns per duplicate certname instead when accept_duplicate_certnames' do
    silence_driftless_logger
    Dir.mktmpdir do |dir|
      populated_tree(dir)
      write_report(dir, 'all-active-nodes', 'west', 'T02', [nodes_row('web1')])
      report = described_class.new(incoming_dir: dir, accept_duplicate_certnames: true)
      expect { report.run }.not_to raise_error
      expect(report.warnings).to contain_exactly(a_string_including('web1'))
    end
  end

  it 'filters nodes to the given environments' do
    silence_driftless_logger
    Dir.mktmpdir do |dir|
      write_report(dir, 'all-active-nodes', 'east', 'T01',
                   [nodes_row('web1'), nodes_row('dr1', env: 'dr')])
      write_report(dir, 'classes-for-all-active-nodes', 'east', 'T01',
                   [class_row('web1', 'Profile::Web'), class_row('dr1', 'Profile::Web', env: 'dr')])
      util = described_class.new(incoming_dir: dir, environments: ['production']).run
      expect(util['profiles']).to contain_exactly(hash_including('name' => 'profile::web', 'nodes' => 1))
    end
  end

  it 'raises when a listed environment has no reports' do
    Dir.mktmpdir do |dir|
      populated_tree(dir)
      expect { described_class.new(incoming_dir: dir, environments: %w[production dr]).run }
        .to raise_error(Driftless::ScanError, /"dr"/)
    end
  end

  it 'records loader parse errors as warnings' do
    silence_driftless_logger
    Dir.mktmpdir do |dir|
      populated_tree(dir)
      File.write(File.join(dir, 'all-active-nodes', 'west--T02.json'), '{ not json')
      report = described_class.new(incoming_dir: dir)
      report.run
      expect(report.warnings).to contain_exactly(a_string_including('JSON parse error'))
    end
  end

  it 'expects the node and classes reports for the coverage check' do
    expect(described_class.new(incoming_dir: '/tmp/x').send(:expected_reports))
      .to eq(%w[all-active-nodes classes-for-all-active-nodes])
  end
end
