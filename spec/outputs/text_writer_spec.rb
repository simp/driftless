require 'spec_helper'
require 'stringio'

require 'driftless/outputs/text_writer'
require 'driftless/finding'

RSpec.describe Driftless::Outputs::TextWriter do
  def finding(**kwargs)
    defaults = { key: 'x', path: nil, line: nil, message: 'msg', meta: {} }
    Driftless::Finding.new(**defaults.merge(kwargs))
  end

  describe '.write' do
    it 'says "no findings" and nothing else when given an empty list' do
      io = StringIO.new
      described_class.write([], io)
      expect(io.string).to eq("no findings\n")
    end

    it 'groups findings by key and prefixes each group with the key + count' do
      io = StringIO.new
      described_class.write([
        finding(key: 'data:missing-class', path: '/tmp/a', line: 2, message: 'a1'),
        finding(key: 'data:missing-class', path: '/tmp/b', line: 3, message: 'b1'),
        finding(key: 'hierarchy:paths-missing-reported-facts', path: '/tmp/c', line: nil, message: 'c1'),
      ], io)
      out = io.string
      expect(out).to include('data:missing-class (2 findings)')
      expect(out).to include('hierarchy:paths-missing-reported-facts (1 finding)')
    end

    it 'sorts groups alphabetically by key' do
      io = StringIO.new
      described_class.write([
        finding(key: 'z:foo', message: 'zzz'),
        finding(key: 'a:bar', message: 'aaa'),
      ], io)
      lines = io.string.lines
      expect(lines[0]).to match(/^a:bar/)
      # First blank + heading for the next group
    end

    it 'formats location as path:line when both are present' do
      io = StringIO.new
      described_class.write([finding(key: 'k', path: '/tmp/x', line: 42, message: 'msg')], io)
      expect(io.string).to include('/tmp/x:42  msg')
    end

    it 'formats location as path alone when line is nil' do
      io = StringIO.new
      described_class.write([finding(key: 'k', path: '/tmp/x', line: nil, message: 'msg')], io)
      expect(io.string).to include('/tmp/x  msg')
      expect(io.string).not_to include('/tmp/x:')
    end

    it 'formats location as `-` when path is nil (e.g. skip findings)' do
      io = StringIO.new
      described_class.write([finding(key: 'skipped:foo', path: nil, line: nil, message: 'skipped: reason')], io)
      expect(io.string).to include('-  skipped: reason')
    end

    it 'separates groups with a blank line for readability' do
      io = StringIO.new
      described_class.write([
        finding(key: 'a', path: '/x', line: 1, message: 'ma'),
        finding(key: 'b', path: '/y', line: 2, message: 'mb'),
      ], io)
      # blank line between the two groups
      expect(io.string).to match(/ma\n\nb \(/)
    end
  end
end
