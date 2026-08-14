require 'spec_helper'
require 'driftless/detectors'

# Snapshot check on every registered detector's declared severity/quality.
# Guards against silent taxonomy drift — a detector inheriting Base's
# :warning default when its author meant :error is a bug the class-body
# declaration is supposed to prevent, and this spec catches the case
# where the declaration was forgotten entirely.
RSpec.describe 'detector severity/quality declarations' do
  EXPECTED = {
    'code:lookup-missing-hiera-keys'                => { severity: :error,   quality: :wrong },
    'data:codebase-missing-class'                   => { severity: :error,   quality: :wrong },
    'data:codebase-missing-class-param'             => { severity: :error,   quality: :wrong },
    'data:legacy-facts'                             => { severity: :error,   quality: :wrong },
    'data:lookup-missing-hiera-keys'                => { severity: :error,   quality: :wrong },
    'data:missing-nodes'                            => { severity: :warning, quality: :stale },
    'hierarchy:files-missed-by-reported-fact-values' => { severity: :warning, quality: :stale },
    'hierarchy:tiers-interpolating-legacy-facts'    => { severity: :error,   quality: :wrong },
    'hierarchy:tiers-interpolating-unreported-facts' => { severity: :warning, quality: :stale },
    'hierarchy:unreachable-data-files'              => { severity: :warning, quality: :impossible },
  }.freeze

  # Subset check, not equality: other specs create anonymous test detectors
  # that pollute the process-wide registry. Requiring the expected set be
  # a subset of what's registered still catches "a driftless detector
  # went missing from EXPECTED" without collapsing under test pollution.
  it 'has every expected key registered' do
    registered_keys = Driftless::Detectors.registry.map(&:key)
    missing = EXPECTED.keys - registered_keys
    expect(missing).to be_empty,
      "expected these detector keys to be registered but they are not: #{missing.inspect}"
  end

  EXPECTED.each do |key, expected|
    it "declares #{expected.inspect} for #{key}" do
      klass = Driftless::Detectors.registry.find { |k| k.key == key }
      raise "detector #{key} not registered" unless klass
      expect(klass.severity).to eq(expected[:severity])
      expect(klass.quality).to  eq(expected[:quality])
    end
  end
end
