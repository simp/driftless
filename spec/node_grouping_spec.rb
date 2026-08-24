require 'spec_helper'

require 'driftless/node_grouping'
require 'driftless/models/node'

RSpec.describe Driftless::NodeGrouping do
  def node(name, family:, role:)
    Driftless::Node.new(
      certname: "#{name}.example.com",
      facts:    { 'os' => { 'family' => family }, 'my_role' => role },
      trusted:  { 'certname' => "#{name}.example.com" },
    )
  end

  subject(:grouping) { described_class.new(nodes, all_vars) }

  # Two families x two roles across eight nodes, so every combination repeats.
  let(:nodes) do
    %w[RedHat Debian].flat_map do |family|
      %w[web db].flat_map do |role|
        (1..2).map { |i| node("#{family}-#{role}#{i}", family: family, role: role) }
      end
    end
  end

  let(:all_vars) { ['facts.os.family', 'facts.my_role', 'trusted.certname'] }

  describe '#representatives' do
    it 'returns one node per distinct value of a single variable' do
      reps = grouping.representatives(['facts.os.family'])
      expect(reps.map { |n| n.fact('facts.os.family') }).to contain_exactly('RedHat', 'Debian')
    end

    it 'returns one node per distinct combination when a path reads two variables' do
      reps = grouping.representatives(['facts.os.family', 'facts.my_role'])
      expect(reps.map { |n| [n.fact('facts.os.family'), n.fact('facts.my_role')] })
        .to contain_exactly(%w[RedHat web], %w[RedHat db], %w[Debian web], %w[Debian db])
    end

    # A combination no node reports is not a group: nothing renders for it.
    it 'produces only combinations that some node reports' do
      only_redhat_web = nodes.select { |n| n.fact('facts.my_role') == 'web' && n.fact('facts.os.family') == 'RedHat' }
      reps = described_class.new(only_redhat_web, all_vars)
        .representatives(['facts.os.family', 'facts.my_role'])
      expect(reps.length).to eq(1)
    end

    it 'ignores the order variables are asked for when reusing a grouping' do
      expect(grouping.representatives(['facts.os.family']).length).to eq(2)
      expect(grouping.representatives(%w[facts.os.family facts.os.family]).length).to eq(2)
    end

    it 'reuses a grouping for a varset it has already built' do
      first = grouping.representatives(['facts.my_role'])
      expect(grouping.representatives(['facts.my_role'])).to equal(first)
    end
  end

  describe 'per-node-unique facts' do
    it 'holds them out of the shared table' do
      expect(grouping.unique_vars).to eq(['trusted.certname'])
    end

    it 'gives every node to a path that reads one, since each is its own group' do
      expect(grouping.representatives(['trusted.certname'])).to eq(nodes)
    end

    it 'gives every node when a path mixes a unique fact with a groupable one' do
      reps = grouping.representatives(['trusted.certname', 'facts.os.family'])
      expect(reps).to eq(nodes)
    end

    # The held-out fact must not widen the shared table: family still groups to
    # two even though every node has a distinct certname.
    it 'does not let a unique fact block grouping for other paths' do
      expect(grouping.representatives(['facts.os.family']).length).to eq(2)
    end
  end
end
