require 'stringio'

require 'spec_helper'
require 'driftless/outputs'
require 'driftless/finding'

RSpec.describe Driftless::Outputs do
  def finding(**kwargs)
    defaults = { key: 'k', path: '/tmp/x', line: 1, message: 'msg', meta: {} }
    Driftless::Finding.new(**defaults, **kwargs)
  end

  describe '.formats' do
    it 'names every format that has a writer' do
      expect(described_class.formats).to match_array(%w[json text])
    end

    it 'recognizes its own formats and nothing else' do
      described_class.formats.each { |f| expect(described_class).to be_format(f) }
      expect(described_class).not_to be_format('yaml')
    end
  end

  describe '.default_format' do
    it 'is text for a TTY' do
      io = StringIO.new
      allow(io).to receive(:tty?).and_return(true)
      expect(described_class.default_format(io)).to eq('text')
    end

    it 'is json for anything else' do
      expect(described_class.default_format(StringIO.new)).to eq('json')
    end
  end

  describe '.format_for_filename' do
    it 'reads json off a .json name, case-insensitively' do
      expect(described_class.format_for_filename('out.json')).to eq('json')
      expect(described_class.format_for_filename('OUT.JSON')).to eq('json')
    end

    it 'implies nothing for other names' do
      expect(described_class.format_for_filename('out.txt')).to be_nil
      expect(described_class.format_for_filename('json.txt')).to be_nil
    end
  end

  describe '.write' do
    it 'dispatches to the json writer' do
      io = StringIO.new
      described_class.write([finding], io, format: 'json')
      expect(io.string).to start_with('[')
    end

    it 'dispatches to the text writer' do
      io = StringIO.new
      described_class.write([finding], io, format: 'text')
      expect(io.string).to include('/tmp/x:1  msg')
    end

    it 'passes rendering options through to the text writer' do
      io = StringIO.new
      described_class.write([finding(path: '/a'), finding(path: '/bbbbbbbb')], io,
                            format: 'text', tabularize: true)
      cols = io.string.lines.grep(/msg$/).map { |l| l.index(/msg$/) }
      expect(cols.uniq.length).to eq(1)
    end

    it 'accepts rendering options for json without complaint' do
      io = StringIO.new
      expect { described_class.write([finding], io, format: 'json', color: true, tabularize: true) }
        .not_to raise_error
    end

    it 'names the known formats when given an unknown one' do
      expect { described_class.write([finding], StringIO.new, format: 'yaml') }
        .to raise_error(ArgumentError, /unknown output format "yaml".*json, text/)
    end
  end
end
