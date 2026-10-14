require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'

require 'driftless/git_remote'

RSpec.describe Driftless::GitRemote do
  def git(dir, *args)
    system('git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.com', *args, exception: true)
  end

  # metadata.json "one" committed and tagged v1, then "two" on main.
  def upstream(dir)
    FileUtils.mkdir_p(dir)
    git(dir, 'init', '-q', '-b', 'main')
    File.write(File.join(dir, 'metadata.json'), "one\n")
    git(dir, 'add', '.')
    git(dir, 'commit', '-q', '-m', 'one')
    git(dir, 'tag', 'v1')
    File.write(File.join(dir, 'metadata.json'), "two\n")
    git(dir, 'commit', '-q', '-am', 'two')
    dir
  end

  let(:tmp)   { Dir.mktmpdir }
  let(:cache) { File.join(tmp, 'cache') }
  let(:url)   { upstream(File.join(tmp, 'up')) }

  after(:each) { FileUtils.rm_rf(tmp) }

  it 'reads a file at a tag and at a branch' do
    remote = described_class.new(url, cache_dir: cache)
    expect(remote.read_file('v1', 'metadata.json')).to eq("one\n")
    expect(remote.read_file('main', 'metadata.json')).to eq("two\n")
  end

  it 'caches only reads marked immutable' do
    remote = described_class.new(url, cache_dir: cache)
    expect(remote.read_file('main', 'metadata.json')).to eq("two\n")
    expect(Dir.exist?(cache)).to be false
    expect(remote.read_file('v1', 'metadata.json', immutable: true)).to eq("one\n")
    expect(Dir.children(cache).size).to eq(1)
    git(url, 'tag', '-f', 'v1', 'main')
    expect(remote.read_file('v1', 'metadata.json', immutable: true)).to eq("one\n")
    expect(described_class.new(url, cache_dir: nil).read_file('v1', 'metadata.json', immutable: true)).to eq("two\n")
  end

  it 'raises for an unknown ref, a missing file, and an absent git' do
    remote = described_class.new(url, cache_dir: nil)
    expect { remote.read_file('nope', 'metadata.json') }.to raise_error(described_class::Error, /git fetch/)
    expect { remote.read_file('v1', 'nope.json') }.to raise_error(described_class::Error, /git cat-file/)
    allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
    expect { remote.read_file('v1', 'metadata.json') }.to raise_error(described_class::Error, /git is not installed/)
  end
end
