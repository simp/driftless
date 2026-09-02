require 'spec_helper'
require 'driftless/reported_checks'

RSpec.describe Driftless::ReportedChecks do
  let(:bare) { Class.new { include Driftless::ReportedChecks }.new }

  it 'starts with no warnings' do
    expect(bare.warnings).to eq([])
  end

  it 'raises until expected_reports is overridden' do
    expect { bare.send(:expected_reports) }
      .to raise_error(NotImplementedError, /expected_reports/)
  end

  it 'records a warning for replay and logs it' do
    log = capture_log { bare.send(:warn, 'partial session') }
    expect(bare.warnings).to eq(['partial session'])
    expect(log).to include('partial session')
  end
end
