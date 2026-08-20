require 'stringio'

require 'spec_helper'
require 'driftless/cli/list/detectors'

RSpec.describe Driftless::CLI::List::Detectors do
  def listed_keys
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
    out.string.lines.map { |l| l.split(/\s{2,}/).first }
  end

  it 'lists every registered detector' do
    expect(listed_keys).to match_array(Driftless::Detectors.registry.map(&:key))
  end

  it 'orders keys alphabetically, matching scan output' do
    expect(listed_keys).to eq(Driftless::Detectors.registry.map(&:key).sort)
  end
end
