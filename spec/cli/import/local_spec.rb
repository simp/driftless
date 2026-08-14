require 'spec_helper'

require 'driftless/cli/import/local'
require 'driftless/cli/import'
require 'driftless/import/local'

# Verifies the CLI leaf's post-import behavior — specifically the §10
# auto-trigger of cleanup. Library-level import mechanics are covered in
# spec/import/local_spec.rb.
RSpec.describe Driftless::CLI::Import::Local do
  around do |ex|
    original_config = Driftless.instance_variable_get(:@config)
    ex.run
  ensure
    Driftless.instance_variable_set(:@config, original_config)
  end

  # Stub Import::Local to a benign no-op returning a Result-shaped double.
  let(:fake_result) do
    Struct.new(:copied, :skipped_missing, :session_id, keyword_init: true)
          .new(copied: 3, skipped_missing: 0, session_id: 'sid-1')
  end
  before do
    fake = Class.new do
      def initialize(**); end
      def run(*, **); end
    end
    stub_const('Driftless::Import::Local', fake)
    allow_any_instance_of(fake).to receive(:run).and_return(fake_result)
  end

  def run_with(argv)
    described_class.new.run(argv)
  rescue SystemExit => e
    e.status
  end

  it 'invokes Import.run_cleanup after a successful import' do
    expect(Driftless::CLI::Import).to receive(:run_cleanup).with(
      'import local: cleanup',
      hash_including(
        incoming_dir: '/tmp/incoming',
        summary_dir:  '/tmp/summary',
        dry_run:      false,
        override:     nil,
      ),
    )
    exit_status = run_with(['-i', '/tmp/incoming', '/tmp/source'])
    expect(exit_status).to eq(0)
  end

  it 'passes --accept-partial-report-sessions through as the override' do
    expect(Driftless::CLI::Import).to receive(:run_cleanup).with(
      'import local: cleanup',
      hash_including(override: :bare),
    )
    run_with(['-i', '/tmp/incoming', '--accept-partial-report-sessions', '/tmp/source'])
  end

  it 'passes the list-form override through verbatim' do
    expect(Driftless::CLI::Import).to receive(:run_cleanup).with(
      'import local: cleanup',
      hash_including(override: %w[a b]),
    )
    run_with(['-i', '/tmp/incoming', '--accept-partial-report-sessions=a,b', '/tmp/source'])
  end

  it 'propagates --dry-run to cleanup' do
    expect(Driftless::CLI::Import).to receive(:run_cleanup).with(
      'import local: cleanup',
      hash_including(dry_run: true),
    )
    run_with(['-i', '/tmp/incoming', '--dry-run', '/tmp/source'])
  end

  it 'exits 2 with a "cleanup failed" message when cleanup raises Import::Error' do
    allow(Driftless::CLI::Import).to receive(:run_cleanup)
      .and_raise(Driftless::Import::Error, 'permission denied on .archive')
    exit_status = nil
    expect { exit_status = run_with(['-i', '/tmp/incoming', '/tmp/source']) }
      .to output(/cleanup failed: permission denied/).to_stderr
    expect(exit_status).to eq(2)
  end

  it 'skips cleanup and exits 2 if the import itself failed' do
    allow_any_instance_of(Driftless::Import::Local).to receive(:run)
      .and_raise(Driftless::Import::Error, 'source not found')
    expect(Driftless::CLI::Import).not_to receive(:run_cleanup)
    exit_status = run_with(['-i', '/tmp/incoming', '/tmp/source'])
    expect(exit_status).to eq(2)
  end
end
