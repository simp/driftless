require 'spec_helper'
require 'driftless/config_keys'

RSpec.describe Driftless::ConfigKeys do
  describe 'declarations made by the classes that own them' do
    {
      'logging.level'              => Driftless::Logging,
      'puppet.role_regex'          => Driftless::RoleProfile,
      'puppet.profile_regex'       => Driftless::RoleProfile,
      'puppet.environments'        => Driftless::Scan,
      'puppet.allow_missing_envs'  => Driftless::Scan,
      'puppet.top_scope_variables' => Driftless::TopScopeVariables,
      'puppet.allow_builtin_top_scope_variables' => Driftless::TopScopeVariables,
      'reports.incoming_dir'       => Driftless::Inputs::ReportLoader,
      'import.git.repo'            => Driftless::Import::Git,
      'import.local.source'        => Driftless::Import::Local,
      'output.format'              => Driftless::Outputs,
      'output.default_file'        => Driftless::Outputs,
      'output.tabularize'          => Driftless::Outputs,
      'scan.fail_on'               => Driftless::CLI::Scan,
      'detectors.only'             => Driftless::CLI::Scan,
      'detectors.skip'             => Driftless::CLI::Scan,
    }.each do |path, owner|
      it "#{path} is owned by #{owner}" do
        expect(described_class[path]&.owner).to eq(owner)
      end
    end
  end

  # The bug this registry exists to prevent: a key read via cfg.dig that no
  # class declares, so the validator rejects it and the setting is unreachable.
  it 'declares every key production code reads' do
    pattern   = /(?:config|cfg)\.dig\(\s*'(\w+)',\s*'(\w+)'\s*\)/
    read_keys = Dir['lib/**/*.rb'].flat_map { |f| File.read(f).scan(pattern) }.uniq
    expect(read_keys).not_to be_empty

    undeclared = read_keys.reject { |subsystem, key| described_class["#{subsystem}.#{key}"] }
    expect(undeclared).to be_empty, "read but never declared: #{undeclared.map { |s, k| "#{s}.#{k}" }.join(', ')}"
  end

  describe 'withheld keys' do
    it 'records a reason for each' do
      expect(described_class.withheld).not_to be_empty
      described_class.withheld.each { |k| expect(k.because).to be_a(String) }
    end

    it 'excludes them from the settable set' do
      expect(described_class.settable('puppet').map(&:name)).not_to include('basemodulepath')
    end
  end

  describe '.build' do
    it 'keeps everything after the first dot as the name' do
      expect(described_class['import.git.repo'].name).to eq('git.repo')
    end

    it 'rejects a path with no subsystem' do
      klass = Class.new { extend Driftless::ConfigKeys::DSL }
      expect { klass.config_key('bare', type: :string) }
        .to raise_error(ArgumentError, /must be 'subsystem.key'/)
    end
  end

  it 'refuses two owners for the same key' do
    a = Class.new { extend Driftless::ConfigKeys::DSL }
    b = Class.new { extend Driftless::ConfigKeys::DSL }
    a.config_key('spec.collides', type: :string)
    expect { b.config_key('spec.collides', type: :string) }
      .to raise_error(/config key collision on spec.collides/)
  ensure
    described_class.registry.delete('spec.collides')
  end
end
