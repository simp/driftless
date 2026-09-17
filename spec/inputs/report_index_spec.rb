require 'spec_helper'
require 'tmpdir'
require 'fileutils'

require 'driftless/inputs/report_index'

RSpec.describe Driftless::Inputs::ReportIndex do
  def file(root, rel, bytes)
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, 'x' * bytes)
  end

  it 'lists live, archived, and quarantined report files in that order, with sizes' do
    Dir.mktmpdir do |incoming|
      file(incoming, 'all-active-nodes/east--S2.json', 10)
      file(incoming, 'classes-for-all-active-nodes/east--S2.ndjson', 20)
      file(incoming, 'all-active-nodes/.hidden.json', 1)
      file(incoming, '.archive/east--S1/all-active-nodes.ndjson', 30)
      file(incoming, '.archive/east--S1/_summary.json', 1)
      file(incoming, '.quarantine/west--S1/all-active-nodes.ndjson', 40)

      rows = described_class.list(incoming).map { |e| [e.state, e.collector, e.session_id, e.report, e.bytes] }
      expect(rows).to eq([
        ['live', 'east', 'S2', 'all-active-nodes', 10],
        ['live', 'east', 'S2', 'classes-for-all-active-nodes', 20],
        ['archive', 'east', 'S1', 'all-active-nodes', 30],
        ['quarantine', 'west', 'S1', 'all-active-nodes', 40],
      ])
    end
  end

  it 'returns nothing for an empty tree' do
    Dir.mktmpdir { |incoming| expect(described_class.list(incoming)).to eq([]) }
  end
end
