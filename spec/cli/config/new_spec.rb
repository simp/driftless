require 'stringio'
require 'tmpdir'
require 'yaml'

require 'spec_helper'
require 'driftless/cli/config/new'
require 'driftless/config_validator'

RSpec.describe Driftless::CLI::Config::New do
  def generate(argv = [], **options)
    dir     = Dir.mktmpdir
    path    = File.join(dir, 'driftless.yaml')
    status  = nil
    cli     = described_class.new
    cli.instance_variable_set(:@options, { path: path }.merge(options))
    begin
      capture_stdout { cli.execute(argv) }
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

  it 'orders the sections puppet, reports, scan, output, logging, detectors' do
    _path, content, = generate
    indexes = %w[puppet reports scan output logging detectors].map { |name| content.index(/^# #{name}:/) }
    expect(indexes).to all(be_an(Integer))
    expect(indexes).to eq(indexes.sort)
  end

  it 'orders the puppet keys as KEY_ORDER lists them' do
    _path, content, = generate
    indexes = described_class::KEY_ORDER['puppet'].map { |key| content.index(/^\#   #{key}:/) }
    expect(indexes).to all(be_an(Integer))
    expect(indexes).to eq(indexes.sort)
  end

  it 'comments a duplicated detector option only at its first appearance' do
    _path, content, = generate
    about = Driftless::Detectors::HierarchyTiersInterpolatingUnreportedFacts
      .config_options[:exclude_tiers][:about]
    expect(content.scan(/^\#     exclude_tiers:/).size).to eq(3)
    expect(content.scan(/^\#     \# #{Regexp.escape(about)}$/).size).to eq(1)
  end

  describe '<subsystem.key>=<value> arguments' do
    # [exit status, log] of a run expected to stop before writing
    def attempt(argv)
      cli = described_class.new
      cli.instance_variable_set(:@options, { path: '--' })
      status = nil
      log = capture_log do
        expect { capture_stdout { cli.execute(argv) } }
          .to raise_error(SystemExit) { |e| status = e.status }
          .and output.to_stderr
      end
      [status, log]
    end

    it 'renders exactly the given keys live' do
      _path, content, status = generate(['puppet.environments=production'])
      expect(status).to eq(0)
      expect(YAML.safe_load(content)).to eq('puppet' => { 'environments' => ['production'] })
    end

    it 'splits an array value on commas' do
      _path, content, = generate(['puppet.environments=production,dr'])
      expect(YAML.safe_load(content)).to eq('puppet' => { 'environments' => %w[production dr] })
    end

    it 'coerces a boolean value' do
      _path, content, = generate(['reports.accept_duplicate_certnames=true'])
      expect(YAML.safe_load(content)).to eq('reports' => { 'accept_duplicate_certnames' => true })
    end

    it 'keeps a set key in its KEY_ORDER slot' do
      _path, content, = generate(['puppet.role_regex=(?:\\A|::)role(?:::|\\z)'])
      indexes = [content.index(/^\#   top_scope_variables:/),
                 content.index(/^  role_regex:/),
                 content.index(/^\#   profile_regex:/)]
      expect(indexes).to all(be_an(Integer))
      expect(indexes).to eq(indexes.sort)
    end

    it "renders a set key's comment active, one layer removed" do
      _path, content, = generate(['puppet.environments=production'])
      expect(content).to match(/^  \# Puppet environment/)
      expect(content).not_to match(/^\#   \# Puppet environment/)
    end

    it 'still passes the validator once fully uncommented' do
      _path, content, = generate(['puppet.environments=production'])
      cfg = Driftless::Config.new(merged: YAML.safe_load(uncommented(content)))
      expect { Driftless::ConfigValidator.new(cfg).validate! }.not_to raise_error
    end

    it 'rejects an unknown key with a suggestion, before writing' do
      status, log = attempt(['puppet.environmnets=x'])
      expect(status).to eq(2)
      expect(log).to include('did you mean "environments"')
    end

    it 'rejects a withheld key' do
      status, log = attempt(['puppet.basemodulepath=/x'])
      expect(status).to eq(2)
      expect(log).to include('cannot be set')
    end

    it 'rejects an argument without =' do
      status, log = attempt(['puppet.environments'])
      expect(status).to eq(2)
      expect(log).to include('expected <subsystem.key>=<value>')
    end

    it 'rejects a non-boolean value for a boolean key' do
      status, log = attempt(['reports.accept_duplicate_certnames=yes'])
      expect(status).to eq(2)
      expect(log).to include('expects true or false')
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

  it 'replaces a malformed driftless.yaml' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'driftless.yaml')
      File.write(path, "{\n")
      Dir.chdir(dir) do
        expect { capture_stdout { described_class.new.run(['--path', path, '--force']) } }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      end
      expect(File.read(path)).to include('driftless configuration')
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
