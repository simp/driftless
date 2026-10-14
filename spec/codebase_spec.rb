require 'spec_helper'
require 'tmpdir'
require 'fileutils'

require 'driftless/codebase'

RSpec.describe Driftless::Codebase do
  # One class with a lookup(), one EPP template with a lookup(), one data
  # file with a class param key and an interpolated lookup, a Forge Puppetfile.
  def control_repo(dir)
    File.write(File.join(dir, 'hiera.yaml'), <<~YAML)
      ---
      version: 5
      defaults:
        datadir: data
        data_hash: yaml_data
      hierarchy:
        - name: common
          path: common.yaml
    YAML
    File.write(File.join(dir, 'environment.conf'), "modulepath = modules\n")
    FileUtils.mkdir_p(File.join(dir, 'modules/apache/manifests'))
    FileUtils.mkdir_p(File.join(dir, 'modules/apache/templates'))
    FileUtils.mkdir_p(File.join(dir, 'data'))
    File.write(File.join(dir, 'modules/apache/manifests/init.pp'), <<~PP)
      class apache (
        Integer $port = 80,
        Optional[String] $docroot = undef,
      ) {
        $extra = lookup('apache::extra')
      }
    PP
    File.write(File.join(dir, 'modules/apache/templates/x.epp'), "<%= lookup('tmpl::key') %>\n")
    File.write(File.join(dir, 'data/common.yaml'), "apache::port: 81\nother: \"%{lookup('data::key')}\"\n")
    File.write(File.join(dir, 'Puppetfile'), "mod 'puppetlabs-stdlib', '9.0.0'\n")
  end

  before(:each) { silence_driftless_logger }

  it 'loads the hierarchy, classes, lookups, data files, and Puppetfile without reports' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      result = described_class.load(dir)
      expect(result.hiera_tiers.map(&:name)).to eq(['common'])
      expect(result.puppet_classes.keys).to eq(['apache'])
      expect(result.puppet_classes['apache'].params.map(&:name)).to eq(%w[port docroot])
      expect(result.code_lookup_calls.map(&:key)).to contain_exactly('apache::extra', 'tmpl::key')
      expect(result.data_lookup_calls.map(&:key)).to eq(['data::key'])
      expect(result.data_files.map { |df| df.top_level_keys.keys }).to eq([%w[apache::port other]])
      expect(result.puppetfile.modules.map(&:name)).to eq(['puppetlabs-stdlib'])
      expect(result.findings).to eq([])
      expect(result.warnings).to eq([])

      corpus = result.corpus(repo_dir: dir)
      expect(corpus.repo_dir).to eq(dir)
      expect(corpus.puppet_classes).to equal(result.puppet_classes)
      expect(corpus.reported.missing?('all-active-nodes')).to be true
    end
  end

  it 'reports a missing hiera.yaml and a Puppetfile that does not evaluate' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      File.delete(File.join(dir, 'hiera.yaml'))
      File.write(File.join(dir, 'Puppetfile'), "raise 'boom'\n")
      result = described_class.load(dir)
      expect(result.findings.map(&:key)).to include('hierarchy:hiera-yaml-missing')
      expect(result.warnings).to eq(['Puppetfile not evaluated: RuntimeError: boom'])
      expect(result.puppet_classes.keys).to eq(['apache'])
    end
  end
end
