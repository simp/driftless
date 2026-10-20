require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'driftless/codebase'
require 'driftless/params_schema'
require 'driftless/params_schema/validate'

RSpec.describe Driftless::ParamsSchema do
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
    File.write(File.join(dir, 'environment.conf'), "modulepath = site-modules:modules\n")
    FileUtils.mkdir_p(File.join(dir, 'modules/apache/manifests'))
    FileUtils.mkdir_p(File.join(dir, 'site-modules/profile/manifests'))
    FileUtils.mkdir_p(File.join(dir, 'data'))
    File.write(File.join(dir, 'modules/apache/manifests/init.pp'), <<~PP)
      class apache (
        Integer $port = 80,
        Optional[Stdlib::Absolutepath] $docroot = undef,
        $untyped,
        Hash[String, Any] $opts = { 'a' => 1 },
      ) { }
    PP
    File.write(File.join(dir, 'modules/apache/manifests/vhost.pp'), "define apache::vhost (String $root) { }\n")
    FileUtils.mkdir_p(File.join(dir, 'modules/timezone/manifests'))
    File.write(File.join(dir, 'modules/timezone/manifests/init.pp'), "class timezone { $c = lookup('timezone::hwclock_cmd') }\n")
    File.write(File.join(dir, 'site-modules/profile/manifests/web.pp'), <<~PP)
      class profile::web (String $vhost) {
        $x = lookup('profile::web::packages')
        $y = lookup('apache::nope')
        $z = lookup('apache::port')
        $w = lookup('lookup::only')
        $v = lookup('apache::looked')
      }
    PP
    File.write(File.join(dir, 'data/common.yaml'), <<~YAML)
      apache::port: 81
      apache::docroot: /srv
      apache::typo: 1
      gone::thing: 1
      profile::web::packages: []
      lookup::only: "%{lookup('also::looked::up')}"
      also::looked::up: 2
      plain: 3
      apache::looked: 1
    YAML
  end

  def corpus_for(dir)
    Driftless::Codebase.load(dir).corpus(repo_dir: dir)
  end

  before(:each) { silence_driftless_logger }

  describe '.assemble' do
    it 'records every class with its params, types and defaults as written, by repo-relative file' do
      Dir.mktmpdir do |dir|
        control_repo(dir)
        doc = described_class.assemble(corpus: corpus_for(dir), now: Time.utc(2026, 10, 14))
        expect(doc).to include('document' => 'params', 'schema_version' => 1, 'generated_at' => '2026-10-14T00:00:00Z')
        expect(doc['repo']).to include('dir' => dir, 'deployments' => {})
        expect(doc['classes'].keys).to eq(%w[apache apache::vhost profile::web timezone])
        expect(doc['classes']['apache']).to eq(
          'file'   => 'modules/apache/manifests/init.pp',
          'params' => {
            'port'    => { 'type' => 'Integer', 'default' => '80' },
            'docroot' => { 'type' => 'Optional[Stdlib::Absolutepath]', 'default' => 'undef' },
            'untyped' => { 'type' => nil, 'default' => nil },
            'opts'    => { 'type' => 'Hash[String, Any]', 'default' => "{ 'a' => 1 }" },
          },
        )
        expect(doc['classes']['apache::vhost']['params']).to eq('root' => { 'type' => 'String', 'default' => nil })
      end
    end

    it 'round-trips through write and read, and read refuses another document kind' do
      Dir.mktmpdir do |dir|
        control_repo(dir)
        path = described_class.write(described_class.assemble(corpus: corpus_for(dir)), File.join(dir, 'out/params.json'))
        expect(described_class.read(path)['classes'].keys).to eq(%w[apache apache::vhost profile::web timezone])
        other = File.join(dir, 'scan.json')
        File.write(other, JSON.generate('document' => 'scan', 'schema_version' => 1))
        expect { described_class.read(other) }.to raise_error(Driftless::JsonDocument::Error, /expected "params"/)
      end
    end
  end

  describe Driftless::ParamsSchema::Validate do
    def schema(dir)
      Driftless::ParamsSchema.assemble(corpus: corpus_for(dir))
    end

    it 'spares a module looking up its own namespace, as the lookup detector does' do
      Dir.mktmpdir do |dir|
        control_repo(dir)
        issues = described_class.new(schema(dir)).call(corpus_for(dir))
        expect(issues.map(&:key)).not_to include('timezone::hwclock_cmd')
      end
    end

    it 'flags Hiera keys and lookups the schema does not record, sparing looked-up keys as the detectors do' do
      Dir.mktmpdir do |dir|
        control_repo(dir)
        issues = described_class.new(schema(dir)).call(corpus_for(dir))
        expect(issues.map { |i| [i.kind, i.path, i.line, i.key] }).to eq([
          ['missing-param', 'data/common.yaml', 3, 'apache::typo'],
          ['missing-class', 'data/common.yaml', 4, 'gone::thing'],
          ['missing-param', 'data/common.yaml', 9, 'apache::looked'],
          ['missing-param', 'site-modules/profile/manifests/web.pp', 3, 'apache::nope'],
          ['missing-param', 'site-modules/profile/manifests/web.pp', 6, 'apache::looked'],
        ])
        expect(issues.first.detail).to eq('apache has no param typo (has: port, docroot, untyped, opts)')
        expect(issues[1].detail).to eq('class gone is not in the schema')
      end
    end

    it 'flags a param the schema no longer has, and leaves out excluded paths, classes, modules, and params' do
      Dir.mktmpdir do |dir|
        control_repo(dir)
        recorded = schema(dir)
        recorded['classes']['apache']['params'].delete('docroot')
        all = described_class.new(recorded).call(corpus_for(dir))
        expect(all.map(&:key)).to eq(%w[apache::docroot apache::typo gone::thing apache::looked apache::nope apache::looked])

        expect(described_class.new(recorded, exclude_paths: ['data/*']).call(corpus_for(dir)).map(&:key)).to eq(%w[apache::nope apache::looked])
        expect(described_class.new(recorded, exclude_classes: ['apa*']).call(corpus_for(dir)).map(&:key)).to eq(['gone::thing'])
        expect(described_class.new(recorded, exclude_modules: ['gone']).call(corpus_for(dir)).map(&:key))
          .to eq(%w[apache::docroot apache::typo apache::looked apache::nope apache::looked])
        expect(described_class.new(recorded, exclude_params: ['apache::typo', 'apache::no*']).call(corpus_for(dir)).map(&:key))
          .to eq(%w[apache::docroot gone::thing apache::looked apache::looked])
      end
    end
  end
end
