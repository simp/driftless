require 'spec_helper'
require 'stringio'
require 'json'

require 'driftless/outputs/json_writer'
require 'driftless/finding'

RSpec.describe Driftless::Outputs::JsonWriter do
  def finding(**kwargs)
    defaults = { key: 'x', path: nil, line: nil, message: 'msg', meta: {} }
    Driftless::Finding.new(**defaults.merge(kwargs))
  end

  describe '.write' do
    it 'emits a JSON array with one finding per line inside brackets' do
      io = StringIO.new
      described_class.write([finding(key: 'a:x'), finding(key: 'b:y')], io)
      lines = io.string.lines
      expect(lines.first.chomp).to eq('[')
      expect(lines.last.chomp).to  eq(']')
      expect(lines.length).to eq(4)  # [ + 2 findings + ]
    end

    it 'produces valid parseable JSON' do
      io = StringIO.new
      described_class.write([finding(key: 'a', path: '/tmp/x', line: 3, message: 'hello', meta: { foo: 1 })], io)
      parsed = JSON.parse(io.string)
      expect(parsed).to be_a(Array)
      expect(parsed.first['key']).to eq('a')
      expect(parsed.first['line']).to eq(3)
      expect(parsed.first['meta']).to eq('foo' => 1)
    end

    it 'sorts findings deterministically by key then path then line' do
      io = StringIO.new
      findings = [
        finding(key: 'b',  path: '/x', line: 5),
        finding(key: 'a',  path: '/z', line: 1),
        finding(key: 'a',  path: '/x', line: 9),
        finding(key: 'a',  path: '/x', line: 2),
      ]
      described_class.write(findings, io)
      keys = JSON.parse(io.string).map { |f| [f['key'], f['path'], f['line']] }
      expect(keys).to eq([
        ['a', '/x', 2], ['a', '/x', 9], ['a', '/z', 1], ['b', '/x', 5],
      ])
    end

    it 'emits {} for empty meta (not {\\n  }) — one-finding-per-line keeps it compact' do
      io = StringIO.new
      described_class.write([finding(meta: {})], io)
      # No newline between "meta":{" and the closing } means the empty hash is inline
      expect(io.string).to match(/"meta":\{\}/)
    end

    it 'produces `[]` (empty array on its own line pair) when given no findings' do
      io = StringIO.new
      described_class.write([], io)
      expect(io.string).to eq("[\n]\n")
    end

    it 'preserves nil for missing path/line rather than omitting the keys' do
      io = StringIO.new
      described_class.write([finding(key: 'k', path: nil, line: nil)], io)
      parsed = JSON.parse(io.string).first
      expect(parsed).to have_key('path')
      expect(parsed).to have_key('line')
      expect(parsed['path']).to be_nil
      expect(parsed['line']).to be_nil
    end
  end
end
