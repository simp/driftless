require 'spec_helper'

require 'driftless/detectors/data_missing_nodes'
require 'driftless/corpus'
require 'driftless/reported'
require 'driftless/models/node'
require 'driftless/inputs/hierarchy_loader'

RSpec.describe Driftless::Detectors::DataMissingNodes do
  def fixture(name)
    File.expand_path("../fixtures/control_repos/#{name}", __dir__)
  end

  def corpus_for(fixture_name, nodes:)
    tiers, = Driftless::Inputs::HierarchyLoader.load(fixture(fixture_name))
    Driftless::Corpus.new(
      repo_dir: nil, hiera_tiers: tiers, puppet_classes: {},
      data_files: [], reported: Driftless::Reported.new(data: nodes.nil? ? {} : { 'all-active-nodes' => nodes }),
      code_lookup_calls: [], data_lookup_calls: [],
    )
  end

  def node(certname)
    Driftless::Node.new(certname: certname, facts: {}, trusted: { 'certname' => certname })
  end

  describe '#call' do
    context 'with no reports/all-active-nodes' do
      it 'emits a single skipped meta finding, not per-file false positives' do
        findings = described_class.new(corpus_for('missing_nodes', nodes: nil)).call
        expect(findings.map(&:key)).to eq(['skipped:data:paths-for-unreported-nodes'])
      end
    end

    context 'against the missing_nodes fixture with only web1 in the fleet' do
      let(:findings) { described_class.new(corpus_for('missing_nodes', nodes: [node('web1.example.com')])).call }

      it 'flags ghost.example.com as missing but not web1 (which is active)' do
        by_path = findings.each_with_object({}) { |f, h| h[f.path] = f }
        ghost_path = File.join(fixture('missing_nodes'), 'data/hosts/ghost.example.com.yaml')
        web1_path  = File.join(fixture('missing_nodes'), 'data/hosts/web1.example.com.yaml')
        expect(by_path).to have_key(ghost_path)
        expect(by_path).not_to have_key(web1_path)
      end

      it 'the finding meta records the reverse-engineered certname and tier' do
        f = findings.first
        expect(f.meta[:certname]).to eq('ghost.example.com')
        expect(f.meta[:tier]).to eq('Per-host')
      end
    end

    context 'when every host file matches an active certname' do
      it 'emits no findings' do
        both = [node('web1.example.com'), node('ghost.example.com')]
        findings = described_class.new(corpus_for('missing_nodes', nodes: both)).call
        expect(findings).to be_empty
      end
    end

    # A glob tier's template carries metacharacters where a path's would be a
    # literal filename, so the certname has to be read through them.
    context 'against a glob tier carrying a certname var' do
      let(:findings) do
        described_class.new(
          corpus_for('glob_tier', nodes: [node('web1.example.com')]),
        ).call
      end

      it 'flags the globbed file naming an unreported certname' do
        expect(findings.map(&:path))
          .to include(File.join(fixture('glob_tier'), 'data/nodes/dev/gone.example.com.yaml'))
      end

      it 'does not flag the globbed file naming a reported certname' do
        expect(findings.map(&:path))
          .not_to include(File.join(fixture('glob_tier'), 'data/nodes/prod/web1.example.com.yaml'))
      end

      it 'reads the certname out of the path, not the glob segment' do
        f = findings.find { |x| x.path.end_with?('gone.example.com.yaml') }
        expect(f.meta[:certname]).to eq('gone.example.com')
      end
    end
  end
end
