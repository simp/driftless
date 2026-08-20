require 'fileutils'
require 'tmpdir'

require 'spec_helper'
require 'driftless/control_repo'

RSpec.describe Driftless::ControlRepo do
  def control_repo(dir)
    FileUtils.touch(File.join(dir, 'hiera.yaml'))
    FileUtils.touch(File.join(dir, 'environment.conf'))
    dir
  end

  describe '.detect' do
    it 'returns a repo when both hiera.yaml and environment.conf are present' do
      Dir.mktmpdir do |dir|
        control_repo(dir)
        expect(described_class.detect(dir).dir).to eq(File.expand_path(dir))
      end
    end

    it 'returns nil when only hiera.yaml is present' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'hiera.yaml'))
        expect(described_class.detect(dir)).to be_nil
      end
    end

    it 'returns nil when only environment.conf is present' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'environment.conf'))
        expect(described_class.detect(dir)).to be_nil
      end
    end

    it 'returns nil in an empty directory' do
      Dir.mktmpdir { |dir| expect(described_class.detect(dir)).to be_nil }
    end
  end

  describe '#dir' do
    it 'is absolute even when constructed from a relative path' do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { expect(described_class.new('.').dir).to eq(File.expand_path(dir)) }
      end
    end
  end

  describe '#readable?' do
    it 'is true for an existing directory' do
      Dir.mktmpdir { |dir| expect(described_class.new(dir)).to be_readable }
    end

    it 'is false for a path that does not exist' do
      expect(described_class.new('/nonexistent/repo')).not_to be_readable
    end
  end

  describe '#default_incoming_dir' do
    it 'returns <dir>/incoming when that subdirectory exists' do
      Dir.mktmpdir do |dir|
        incoming = File.join(dir, 'incoming')
        Dir.mkdir(incoming)
        expect(described_class.new(dir).default_incoming_dir).to eq(incoming)
      end
    end

    it 'returns nil when <dir>/incoming is absent' do
      Dir.mktmpdir { |dir| expect(described_class.new(dir).default_incoming_dir).to be_nil }
    end

    it 'returns nil when <dir>/incoming exists as a regular file' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'incoming'))
        expect(described_class.new(dir).default_incoming_dir).to be_nil
      end
    end
  end
end
