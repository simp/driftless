require 'stringio'

require 'spec_helper'
require 'driftless/cli/list/detectors'

RSpec.describe Driftless::CLI::List::Detectors do
  def strip_ansi(str)
    str.gsub(/\e\[[0-9;]*m/, '')
  end

  def raw_output
    out      = StringIO.new
    original = $stdout
    $stdout  = out
    begin
      described_class.new.execute([])
    rescue SystemExit
      nil
    ensure
      $stdout = original
    end
    out.string
  end

  def listed_keys
    raw_output.lines.map { |l| strip_ansi(l).split(/\s{2,}/).first }
  end

  it 'lists every registered detector' do
    expect(listed_keys).to match_array(Driftless::Detectors.registry.map(&:key))
  end

  it 'orders keys alphabetically, matching scan output' do
    expect(listed_keys).to eq(Driftless::Detectors.registry.map(&:key).sort)
  end

  it 'emits no escapes when the destination is not a terminal' do
    expect(raw_output).not_to include("\e[")
  end

  it 'colorizes when --color forces it on' do
    Driftless::Ansi.preference = true
    expect(raw_output).to include("\e[")
  end
end
