require 'spec_helper'
require 'driftless/config_validator'
require 'driftless/detectors/code_lookup_missing_hiera_keys'

RSpec.describe Driftless::ConfigValidator do
  # Every key here is read somewhere in lib/; the validator has to let it through
  # or the setting is unreachable.
  # Before the registry only puppet: keys were checked, so a typo under any
  # other subsystem was silently ignored.
  describe 'unknown keys in every subsystem' do
    {
      'output'  => 'tabularise',
      'scan'    => 'fail_onn',
      'logging' => 'levl',
      'reports' => 'incoming_dirs',
      'puppet'  => 'enviroments',
    }.each do |subsystem, typo|
      it "rejects #{subsystem}.#{typo}" do
        cfg = Driftless::Config.new(merged: { subsystem => { typo => 'x' } })
        expect { described_class.new(cfg).validate! }
          .to raise_error(Driftless::ConfigValidationError, /unknown #{subsystem} config key.*#{typo}/)
      end
    end

    it 'suggests the intended key when the typo is close' do
      cfg = Driftless::Config.new(merged: { 'output' => { 'tabularise' => true } })
      expect { described_class.new(cfg).validate! }
        .to raise_error(Driftless::ConfigValidationError, /did you mean "tabularize"/)
    end
  end

  describe 'nested subsystem keys' do
    it 'accepts a declared dotted key spelled as nested mappings' do
      cfg = Driftless::Config.new(merged: { 'import' => { 'git' => { 'repo' => 'https://x/r.git' } } })
      expect { described_class.new(cfg).validate! }.not_to raise_error
    end

    it 'rejects an unknown nested key with its dotted path' do
      cfg = Driftless::Config.new(merged: { 'import' => { 'git' => { 'repos' => 'x' } } })
      expect { described_class.new(cfg).validate! }
        .to raise_error(Driftless::ConfigValidationError,
                        /unknown import config key: "git\.repos" \(did you mean "repo"\?\)/)
    end

    it 'rejects a value where nested keys are declared' do
      cfg = Driftless::Config.new(merged: { 'import' => { 'git' => 'https://x/r.git' } })
      expect { described_class.new(cfg).validate! }
        .to raise_error(Driftless::ConfigValidationError, /import\.git holds nested keys \(repo\), not a value/)
    end

    it 'rejects a literal dotted key' do
      cfg = Driftless::Config.new(merged: { 'import' => { 'git.repo' => 'x' } })
      expect { described_class.new(cfg).validate! }
        .to raise_error(Driftless::ConfigValidationError, /must be spelled as nested mappings/)
    end
  end

  describe 'keys that moved or were renamed' do
    it 'rejects scan.incoming_dir with its new location' do
      cfg = Driftless::Config.new(merged: { 'scan' => { 'incoming_dir' => 'incoming' } })
      expect { described_class.new(cfg).validate! }
        .to raise_error(Driftless::ConfigValidationError, /scan\.incoming_dir has moved to reports\.incoming_dir/)
    end

    it 'rejects puppet.builtin_top_scope_variables with its new name' do
      cfg = Driftless::Config.new(merged: { 'puppet' => { 'builtin_top_scope_variables' => false } })
      expect { described_class.new(cfg).validate! }
        .to raise_error(Driftless::ConfigValidationError,
                        /puppet\.builtin_top_scope_variables has moved to puppet\.allow_builtin_top_scope_variables/)
    end

    it 'accepts the new location' do
      cfg = Driftless::Config.new(merged: { 'reports' => { 'incoming_dir' => 'incoming' } })
      expect { described_class.new(cfg).validate! }.not_to raise_error
    end

    it 'leaves other scan keys alone' do
      cfg = Driftless::Config.new(merged: { 'scan' => { 'fail_on' => 'never' } })
      expect { described_class.new(cfg).validate! }.not_to raise_error
    end
  end

  describe 'keys that production code actually reads' do
    {
      %w[puppet role_regex]    => '^role::',
      %w[puppet profile_regex] => '^profile::',
      %w[detectors only]       => ['data:legacy-facts'],
      %w[detectors skip]       => ['data:legacy-facts'],
    }.each do |(section, key), value|
      it "accepts #{section}.#{key}" do
        cfg = Driftless::Config.new(merged: { section => { key => value } })
        expect { described_class.new(cfg).validate! }.not_to raise_error
      end
    end
  end
  def validate(hash)
    described_class.new(Driftless::Config.new(merged: hash)).validate!
  end

  describe 'top-level keys' do
    it 'accepts known subsystems' do
      expect { validate('detectors' => {}, 'output' => {}) }.not_to raise_error
    end

    it 'accepts an empty config' do
      expect { validate({}) }.not_to raise_error
    end

    it 'rejects an unknown top-level key' do
      expect { validate('detactors' => {}) }
        .to raise_error(Driftless::ConfigValidationError, /unknown top-level config key.*"detactors"/)
    end

    it 'suggests a close match for a typo (via did_you_mean)' do
      expect { validate('detactors' => {}) }
        .to raise_error(Driftless::ConfigValidationError, /did you mean "detectors"/)
    end
  end

  describe 'detector keys' do
    it 'accepts the special "defaults" key' do
      expect { validate('detectors' => { 'defaults' => {} }) }.not_to raise_error
    end

    it 'accepts a registered detector key' do
      expect {
        validate('detectors' => { 'code:lookup-missing-hiera-keys' => {} })
      }.not_to raise_error
    end

    it 'rejects an unknown detector key' do
      expect {
        validate('detectors' => { 'code:lookup-missing-hera-keys' => {} })
      }.to raise_error(Driftless::ConfigValidationError, /unknown detector key.*"code:lookup-missing-hera-keys"/)
    end

    it 'suggests a close registered key for a typo' do
      expect {
        validate('detectors' => { 'code:lookup-missing-hera-keys' => {} })
      }.to raise_error(Driftless::ConfigValidationError, /did you mean "code:lookup-missing-hiera-keys"/)
    end
  end

  describe 'per-detector options' do
    it 'accepts universal :enabled on a per-detector section' do
      expect {
        validate('detectors' => { 'code:lookup-missing-hiera-keys' => { 'enabled' => false } })
      }.not_to raise_error
    end

    it 'accepts a detector-specific option declared on that detector' do
      expect {
        validate('detectors' => {
          'code:lookup-missing-hiera-keys' => { 'ignore_lookups_with_defaults' => true },
        })
      }.not_to raise_error
    end

    it 'rejects an undeclared option under a per-detector section' do
      expect {
        validate('detectors' => {
          'code:lookup-missing-hiera-keys' => { 'ignore_lookups_with_defualts' => true },
        })
      }.to raise_error(Driftless::ConfigValidationError,
                       /unknown option in detectors\.code:lookup-missing-hiera-keys.*"ignore_lookups_with_defualts"/)
    end

    it 'suggests a close declared option for a typo' do
      expect {
        validate('detectors' => {
          'code:lookup-missing-hiera-keys' => { 'ignore_lookups_with_defualts' => true },
        })
      }.to raise_error(Driftless::ConfigValidationError, /did you mean "ignore_lookups_with_defaults"/)
    end

    it 'rejects the not-yet-implemented ignore_lookups_for_optional_params (undeclared)' do
      expect {
        validate('detectors' => {
          'code:lookup-missing-hiera-keys' => { 'ignore_lookups_for_optional_params' => true },
        })
      }.to raise_error(Driftless::ConfigValidationError, /unknown option.*ignore_lookups_for_optional_params/)
    end
  end

  describe 'puppet section keys' do
    it 'accepts known keys (environments, allow_missing_envs)' do
      expect {
        validate('puppet' => {
          'environments'       => ['production'],
          'allow_missing_envs' => false,
        })
      }.not_to raise_error
    end

    it 'rejects basemodulepath with the reason it is withheld' do
      expect { validate('puppet' => { 'basemodulepath' => '/a:/b' }) }
        .to raise_error(Driftless::ConfigValidationError,
                        /puppet\.basemodulepath cannot be set in config.*environment\.conf/m)
    end

    it 'accepts an absent puppet section' do
      expect { validate({}) }.not_to raise_error
    end

    it 'rejects an unknown puppet key' do
      expect { validate('puppet' => { 'enviornments' => ['prod'] }) }
        .to raise_error(Driftless::ConfigValidationError, /unknown puppet config key.*"enviornments"/)
    end

    it 'suggests a close match for a puppet key typo' do
      expect { validate('puppet' => { 'enviornments' => ['prod'] }) }
        .to raise_error(Driftless::ConfigValidationError, /did you mean "environments"/)
    end
  end

  describe 'defaults section options' do
    it 'accepts universal options (enabled, exclude_paths)' do
      expect {
        validate('detectors' => { 'defaults' => { 'enabled' => true, 'exclude_paths' => [] } })
      }.not_to raise_error
    end

    it 'accepts any option declared by at least one detector' do
      # ignore_lookups_with_defaults is declared by code:lookup-missing-hiera-keys;
      # may be set in defaults to establish a codebase-wide convention.
      expect {
        validate('detectors' => { 'defaults' => { 'ignore_lookups_with_defaults' => true } })
      }.not_to raise_error
    end

    it 'rejects an option no detector declares' do
      expect {
        validate('detectors' => { 'defaults' => { 'totally_made_up_option' => 1 } })
      }.to raise_error(Driftless::ConfigValidationError, /unknown option in detectors\.defaults/)
    end
  end
end
