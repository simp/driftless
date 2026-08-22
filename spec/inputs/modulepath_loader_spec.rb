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

    it 'emits controlrepo:missing-modulepaths-from-envconf for a basemodulepath dir that does not exist' do
      Dir.mktmpdir do |repo|
        _, findings = described_class.load(repo, basemodulepath: ['/does/not/exist'])
        expect(findings.map(&:key)).to eq(['controlrepo:missing-modulepaths-from-envconf'])
      end
    end

    context 'with environment.conf' do
      it 'honors an env.conf modulepath that references a non-conventional directory (e.g. site/)' do
        Dir.mktmpdir do |repo|
          File.write(File.join(repo, 'environment.conf'), "modulepath = site\n")
          FileUtils.mkdir_p(File.join(repo, 'site/role/manifests'))
          FileUtils.touch(File.join(repo, 'site/role/manifests/base.pp'))
          # site-modules exists too, but is NOT in env.conf's modulepath.
          FileUtils.mkdir_p(File.join(repo, 'site-modules/other/manifests'))
          FileUtils.touch(File.join(repo, 'site-modules/other/manifests/ignored.pp'))

          files, findings = described_class.load(repo, basemodulepath: [])
          rels = files.map { |f| f.sub("#{repo}/", '') }
          expect(rels).to contain_exactly('site/role/manifests/base.pp')
          expect(findings).to be_empty
        end
      end

      it 'emits controlrepo:missing-modulepaths-from-envconf when env.conf declares a modulepath dir that does not exist' do
        Dir.mktmpdir do |repo|
          File.write(File.join(repo, 'environment.conf'), "modulepath = site\n")
          _, findings = described_class.load(repo, basemodulepath: [])
          expect(findings.map(&:key)).to eq(['controlrepo:missing-modulepaths-from-envconf'])
          expect(findings.first.message).to match(%r{/site" is in \$modulepath, but not on disk})
        end
      end

      it 'expands $basemodulepath in env.conf modulepath' do
        Dir.mktmpdir do |repo|
          File.write(File.join(repo, 'environment.conf'), "modulepath = site:$basemodulepath\n")
          FileUtils.mkdir_p(File.join(repo, 'site/role/manifests'))
          FileUtils.touch(File.join(repo, 'site/role/manifests/base.pp'))
          Dir.mktmpdir do |base|
            FileUtils.mkdir_p(File.join(base, 'stdlib/manifests'))
            FileUtils.touch(File.join(base, 'stdlib/manifests/init.pp'))
            files, _ = described_class.load(repo, basemodulepath: [base])
            expect(files.length).to eq(2)
          end
        end
      end

      it 'does NOT add basemodulepath when env.conf modulepath omits $basemodulepath' do
        Dir.mktmpdir do |repo|
          File.write(File.join(repo, 'environment.conf'), "modulepath = site\n")
          FileUtils.mkdir_p(File.join(repo, 'site/role/manifests'))
          FileUtils.touch(File.join(repo, 'site/role/manifests/base.pp'))
          Dir.mktmpdir do |base|
            FileUtils.mkdir_p(File.join(base, 'stdlib/manifests'))
            FileUtils.touch(File.join(base, 'stdlib/manifests/init.pp'))
            files, findings = described_class.load(repo, basemodulepath: [base])
            rels = files.map { |f| f.sub("#{repo}/", '') }
            expect(rels).to contain_exactly('site/role/manifests/base.pp')
            expect(findings).to be_empty
          end
        end
      end

      it 'falls back to ./modules when env.conf exists but omits the modulepath line' do
        Dir.mktmpdir do |repo|
          File.write(File.join(repo, 'environment.conf'), "environment_timeout = 0\n")
          FileUtils.mkdir_p(File.join(repo, 'modules/stdlib/manifests'))
          FileUtils.touch(File.join(repo, 'modules/stdlib/manifests/init.pp'))
          # site-modules is NOT Puppet's default; it should be ignored here
          # (only the driftless legacy fallback, when env.conf is absent, adds it).
          FileUtils.mkdir_p(File.join(repo, 'site-modules/other/manifests'))
          FileUtils.touch(File.join(repo, 'site-modules/other/manifests/ignored.pp'))

          files, _ = described_class.load(repo, basemodulepath: [])
          rels = files.map { |f| f.sub("#{repo}/", '') }
          expect(rels).to contain_exactly('modules/stdlib/manifests/init.pp')
        end
      end
    end

    context "with the environment's own manifest directory" do
      it 'includes .pp files under manifests/ by default when the directory exists' do
        Dir.mktmpdir do |repo|
          FileUtils.mkdir_p(File.join(repo, 'manifests'))
          File.write(File.join(repo, 'manifests/site.pp'), "# noop\n")
          files, _ = described_class.load(repo, basemodulepath: [])
          rels = files.map { |f| f.sub("#{repo}/", '') }
          expect(rels).to include('manifests/site.pp')
        end
      end

      it 'honors an explicit `manifest = <file>` in env.conf (single-file form)' do
        Dir.mktmpdir do |repo|
          File.write(File.join(repo, 'environment.conf'), "manifest = manifests/only.pp\n")
          FileUtils.mkdir_p(File.join(repo, 'manifests'))
          File.write(File.join(repo, 'manifests/only.pp'), "# only\n")
          File.write(File.join(repo, 'manifests/other.pp'), "# not scanned\n")

          files, _ = described_class.load(repo, basemodulepath: [])
          rels = files.map { |f| f.sub("#{repo}/", '') }
          expect(rels).to contain_exactly('manifests/only.pp')
        end
      end

      it 'traverses nested .pp files when manifest points at a directory' do
        Dir.mktmpdir do |repo|
          File.write(File.join(repo, 'environment.conf'), "manifest = manifests\n")
          FileUtils.mkdir_p(File.join(repo, 'manifests/nodes'))
          File.write(File.join(repo, 'manifests/site.pp'), "# top\n")
          File.write(File.join(repo, 'manifests/nodes/web.pp'), "# nested\n")

          files, _ = described_class.load(repo, basemodulepath: [])
          rels = files.map { |f| f.sub("#{repo}/", '') }
          expect(rels).to contain_exactly('manifests/site.pp', 'manifests/nodes/web.pp')
        end
      end

      it 'silently no-ops when the manifest target does not exist' do
        Dir.mktmpdir do |repo|
          # No manifests/ dir at all.
          files, findings = described_class.load(repo, basemodulepath: [])
          expect(files).to be_empty
          expect(findings).to be_empty
        end
      end
    end
  end
end
