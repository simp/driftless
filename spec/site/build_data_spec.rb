require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'

require 'driftless/site/build_data'
require 'driftless/models/node'
require 'driftless/reported'
require 'driftless/finding'

RSpec.describe Driftless::Site::BuildData do
  def node(certname, environment: 'production', collector: 'east')
    Driftless::Node.new(certname: certname, environment: environment, collector: collector)
  end

  def reported_with(nodes)
    Driftless::Reported.new(data: { 'all-active-nodes' => nodes })
  end

  def finding(key: 'data:missing-nodes', path: 'data/nodes/x.yaml', line: nil, message: 'gone')
    Driftless::Finding.new(key: key, path: path, line: line, message: message, meta: { certname: 'x' })
  end

  def assemble(**overrides)
    defaults = {
      findings:     [],
      corpus:       build_corpus(reported: reported_with([])),
      warnings:     [],
      environments: ['production'],
      summary_dir:  nil,
      now:          Time.utc(2026, 8, 26, 12, 0, 0),
    }
    described_class.assemble(**defaults, **overrides)
  end

  it 'stamps the schema version, generation time, and driftless version' do
    data = assemble
    expect(data['schema_version']).to eq(1)
    expect(data['generated_at']).to eq('2026-08-26T12:00:00Z')
    expect(data['driftless_version']).to eq(Driftless::VERSION)
  end

  it 'reserves utilization as null until report exists' do
    expect(assemble).to include('utilization' => nil)
  end

  it 'carries the scan warnings and environments through' do
    data = assemble(warnings: %w[w1 w2], environments: %w[production staging])
    expect(data['warnings']).to eq(%w[w1 w2])
    expect(data['environments']).to eq(%w[production staging])
  end

  it 'renders nil environments as an empty list' do
    expect(assemble(environments: nil)['environments']).to eq([])
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

  describe 'sessions' do
    def write_summary(dir, collector, session_id, reports)
      File.write(File.join(dir, "#{collector}--#{session_id}.json"), JSON.generate('reports' => reports))
    end

    it 'lists the newest session per collector, in collector order' do
      Dir.mktmpdir do |dir|
        write_summary(dir, 'west', '20260101T000000Z', { 'all-active-nodes' => 'ok' })
        write_summary(dir, 'east', '20260101T000000Z', { 'all-active-nodes' => 'ok' })
        write_summary(dir, 'east', '20260102T000000Z', { 'all-active-nodes' => 'ok', 'factsets-for-all-active-nodes' => 'ok' })

        sessions = assemble(summary_dir: dir)['sessions']
        expect(sessions.map { |s| [s['collector'], s['session_id']] })
          .to eq([%w[east 20260102T000000Z], %w[west 20260101T000000Z]])
        expect(sessions.first['reports_declared'].keys).to contain_exactly('all-active-nodes', 'factsets-for-all-active-nodes')
      end
    end

    it 'is empty without a summary dir' do
      expect(assemble(summary_dir: nil)['sessions']).to eq([])
    end
  end

  describe 'repo' do
    it 'records the corpus repo_dir' do
      corpus = build_corpus(repo_dir: '/srv/repo', reported: reported_with([]))
      expect(assemble(corpus: corpus)['repo']['dir']).to eq('/srv/repo')
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

    it 'has no git revision when git is not installed' do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
      Dir.mktmpdir do |dir|
        corpus = build_corpus(repo_dir: dir, reported: reported_with([]))
        expect(assemble(corpus: corpus)['repo']['git']).to be_nil
      end
    end
  end

  it 'round-trips through JSON' do
    data   = assemble(findings: [finding(line: 4)], warnings: ['w'])
    parsed = JSON.parse(JSON.generate(data))
    expect(parsed.keys).to eq(data.keys)
    expect(parsed['findings'].first).to include('line' => 4, 'meta' => { 'certname' => 'x' })
    expect(parsed['warnings']).to eq(['w'])
  end
end
