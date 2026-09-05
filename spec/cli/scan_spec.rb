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
        expect(log).to include('incoming-dir not readable')
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
        expect(log).to include('incoming-dir not readable')
        expect(log).to include('/nonexistent/incoming')
      end
    end
  end

  describe 'positional arguments' do
    # The optional argument of --data-file reads only when attached with `=`;
    # `--data-file out.json` must not pass as the default path plus a stray.
    it 'exits 2 with help on an unexpected argument' do
      s = described_class.new(parent_options: {})
      s.instance_variable_set(:@options, { fail_on: 'never' })
      log = capture_log do
        expect { s.execute(['out.json']) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(2) }
          .and output(/Usage:/).to_stderr
      end
      expect(log).to include('scan: unexpected argument "out.json"')
    end
  end

  describe '--data-file' do
    def control_repo(dir)
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
    end

    it 'writes the scan data document after the findings' do
      Dir.mktmpdir do |repo|
        control_repo(repo)
        data_path = File.join(repo, 'out', 'scan.json')
        s = described_class.new(parent_options: {})
        s.instance_variable_set(:@options, {
          fail_on: 'none', repo_dir: repo, incoming_dir: File.join(repo, 'incoming'),
          environments: ['production'], proceed_with_subset_of_configured_envs: true,
          format: 'json', output_file: File.join(repo, 'findings.json'),
          data_file: data_path
        })
        capture_log { expect { s.execute([]) }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) } }

        data = JSON.parse(File.read(data_path))
        expect(data).to include('document' => 'scan', 'schema_version' => 1)
        expect(data['overrides']).to eq('accept_partial_report_sessions' => nil, 'accept_duplicate_certnames' => false,
                                        'proceed_with_subset_of_configured_envs' => true)
        expect(data['repo']['dir']).to eq(repo)
        expect(data['environments']).to eq(['production'])
        expect(data['findings']).to eq(JSON.parse(File.read(File.join(repo, 'findings.json'))))
      end
    end
  end
end
