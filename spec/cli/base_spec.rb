require 'spec_helper'
require 'tmpdir'

require 'driftless/cli/base'

RSpec.describe Driftless::CLI::Base do
  # Save/restore process-global logger level around every example.
  around(:each) do |example|
    original_level = Driftless.logger.level
    example.run
  ensure
    Driftless.logger.level = original_level
  end


  # Fresh anonymous parent per test — keeps @subcommands state isolated.
  let(:parent_class) do
    Class.new(described_class) do
      register_command name: 'parent'
      desc 'parent command'
    end
  end

  describe '.name' do
    it 'returns empty when register_command has not been called' do
      expect(Class.new(described_class).name).to eq([])
    end

    it 'stores a single name as a one-element array' do
      klass = Class.new(described_class) { register_command name: 'foo' }
      expect(klass.name).to eq(%w[foo])
    end

    it 'accepts an array of names for aliases' do
      klass = Class.new(described_class) { register_command name: %w[foo f] }
      expect(klass.name).to eq(%w[foo f])
    end

    it 'canonical_name is the first entry' do
      klass = Class.new(described_class) { register_command name: %w[foo f] }
      expect(klass.canonical_name).to eq('foo')
    end
  end

  describe '.register_command' do
    it 'registers the child under every alias' do
      parent = parent_class
      child = Class.new(described_class) do
        register_command name: %w[child c], subcommand_of: parent
      end
      expect(parent.find_subcommand('child')).to eq(child)
      expect(parent.find_subcommand('c')).to eq(child)
    end

    it 'sets parent_command on the child' do
      parent = parent_class
      child = Class.new(described_class) do
        register_command name: 'child', subcommand_of: parent
      end
      expect(child.parent_command).to eq(parent)
    end

    it 'includes the child in the parent subcommands list' do
      parent = parent_class
      child = Class.new(described_class) do
        register_command name: 'child', subcommand_of: parent
      end
      expect(parent.subcommands).to eq([child])
    end

    it 'is a no-op registration when subcommand_of is omitted' do
      klass = Class.new(described_class) { register_command name: 'orphan' }
      expect(klass.name).to eq(%w[orphan])
      expect(klass.parent_command).to be_nil
    end

    it 'raises on name collision with a different class' do
      parent = parent_class
      Class.new(described_class) do
        register_command name: 'clash', subcommand_of: parent
      end
      expect {
        Class.new(described_class) do
          register_command name: 'clash', subcommand_of: parent
        end
      }.to raise_error(/collision/)
    end
  end

  describe '.find_subcommand' do
    it 'returns nil when no matches and no children' do
      expect(parent_class.find_subcommand('nope')).to be_nil
    end

    context 'with two children having distinct prefixes' do
      let!(:foo) do
        p = parent_class
        Class.new(described_class) { register_command name: 'foo', subcommand_of: p }
      end

      let!(:bar) do
        p = parent_class
        Class.new(described_class) { register_command name: 'bar', subcommand_of: p }
      end

      it 'returns the exact match' do
        expect(parent_class.find_subcommand('foo')).to eq(foo)
      end

      it 'returns via unambiguous prefix' do
        expect(parent_class.find_subcommand('f')).to eq(foo)
        expect(parent_class.find_subcommand('b')).to eq(bar)
      end

      it 'returns nil for a prefix that matches nothing' do
        expect(parent_class.find_subcommand('z')).to be_nil
      end
    end

    context 'with two children sharing a prefix' do
      let!(:list_cmd) do
        p = parent_class
        Class.new(described_class) { register_command name: 'list', subcommand_of: p }
      end

      let!(:logs_cmd) do
        p = parent_class
        Class.new(described_class) { register_command name: 'logs', subcommand_of: p }
      end

      it 'raises AmbiguousSubcommand for the ambiguous prefix' do
        expect { parent_class.find_subcommand('l') }
          .to raise_error(Driftless::CLI::Base::AmbiguousSubcommand) do |e|
            expect(e.input).to eq('l')
            expect(e.candidates).to eq(%w[list logs])
          end
      end

      it 'exact match wins over ambiguous prefix' do
        expect(parent_class.find_subcommand('list')).to eq(list_cmd)
        expect(parent_class.find_subcommand('logs')).to eq(logs_cmd)
      end

      it 'longer prefix disambiguates' do
        expect(parent_class.find_subcommand('li')).to eq(list_cmd)
        expect(parent_class.find_subcommand('lo')).to eq(logs_cmd)
      end
    end
  end

  describe '.command_path' do
    it 'returns [canonical_name] for a rootless command' do
      expect(parent_class.command_path).to eq(['parent'])
    end

    it 'walks the parent chain' do
      p = parent_class
      child = Class.new(described_class) do
        register_command name: 'child', subcommand_of: p
      end
      grand = Class.new(described_class) do
        register_command name: 'grand', subcommand_of: child
      end
      expect(child.command_path).to eq(%w[parent child])
      expect(grand.command_path).to eq(%w[parent child grand])
    end
  end

  describe '#run — leaf' do
    let(:leaf_class) do
      Class.new(described_class) do
        register_command name: 'leaf'
        desc 'leaf command'
        class << self
          attr_accessor :last_execute_argv
        end
        define_method(:execute) do |argv|
          self.class.last_execute_argv = argv
        end
      end
    end

    it 'calls execute with empty argv' do
      leaf_class.new.run([])
      expect(leaf_class.last_execute_argv).to eq([])
    end

    it 'passes unparsed positionals to execute' do
      leaf_class.new.run(%w[pos1 pos2])
      expect(leaf_class.last_execute_argv).to eq(%w[pos1 pos2])
    end

    it 'raises NotImplementedError when execute is not overridden' do
      bare = Class.new(described_class) do
        register_command name: 'bare'
        desc 'bare'
      end
      expect { bare.new.run([]) }
        .to raise_error(NotImplementedError, /must implement/)
    end
  end

  describe '#run — branch' do
    let(:branch) { parent_class }
    let!(:child) do
      b = branch
      Class.new(described_class) do
        register_command name: 'child', subcommand_of: b
        desc 'child leaf'
        class << self
          attr_accessor :was_called
        end
        define_method(:execute) do |_argv|
          self.class.was_called = true
        end
      end
    end

    it 'dispatches to the child by exact name' do
      branch.new.run(['child'])
      expect(child.was_called).to be(true)
    end

    it 'dispatches to the child via unambiguous prefix' do
      branch.new.run(['c'])
      expect(child.was_called).to be(true)
    end

    it 'exits 2 with usage on stderr when no argv' do
      expect { branch.new.run([]) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(2) }
        .and output(/Usage:/).to_stderr
    end

    it 'exits 2 on an unknown subcommand' do
      expect { branch.new.run(['nope']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(2) }
        .and output(/unknown subcommand/).to_stderr
    end
  end

  describe '#run — -c/--config at any position' do
    around(:each) do |ex|
      original = Driftless.instance_variable_get(:@config)
      ex.run
    ensure
      Driftless.instance_variable_set(:@config, original)
    end

    let(:branch) { parent_class }
    let!(:child) do
      b = branch
      Class.new(described_class) do
        register_command name: 'child', subcommand_of: b
        desc 'child leaf'
        define_method(:execute) { |_argv| }
      end
    end

    def with_config(body)
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'driftless.yaml')
        File.write(path, body)
        yield path
      end
    end

    it 'loads the file when -c follows the subcommand' do
      with_config("logging:\n  level: info\n") do |path|
        branch.new.run(['child', '-c', path])
        expect(Driftless.config.sources).to eq([path])
      end
    end

    it 'loads the file when --config follows the subcommand' do
      with_config("logging:\n  level: info\n") do |path|
        branch.new.run(['child', "--config=#{path}"])
        expect(Driftless.config.sources).to eq([path])
      end
    end

    it 'lets a subcommand -c override the one the parent already loaded' do
      with_config("logging:\n  level: error\n") do |parent_path|
        with_config("logging:\n  level: debug\n") do |child_path|
          branch.new.run(['-c', parent_path, 'child', '-c', child_path])
          expect(Driftless.config.sources).to eq([child_path])
          expect(Driftless.logger.level).to eq(Logger::DEBUG)
        end
      end
    end

    it 'reports a bad path from the subcommand position the same way as from the root' do
      expect {
        expect { branch.new.run(['child', '-c', '/no/such/driftless.yaml']) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(2) }
      }.to output(/config error:.*file not found/).to_stderr
    end

    it 'does not let -c fall through to --color' do
      seen = nil
      child.define_method(:execute) { |_argv| seen = @options[:color] }
      expect { branch.new.run(['child', '-c', '/some/driftless.yaml']) }
        .to raise_error(SystemExit).and output.to_stderr
      expect(seen).to be_nil
    end

    it 'leaves --no-color working' do
      seen = nil
      child.define_method(:execute) { |_argv| seen = @options[:color] }
      branch.new.run(['child', '--no-color'])
      expect(seen).to be(false)
    end
  end

  describe '#run — --help' do
    it 'prints help to stdout and exits 0' do
      leaf = Class.new(described_class) do
        register_command name: 'leaf'
        desc 'a leaf'
      end
      expect { leaf.new.run(['--help']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/Usage:/).to_stdout
    end
  end

  describe '#run — parent_options threading' do
    let(:branch) { parent_class }
    let!(:child) do
      b = branch
      Class.new(described_class) do
        register_command name: 'child', subcommand_of: b
        desc 'child leaf'
        class << self
          attr_accessor :seen_options
        end
        define_method(:execute) do |_argv|
          self.class.seen_options = @options.dup
        end
      end
    end

    it 'child inherits parent @options at construction' do
      p = branch.new(parent_options: { foo: :bar })
      p.run(['child'])
      expect(child.seen_options[:foo]).to eq(:bar)
    end

    it 'child inherits parent @options set via CLI flags (verbose flows down)' do
      branch.new.run(['--verbose', 'child'])
      expect(child.seen_options[:verbose]).to be(true)
    end

    it 'child mutations do not leak back to parent (snapshot semantics)' do
      parent = branch.new(parent_options: { shared: [1, 2] })
      b = branch
      Class.new(described_class) do
        register_command name: 'mut', subcommand_of: b
        define_method(:execute) do |_argv|
          @options[:new_key] = :leaked?
        end
      end
      parent.run(['mut'])
      expect(parent.instance_variable_get(:@options)).not_to have_key(:new_key)
      expect(parent.instance_variable_get(:@options)[:shared]).to eq([1, 2])
    end
  end

  describe '#apply_log_level (derivation from @options)' do
    let(:leaf) do
      Class.new(described_class) do
        register_command name: 'leaf'
        desc 'a leaf'
        define_method(:execute) { |_argv| }
      end
    end

    it 'defaults to WARN when neither flag is set' do
      leaf.new.run([])
      expect(Driftless.logger.level).to eq(Logger::WARN)
    end

    it 'sets INFO when --verbose is parsed' do
      leaf.new.run(['--verbose'])
      expect(Driftless.logger.level).to eq(Logger::INFO)
    end

    it 'sets ERROR when --quiet is parsed' do
      leaf.new.run(['--quiet'])
      expect(Driftless.logger.level).to eq(Logger::ERROR)
    end

    it 'quiet wins over verbose when both are set' do
      leaf.new.run(['--verbose', '--quiet'])
      expect(Driftless.logger.level).to eq(Logger::ERROR)
    end

    it 'sets DEBUG when --verbose is repeated (-vv)' do
      leaf.new.run(['-vv'])
      expect(Driftless.logger.level).to eq(Logger::DEBUG)
    end

    it 'sets DEBUG for two separate -v flags (equivalent to -vv)' do
      leaf.new.run(['-v', '-v'])
      expect(Driftless.logger.level).to eq(Logger::DEBUG)
    end

    it 'sets DEBUG for two --verbose flags' do
      leaf.new.run(['--verbose', '--verbose'])
      expect(Driftless.logger.level).to eq(Logger::DEBUG)
    end

    it 'quiet still wins over debug' do
      leaf.new.run(['-vv', '-q'])
      expect(Driftless.logger.level).to eq(Logger::ERROR)
    end

    it 'applies inherited parent_options[:verbose] too' do
      leaf.new(parent_options: { verbose: true }).run([])
      expect(Driftless.logger.level).to eq(Logger::INFO)
    end

    it 'respects @options[:log_level] (from config) when no CLI verbosity flag is set' do
      leaf.new(parent_options: { log_level: 'info' }).run([])
      expect(Driftless.logger.level).to eq(Logger::INFO)
    end

    it 'CLI --verbose overrides config-derived log_level' do
      leaf.new(parent_options: { log_level: 'error' }).run(['-v'])
      expect(Driftless.logger.level).to eq(Logger::INFO)
    end

    it 'unknown log_level names fall through to default WARN' do
      leaf.new(parent_options: { log_level: 'BOGUS' }).run([])
      expect(Driftless.logger.level).to eq(Logger::WARN)
    end
  end

  describe 'universal -v/-q availability' do
    it '-v is accepted on a command that did not declare it' do
      leaf = Class.new(described_class) do
        register_command name: 'leaf'
        define_method(:execute) { |_argv| }
      end
      expect { leaf.new.run(['-v']) }.not_to raise_error
    end

    it '-q is accepted on a command that did not declare it' do
      leaf = Class.new(described_class) do
        register_command name: 'leaf'
        define_method(:execute) { |_argv| }
      end
      expect { leaf.new.run(['-q']) }.not_to raise_error
    end
  end
end
