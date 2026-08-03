require 'spec_helper'
require 'tmpdir'
require 'json'
require 'fileutils'

require 'driftless/inputs/report_loader'

RSpec.describe Driftless::Inputs::ReportLoader do
  def fixture(name)
    File.expand_path("../fixtures/incoming/#{name}", __dir__)
  end

  describe '.load' do
    context 'against an incoming dir that does not exist' do
      it 'returns Reported with MissingReport marker for all-active-nodes' do
        reported, findings = described_class.load('/does/not/exist')
        expect(reported.missing?('all-active-nodes')).to be true
        expect(findings).to be_empty
      end
    end

    context 'against an empty <query>/ directory' do
      let(:reported) { described_class.load(fixture('empty'))[0] }

      it 'returns Reported with MissingReport marker for all-active-nodes' do
        expect(reported.missing?('all-active-nodes')).to be true
      end
    end

    context 'against a basic single-contributor incoming dir' do
      let(:reported) { described_class.load(fixture('basic'))[0] }
      let(:nodes)    { reported.report('all-active-nodes') }

      it 'materializes each record as a Driftless::Node' do
        expect(nodes).to all(be_a(Driftless::Node))
      end

      it 'includes every certname from the report' do
        expect(nodes.map(&:certname)).to contain_exactly('web1.example.com', 'db1.example.com')
      end

      it 'populates facts and trusted from the record' do
        web1 = nodes.find { |n| n.certname == 'web1.example.com' }
        expect(web1.facts).to eq('hostname' => 'web1')
        expect(web1.trusted).to eq('certname' => 'web1.example.com')
      end
    end

    context 'against a two-contributor incoming dir' do
      let(:reported) { described_class.load(fixture('two_contributors'))[0] }
      let(:nodes)    { reported.report('all-active-nodes') }
      let(:by_certname) { nodes.each_with_object({}) { |n, h| h[n.certname] = n } }

      it 'discards a contributor\'s older file in favor of its newest' do
        # The 14:00 east file has alpha with facts.hostname="alpha-OLD"
        # The 15:00 east file has alpha with facts.hostname="alpha".
        # Older file must not contribute.
        expect(by_certname['alpha.example.com'].facts['hostname']).not_to eq('alpha-OLD')
      end

      it 'produces the union of certnames across both contributors' do
        expect(nodes.map(&:certname)).to contain_exactly(
          'alpha.example.com', 'beta.example.com', 'gamma.example.com',
        )
      end

      it 'picks the record with the later report_timestamp on cross-contributor conflict' do
        # alpha: east 15:00 vs west 14:55 → east wins → hostname="alpha", not "alpha-west"
        expect(by_certname['alpha.example.com'].facts['hostname']).to eq('alpha')
      end
    end

    context 'tie-break on report_timestamp' do
      it 'gives the tie to the alphabetically-first contributor' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'all-active-nodes'))
          File.write(
            File.join(dir, 'all-active-nodes', 'east--20260803150000.json'),
            JSON.generate([{ certname: 'alpha', report_timestamp: '2026-08-03T15:00:00Z',
                             facts: { hostname: 'east-wins' }, trusted: {} }]),
          )
          File.write(
            File.join(dir, 'all-active-nodes', 'west--20260803150000.json'),
            JSON.generate([{ certname: 'alpha', report_timestamp: '2026-08-03T15:00:00Z',
                             facts: { hostname: 'west-loses' }, trusted: {} }]),
          )

          reported, = described_class.load(dir)
          alpha = reported.report('all-active-nodes').first
          expect(alpha.facts['hostname']).to eq('east-wins')
        end
      end
    end

    context 'malformed JSON in one contributor file' do
      it 'emits a data:json-parse-error finding and continues with other contributors' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'all-active-nodes'))
          File.write(File.join(dir, 'all-active-nodes', 'good--20260803150000.json'),
                     JSON.generate([{ certname: 'ok', report_timestamp: '2026-08-03T15:00:00Z',
                                      facts: {}, trusted: {} }]))
          File.write(File.join(dir, 'all-active-nodes', 'bad--20260803150000.json'),
                     '{{ not json')

          reported, findings = described_class.load(dir)
          expect(findings.map(&:key)).to include('data:json-parse-error')
          expect(reported.report('all-active-nodes').map(&:certname)).to eq(['ok'])
        end
      end
    end
  end
end
