require 'spec_helper'
require 'driftless'

RSpec.describe 'input registrations' do
  # Key => severity each emit site passed to Finding.new before the key was
  # registered. Declaring a severity must not regrade an existing finding.
  severities_at_emit_sites = {
    'code:parse-error' => :warning,
    'controlrepo:missing-modulepaths-from-envconf' => :warning,
    'data:json-parse-error' => :warning,
    'data:yaml-parse-error' => :warning,
    'hierarchy:hiera-yaml-missing' => :warning,
    'hierarchy:tier-missing-path' => :note,
    'hierarchy:unscannable-backend' => :note,
    'hierarchy:unscannable-by-driftless-backend' => :note,
    'hierarchy:unsupported-version' => :warning,
  }.freeze

  severities_at_emit_sites.each do |key, severity|
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

      it "grades its findings #{severity}, as the emit sites did" do
        expect(registration.severity).to eq(severity)
      end

      it 'accepts the universal options, so a config file can reach it' do
        expect(registration.config_options.keys).to include(:enabled, :exclude_paths)
      end
    end
  end

  it 'keeps the modulepath finding tagged :weird' do
    expect(Driftless::Detectors.find('controlrepo:missing-modulepaths-from-envconf').quality)
      .to eq(:weird)
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
