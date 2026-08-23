require 'spec_helper'
require 'tmpdir'
require 'fileutils'

require 'driftless/cli/scan'

RSpec.describe Driftless::CLI::Scan do
  describe '#execute (input validation)' do
    def scan_with(options)
      s = described_class.new(parent_options: {})
      s.instance_variable_set(:@options, { fail_on: 'never' }.merge(options))
      s
    end

    it 'exits 3 with an incoming-dir-specific message when incoming_dir does not exist' do
      Dir.mktmpdir do |repo|
        FileUtils.touch(File.join(repo, 'hiera.yaml'))
        FileUtils.touch(File.join(repo, 'environment.conf'))
        s = scan_with(
          repo_dir:     repo,
          incoming_dir: '/nonexistent/incoming',
          environments: ['production'],
        )
        log = capture_log do
          expect { s.execute([]) }
            .to raise_error(SystemExit) { |e| expect(e.status).to eq(3) }
        end
        expect(log).to match(/incoming-dir not readable/)
      end
    end

    it 'exits 3 for a bad incoming_dir even when repo_dir is fine (separate messages)' do
      Dir.mktmpdir do |repo|
        FileUtils.touch(File.join(repo, 'hiera.yaml'))
        FileUtils.touch(File.join(repo, 'environment.conf'))
        s = scan_with(
          repo_dir:     repo,
          incoming_dir: '/nonexistent/incoming',
          environments: ['production'],
        )
        log = capture_log { expect { s.execute([]) }.to raise_error(SystemExit) }
        expect(log).to match(/incoming-dir not readable/)
        expect(log).to include('/nonexistent/incoming')
      end
    end
  end

end
