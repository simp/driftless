require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'

require 'driftless/import/git'

RSpec.describe Driftless::Import::Git do
  # Builds a bare git repo at <root>/remote.git populated with one branch per
  # collector under <branch_prefix>/<name>. `branches` is a Hash mapping
  # collector name -> { session:, extra_branch: (optional non-matching branch name) }.
  # Returns the bare-repo path.
  def make_remote(root, branches, branch_prefix: 'collector', extra_branches: [])
    remote = File.join(root, 'remote.git')
    run('git', 'init', '--bare', '-q', remote)

    branches.each do |collector, spec|
      session = spec[:session]
      work    = File.join(root, "work-#{collector}")
      # Populate a target-shape tree: incoming/<query>/<collector>--<session>.ndjson + summary/<same>.json
      FileUtils.mkdir_p(File.join(work, 'incoming', 'all-active-nodes'))
      FileUtils.mkdir_p(File.join(work, 'incoming', 'factsets-for-all-active-nodes'))
      FileUtils.mkdir_p(File.join(work, 'summary'))
      File.write(File.join(work, 'incoming', 'all-active-nodes',
                           "#{collector}--#{session}.ndjson"), %({"certname":"n"}\n))
      File.write(File.join(work, 'incoming', 'factsets-for-all-active-nodes',
                           "#{collector}--#{session}.ndjson"), %({"certname":"n","facts":{}}\n))
      File.write(File.join(work, 'summary', "#{collector}--#{session}.json"),
                 %({"collector":"#{collector}","session_id":"#{session}"}\n))

      run('git', '-C', work, 'init', '-q', '-b', 'main')
      run('git', '-C', work, 'checkout', '-q', '--orphan', "#{branch_prefix}/#{collector}")
      run('git', '-C', work, 'add', '.')
      run('git', '-C', work, '-c', 'user.email=t@e', '-c', 'user.name=t',
          'commit', '-q', '-m', "session #{session}")
      run('git', '-C', work, 'push', '-q', '--force', remote,
          "#{branch_prefix}/#{collector}:#{branch_prefix}/#{collector}")
    end

    extra_branches.each do |name|
      work = File.join(root, "work-extra-#{name.tr('/', '-')}")
      FileUtils.mkdir_p(work)
      File.write(File.join(work, 'noise.txt'), 'x')
      run('git', '-C', work, 'init', '-q', '-b', 'main')
      run('git', '-C', work, 'checkout', '-q', '--orphan', name)
      run('git', '-C', work, 'add', '.')
      run('git', '-C', work, '-c', 'user.email=t@e', '-c', 'user.name=t',
          'commit', '-q', '-m', 'noise')
      run('git', '-C', work, 'push', '-q', '--force', remote, "#{name}:#{name}")
    end

    remote
  end

  def run(*cmd)
    _, err, status = Open3.capture3(*cmd)
    raise "cmd failed: #{cmd.inspect}\n#{err}" unless status.success?
  end

  describe '#run' do
    it 'merges multiple collector branches into the target ingest tree' do
      Dir.mktmpdir do |root|
        remote = make_remote(root, {
          'alpha' => { session: 'sess-a' },
          'beta'  => { session: 'sess-b' },
        })
        target = File.join(root, 'target', 'incoming')

        result = described_class.new(repo_url: remote, incoming_dir: target).run

        expect(result.branches_imported).to eq(2)
        expect(result.reports_copied).to eq(4) # 2 queries * 2 collectors
        expect(File).to exist(File.join(target, 'all-active-nodes', 'alpha--sess-a.ndjson'))
        expect(File).to exist(File.join(target, 'all-active-nodes', 'beta--sess-b.ndjson'))
        expect(File).to exist(File.join(target, 'factsets-for-all-active-nodes', 'alpha--sess-a.ndjson'))
        expect(File).to exist(File.join(target, 'factsets-for-all-active-nodes', 'beta--sess-b.ndjson'))
      end
    end

    it 'copies summary/ files to summary_dir when provided' do
      Dir.mktmpdir do |root|
        remote = make_remote(root, { 'alpha' => { session: 'sess-a' } })
        target  = File.join(root, 'target', 'incoming')
        summary = File.join(root, 'target', 'summary')

        result = described_class.new(repo_url: remote, incoming_dir: target,
                                     summary_dir: summary).run

        expect(result.summaries_copied).to eq(1)
        expect(File).to exist(File.join(summary, 'alpha--sess-a.json'))
      end
    end

    it 'omits summaries when summary_dir is nil (default)' do
      Dir.mktmpdir do |root|
        remote = make_remote(root, { 'alpha' => { session: 'sess-a' } })
        target = File.join(root, 'target', 'incoming')

        result = described_class.new(repo_url: remote, incoming_dir: target).run

        expect(result.summaries_copied).to eq(0)
        expect(File.directory?(File.join(root, 'target', 'summary'))).to be false
      end
    end

    it 'filters to a single collector via `collector:`' do
      Dir.mktmpdir do |root|
        remote = make_remote(root, {
          'alpha' => { session: 'sess-a' },
          'beta'  => { session: 'sess-b' },
        })
        target = File.join(root, 'target', 'incoming')

        result = described_class.new(repo_url: remote, incoming_dir: target,
                                     collector: 'alpha').run

        expect(result.branches_imported).to eq(1)
        expect(File).to exist(File.join(target, 'all-active-nodes', 'alpha--sess-a.ndjson'))
        expect(File).not_to exist(File.join(target, 'all-active-nodes', 'beta--sess-b.ndjson'))
      end
    end

    it 'ignores branches outside the branch_prefix' do
      Dir.mktmpdir do |root|
        remote = make_remote(root,
          { 'alpha' => { session: 'sess-a' } },
          extra_branches: ['other/junk'],
        )
        target = File.join(root, 'target', 'incoming')

        result = described_class.new(repo_url: remote, incoming_dir: target).run

        expect(result.branches_imported).to eq(1) # only collector/alpha
        expect(File.directory?(File.join(target, 'junk'))).to be false
      end
    end

    it 'honors a custom branch_prefix' do
      Dir.mktmpdir do |root|
        remote = make_remote(root,
          { 'alpha' => { session: 'sess-a' } },
          branch_prefix: 'edge',
        )
        target = File.join(root, 'target', 'incoming')

        result = described_class.new(repo_url: remote, incoming_dir: target,
                                     branch_prefix: 'edge').run

        expect(result.branches_imported).to eq(1)
        expect(File).to exist(File.join(target, 'all-active-nodes', 'alpha--sess-a.ndjson'))
      end
    end

    it 'reports 0 branches with a warn log when no branches match' do
      Dir.mktmpdir do |root|
        remote = make_remote(root, {}, extra_branches: ['unrelated/one'])
        target = File.join(root, 'target', 'incoming')

        result = described_class.new(repo_url: remote, incoming_dir: target).run

        expect(result.branches_imported).to eq(0)
        expect(result.reports_copied).to eq(0)
      end
    end

    it 'dry_run does not touch the target filesystem' do
      Dir.mktmpdir do |root|
        remote = make_remote(root, { 'alpha' => { session: 'sess-a' } })
        target = File.join(root, 'target', 'incoming')

        result = described_class.new(repo_url: remote, incoming_dir: target,
                                     dry_run: true).run

        expect(result.reports_copied).to eq(2)
        expect(File.directory?(target)).to be false
      end
    end

    it 'runs checkout with the same auth env and config as clone' do
      Dir.mktmpdir do |root|
        remote = make_remote(root, { 'alpha' => { session: 'sess-a' } })
        target = File.join(root, 'target', 'incoming')
        calls = []
        allow(Open3).to receive(:capture3).and_wrap_original do |m, *args|
          calls << args
          m.call(*args)
        end

        saved = ENV['DRIFTLESS_REPORT_PULL_TOKEN']
        ENV['DRIFTLESS_REPORT_PULL_TOKEN'] = 'tok'
        begin
          described_class.new(repo_url: remote, incoming_dir: target).run
        ensure
          ENV['DRIFTLESS_REPORT_PULL_TOKEN'] = saved
        end

        clone    = calls.find { |a| a.include?('clone') }
        checkout = calls.find { |a| a.include?('checkout') }
        expect(clone.first).to include('GIT_TERMINAL_PROMPT' => '0')
        expect(checkout.first).to eq(clone.first)
        expect(checkout.grep(/\Acredential\.helper=/)).to eq(clone.grep(/\Acredential\.helper=/))
        expect(checkout.grep(/\Acredential\.helper=!/)).not_to be_empty
      end
    end

    it 'raises Import::Error when repo_url is blank' do
      expect { described_class.new(repo_url: '', incoming_dir: '/tmp/x').run }
        .to raise_error(Driftless::Import::Error, /repo_url required/)
    end

    it 'raises Import::Error when incoming_dir is blank' do
      expect { described_class.new(repo_url: 'x', incoming_dir: '').run }
        .to raise_error(Driftless::Import::Error, /incoming_dir required/)
    end

    it 'raises Import::Error when the remote is unreachable' do
      expect {
        described_class.new(repo_url: '/definitely/not/a/repo', incoming_dir: '/tmp/x').run
      }.to raise_error(Driftless::Import::Error, /git clone failed/)
    end
  end
end
