require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'driftless/export/role_tree'

RSpec.describe Driftless::Export::RoleTree do
  # <incoming>/<query>/<collector>--<session>.ndjson
  def seed(incoming, query, collector, records)
    dir = File.join(incoming, query)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{collector}--2026-08-14T00-00-00Z.ndjson"),
               records.map { |r| JSON.generate(r) }.join("\n") + "\n")
  end

  def factset(certname, facts = {})
    { 'certname' => certname, 'catalog_environment' => 'production', 'facts' => facts,
      'trusted' => { 'certname' => certname }, 'report_timestamp' => '2026-08-14T00:00:00Z' }
  end

  def classes(certname, roles)
    roles.map { |r| { 'certname' => certname, 'environment' => 'production', 'title' => r } }
  end

  # east: web1, web2 (role::web), db1 (role::db); west: web3 (role::web), mixed (both).
  # With pick 'first', west's role::web pick is mixed (sorts before web3).
  def fleet(incoming)
    seed(incoming, 'factsets-for-all-active-nodes', 'east',
         [factset('web1', 'k' => 1), factset('web2', 'k' => 2), factset('db1', 'k' => 3)])
    seed(incoming, 'factsets-for-all-active-nodes', 'west', [factset('web3', 'k' => 4), factset('mixed', 'k' => 5)])
    seed(incoming, 'classes-for-all-active-nodes', 'east',
         classes('web1', %w[Role::Web]) + classes('web2', %w[Role::Web]) + classes('db1', %w[Role::Db]))
    seed(incoming, 'classes-for-all-active-nodes', 'west',
         classes('web3', %w[Role::Web]) + classes('mixed', %w[Role::Web Role::Db]))
  end

  def tree(root)
    Dir.glob(File.join(root, '**', '*.json')).map { |p| p.sub("#{root}/", '') }.sort
  end

  def run(incoming, root, **opts)
    described_class.new(incoming_dir: incoming, root: root, **opts).run
  end

  let(:tmp)      { Dir.mktmpdir }
  let(:incoming) { File.join(tmp, 'incoming') }
  let(:root)     { File.join(tmp, 'spec/factsets/raw') }

  before(:each) do
    silence_driftless_logger
    fleet(incoming)
  end

  after(:each) { FileUtils.rm_rf(tmp) }

  it 'writes one factset per role and collector into <role::name>/ directories' do
    result = run(incoming, root, pick: 'first')
    expect(tree(root)).to eq(%w[role::db/db1.json role::db/mixed.json role::web/mixed.json role::web/web1.json])
    expect(result.to_h).to include(written: 4, updated: 0, pruned: 0, stale: 0, over_limit: 0)
    expect(JSON.parse(File.read(File.join(root, 'role::web/web1.json')))).to eq('k' => 1)
  end

  it 'picks randomly by default from the collector\'s nodes in the role' do
    picks = Array.new(6) do
      FileUtils.rm_rf(root)
      run(incoming, root)
      tree(root).grep(%r{\Arole::web/web[12]\.json\z}).first
    end
    expect(picks.uniq.sort).to eq(%w[role::web/web1.json role::web/web2.json])
  end

  it 'refreshes files already in the tree instead of picking again' do
    FileUtils.mkdir_p(File.join(root, 'role::web'))
    File.write(File.join(root, 'role::web/web2.json'), "{}\n")
    result = run(incoming, root, pick: 'first')
    expect(tree(root)).to include('role::web/web2.json')
    expect(tree(root)).not_to include('role::web/web1.json')
    expect(JSON.parse(File.read(File.join(root, 'role::web/web2.json')))).to eq('k' => 2)
    expect(result.to_h).to include(written: 3, updated: 1)
  end

  it 'keeps more files than the limit for a collector, with a warning' do
    FileUtils.mkdir_p(File.join(root, 'role::web'))
    %w[web1 web2].each { |n| File.write(File.join(root, "role::web/#{n}.json"), "{}\n") }
    exporter = described_class.new(incoming_dir: incoming, root: root, pick: 'first')
    result = exporter.run
    expect(result.to_h).to include(updated: 2, over_limit: 1)
    expect(exporter.warnings).to include(a_string_matching(%r{role::web/ holds 2 factsets from east, over the limit of 1}))
  end

  it 'honours a limit above one per role and collector' do
    run(incoming, root, limit: 2, pick: 'first')
    expect(tree(root)).to eq(%w[role::db/db1.json role::db/mixed.json role::web/mixed.json
                                role::web/web1.json role::web/web2.json role::web/web3.json])
  end

  context 'with a stale file' do
    before(:each) do
      FileUtils.mkdir_p(File.join(root, 'role::web'))
      File.write(File.join(root, 'role::web/gone.json'), "{}\n")
      File.write(File.join(root, 'role::web/db1.json'), "{}\n")
    end

    it 'stops and writes nothing' do
      expect { run(incoming, root) }.to raise_error(Driftless::Export::Error, /2 stale factset/)
      expect(tree(root)).to eq(%w[role::web/db1.json role::web/gone.json])
    end

    it 'deletes them with prune' do
      result = run(incoming, root, prune: true, pick: 'first')
      expect(tree(root)).to eq(%w[role::db/db1.json role::db/mixed.json role::web/mixed.json role::web/web1.json])
      expect(result.to_h).to include(stale: 2, pruned: 2)
    end

    it 'leaves them with ignore_stale, warning' do
      exporter = described_class.new(incoming_dir: incoming, root: root, ignore_stale: true, pick: 'first')
      result = exporter.run
      expect(tree(root)).to include('role::web/gone.json', 'role::web/db1.json', 'role::web/web1.json')
      expect(result.to_h).to include(stale: 2, pruned: 0)
      expect(exporter.warnings.grep(/stale factset/).size).to eq(2)
    end
  end

  it 'maintains only the roles the selector names' do
    run(incoming, root, pick: 'first', selector: Driftless::NodeSelector.new(roles: ['role::db']))
    expect(tree(root)).to eq(%w[role::db/db1.json role::db/mixed.json])
  end

  it 'raises ScanError without the classes report' do
    FileUtils.rm_rf(File.join(incoming, 'classes-for-all-active-nodes'))
    expect { run(incoming, root) }.to raise_error(Driftless::ScanError, /classes-for-all-active-nodes/)
  end

  it 'rejects an unknown pick' do
    expect { described_class.new(incoming_dir: incoming, root: root, pick: 'last') }
      .to raise_error(Driftless::Export::Error, /unknown pick/)
  end
end
