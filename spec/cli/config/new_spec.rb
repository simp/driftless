require 'stringio'
require 'tmpdir'
require 'yaml'

require 'spec_helper'
require 'pupgrade/cli/config/new'
require 'pupgrade/config_validator'

RSpec.describe Pupgrade::CLI::Config::New do
  def generate(argv = [], **options)
    dir     = Dir.mktmpdir
    path    = File.join(dir, 'pupgrade.yaml')
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

  def capture_stdout
    original = $stdout
    $stdout  = StringIO.new
    yield
  ensure
    $stdout = original
  end

  # Every line carries one "# " of commenting; stripping it must yield a
  # usable config, with prose lines surviving as ordinary YAML comments.
  def uncommented(text)
    text.lines.map { |l| l.sub(/\A# ?/, '') }.join
  end

  it 'writes an inert file that is valid, validator-clean YAML once uncommented' do
    path, content, status = generate
    expect(status).to eq(0)
    expect(File.exist?(path)).to be(true)
    expect(content).to include('pupgrade configuration', 'relative to the control repo')
    expect(YAML.safe_load(content)).to be_nil
    cfg = Pupgrade::Config.new(merged: YAML.safe_load(uncommented(content)))
    expect { Pupgrade::ConfigValidator.new(cfg).validate! }.not_to raise_error
  end

  it 'lists every settable key under its subsystem, compile first, logging last' do
    _path, content, = generate
    Pupgrade::ConfigKeys.all.each do |key|
      expect(content).to match(/^#   #{Regexp.escape(key.name)}:/), key.path
    end
    indexes = %w[compile surface modules solve impact output logging].map { |name| content.index(/^# #{name}:/) }
    expect(indexes).to all(be_an(Integer))
    expect(indexes).to eq(indexes.sort)
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

    it 'renders exactly the given keys live, arrays split on commas, with the comment one layer removed' do
      _path, content, status = generate(['compile.factsets=spec/factsets,more', 'compile.on_leak=allow'])
      expect(status).to eq(0)
      expect(YAML.safe_load(content)).to eq('compile' => { 'factsets' => ['spec/factsets', 'more'], 'on_leak' => 'allow' })
      expect(content).to match(/^  # Factset files or directories/)
      expect(content).not_to match(/^#   # Factset files or directories/)
      cfg = Pupgrade::Config.new(merged: YAML.safe_load(uncommented(content)))
      expect { Pupgrade::ConfigValidator.new(cfg).validate! }.not_to raise_error
    end

    it 'rejects an unknown key with a suggestion, a mapping key, and a malformed argument, before writing' do
      status, log = attempt(['compile.factset=x'])
      expect(status).to eq(2)
      expect(log).to include('did you mean "factsets"')
      status, log = attempt(['modules.operatingsystems=RedHat'])
      expect(status).to eq(2)
      expect(log).to include('takes a mapping; set it in the file')
      status, log = attempt(['compile.factsets'])
      expect(status).to eq(2)
      expect(log).to include('expected <subsystem.key>=<value>')
    end
  end

  it 'writes the whole tree with --dir, inert, keeping files already there, and lists cache/ and logs/ in .gitignore once on request' do
    silence_logger
    Dir.mktmpdir do |dir|
      run = ->(argv) do
        out = StringIO.new
        original = $stdout
        $stdout = out
        Dir.chdir(dir) { described_class.new.run(argv) }
      rescue SystemExit => e
        [e.status, out.string]
      ensure
        $stdout = original
      end
      status, out = run.call(['--dir', '--gitignore'])
      expect(status).to eq(0)
      root = File.join(dir, 'pupgrade')
      expect(Dir.glob('**/*', base: root).sort).to eq(%w[branches.yaml cache compiler compiler/before.pp compiler/enc.yaml compiler/mocks.rb compiler/mocks.yaml logs pupgrade.yaml])
      expect(out).to include('wrote pupgrade/pupgrade.yaml', 'wrote pupgrade/compiler/mocks.rb', 'created pupgrade/cache/', '.gitignore: added pupgrade/cache/, pupgrade/logs/')
      expect(File.read(File.join(dir, '.gitignore'))).to eq("pupgrade/cache/\npupgrade/logs/\n")
      # every file is inert as written
      expect(YAML.safe_load(File.read(File.join(root, 'pupgrade.yaml')))).to be_nil
      expect(Pupgrade::Compile::Mocks.load(File.join(root, 'compiler/mocks.yaml'), defaults: false).commands).to eq([])
      expect(Pupgrade::Compile::Enc.load(File.join(root, 'compiler/enc.yaml'), File.join(root, 'compiler/mocks.rb')).empty?).to be(true)
      expect(Pupgrade::Inputs::Branchfile.load(File.join(root, 'branches.yaml'))).to have_attributes(branches: {}, error: nil)
      expect(File.read(File.join(root, 'compiler/before.pp')).lines).to all(start_with('#').or(eq("\n")))
      # a second run keeps what is there and adds nothing to .gitignore; --force overwrites
      File.write(File.join(root, 'compiler/enc.yaml'), "rules: []\n")
      status, out = run.call(['--dir=pupgrade', '--gitignore'])
      expect(status).to eq(0)
      expect(out).to include('kept pupgrade/compiler/enc.yaml (exists; --force overwrites)', '.gitignore already lists pupgrade/cache/, pupgrade/logs/')
      expect(out).not_to include('created')
      expect(File.read(File.join(root, 'compiler/enc.yaml'))).to eq("rules: []\n")
      expect(File.read(File.join(dir, '.gitignore'))).to eq("pupgrade/cache/\npupgrade/logs/\n")
      expect(run.call(['--dir', '--force']).first).to eq(0)
      expect(File.read(File.join(root, 'compiler/enc.yaml'))).to start_with('# What an ENC')
      # another name, key=value arguments, and the flags that do not go together
      status, = run.call(['--dir=other', '--gitignore', 'compile.on_leak=allow'])
      expect(status).to eq(0)
      expect(YAML.safe_load(File.read(File.join(dir, 'other/pupgrade.yaml')))).to eq('compile' => { 'on_leak' => 'allow' })
      expect(File.read(File.join(dir, '.gitignore'))).to end_with("other/cache/\nother/logs/\n")
      expect(run.call(['--dir', '--path', 'x.yaml']).first).to eq(2)
      expect(run.call(['--gitignore']).first).to eq(2)
    end
  end

  it 'refuses to clobber an existing file unless --force, and replaces a malformed one' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'pupgrade.yaml')
      File.write(path, "{\n")
      _path, _content, status = generate([], path: path)
      expect(status).to eq(3)
      expect(File.read(path)).to eq("{\n")
      Dir.chdir(dir) do
        expect { capture_stdout { described_class.new.run(['--path', path, '--force']) } }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      end
      expect(File.read(path)).to include('pupgrade configuration')
    end
  end
end
