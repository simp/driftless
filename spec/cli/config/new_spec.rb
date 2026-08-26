require 'stringio'
require 'tmpdir'
require 'yaml'

require 'spec_helper'
require 'driftless/cli/config/new'
require 'driftless/config_validator'

RSpec.describe Driftless::CLI::Config::New do
  def generate(**options)
    dir     = Dir.mktmpdir
    path    = File.join(dir, 'driftless.yaml')
    status  = nil
    cli     = described_class.new
    cli.instance_variable_set(:@options, { path: path }.merge(options))
    begin
      capture_stdout { cli.execute([]) }
    rescue SystemExit => e
      status = e.status
    end
    [path, (File.exist?(path) ? File.read(path) : nil), status]
  end

  # Every line carries one "# " of commenting; stripping it must yield a usable
  # config, with prose lines surviving as ordinary YAML comments.
  def capture_stdout
    original = $stdout
    $stdout  = StringIO.new
    yield
  ensure
    $stdout = original
  end

  def uncommented(text)
    text.lines.map { |l| l.sub(/\A# ?/, '') }.join
  end

  it 'writes the file and exits 0' do
    path, content, status = generate
    expect(status).to eq(0)
    expect(File.exist?(path)).to be(true)
    expect(content).to include('driftless configuration')
  end

  it 'is inert as written — every key commented out' do
    _path, content, = generate
    expect(YAML.safe_load(content)).to be_nil
  end

  it 'is valid YAML once uncommented' do
    _path, content, = generate
    expect { YAML.safe_load(uncommented(content)) }.not_to raise_error
  end

  it 'passes the config validator once uncommented' do
    _path, content, = generate
    cfg = Driftless::Config.new(merged: YAML.safe_load(uncommented(content)))
    expect { Driftless::ConfigValidator.new(cfg).validate! }.not_to raise_error
  end

  it 'lists every registered detector' do
    _path, content, = generate
    Driftless::Detectors.registry.each do |klass|
      expect(content).to include("#   #{klass.key}:")
    end
  end

  it 'lists every option each detector declares' do
    _path, content, = generate
    Driftless::Detectors.registry.each do |klass|
      klass.config_options.each_key do |opt|
        expect(content).to match(/^#     #{Regexp.escape(opt.to_s)}:/)
      end
    end
  end

  it 'refuses to clobber an existing file' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'driftless.yaml')
      File.write(path, "puppet:\n  environments: [production]\n")
      cli = described_class.new
      cli.instance_variable_set(:@options, { path: path })
      log = capture_log do
        expect { capture_stdout { cli.execute([]) } }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(3) }
      end
      expect(log).to include('already exists')
      expect(File.read(path)).to include('production')
    end
  end

  it 'overwrites when --force is given' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'driftless.yaml')
      File.write(path, "stale\n")
      cli = described_class.new
      cli.instance_variable_set(:@options, { path: path, force: true })
      expect { capture_stdout { cli.execute([]) } }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      expect(File.read(path)).to include('driftless configuration')
    end
  end
end
