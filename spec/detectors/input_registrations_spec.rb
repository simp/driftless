require 'spec_helper'
require 'driftless'

RSpec.describe 'input registrations' do
  # The grade each key's findings carry, pinned so that changing one has to be
  # an edit here and not only a change in behaviour. A nil quality is a real
  # value: the key is unlabelled, filter-only.
  declared_grades = {
    'code:parse-error' => { severity: :warning, quality: :wrong },
    'controlrepo:missing-modulepaths-from-envconf' => { severity: :warning, quality: :weird },
    'data:json-parse-error' => { severity: :warning, quality: :wrong },
    'data:yaml-parse-error' => { severity: :warning, quality: :wrong },
    'hierarchy:hiera-yaml-missing' => { severity: :error, quality: :impossible },
    'hierarchy:interpolated-datadir' => { severity: :note, quality: :weird },
    'hierarchy:missing-datadir' => { severity: :error, quality: :wrong },
    'hierarchy:tier-missing-path' => { severity: :note, quality: nil },
    'hierarchy:unscannable-backend' => { severity: :note, quality: nil },
    'hierarchy:unscannable-by-driftless-backend' => { severity: :note, quality: nil },
    'hierarchy:unsupported-version' => { severity: :error, quality: nil },
  }.freeze

  declared_grades.each do |key, grade|
    context key do
      let(:registration) { Driftless::Detectors.find(key) }

      it 'is in the registry' do
        expect(registration).not_to be_nil
      end

      it 'is not callable: Scan never runs it' do
        expect(registration).not_to be_callable
      end

      it 'declares an about line for `list detectors`' do
        expect(registration.about).to be_a(String).and(satisfy { |s| !s.empty? })
      end

      it "grades its findings #{grade[:severity]}" do
        expect(registration.severity).to eq(grade[:severity])
      end

      it "tags its findings #{grade[:quality].inspect}" do
        expect(registration.quality).to eq(grade[:quality])
      end

      it 'accepts the universal options, so a config file can reach it' do
        expect(registration.config_options.keys).to include(:enabled, :exclude_paths)
      end
    end
  end

  describe '.finding' do
    it 'stamps the declared key, severity and quality onto the finding' do
      f = Driftless::Detectors::HierarchyTierMissingPath.finding(
        path: '/repo/hiera.yaml', line: 4, message: 'no path',
      )
      expect(f.key).to eq('hierarchy:tier-missing-path')
      expect(f.severity).to eq(:note)
      expect(f.path).to eq('/repo/hiera.yaml')
      expect(f.line).to eq(4)
    end
  end
end
