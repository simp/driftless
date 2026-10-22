require 'stringio'
require 'tmpdir'
require 'fileutils'

require 'spec_helper'
require 'driftless/cli/params'
require 'driftless/codebase'
require 'driftless/params_schema'

RSpec.describe Driftless::CLI::Params::Compare do
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
    FileUtils.mkdir_p(File.join(dir, 'data'))
    File.write(File.join(dir, 'modules/apache/manifests/init.pp'), "class apache (Integer $port = 80) { }\n")
    File.write(File.join(dir, 'data/common.yaml'), "apache::port: 81\n")
  end

  # A schema of the repo as it stands, written by driftless's recorder.
  def record(dir, name)
    corpus = Driftless::Codebase.load(dir).corpus(repo_dir: dir)
    Driftless::ParamsSchema.write(Driftless::ParamsSchema.assemble(corpus: corpus), File.join(dir, name))
  end

  # [exit status, stdout]
  def run(argv)
    out      = StringIO.new
    original = $stdout
    $stdout  = out
    status   = nil
    begin
      described_class.new.run(argv)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    [status, out.string]
  end

  def cells(output)
    output.lines.map(&:rstrip).reject { |l| l.start_with?('--') }.map { |l| l.split('|', -1).map(&:strip) }
  end

  around(:each) do |ex|
    original = Driftless.instance_variable_get(:@config)
    ex.run
  ensure
    Driftless.instance_variable_set(:@config, original)
  end

  before(:each) { silence_driftless_logger }

  it 'compares two recordings' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      before = record(dir, 'before.json')
      File.write(File.join(dir, 'modules/apache/manifests/init.pp'), "class apache (Stdlib::Port $port = 80, Boolean $ssl = false) { }\n")
      after = record(dir, 'after.json')

      status, out = run(['--no-config', before, after])
      expect(status).to eq(1)
      expect(cells(out)).to eq([
        %w[change class param detail],
        ['type-changed', 'apache', 'port', 'Integer -> Stdlib::Port'],
        ['param-added', 'apache', 'ssl', 'Boolean = false'],
      ])
      expect(run(['--no-config', before, before])).to eq([0, "no differences\n"])
      expect(run(['--no-config', before]).first).to eq(2)
      File.write(File.join(dir, 'scan.json'), '{"document":"scan","schema_version":1}')
      expect(run(['--no-config', before, File.join(dir, 'scan.json')]).first).to eq(3)
    end
  end
end
