require 'spec_helper'
require 'json'
require 'tmpdir'

require 'driftless/json_document'

RSpec.describe Driftless::JsonDocument do
  def doc(**overrides)
    { 'document' => 'scan', 'schema_version' => 1, 'k' => 'v' }.merge(overrides)
  end

  def read(path)
    described_class.read(path, document: 'scan', schema_version: 1)
  end

  it 'writes pretty JSON with a trailing newline, creating parent directories' do
    Dir.mktmpdir do |dir|
      path = described_class.write(doc, File.join(dir, 'a', 'b', 'x.json'))
      text = File.read(path)
      expect(text).to end_with("}\n")
      expect(text.lines.length).to be > 1
      expect(read(path)).to eq(doc)
    end
  end

  it 'raises for a missing file, naming it' do
    expect { read('/nonexistent/x.json') }
      .to raise_error(described_class::Error, %r{\A/nonexistent/x.json: No such file or directory\z})
  end

  it 'raises for invalid JSON' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'x.json')
      File.write(path, '{')
      expect { read(path) }.to raise_error(described_class::Error, /not valid JSON/)
    end
  end

  it 'raises for a non-object document' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'x.json')
      File.write(path, '[1]')
      expect { read(path) }.to raise_error(described_class::Error, /not a driftless document/)
    end
  end

  it 'raises for another document kind' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'x.json')
      File.write(path, JSON.generate(doc('document' => 'report')))
      expect { read(path) }.to raise_error(described_class::Error, /is a "report" document, expected "scan"/)
    end
  end

  it 'raises for another schema version' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'x.json')
      File.write(path, JSON.generate(doc('schema_version' => 2)))
      expect { read(path) }.to raise_error(described_class::Error, /scan schema_version 2, expected 1/)
    end
  end
end
