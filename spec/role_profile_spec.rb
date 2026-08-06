require 'spec_helper'
require 'driftless/role_profile'

RSpec.describe Driftless::RoleProfile do
  around do |ex|
    original = Driftless.instance_variable_get(:@config)
    ex.run
  ensure
    Driftless.instance_variable_set(:@config, original)
  end

  def set_config(hash)
    Driftless.config = Driftless::Config.new(merged: hash)
  end

  describe '.role? / .profile? with default (permissive) regexes' do
    before { set_config({}) }

    it 'recognizes role init class (`role` bare name)'                   do expect(described_class.role?('role')).to be true                    end
    it 'recognizes standard role class'                                  do expect(described_class.role?('role::web')).to be true                end
    it 'recognizes namespaced role class (baseline::role::web)'          do expect(described_class.role?('baseline::role::web')).to be true     end
    it 'recognizes deeply namespaced role class'                         do expect(described_class.role?('a::b::role::web')).to be true         end
    it 'does not false-match on classes containing "role" as substring'  do expect(described_class.role?('myrole::web')).to be false             end
    it 'does not match a non-role class'                                 do expect(described_class.role?('profile::web')).to be false            end

    it 'recognizes profile init class'    do expect(described_class.profile?('profile')).to be true              end
    it 'recognizes standard profile'      do expect(described_class.profile?('profile::apache')).to be true      end
    it 'recognizes namespaced profile'    do expect(described_class.profile?('baseline::profile::db')).to be true end

    it 'returns false for nil class name' do
      expect(described_class.role?(nil)).to be false
      expect(described_class.profile?(nil)).to be false
    end
  end

  describe '.role? / .profile? with user-overridden regexes' do
    it 'honors a narrow puppet.role_regex' do
      set_config('puppet' => { 'role_regex' => '\Arole::' })
      expect(described_class.role?('role::web')).to be true
      expect(described_class.role?('baseline::role::web')).to be false
    end

    it 'honors a broadened puppet.profile_regex' do
      set_config('puppet' => { 'profile_regex' => '\Amy_profiles::' })
      expect(described_class.profile?('my_profiles::apache')).to be true
      expect(described_class.profile?('profile::apache')).to be false
    end

    it 'accepts a pre-compiled Regexp value' do
      set_config('puppet' => { 'role_regex' => /^\Aexact_role\z/ })
      expect(described_class.role?('exact_role')).to be true
      expect(described_class.role?('role::web')).to be false
    end
  end
end
