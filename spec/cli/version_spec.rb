require 'tmpdir'

require 'spec_helper'
require 'driftless/cli/version'

RSpec.describe Driftless::CLI::Version do
  # run (not execute) so after_own_parse — the path skip_config_load gates — runs.
  it 'prints the version from a cwd with a malformed driftless.yaml' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'driftless.yaml'), "{\n")
      Dir.chdir(dir) do
        expect { described_class.new.run([]) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
          .and output("#{Driftless::VERSION}\n").to_stdout
      end
    end
  end
end
