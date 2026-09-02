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

    describe 'collector attribution' do
      def incoming(files)
        dir = Dir.mktmpdir
        FileUtils.mkdir_p(File.join(dir, 'all-active-nodes'))
        files.each do |name, records|
          File.write(File.join(dir, 'all-active-nodes', name), JSON.generate(records))
        end
        dir
      end

      def nodes_by_certname(dir)
        described_class.load(dir)[0].report('all-active-nodes').to_h { |n| [n.certname, n] }
      end

      it 'names the collector whose file the node came from' do
        dir = incoming(
          'alpha--2026-08-20T00:00:00Z.json' => [{ 'certname' => 'a', 'environment' => 'production' }],
          'beta--2026-08-20T00:00:00Z.json'  => [{ 'certname' => 'b', 'environment' => 'production' }],
        )
        nodes = nodes_by_certname(dir)
        expect(nodes['a'].collector).to eq('alpha')
        expect(nodes['b'].collector).to eq('beta')
      end

      it 'keeps the newest record when two collectors report one certname' do
        dir = incoming(
          'alpha--2026-08-20T00:00:00Z.json' => [
            { 'certname' => 'shared', 'report_timestamp' => '2026-08-01T00:00:00Z' },
          ],
          'beta--2026-08-20T00:00:00Z.json' => [
            { 'certname' => 'shared', 'report_timestamp' => '2026-08-18T00:00:00Z' },
          ],
        )
        expect(nodes_by_certname(dir)['shared'].collector).to eq('beta')
      end
    end

    describe 'sessions read' do
      def incoming(files_by_query)
        dir = Dir.mktmpdir
        files_by_query.each do |query, files|
          FileUtils.mkdir_p(File.join(dir, query))
          files.each do |name|
            record  = { 'certname' => 'a' }
            content = name.end_with?('.ndjson') ? "#{JSON.generate(record)}\n" : JSON.generate([record])
            File.write(File.join(dir, query, name), content)
          end
        end
        dir
      end

      def sessions(dir)
        described_class.load(dir)[0].sessions.map { |s| [s.collector, s.session_id, s.reports] }
      end

      it 'records one session per collector with the reports read from it, in collector order' do
        dir = incoming(
          'all-active-nodes'              => ['west--T01.json', 'east--T02.json'],
          'factsets-for-all-active-nodes' => ['west--T01.ndjson', 'east--T02.ndjson'],
        )
        expect(sessions(dir)).to eq([
          ['east', 'T02', %w[all-active-nodes factsets-for-all-active-nodes]],
          ['west', 'T01', %w[all-active-nodes factsets-for-all-active-nodes]],
        ])
      end

      it 'records the newest session per collector, ignoring superseded files' do
        dir = incoming('all-active-nodes' => ['east--T01.json', 'east--T02.json'])
        expect(sessions(dir)).to eq([['east', 'T02', ['all-active-nodes']]])
      end

      # Only reachable when the acceptance rule was relaxed: the live tree
      # normally holds one complete session per collector.
      it 'shows a collector twice when its reports came from different sessions' do
        dir = incoming(
          'all-active-nodes'              => ['east--T02.json'],
          'factsets-for-all-active-nodes' => ['east--T01.ndjson'],
        )
        expect(sessions(dir)).to eq([
          ['east', 'T01', ['factsets-for-all-active-nodes']],
          ['east', 'T02', ['all-active-nodes']],
        ])
      end

      it 'is empty when nothing was loaded' do
        expect(described_class.load('/does/not/exist')[0].sessions).to eq([])
      end
    end

    describe 'duplicate certnames' do
      def incoming(files)
        dir = Dir.mktmpdir
        FileUtils.mkdir_p(File.join(dir, 'all-active-nodes'))
        files.each do |name, records|
          File.write(File.join(dir, 'all-active-nodes', name), JSON.generate(records))
        end
        dir
      end

      it 'reports the certname and every collector that claimed it' do
        reported, = described_class.load(fixture('two_collectors'))
        expect(reported.duplicate_certnames).to eq('alpha.example.com' => %w[east west])
      end

      it 'is empty when each collector reports a distinct set' do
        dir = incoming(
          'alpha--2026-08-20T00:00:00Z.json' => [{ 'certname' => 'a' }],
          'beta--2026-08-20T00:00:00Z.json'  => [{ 'certname' => 'b' }],
        )
        expect(described_class.load(dir)[0].duplicate_certnames).to be_empty
      end

      # Two files from one collector are a normal supersession, not a conflict.
      it 'ignores repeats within a single collector' do
        dir = incoming(
          'alpha--2026-08-19T00:00:00Z.json' => [{ 'certname' => 'a' }],
          'alpha--2026-08-20T00:00:00Z.json' => [{ 'certname' => 'a' }],
        )
        expect(described_class.load(dir)[0].duplicate_certnames).to be_empty
      end

      it 'is empty for an incoming dir that does not exist' do
        expect(described_class.load('/does/not/exist')[0].duplicate_certnames).to be_empty
      end

      it 'defaults to nil for a node not built from a report file' do
        expect(Driftless::Node.new(certname: 'x').collector).to be_nil
      end
    end

    context 'against a basic single-collector incoming dir' do
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

    context 'against a two-collector incoming dir' do
      let(:reported) { described_class.load(fixture('two_collectors'))[0] }
      let(:nodes)    { reported.report('all-active-nodes') }
      let(:by_certname) { nodes.each_with_object({}) { |n, h| h[n.certname] = n } }

      it 'discards a collector\'s older file in favor of its newest' do
        # The 14:00 east file has alpha with facts.hostname="alpha-OLD"
        # The 15:00 east file has alpha with facts.hostname="alpha".
        # Older file must not contribute.
        expect(by_certname['alpha.example.com'].facts['hostname']).not_to eq('alpha-OLD')
      end

      it 'produces the union of certnames across both collectors' do
        expect(nodes.map(&:certname)).to contain_exactly(
          'alpha.example.com', 'beta.example.com', 'gamma.example.com',
        )
      end

      it 'picks the record with the later report_timestamp on cross-collector conflict' do
        # alpha: east 15:00 vs west 14:55 → east wins → hostname="alpha", not "alpha-west"
        expect(by_certname['alpha.example.com'].facts['hostname']).to eq('alpha')
      end
    end

    context 'tie-break on report_timestamp' do
      it 'gives the tie to the alphabetically-first collector' do
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

    context 'malformed JSON in one collector file' do
      it 'emits a data:json-parse-error finding and continues with other collectors' do
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

    context 'NDJSON format (.ndjson extension)' do
      it 'parses each line as a separate JSON record' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'factsets-for-all-active-nodes'))
          File.write(
            File.join(dir, 'factsets-for-all-active-nodes', 'puppet--20260807160000.ndjson'),
            [
              JSON.generate({ certname: 'web1.example.com', environment: 'production',
                              facts: { 'hostname' => 'web1' }, trusted: {} }),
              JSON.generate({ certname: 'db1.example.com',  environment: 'production',
                              facts: { 'hostname' => 'db1'  }, trusted: {} }),
            ].join("\n") + "\n",
          )

          reported, findings = described_class.load(dir)
          expect(findings).to be_empty
          nodes = reported.report('factsets-for-all-active-nodes')
          expect(nodes.map(&:certname)).to contain_exactly('web1.example.com', 'db1.example.com')
        end
      end

      it 'captures the environment field from NDJSON records' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'factsets-for-all-active-nodes'))
          File.write(
            File.join(dir, 'factsets-for-all-active-nodes', 'puppet--20260807160000.ndjson'),
            JSON.generate({ certname: 'web1.example.com', environment: 'staging',
                            facts: {}, trusted: {} }) + "\n",
          )

          reported, = described_class.load(dir)
          node = reported.report('factsets-for-all-active-nodes').first
          expect(node.environment).to eq('staging')
        end
      end

      it 'skips blank lines in NDJSON files' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'factsets-for-all-active-nodes'))
          File.write(
            File.join(dir, 'factsets-for-all-active-nodes', 'puppet--20260807160000.ndjson'),
            "\n" + JSON.generate({ certname: 'web1.example.com', environment: 'production',
                                   facts: {}, trusted: {} }) + "\n\n",
          )

          reported, findings = described_class.load(dir)
          expect(findings).to be_empty
          expect(reported.report('factsets-for-all-active-nodes').size).to eq(1)
        end
      end

      it 'emits a data:json-parse-error for a malformed NDJSON line' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'factsets-for-all-active-nodes'))
          File.write(
            File.join(dir, 'factsets-for-all-active-nodes', 'puppet--20260807160000.ndjson'),
            "not valid json\n",
          )

          _, findings = described_class.load(dir)
          expect(findings.map(&:key)).to include('data:json-parse-error')
        end
      end

      it 'prefers a newer .ndjson over an older .json from the same collector' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'factsets-for-all-active-nodes'))
          File.write(
            File.join(dir, 'factsets-for-all-active-nodes', 'puppet--20260807150000.json'),
            JSON.generate([{ certname: 'web1.example.com', environment: 'production',
                             facts: { 'source' => 'old' }, trusted: {} }]),
          )
          File.write(
            File.join(dir, 'factsets-for-all-active-nodes', 'puppet--20260807160000.ndjson'),
            JSON.generate({ certname: 'web1.example.com', environment: 'production',
                            facts: { 'source' => 'new' }, trusted: {} }) + "\n",
          )

          reported, = described_class.load(dir)
          node = reported.report('factsets-for-all-active-nodes').first
          expect(node.facts['source']).to eq('new')
        end
      end
    end

    context 'factsets-for-all-active-nodes query' do
      it 'is absent (MissingReport) when the directory does not exist' do
        reported, = described_class.load('/does/not/exist')
        expect(reported.missing?('factsets-for-all-active-nodes')).to be true
      end
    end

    context 'dot-prefixed entries' do
      it 'ignores dot-prefixed files inside a query dir' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'all-active-nodes'))
          File.write(
            File.join(dir, 'all-active-nodes', '.hidden--20260803150000.json'),
            JSON.generate([{ certname: 'ghost', report_timestamp: '2026-08-03T15:00:00Z',
                             facts: {}, trusted: {} }]),
          )

          reported, = described_class.load(dir)
          expect(reported.missing?('all-active-nodes')).to be true
        end
      end

      it 'ignores a dot-prefixed sibling dir (.archive) at the incoming root' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, '.archive', 'foo--sess-old'))
          File.write(
            File.join(dir, '.archive', 'foo--sess-old', 'all-active-nodes.ndjson'),
            JSON.generate({ certname: 'archived', report_timestamp: '2026-01-01T00:00:00Z',
                            facts: {}, trusted: {} }) + "\n",
          )

          reported, = described_class.load(dir)
          expect(reported.missing?('all-active-nodes')).to be true
        end
      end
    end
  end

  describe 'classes-for-all-active-nodes' do
    let(:classed) { described_class.load(fixture('basic'))[0].report('classes-for-all-active-nodes') }
    let(:by_certname) { classed.each_with_object({}) { |n, h| h[n.certname] = n } }

    it 'is loaded' do
      expect(described_class::QUERIES).to include('classes-for-all-active-nodes')
    end

    it 'is not a node report' do
      expect(described_class::NODE_REPORTS)
        .to eq(%w[all-active-nodes factsets-for-all-active-nodes])
    end

    it 'yields Nodes, as the other reports do' do
      expect(classed).to all(be_a(Driftless::Node))
    end

    it 'leaves facts and trusted empty, as the node reports leave classes' do
      expect(by_certname['alpha.example.com'].facts).to eq({})
      expect(by_certname['alpha.example.com'].trusted).to eq({})
    end

    # The query returns one row per (certname, class); the report is per node.
    it 'collects a node\'s rows into one entry rather than keeping the last' do
      expect(classed.map(&:certname))
        .to contain_exactly('alpha.example.com', 'beta.example.com')
      expect(by_certname['alpha.example.com'].classes)
        .to eq(['Profile::Base', 'Role::Web'])
    end

    it 'dedupes a class repeated across rows' do
      titles = by_certname['alpha.example.com'].classes
      expect(titles.length).to eq(titles.uniq.length)
    end

    it 'sorts the class list, so it does not depend on row order' do
      expect(by_certname['alpha.example.com'].classes).to eq(
        by_certname['alpha.example.com'].classes.sort,
      )
    end

    it 'carries the environment and the collector the rows came from' do
      c = by_certname['beta.example.com']
      expect(c.environment).to eq('production')
      expect(c.collector).to eq('east')
    end

    it 'reports a certname claimed by two collectors, as the node reports do' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'classes-for-all-active-nodes'))
        {
          'east--20260803150000.ndjson' => '{"certname":"a","title":"Role::X"}',
          'west--20260803150000.ndjson' => '{"certname":"a","title":"Role::Y"}',
        }.each { |name, body| File.write(File.join(dir, 'classes-for-all-active-nodes', name), body + "\n") }
        expect(described_class.load(dir)[0].duplicate_certnames).to eq('a' => %w[east west])
      end
    end

    it 'emits a data:json-parse-error finding for an unparseable file' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'classes-for-all-active-nodes'))
        File.write(File.join(dir, 'classes-for-all-active-nodes', 'east--20260803150000.json'), '{ nope')
        _reported, findings = described_class.load(dir)
        expect(findings.map(&:key)).to eq(['data:json-parse-error'])
      end
    end

    it 'skips a row with no certname' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'classes-for-all-active-nodes'))
        File.write(
          File.join(dir, 'classes-for-all-active-nodes', 'east--20260803150000.ndjson'),
          %({"title":"Role::Orphan"}\n{"certname":"a","title":"Role::X"}\n),
        )
        loaded = described_class.load(dir)[0].report('classes-for-all-active-nodes')
        expect(loaded.map(&:certname)).to eq(['a'])
      end
    end
  end
end
