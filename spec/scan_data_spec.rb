require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'

require 'driftless/scan_data'
require 'driftless/scan'
require 'driftless/models/node'
require 'driftless/models/hiera_tier'
require 'driftless/reported'
require 'driftless/inputs/puppetfile'
require 'driftless/finding'

RSpec.describe Driftless::ScanData do
  def node(certname, environment: 'production', collector: 'east')
    Driftless::Node.new(certname: certname, environment: environment, collector: collector)
  end

  def session(collector, session_id, reports = ['all-active-nodes'])
    Driftless::Reported::Session.new(collector: collector, session_id: session_id, reports: reports)
  end

  def reported_with(nodes, sessions: [])
    Driftless::Reported.new(data: { 'all-active-nodes' => nodes }, sessions: sessions)
  end

  def finding(key: 'data:missing-nodes', path: 'data/nodes/x.yaml', line: nil, message: 'gone')
    Driftless::Finding.new(key: key, path: path, line: line, message: message, meta: { certname: 'x' })
  end

  NO_OVERRIDES = {
    'accept_partial_report_sessions' => nil, 'accept_duplicate_certnames' => false, 'proceed_with_subset_of_configured_envs' => false
  }.freeze

  def assemble(**overrides)
    defaults = {
      findings:     [],
      corpus:       build_corpus(reported: reported_with([])),
      warnings:     [],
      environments: ['production'],
      overrides:    NO_OVERRIDES,
      now:          Time.utc(2026, 8, 26, 12, 0, 0),
    }
    described_class.assemble(**defaults, **overrides)
  end

  it 'names its document kind and schema version first' do
    expect(assemble.keys.first(2)).to eq(%w[document schema_version])
    expect(assemble).to include('document' => 'scan', 'schema_version' => 1)
  end

  it 'stamps the generation time and driftless version' do
    data = assemble
    expect(data['generated_at']).to eq('2026-08-26T12:00:00Z')
    expect(data['driftless_version']).to eq(Driftless::VERSION)
  end

  it 'carries the warnings, environments, and overrides through' do
    data = assemble(warnings: %w[w1 w2], environments: %w[production staging],
                    overrides: NO_OVERRIDES.merge('proceed_with_subset_of_configured_envs' => true))
    expect(data['warnings']).to eq(%w[w1 w2])
    expect(data['environments']).to eq(%w[production staging])
    expect(data['overrides']['proceed_with_subset_of_configured_envs']).to be(true)
  end

  it 'renders nil environments as an empty list' do
    expect(assemble(environments: nil)['environments']).to eq([])
  end

  describe '.overrides_from' do
    def scanner(**attrs)
      instance_double(Driftless::Scan, { accept_partial_report_sessions: nil, accept_duplicate_certnames: false,
                                         proceed_with_subset_of_configured_envs: false }.merge(attrs))
    end

    it 'records nothing relaxed as nil and false' do
      expect(described_class.overrides_from(scanner)).to eq(NO_OVERRIDES)
    end

    it 'spells the bare partial-sessions override as "bare" and keeps a list as is' do
      expect(described_class.overrides_from(scanner(accept_partial_report_sessions: :bare))['accept_partial_report_sessions'])
        .to eq('bare')
      expect(described_class.overrides_from(scanner(accept_partial_report_sessions: %w[a b]))['accept_partial_report_sessions'])
        .to eq(%w[a b])
    end

    it 'normalizes the booleans' do
      expect(described_class.overrides_from(scanner(accept_duplicate_certnames: true, proceed_with_subset_of_configured_envs: nil)))
        .to include('accept_duplicate_certnames' => true, 'proceed_with_subset_of_configured_envs' => false)
    end
  end

  describe 'findings' do
    it 'renders each finding as the json writer does, string-keyed and in its order' do
      findings = [
        finding(key: 'hierarchy:x', path: 'hiera.yaml', line: 3),
        finding(key: 'data:missing-nodes', path: 'data/nodes/b.yaml'),
        finding(key: 'data:missing-nodes', path: 'data/nodes/a.yaml'),
      ]
      rows = assemble(findings: findings)['findings']
      expect(rows.map { |r| [r['key'], r['path']] }).to eq(
        [['data:missing-nodes', 'data/nodes/a.yaml'], ['data:missing-nodes', 'data/nodes/b.yaml'], ['hierarchy:x', 'hiera.yaml']],
      )
      expect(rows.first.keys).to eq(%w[key severity quality path line message meta])
    end
  end

  describe 'sessions' do
    it 'lists the sessions the loader read, with the reports read from each' do
      sessions = [session('east', 'T02', %w[all-active-nodes factsets-for-all-active-nodes]), session('west', 'T01')]
      corpus   = build_corpus(reported: reported_with([], sessions: sessions))
      expect(assemble(corpus: corpus)['sessions']).to eq([
        { 'collector' => 'east', 'session_id' => 'T02', 'reports' => %w[all-active-nodes factsets-for-all-active-nodes] },
        { 'collector' => 'west', 'session_id' => 'T01', 'reports' => ['all-active-nodes'] },
      ])
    end

    it 'is empty when nothing was loaded' do
      expect(assemble['sessions']).to eq([])
    end
  end

  describe 'nodes' do
    it 'tallies the all-active-nodes report by collector and environment' do
      corpus = build_corpus(reported: reported_with([
        node('a', collector: 'east', environment: 'production'),
        node('b', collector: 'west', environment: 'production'),
        node('c', collector: 'east', environment: 'staging'),
      ]))
      expect(assemble(corpus: corpus)['nodes']).to eq(
        'total'          => 3,
        'by_collector'   => { 'east' => 2, 'west' => 1 },
        'by_environment' => { 'production' => 2, 'staging' => 1 },
      )
    end

    it 'tallies a node with no environment under a placeholder key' do
      corpus = build_corpus(reported: reported_with([node('a', environment: nil)]))
      expect(assemble(corpus: corpus)['nodes']['by_environment']).to eq('(unknown)' => 1)
    end

    it 'reports zero nodes when the report was not loaded' do
      corpus = build_corpus(reported: Driftless::Reported.new(data: {}))
      expect(assemble(corpus: corpus)['nodes']).to eq('total' => 0, 'by_collector' => {}, 'by_environment' => {})
    end
  end

  describe 'repo' do
    it 'records the corpus repo_dir' do
      corpus = build_corpus(repo_dir: '/srv/repo', reported: reported_with([]))
      expect(assemble(corpus: corpus)['repo']['dir']).to eq('/srv/repo')
    end

    it 'lists the declared hierarchy under repo' do
      tier = Driftless::HieraTier.new(
        name: 'Per-node data', datadir: '/tmp/data', backend: :yaml_data, source_line: 7,
        path_templates: ['nodes/%{trusted.certname}.yaml'], interpolation_vars: ['trusted.certname'], multi_path: false,
      )
      corpus = build_corpus(hiera_tiers: [tier], reported: reported_with([]))
      expect(assemble(corpus: corpus)['repo']['hierarchy']).to eq([
        { 'name' => 'Per-node data', 'backend' => 'yaml_data', 'line' => 7,
          'paths' => ['nodes/%{trusted.certname}.yaml'], 'vars' => ['trusted.certname'] },
      ])
    end

    it 'has no git revision for a directory that is not a work tree' do
      Dir.mktmpdir do |dir|
        corpus = build_corpus(repo_dir: dir, reported: reported_with([]))
        expect(assemble(corpus: corpus)['repo']['git']).to be_nil
      end
    end

    it 'has no git revision when repo_dir is nil' do
      expect(assemble['repo']['git']).to be_nil
    end

    it 'records the sha and branch of a work tree' do
      Dir.mktmpdir do |dir|
        system('git', '-C', dir, 'init', '-q', '-b', 'main', exception: true)
        system('git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.com',
               'commit', '-q', '--allow-empty', '-m', 'init', exception: true)
        corpus = build_corpus(repo_dir: dir, reported: reported_with([]))
        git = assemble(corpus: corpus)['repo']['git']
        expect(git['sha']).to match(/\A[0-9a-f]{40}\z/)
        expect(git['branch']).to eq('main')
      end
    end

    it 'records the origin remote when there is one' do
      Dir.mktmpdir do |dir|
        system('git', '-C', dir, 'init', '-q', '-b', 'main', exception: true)
        system('git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.com',
               'commit', '-q', '--allow-empty', '-m', 'init', exception: true)
        expect(assemble(corpus: build_corpus(repo_dir: dir, reported: reported_with([])))['repo']['git']['remote']).to be_nil
        system('git', '-C', dir, 'remote', 'add', 'origin', 'git@h:g/p.git', exception: true)
        expect(assemble(corpus: build_corpus(repo_dir: dir, reported: reported_with([])))['repo']['git']['remote']).to eq('git@h:g/p.git')
      end
    end

    it 'has no git revision when git is not installed' do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
      Dir.mktmpdir do |dir|
        corpus = build_corpus(repo_dir: dir, reported: reported_with([]))
        expect(assemble(corpus: corpus)['repo']['git']).to be_nil
      end
    end
  end

  describe 'repo deployments' do
    def puppetfile(modules)
      Driftless::Inputs::Puppetfile::Result.new(exists: true, modules: modules, error: nil)
    end

    def mod(name, path:, git:, ref: nil, ref_type: nil)
      Driftless::Inputs::Puppetfile::Module.new(name: name, path: path, git: git, ref: ref, ref_type: ref_type)
    end

    it 'is empty without a Puppetfile' do
      expect(assemble['repo']['deployments']).to eq({})
      corpus = build_corpus(puppetfile: Driftless::Inputs::Puppetfile::Result.new(exists: false, modules: [], error: nil),
                            reported: reported_with([]))
      expect(assemble(corpus: corpus)['repo']['deployments']).to eq({})
    end

    it 'keys git modules by path with their remote and declared ref, leaving Forge modules out' do
      Dir.mktmpdir do |dir|
        pf = puppetfile([mod('org-a', path: 'modules/a', git: 'git@h:o/a.git', ref: 'v1', ref_type: 'tag'),
                         mod('org-b', path: 'modules/b', git: nil)])
        corpus = build_corpus(repo_dir: dir, puppetfile: pf, reported: reported_with([]))
        expect(assemble(corpus: corpus)['repo']['deployments']).to eq(
          'modules/a' => { 'remote' => 'git@h:o/a.git', 'ref' => 'v1', 'ref_type' => 'tag', 'sha' => nil },
        )
      end
    end

    it 'reads the sha from a deployed clone, but not from a plain directory inside the control repo' do
      Dir.mktmpdir do |dir|
        %w[. modules/a].each do |rel|
          d = File.join(dir, rel)
          FileUtils.mkdir_p(d)
          system('git', '-C', d, 'init', '-q', '-b', 'main', exception: true)
          system('git', '-C', d, '-c', 'user.name=t', '-c', 'user.email=t@example.com',
                 'commit', '-q', '--allow-empty', '-m', "init #{rel}", exception: true)
        end
        FileUtils.mkdir_p(File.join(dir, 'modules/b'))
        pf = puppetfile([mod('a', path: 'modules/a', git: 'git@h:o/a.git', ref: 'main', ref_type: 'branch'),
                         mod('b', path: 'modules/b', git: 'git@h:o/b.git', ref: 'main', ref_type: 'branch')])
        corpus = build_corpus(repo_dir: dir, puppetfile: pf, reported: reported_with([]))
        deployments = assemble(corpus: corpus)['repo']['deployments']
        expect(deployments['modules/a']['sha']).to match(/\A[0-9a-f]{40}\z/)
        expect(deployments['modules/a']['sha']).not_to eq(assemble(corpus: corpus)['repo']['git']['sha'])
        expect(deployments['modules/b']['sha']).to be_nil
      end
    end

    it 'resolves :control_branch to the control repo branch' do
      Dir.mktmpdir do |dir|
        system('git', '-C', dir, 'init', '-q', '-b', 'production', exception: true)
        system('git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.com',
               'commit', '-q', '--allow-empty', '-m', 'init', exception: true)
        pf = puppetfile([mod('a', path: 'modules/a', git: 'g', ref: :control_branch, ref_type: 'branch')])
        corpus = build_corpus(repo_dir: dir, puppetfile: pf, reported: reported_with([]))
        expect(assemble(corpus: corpus)['repo']['deployments']['modules/a']).to include('ref' => 'production', 'ref_type' => 'branch')
      end
    end

    it 'leaves :control_branch unresolved when the control repo is not under git' do
      Dir.mktmpdir do |dir|
        pf = puppetfile([mod('a', path: 'modules/a', git: 'g', ref: :control_branch, ref_type: 'branch')])
        corpus = build_corpus(repo_dir: dir, puppetfile: pf, reported: reported_with([]))
        expect(assemble(corpus: corpus)['repo']['deployments']['modules/a']['ref']).to be_nil
      end
    end
  end

  describe '.write and .read' do
    it 'round-trips a document through a file' do
      Dir.mktmpdir do |dir|
        data = assemble(findings: [finding(line: 4)], warnings: ['w'])
        path = described_class.write(data, File.join(dir, 'public', 'scan.json'))
        expect(described_class.read(path)).to eq(JSON.parse(JSON.generate(data)))
        expect(described_class.read(path)['findings'].first).to include('line' => 4, 'meta' => { 'certname' => 'x' })
      end
    end

    it 'refuses a document of another kind' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'x.json')
        File.write(path, JSON.generate(assemble.merge('document' => 'site')))
        expect { described_class.read(path) }
          .to raise_error(Driftless::JsonDocument::Error, /is a "site" document, expected "scan"/)
      end
    end
  end
end
