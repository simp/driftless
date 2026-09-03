require 'spec_helper'
require 'tmpdir'
require 'fileutils'

require 'driftless/config'
require 'driftless/corpus'
require 'driftless/reported'
require 'driftless/models/node'
require 'driftless/inputs/hierarchy_loader'
require 'driftless/detectors/hierarchy_files_missed_by_reported_fact_values'

RSpec.describe Driftless::Detectors::HierarchyFilesMissedByReportedFactValues do
  def fixture(name)
    File.expand_path("../fixtures/control_repos/#{name}", __dir__)
  end

  def corpus_for(fixture_name, nodes: nil)
    tiers, = Driftless::Inputs::HierarchyLoader.load(fixture(fixture_name))
    data = nodes.nil? ? {} : { 'factsets-for-all-active-nodes' => nodes }
    Driftless::Corpus.new(
      repo_dir:       nil,
      hiera_tiers:    tiers,
      puppet_classes: {},
      data_files:     [],
      reported:       Driftless::Reported.new(data: data),
      code_lookup_calls:   [], data_lookup_calls: [],
    )
  end

  let(:web1) do
    Driftless::Node.new(
      certname: 'web1.example.com',
      facts:    { 'hostname' => 'web1', 'os' => { 'family' => 'RedHat' } },
      trusted:  { 'certname' => 'web1.example.com', 'hostname' => 'web1' },
    )
  end

  describe '#call' do
    context 'with top-scope variable values configured' do
      around(:each) do |ex|
        original = Driftless.instance_variable_get(:@config)
        ex.run
      ensure
        Driftless.instance_variable_set(:@config, original)
      end

      let(:repo) { Dir.mktmpdir }

      after(:each) { FileUtils.rm_rf(repo) }

      before(:each) do
        dir = repo
        File.write(File.join(dir, 'hiera.yaml'), <<~YAML)
          ---
          version: 5
          defaults:
            datadir: data
            data_hash: yaml_data
          hierarchy:
            - name: Region
              path: "regions/%{::site_region}.yaml"
            - name: Region by OS
              path: "mixed/%{facts.os.family}/%{::site_region}.yaml"
            - name: Profile
              path: "profiles/%{::compliance_profile}.yaml"
        YAML
        %w[regions/east regions/mars mixed/RedHat/east mixed/RedHat/mars mixed/Debian/east profiles/stig].each do |rel|
          path = File.join(dir, 'data', "#{rel}.yaml")
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, "---\n")
        end
      end

      def set_top_scope(value)
        Driftless.config = Driftless::Config.new(merged: { 'puppet' => { 'top_scope_variables' => value } })
      end

      def missed
        tiers, = Driftless::Inputs::HierarchyLoader.load(repo)
        corpus = build_corpus(hiera_tiers: tiers,
                              reported: Driftless::Reported.new(data: { 'factsets-for-all-active-nodes' => [web1] }))
        findings = described_class.new(corpus).call.select { |f| f.key == described_class.key }
        findings.to_h { |f| [f.path.delete_prefix("#{repo}/data/"), f.message] }
      end

      it 'reports the files no configured value reaches, and nothing under a name with no values' do
        set_top_scope('site_region' => %w[east west], 'compliance_profile' => nil)
        expect(missed).to eq(
          'regions/mars.yaml'      => 'no configured value of ::site_region resolves this path',
          'mixed/RedHat/mars.yaml' => 'no reported or configured combination of facts.os.family and ::site_region resolves this path',
          'mixed/Debian/east.yaml' => 'no reported or configured combination of facts.os.family and ::site_region resolves this path',
        )
      end

      it 'leaves every such tier alone under the list form, as before' do
        set_top_scope(%w[site_region compliance_profile])
        expect(missed).to eq({})
      end
    end

    context 'with no report:factsets-for-all-active-nodes data' do
      let(:findings) { described_class.new(corpus_for('orphans')).call }

      it 'emits exactly one skipped meta finding' do
        expect(findings.length).to eq(1)
      end

      it 'the skip finding is keyed skipped:hierarchy:files-missed-by-reported-fact-values' do
        expect(findings.first.key).to eq('skipped:hierarchy:files-missed-by-reported-fact-values')
      end
    end

    context 'against the orphans fixture with one node (web1 / RedHat)' do
      let(:findings) { described_class.new(corpus_for('orphans', nodes: [web1])).call }
      let(:orphans)  { findings.select { |f| f.key == 'hierarchy:files-missed-by-reported-fact-values' } }

      it 'reports exactly the two files no tier resolves to' do
        expect(orphans.map(&:path)).to contain_exactly(
          File.join(fixture('orphans'), 'data/hosts/ghost.example.com.yaml'),
          File.join(fixture('orphans'), 'data/os/family/Debian.yaml'),
        )
      end

      it 'names the fact the path interpolates' do
        by_path = orphans.to_h { |f| [f.path.delete_prefix("#{fixture('orphans')}/"), f] }
        expect(by_path['data/os/family/Debian.yaml'].message)
          .to eq('no reported value of facts.os.family resolves this path')
        expect(by_path['data/hosts/ghost.example.com.yaml'].message)
          .to eq('no reported value of trusted.certname resolves this path')
      end

      it 'records the tier and its variables in meta' do
        f = orphans.find { |o| o.path.end_with?('Debian.yaml') }
        expect(f.meta).to eq(tier: 'OS family', vars: ['facts.os.family'])
      end

      it 'does NOT flag reachable files' do
        reachable_files = [
          File.join(fixture('orphans'), 'data/hosts/web1.example.com.yaml'),
          File.join(fixture('orphans'), 'data/os/family/RedHat.yaml'),
          File.join(fixture('orphans'), 'data/default.yaml'),
        ]
        expect(orphans.map(&:path)).not_to include(*reachable_files)
      end

      it 'emits no hierarchy:tier-unresolved (all tiers resolve for web1)' do
        expect(findings.map(&:key)).not_to include('hierarchy:tier-unresolved')
      end
    end

    context 'against the unresolvable_tier fixture with a node lacking that fact' do
      let(:findings) { described_class.new(corpus_for('unresolvable_tier', nodes: [web1])).call }

      it 'does NOT emit a meta finding for the unresolvable tier (disabled; low-priority informational)' do
        keys = findings.map(&:key)
        expect(keys).not_to include('hierarchy:tier-unresolved')
        expect(keys).not_to include('hierarchy:tiers-interpolating-unreported-facts')
      end

      it 'does NOT flood-report the unresolvable tier\'s files (suppression still active)' do
        stig_path = File.join(fixture('unresolvable_tier'), 'data/compliance/stig.yaml')
        orphan_paths = findings.select { |f| f.key == 'hierarchy:files-missed-by-reported-fact-values' }.map(&:path)
        expect(orphan_paths).not_to include(stig_path)
      end

      it 'still recognizes default.yaml as reachable via the static Default tier' do
        default_path = File.join(fixture('unresolvable_tier'), 'data/default.yaml')
        orphan_paths = findings.select { |f| f.key == 'hierarchy:files-missed-by-reported-fact-values' }.map(&:path)
        expect(orphan_paths).not_to include(default_path)
      end
    end

    # A glob reaches whatever is on disk, so expanding it is what keeps its
    # files from reading as orphans.
    context 'against a hierarchy using glob: and globs:' do
      let(:redhat_web1) do
        Driftless::Node.new(
          certname: 'web1.example.com',
          facts:    { 'os' => { 'family' => 'RedHat' } },
          trusted:  { 'certname' => 'web1.example.com' },
        )
      end

      let(:orphans) do
        described_class.new(corpus_for('glob_tier', nodes: [redhat_web1])).call
          .select { |f| f.key == 'hierarchy:files-missed-by-reported-fact-values' }
          .map(&:path)
      end

      def data(rel)
        File.join(fixture('glob_tier'), 'data', rel)
      end

      it 'does not flag a file the glob reaches for a reported node' do
        expect(orphans).not_to include(data('nodes/prod/web1.example.com.yaml'))
      end

      it 'does not flag a file matched by a literal glob segment' do
        expect(orphans).not_to include(data('os/shared-tuning.yaml'))
      end

      it 'does not flag a file reached by an interpolated glob' do
        expect(orphans).not_to include(data('os/RedHat.yaml'))
      end

      # The glob renders per node, so a value no node reports stays unreached.
      it 'still flags a file no reported fact value reaches' do
        expect(orphans).to include(data('os/Debian.yaml'))
      end

      # A file matching no interpolating template belongs to
      # hierarchy:unreachable-data-files, which flags stray.yaml in its own spec.
      it 'leaves a file no tier reaches to the unreachable-data-files detector' do
        expect(orphans).not_to include(data('stray.yaml'))
      end

      # nodes/dev/gone.example.com.yaml matches the glob's shape but names a
      # certname nothing reported, so no representative renders it.
      it 'flags a globbed per-node file for an unreported certname' do
        expect(orphans).to include(data('nodes/dev/gone.example.com.yaml'))
      end
    end

    context 'grouping nodes by the values a tier interpolates' do
      def redhat(n)
        Driftless::Node.new(
          certname: "#{n}.example.com",
          facts:    { 'hostname' => n, 'os' => { 'family' => 'RedHat' } },
          trusted:  { 'certname' => "#{n}.example.com", 'hostname' => n },
        )
      end

      let(:fleet) { %w[web1 web2 web3 web4].map { |n| redhat(n) } }

      def orphans_for(nodes)
        described_class.new(corpus_for('orphans', nodes: nodes)).call
          .select { |f| f.key == 'hierarchy:files-missed-by-reported-fact-values' }
          .map(&:path).sort
      end

      # Three more RedHat nodes reach the same os/family path, and their own
      # hosts/ files are absent either way, so the findings must not move.
      it 'reports the same paths for four RedHat nodes as for one' do
        expect(orphans_for(fleet)).to eq(orphans_for([fleet.first]))
      end

      # The per-certname tier still renders per node, so a fleet of four
      # produces four of those paths while the os/family tier produces one.
      it 'renders the os/family path once for a fleet sharing that value' do
        debian = Driftless::Node.new(
          certname: 'db1.example.com',
          facts:    { 'hostname' => 'db1', 'os' => { 'family' => 'Debian' } },
          trusted:  { 'certname' => 'db1.example.com' },
        )
        grouping = Driftless::NodeGrouping.new(fleet + [debian], ['facts.os.family'])
        reps = grouping.representatives(['facts.os.family'])
        expect(reps.map { |n| n.fact('facts.os.family') }).to contain_exactly('RedHat', 'Debian')
      end
    end
  end
end
