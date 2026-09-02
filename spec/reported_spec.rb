require 'set'

require 'spec_helper'
require 'driftless/reported'

RSpec.describe Driftless::Reported do
  def classed(certname, classes)
    Driftless::Node.new(certname: certname, classes: classes)
  end

  describe '#all_active_classes' do
    it 'is the unique, downcased union of every node class list' do
      reported = described_class.new(data: { 'classes-for-all-active-nodes' => [
        classed('a', ['Profile::Base', 'Role::Web']),
        classed('b', ['profile::base', 'Apache']),
      ] })
      expect(reported.all_active_classes).to eq(Set.new(%w[apache profile::base role::web]))
    end

    it 'is empty when the classes report is missing' do
      expect(described_class.new(data: {}).all_active_classes).to eq(Set.new)
    end
  end
end
