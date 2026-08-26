require 'spec_helper'

require 'driftless/cli/import/git'
require 'driftless/cli/import'
require 'driftless/import/git'

# Verifies the CLI leaf's post-import behavior — specifically the §10
# auto-trigger of cleanup and its interaction with --no-summaries.
RSpec.describe Driftless::CLI::Import::Git do
  around do |ex|
    original_config = Driftless.instance_variable_get(:@config)
    ex.run
  ensure
    Driftless.instance_variable_set(:@config, original_config)
  end

  let(:fake_result) do
    Struct.new(:reports_copied, :summaries_copied, :branches_imported, keyword_init: true)
      .new(reports_copied: 5, summaries_copied: 2, branches_imported: 2)
  end
  before do
    fake = Class.new do
      def initialize(**); end
      def run; end
    end
    stub_const('Driftless::Import::Git', fake)
    allow_any_instance_of(fake).to receive(:run).and_return(fake_result)
  end

  def run_with(argv)
    described_class.new.run(argv)
  rescue SystemExit => e
    e.status
  end

  it 'invokes Import.run_cleanup after a successful import' do
    expect(Driftless::CLI::Import).to receive(:run_cleanup).with(
      'import git: cleanup',
      hash_including(
        incoming_dir: '/tmp/incoming',
        summary_dir:  '/tmp/summary',
        dry_run:      false,
        override:     nil,
      ),
    )
    exit_status = run_with(['-i', '/tmp/incoming', 'https://example/repo.git'])
    expect(exit_status).to eq(0)
  end

  it 'skips cleanup when --no-summaries is set' do
    expect(Driftless::CLI::Import).not_to receive(:run_cleanup)
    exit_status = run_with(['-i', '/tmp/incoming', '--no-summaries', 'https://example/repo.git'])
    expect(exit_status).to eq(0)
  end

  it 'passes --accept-partial-report-sessions through as the override' do
    expect(Driftless::CLI::Import).to receive(:run_cleanup).with(
      'import git: cleanup',
      hash_including(override: :bare),
    )
    run_with(['-i', '/tmp/incoming', '--accept-partial-report-sessions', 'https://example/repo.git'])
  end

  it 'propagates --dry-run to cleanup' do
    expect(Driftless::CLI::Import).to receive(:run_cleanup).with(
      'import git: cleanup',
      hash_including(dry_run: true),
    )
    run_with(['-i', '/tmp/incoming', '--dry-run', 'https://example/repo.git'])
  end

  it 'exits 2 with a "cleanup failed" message when cleanup raises Import::Error' do
    allow(Driftless::CLI::Import).to receive(:run_cleanup)
      .and_raise(Driftless::Import::Error, 'archive dir not writable')
    exit_status = nil
    log = capture_log { exit_status = run_with(['-i', '/tmp/incoming', 'https://example/repo.git']) }
    expect(log).to match(/cleanup failed: archive dir not writable/)
    expect(exit_status).to eq(2)
  end

  it 'skips cleanup and exits 2 if the import itself failed' do
    allow_any_instance_of(Driftless::Import::Git).to receive(:run)
      .and_raise(Driftless::Import::Error, 'clone failed')
    expect(Driftless::CLI::Import).not_to receive(:run_cleanup)
    exit_status = run_with(['-i', '/tmp/incoming', 'https://example/repo.git'])
    expect(exit_status).to eq(2)
  end
end
