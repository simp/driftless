require 'spec_helper'

require 'driftless/node_selector'
require 'driftless/models/node'
require 'driftless/reported'

RSpec.describe Driftless::NodeSelector do
  def node(certname, environment: 'production', collector: 'coll', os: {}, classes: [])
    Driftless::Node.new(
      certname: certname, environment: environment, collector: collector,
      facts: { 'os' => os }, classes: classes,
    )
  end

  let(:web_rocky) { node('web01.example.com', os: { 'name' => 'Rocky', 'family' => 'RedHat' }) }
  let(:web_ubuntu) { node('web02.example.com', environment: 'dev', collector: 'site-b', os: { 'name' => 'Ubuntu', 'family' => 'Debian' }) }
  let(:db_rocky) { node('db01.example.com', os: { 'name' => 'Rocky', 'family' => 'RedHat' }) }
  let(:nodes) { [web_rocky, web_ubuntu, db_rocky] }

  let(:reported) do
    Driftless::Reported.new(data: {
      'classes-for-all-active-nodes' => [
        node('web01.example.com', classes: %w[Role::Web Profile::Base]),
        node('web02.example.com', classes: %w[Role::Web]),
        node('db01.example.com',  classes: %w[Role::Db]),
      ],
    })
  end

  it 'passes every node when no criteria are given' do
    expect(described_class.new).to be_empty
    expect(described_class.new.select(nodes, reported)).to eq(nodes)
  end

  it 'matches certnames by glob' do
    expect(described_class.new(certname_globs: ['web*']).select(nodes, reported)).to eq([web_rocky, web_ubuntu])
  end

  it 'matches environments and collectors exactly' do
    expect(described_class.new(environments: ['dev']).select(nodes, reported)).to eq([web_ubuntu])
    expect(described_class.new(collectors: ['site-b']).select(nodes, reported)).to eq([web_ubuntu])
  end

  it 'matches os against os.name or os.family, case-insensitively' do
    expect(described_class.new(os: ['redhat']).select(nodes, reported)).to eq([web_rocky, db_rocky])
    expect(described_class.new(os: ['ubuntu']).select(nodes, reported)).to eq([web_ubuntu])
  end

  it 'matches roles from the classes report by glob, case-insensitively' do
    expect(described_class.new(roles: ['Role::Web']).select(nodes, reported)).to eq([web_rocky, web_ubuntu])
    expect(described_class.new(roles: ['role::*']).select(nodes, reported)).to eq(nodes)
  end

  it 'ORs values within a criterion and ANDs criteria' do
    selector = described_class.new(roles: ['role::web'], os: %w[debian nothing])
    expect(selector.select(nodes, reported)).to eq([web_ubuntu])
  end

  it 'raises ScanError when roles are asked for and the classes report is absent' do
    expect {
      described_class.new(roles: ['role::web']).select(nodes, Driftless::Reported.new(data: {}))
    }.to raise_error(Driftless::ScanError, /classes-for-all-active-nodes/)
  end

  it 'does not need the classes report when roles are not asked for' do
    expect(described_class.new(os: ['rocky']).select(nodes, Driftless::Reported.new(data: {}))).to eq([web_rocky, db_rocky])
  end
end
