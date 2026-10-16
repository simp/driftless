require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'

require 'driftless/git_clone'

RSpec.describe Driftless::GitClone do
  def git(dir, *args)
    system('git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.com', *args, exception: true)
  end

  # Two empty commits on main; the first is tagged v1.
  def repo(dir)
    FileUtils.mkdir_p(dir)
    git(dir, 'init', '-q', '-b', 'main')
    git(dir, 'commit', '-q', '--allow-empty', '-m', 'one')
    git(dir, 'tag', 'v1')
    git(dir, 'commit', '-q', '--allow-empty', '-m', 'two')
  end

  let(:tmp) { Dir.mktmpdir }

  after(:each) { FileUtils.rm_rf(tmp) }

  it 'answers nil for a directory that is not a work tree' do
    clone = described_class.new(tmp)
    expect(clone.own?).to be false
    expect([clone.sha, clone.current_branch, clone.remote, clone.branch_at_head, clone.resolve('main')]).to all(be_nil)
  end

  it 'answers nil when git is not installed' do
    repo(tmp)
    allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
    expect(described_class.new(tmp).sha).to be_nil
  end

  it 'reads HEAD, the current branch, and the origin remote' do
    repo(tmp)
    clone = described_class.new(tmp)
    expect(clone.own?).to be true
    expect(clone.sha).to match(/\A[0-9a-f]{40}\z/)
    expect(clone.current_branch).to eq('main')
    expect(clone.remote).to be_nil
    git(tmp, 'remote', 'add', 'origin', 'git@h:o/p.git')
    expect(clone.remote).to eq('git@h:o/p.git')
    git(tmp, 'checkout', '-q', '--detach')
    expect(clone.current_branch).to eq('HEAD')
  end

  it 'resolves a tag, a branch, a sha prefix, and an origin branch to a commit' do
    upstream = File.join(tmp, 'up')
    deployed = File.join(tmp, 'dep')
    repo(upstream)
    clone = described_class.new(upstream)
    expect(clone.resolve('v1')).to match(/\A[0-9a-f]{40}\z/)
    expect(clone.resolve('v1')).not_to eq(clone.sha)
    expect(clone.resolve('main')).to eq(clone.sha)
    expect(clone.resolve(clone.sha[0, 12])).to eq(clone.sha)
    expect(clone.resolve('nope')).to be_nil

    git(tmp, 'clone', '-q', upstream, deployed)
    git(deployed, 'checkout', '-q', '--detach', 'v1')
    git(deployed, 'branch', '-q', '-D', 'main')
    expect(described_class.new(deployed).resolve('main')).to eq(clone.sha)
  end

  it 'fetches origin and logs a range' do
    upstream = File.join(tmp, 'up')
    deployed = File.join(tmp, 'dep')
    repo(upstream)
    git(tmp, 'clone', '-q', upstream, deployed)
    git(upstream, 'commit', '-q', '--allow-empty', '-m', 'three')
    clone = described_class.new(deployed)
    expect(clone.log('--oneline', '--decorate', 'HEAD..origin/main')).to eq('')
    expect(clone.fetch).not_to be_nil
    expect(clone.log('--oneline', '--decorate', 'HEAD..origin/main')).to match(%r{\A[0-9a-f]+ \(origin/main, origin/HEAD\) three\z})
    expect(clone.log('--oneline', '-n', '1', 'HEAD')).to match(/ two\z/)
    expect(described_class.new(tmp).fetch).to be_nil
  end

  it 'names a tag at HEAD' do
    repo(tmp)
    clone = described_class.new(tmp)
    expect(clone.tag_at_head).to be_nil
    git(tmp, 'checkout', '-q', '--detach', 'v1')
    expect(clone.tag_at_head).to eq('v1')
  end

  it 'names a branch whose tip is HEAD, preferring the one asked for' do
    repo(tmp)
    clone = described_class.new(tmp)
    expect(clone.branch_at_head).to eq('main')
    git(tmp, 'branch', '-q', 'feature')
    expect(clone.branch_at_head).to eq('feature')
    expect(clone.branch_at_head(prefer: 'main')).to eq('main')
    git(tmp, 'checkout', '-q', '--detach', 'v1')
    expect(clone.branch_at_head).to be_nil
  end
end
