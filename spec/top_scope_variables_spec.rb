require 'spec_helper'
require 'driftless/config'
require 'driftless/top_scope_variables'

RSpec.describe Driftless::TopScopeVariables do
  around(:each) do |ex|
    original = Driftless.instance_variable_get(:@config)
    ex.run
  ensure
    Driftless.instance_variable_set(:@config, original)
  end

  def set_config(puppet)
    Driftless.config = Driftless::Config.new(merged: { 'puppet' => puppet })
  end

  describe '.known?' do
    context 'with no config' do
      before(:each) { set_config({}) }

      it 'knows the server variables' do
        %w[environment servername serverip serverversion server_facts].each do |v|
          expect(described_class.known?(v)).to be(true), v
        end
      end

      it 'knows them with a leading :: and a subkey' do
        expect(described_class.known?('::environment')).to be true
        expect(described_class.known?('server_facts.environment')).to be true
      end

      it 'knows the settings:: namespace' do
        expect(described_class.known?('settings::strict_variables')).to be true
        expect(described_class.known?('::settings::all_local')).to be true
      end

      it 'does not know a fact, a trusted fact, or an unlisted name' do
        expect(described_class.known?('facts.environment')).to be false
        expect(described_class.known?('trusted.certname')).to be false
        expect(described_class.known?('site_region')).to be false
      end

      it 'does not know the compiler variables, which are local scope' do
        expect(described_class.known?('module_name')).to be false
        expect(described_class.known?('caller_module_name')).to be false
      end
    end

    context 'with puppet.top_scope_variables' do
      before(:each) { set_config('top_scope_variables' => %w[site_region compliance_profile]) }

      it 'knows a listed name, with or without :: and a subkey' do
        expect(described_class.known?('site_region')).to be true
        expect(described_class.known?('::site_region')).to be true
        expect(described_class.known?('compliance_profile.level')).to be true
      end

      it 'matches exact names, not patterns' do
        expect(described_class.known?('site_region_v2')).to be false
      end

      it 'still knows the server variables' do
        expect(described_class.known?('environment')).to be true
      end
    end

    context 'with puppet.builtin_top_scope_variables: false' do
      before(:each) { set_config('builtin_top_scope_variables' => false, 'top_scope_variables' => ['site_region']) }

      it 'forgets the server variables' do
        expect(described_class.known?('environment')).to be false
        expect(described_class.known?('settings::strict_variables')).to be false
      end

      it 'keeps the listed names' do
        expect(described_class.known?('site_region')).to be true
      end
    end
  end
end
