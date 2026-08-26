require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'driftless/cli/import/cleanup'
require 'driftless/import/cleanup'

RSpec.describe Driftless::CLI::Import::Cleanup do
  around(:each) do |example|
    original_level = Driftless.logger.level
    example.run
  ensure
    Driftless.logger.level = original_level
  end

  # Captures the args Import::Cleanup gets constructed with, without
  # actually gardening a real tree.
  let(:construction) { {} }

  before(:each) do
    fake = Class.new do
      def initialize(**kwargs)
        $construction_capture.replace(kwargs)
      end

      def run
        Struct.new(:live, :archived, :quarantined, :dry_run, keyword_init: true)
          .new(live: [], archived: [], quarantined: [], dry_run: false)
      end
    end
    $construction_capture = construction
    stub_const('Driftless::Import::Cleanup', fake)
  end

  def run_with(argv)
    argv = ['-i', '/tmp/incoming-fake'] + argv
    begin
      described_class.new.run(argv)
    rescue SystemExit
    end
  end

  it 'passes expected_reports: nil and accept_missing_summary: false when the flag is absent' do
    run_with([])
    expect(construction[:expected_reports]).to be_nil
    expect(construction[:accept_missing_summary]).to be false
  end

  it 'translates bare --accept-partial-report-sessions to expected_reports=[] + accept_missing_summary=true' do
    run_with(['--accept-partial-report-sessions'])
    expect(construction[:expected_reports]).to eq([])
    expect(construction[:accept_missing_summary]).to be true
  end

  it 'translates --accept-partial-report-sessions=A,B to expected_reports=[A,B] + accept_missing_summary=false' do
    run_with(['--accept-partial-report-sessions=all-active-nodes,factsets-for-all-active-nodes'])
    expect(construction[:expected_reports]).to eq(%w[all-active-nodes factsets-for-all-active-nodes])
    expect(construction[:accept_missing_summary]).to be false
  end
end
