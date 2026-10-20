require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'spec_helper'
require 'driftless/cli/params'

RSpec.describe Driftless::CLI::Params do
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

  # [exit status, stdout]
  def run(command, argv)
    out      = StringIO.new
    original = $stdout
    $stdout  = out
    status   = nil
    begin
      command.new.run(argv)
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

  it 'records to the default file, validates clean against it, then flags a new key' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, out = run(Driftless::CLI::Params::Record, ['--no-config', '-d', dir])
      expect(status).to eq(0)
      path = File.join(dir, 'driftless-params.json')
      expect(out).to eq("#{path}\n")
      expect(JSON.parse(File.read(path))['classes']['apache']['params']).to eq('port' => { 'type' => 'Integer', 'default' => '80' })

      status, out = run(Driftless::CLI::Params::Validate, ['--no-config', '-d', dir, '--hiera'])
      expect([status, out]).to eq([0, "no issues\n"])

      File.write(File.join(dir, 'data/common.yaml'), "apache::port: 81\napache::prot: 1\n")
      status, out = run(Driftless::CLI::Params::Validate, ['--no-config', '-d', dir])
      expect(status).to eq(1)
      expect(cells(out)).to eq([
        %w[issue file line key detail],
        ['missing-param', 'data/common.yaml', '2', 'apache::prot', 'apache has no param prot (has: port)'],
      ])
    end
  end

  it 'reads the schema file from config and --against, and fails on a schema that is not there' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      cfg = File.join(dir, 'driftless.yaml')
      File.write(cfg, "params:\n  schema_file: schemas/current.json\n  exclude_params:\n    - 'apache::pr*'\n")
      status, out = run(Driftless::CLI::Params::Record, ['-c', cfg, '-d', dir])
      expect([status, out]).to eq([0, "#{File.join(dir, 'schemas/current.json')}\n"])

      File.write(File.join(dir, 'data/common.yaml'), "apache::prot: 1\n")
      expect(run(Driftless::CLI::Params::Validate, ['-c', cfg, '-d', dir]).first).to eq(0)
      expect(run(Driftless::CLI::Params::Validate, ['--no-config', '-d', dir, '--against', File.join(dir, 'schemas/current.json')]).first).to eq(1)
      expect(run(Driftless::CLI::Params::Validate, ['--no-config', '-d', dir]).first).to eq(3)
    end
  end
end
