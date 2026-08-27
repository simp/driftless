require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'

require 'driftless/cli/site'
require 'driftless/scan_data'
require 'driftless/finding'
require 'driftless/reported'

RSpec.describe Driftless::CLI::Site do
  def site_with(options = {})
    s = described_class.new(parent_options: {})
    s.instance_variable_set(:@options, options)
    s
  end

  def scan_data(findings: [])
    Driftless::ScanData.assemble(
      findings:     findings,
      corpus:       build_corpus(repo_dir: '/srv/repo', reported: Driftless::Reported.new(data: {})),
      warnings:     [],
      environments: ['production'],
      overrides:    {},
      now:          Time.utc(2026, 8, 26, 12, 0, 0),
    )
  end

  def error_finding
    Driftless::Finding.new(key: 'data:missing-nodes', path: 'x.yaml', message: 'gone', severity: :error)
  end

  # [exit status, stdout]
  def run(site, argv = [])
    status   = nil
    out      = StringIO.new
    original = $stdout
    $stdout  = out
    begin
      site.execute(argv)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    [status, out.string]
  end

  it 'builds index.html and data.json beside the scan document and prints both paths' do
    Dir.mktmpdir do |dir|
      scan_path = Driftless::ScanData.write(scan_data, File.join(dir, 'public', 'scan.json'))
      status, stdout = run(site_with, [scan_path])
      expect(status).to eq(0)
      expect(stdout.lines.map(&:chomp)).to eq([File.join(dir, 'public', 'index.html'), File.join(dir, 'public', 'data.json')])
      expect(File.read(File.join(dir, 'public', 'index.html'))).to include('<title>driftless — repo</title>')
      data = JSON.parse(File.read(File.join(dir, 'public', 'data.json')))
      expect(data['document']).to eq('site')
      expect(data['sources']['scan']['generated_at']).to eq('2026-08-26T12:00:00Z')
    end
  end

  it 'writes both files into --output-dir when given' do
    Dir.mktmpdir do |dir|
      scan_path = Driftless::ScanData.write(scan_data, File.join(dir, 'scan.json'))
      out       = File.join(dir, 'site')
      status, = run(site_with(output_dir: out), [scan_path])
      expect(status).to eq(0)
      expect(File).to exist(File.join(out, 'index.html'))
      expect(File).to exist(File.join(out, 'data.json'))
    end
  end

  it 'passes --repo-url into the build data' do
    Dir.mktmpdir do |dir|
      scan_path = Driftless::ScanData.write(scan_data, File.join(dir, 'scan.json'))
      run(site_with(repo_url: 'https://h/g/p/-/blob/production'), [scan_path])
      data = JSON.parse(File.read(File.join(dir, 'data.json')))
      expect(data['repo']['web']).to eq('https://h/g/p/-/blob/production/{path}#L{line}')
    end
  end

  it 'reads public/scan.json relative to the working directory by default' do
    Dir.mktmpdir do |dir|
      Driftless::ScanData.write(scan_data, File.join(dir, 'public', 'scan.json'))
      Dir.chdir(dir) { expect(run(site_with).first).to eq(0) }
      expect(File).to exist(File.join(dir, 'public', 'index.html'))
    end
  end

  # The page is the signal; the exit status only says whether it was written.
  it 'exits 0 whatever the findings say' do
    Dir.mktmpdir do |dir|
      scan_path = Driftless::ScanData.write(scan_data(findings: [error_finding]), File.join(dir, 'scan.json'))
      expect(run(site_with, [scan_path]).first).to eq(0)
    end
  end

  describe 'unusable input' do
    it 'exits 3 when the scan document is missing' do
      log = capture_log { expect(run(site_with, ['/nonexistent/scan.json']).first).to eq(3) }
      expect(log).to include('site: /nonexistent/scan.json: No such file or directory')
    end

    it 'exits 3 when handed the wrong document, and writes nothing' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'data.json')
        File.write(path, JSON.generate(scan_data.merge('document' => 'site')))
        log = capture_log { expect(run(site_with, [path]).first).to eq(3) }
        expect(log).to include('is a "site" document, expected "scan"')
        expect(File).not_to exist(File.join(dir, 'index.html'))
      end
    end
  end
end
