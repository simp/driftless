require 'spec_helper'
require 'driftless/utilization'

RSpec.describe Driftless::Utilization do
  before(:each) { Driftless.config = Driftless::Config.new(merged: {}) }

  def node(certname, classes, collector: nil, environment: nil)
    Driftless::Node.new(certname: certname, classes: classes,
                        collector: collector, environment: environment)
  end

  describe '.compute' do
    it 'carries all four categories, even over no nodes' do
      expect(described_class.compute([]).keys).to eq(%w[modules roles profiles classes])
    end

    it 'renders the entry shape the site page reads' do
      util = described_class.compute([node('a', ['apache'], collector: 'east', environment: 'production')])
      expect(util['classes']).to eq([{
        'name'           => 'apache',
        'nodes'          => 1,
        'by_collector'   => { 'east' => 1 },
        'by_environment' => { 'production' => 1 },
      }])
    end

    it 'counts the nodes using each class' do
      util = described_class.compute([
        node('a', ['profile::base', 'apache']),
        node('b', ['profile::base']),
      ])
      expect(util['classes']).to contain_exactly(
        hash_including('name' => 'apache', 'nodes' => 1),
        hash_including('name' => 'profile::base', 'nodes' => 2),
      )
    end

    it 'downcases PuppetDB titles to fqnames' do
      util = described_class.compute([node('a', ['Profile::Base'])])
      expect(util['classes'].map { |e| e['name'] }).to eq(['profile::base'])
    end

    it 'counts a title differing only in case as one class' do
      util = described_class.compute([node('a', ['Profile::Base', 'profile::base'])])
      expect(util['classes']).to contain_exactly(hash_including('name' => 'profile::base', 'nodes' => 1))
    end

    it 'counts a node once per module however many of its classes it uses' do
      util = described_class.compute([node('a', %w[apache apache::mod::ssl apache::vhost])])
      expect(util['modules']).to contain_exactly(hash_including('name' => 'apache', 'nodes' => 1))
    end

    it 'selects roles and profiles by the default regexes' do
      util = described_class.compute([node('a', ['Role::Web', 'Profile::Web', 'apache'])])
      expect(util['roles'].map { |e| e['name'] }).to eq(['role::web'])
      expect(util['profiles'].map { |e| e['name'] }).to eq(['profile::web'])
    end

    it 'selects roles by a site role_regex override' do
      Driftless.config = Driftless::Config.new(merged: { 'puppet' => { 'role_regex' => '\Awrapper::role::' } })
      util = described_class.compute([node('a', ['Wrapper::Role::Web', 'role::web'])])
      expect(util['roles'].map { |e| e['name'] }).to eq(['wrapper::role::web'])
    end

    it 'tallies nodes with no collector or environment under (unknown)' do
      util = described_class.compute([
        node('a', ['apache'], collector: 'east', environment: 'production'),
        node('b', ['apache']),
      ])
      entry = util['classes'].first
      expect(entry['by_collector']).to eq('(unknown)' => 1, 'east' => 1)
      expect(entry['by_environment']).to eq('(unknown)' => 1, 'production' => 1)
    end

    it 'sorts entries by name' do
      util = described_class.compute([node('a', %w[zebra apache mysql])])
      expect(util['classes'].map { |e| e['name'] }).to eq(%w[apache mysql zebra])
    end
  end
end
