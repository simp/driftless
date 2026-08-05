require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'fileutils'

require 'driftless/scan'

RSpec.describe Driftless::Scan do
  # Spot-check: confirm scan.rb actually calls Driftless.logger during a run.
  # A single canary test proves the wire between the log-emitter and the logger
  # is intact end-to-end; per-line coverage is deferred until it earns its keep.
  describe 'log narration' do
    around do |example|
      captured        = StringIO.new
      original_logger = Driftless.logger
      Driftless.logger = Logger.new(captured, level: Logger::INFO)
      Driftless.logger.formatter = proc { |sev, _t, _p, msg| "#{sev.downcase}: #{msg}\n" }
      @captured = captured
      example.run
    ensure
      Driftless.logger = original_logger
    end

    it 'emits INFO milestones during a scan against a minimal control repo' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'hiera.yaml'), <<~YAML)
          ---
          version: 5
          defaults:
            datadir: data
            data_hash: yaml_data
          hierarchy:
            - name: 'Common'
              path: 'common.yaml'
        YAML
        File.write(File.join(dir, 'environment.conf'), "modulepath = site-modules:modules\n")
        FileUtils.mkdir_p(File.join(dir, 'data'))
        FileUtils.mkdir_p(File.join(dir, 'incoming'))

        described_class.new(repo_dir: dir, incoming_dir: File.join(dir, 'incoming')).run

        expect(@captured.string).to match(/info: Scanning control repo: /)
        expect(@captured.string).to match(/info: Loaded \d+ hierarchy tiers/)
        expect(@captured.string).to match(/info: Scan complete: \d+ findings/)
      end
    end
  end
end
