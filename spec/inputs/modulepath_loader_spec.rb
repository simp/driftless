require 'spec_helper'
require 'tmpdir'
require 'fileutils'

require 'driftless/inputs/modulepath_loader'

RSpec.describe Driftless::Inputs::ModulepathLoader do
  describe '.load' do
    it 'discovers .pp files under site-modules/<module>/manifests/ and modules/<module>/manifests/' do
      Dir.mktmpdir do |repo|
        FileUtils.mkdir_p(File.join(repo, 'site-modules/profile/manifests'))
        FileUtils.mkdir_p(File.join(repo, 'modules/stdlib/manifests'))
        FileUtils.touch(File.join(repo, 'site-modules/profile/manifests/example.pp'))
        FileUtils.touch(File.join(repo, 'site-modules/profile/manifests/other.pp'))
        FileUtils.touch(File.join(repo, 'modules/stdlib/manifests/init.pp'))
        FileUtils.touch(File.join(repo, 'modules/stdlib/manifests/README.md'))

        files, findings = described_class.load(repo, basemodulepath: [])
        rels = files.map { |f| f.sub("#{repo}/", '') }
        expect(rels).to contain_exactly(
          'site-modules/profile/manifests/example.pp',
          'site-modules/profile/manifests/other.pp',
          'modules/stdlib/manifests/init.pp',
        )
        expect(findings).to be_empty
      end
    end

    it 'traverses into nested manifests subdirectories' do
      Dir.mktmpdir do |repo|
        FileUtils.mkdir_p(File.join(repo, 'site-modules/profile/manifests/sub/deeper'))
        FileUtils.touch(File.join(repo, 'site-modules/profile/manifests/init.pp'))
        FileUtils.touch(File.join(repo, 'site-modules/profile/manifests/sub/one.pp'))
        FileUtils.touch(File.join(repo, 'site-modules/profile/manifests/sub/deeper/two.pp'))

        files, _ = described_class.load(repo, basemodulepath: [])
        rels = files.map { |f| f.sub("#{repo}/", '') }
        expect(rels).to contain_exactly(
          'site-modules/profile/manifests/init.pp',
          'site-modules/profile/manifests/sub/one.pp',
          'site-modules/profile/manifests/sub/deeper/two.pp',
        )
      end
    end

    it 'silently skips missing site-modules or modules dirs' do
      Dir.mktmpdir do |repo|
        # only site-modules, no modules
        FileUtils.mkdir_p(File.join(repo, 'site-modules/profile/manifests'))
        FileUtils.touch(File.join(repo, 'site-modules/profile/manifests/init.pp'))

        files, findings = described_class.load(repo, basemodulepath: [])
        expect(files.length).to eq(1)
        expect(findings).to be_empty
      end
    end

    it 'emits hierarchy:absolute-modulepath-missing for a basemodulepath dir that does not exist' do
      Dir.mktmpdir do |repo|
        _, findings = described_class.load(repo, basemodulepath: ['/does/not/exist'])
        expect(findings.map(&:key)).to eq(['hierarchy:absolute-modulepath-missing'])
      end
    end
  end
end
