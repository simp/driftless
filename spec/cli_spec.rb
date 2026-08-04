require 'spec_helper'
require 'tmpdir'
require 'fileutils'

require 'driftless/cli'

RSpec.describe Driftless::CLI do
  describe '.default_repo_dir' do
    it 'returns the dir when both hiera.yaml and environment.conf are present' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'hiera.yaml'))
        FileUtils.touch(File.join(dir, 'environment.conf'))
        expect(described_class.default_repo_dir(dir)).to eq(dir)
      end
    end

    it 'returns nil when only hiera.yaml is present' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'hiera.yaml'))
        expect(described_class.default_repo_dir(dir)).to be_nil
      end
    end

    it 'returns nil when only environment.conf is present' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'environment.conf'))
        expect(described_class.default_repo_dir(dir)).to be_nil
      end
    end

    it 'returns nil in an empty directory' do
      Dir.mktmpdir do |dir|
        expect(described_class.default_repo_dir(dir)).to be_nil
      end
    end
  end

  describe '.default_incoming_dir' do
    it 'returns <repo_dir>/incoming when that subdirectory exists' do
      Dir.mktmpdir do |repo|
        incoming = File.join(repo, 'incoming')
        Dir.mkdir(incoming)
        expect(described_class.default_incoming_dir(repo)).to eq(incoming)
      end
    end

    it 'returns nil when <repo_dir>/incoming is absent' do
      Dir.mktmpdir do |repo|
        expect(described_class.default_incoming_dir(repo)).to be_nil
      end
    end

    it 'returns nil when <repo_dir>/incoming exists as a regular file (not a dir)' do
      Dir.mktmpdir do |repo|
        FileUtils.touch(File.join(repo, 'incoming'))
        expect(described_class.default_incoming_dir(repo)).to be_nil
      end
    end

    it 'returns nil when repo_dir itself is nil' do
      expect(described_class.default_incoming_dir(nil)).to be_nil
    end
  end
end
