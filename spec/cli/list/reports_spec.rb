require 'stringio'
require 'tmpdir'
require 'fileutils'

require 'spec_helper'
require 'driftless/cli/list/reports'

RSpec.describe Driftless::CLI::List::Reports do
  def file(root, rel, bytes)
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, 'x' * bytes)
  end

  def run(argv)
    out      = StringIO.new
    original = $stdout
    $stdout  = out
    begin
      described_class.new.run(argv)
    rescue SystemExit
      nil
    ensure
      $stdout = original
    end
    out.string
  end

  around(:each) do |ex|
    original = Driftless.instance_variable_get(:@config)
    ex.run
  ensure
    Driftless.instance_variable_set(:@config, original)
  end

  before(:each) { silence_driftless_logger }

  it 'lists each report file with its state and size, then a total' do
    Dir.mktmpdir do |incoming|
      file(incoming, 'all-active-nodes/east--S2.json', 512)
      file(incoming, '.archive/east--S1/all-active-nodes.ndjson', 2048)

      lines = run(['--no-config', '-i', incoming]).lines.map(&:rstrip)
      expect(lines).to eq([
        'state   | collector | session | report           | size',
        '--------+-----------+---------+------------------+--------',
        'live    | east      | S2      | all-active-nodes | 512 B',
        'archive | east      | S1      | all-active-nodes | 2.0 KiB',
        'total 2.5 KiB in 2 file(s)',
      ])
    end
  end

  it 'says so for an empty tree' do
    Dir.mktmpdir { |incoming| expect(run(['--no-config', '-i', incoming])).to eq("(nothing matches)\n") }
  end
end
