require 'spec_helper'
require 'stringio'

require 'driftless/outputs/text_writer'
require 'driftless/finding'

RSpec.describe Driftless::Outputs::TextWriter do
  def finding(**kwargs)
    defaults = { key: 'x', path: nil, line: nil, message: 'msg', meta: {} }
    Driftless::Finding.new(**defaults.merge(kwargs))
  end

  # StringIO isn't a TTY, so auto-mode won't emit color. Tests that need to
  # exercise color rendering pass `color: true` explicitly.

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
        finding(key: 'hierarchy:files-missed-by-reported-fact-values', path: '/tmp/c', line: nil, message: 'c1'),
      ], io)
      out = io.string
      expect(out).to include('data:missing-class (2 findings)')
      expect(out).to include('hierarchy:files-missed-by-reported-fact-values (1 finding)')
    end

    it 'sorts groups alphabetically by key' do
      io = StringIO.new
      described_class.write([
        finding(key: 'z:foo', message: 'zzz'),
        finding(key: 'a:bar', message: 'aaa'),
      ], io)
      lines = io.string.lines
      expect(lines[0]).to include('a:bar')
      expect(lines[0]).not_to include('z:foo')
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
      expect(io.string).to match(/ma\n\n.*b \(/)
    end
  end

  describe 'severity/quality header rendering' do
    it 'renders the severity label in the group header' do
      io = StringIO.new
      described_class.write([finding(key: 'k', severity: :error, quality: :wrong)], io)
      expect(io.string).to match(/^error\s+wrong\s+k \(1 finding\)/)
    end

    it 'leaves the quality column blank when quality is nil, preserving column alignment' do
      io = StringIO.new
      described_class.write([finding(key: 'k', severity: :warning, quality: nil)], io)
      # severity ("warning" — fills 7-char col) + 1-space gutter + blank
      # 10-char quality col + 2-space gutter = 13 spaces before the key.
      expect(io.string).to match(/^warning\s{13}k \(1 finding\)/)
    end

    it 'aligns severity and quality columns across heterogeneous groups' do
      io = StringIO.new
      described_class.write([
        finding(key: 'a', severity: :error,   quality: :wrong),
        finding(key: 'b', severity: :warning, quality: :stale),
        finding(key: 'c', severity: :note,    quality: nil),
      ], io)
      lines = io.string.lines
      header_starts = lines.grep(/\(1 finding\)/).map { |l| l.index(/[abc] \(/) }
      # All group-header key positions should be identical (column alignment).
      expect(header_starts.uniq.length).to eq(1)
    end

    it 'omits ANSI escapes when color is off (default with non-TTY io)' do
      io = StringIO.new
      described_class.write([finding(key: 'k', severity: :error, quality: :wrong)], io)
      expect(io.string).not_to include("\e[")
    end

    it 'emits ANSI escapes when color: true is passed explicitly' do
      io = StringIO.new
      described_class.write([finding(key: 'k', severity: :error, quality: :wrong)], io, color: true)
      # error styling includes red + bold, key is bold
      expect(io.string).to include("\e[0;31m")
      expect(io.string).to include("\e[1m")
      expect(io.string).to include("\e[0m")
    end

    it 'suppresses ANSI when color: false is passed explicitly even on a TTY-like io' do
      tty_io = Class.new(StringIO) { def tty?; true; end }.new
      described_class.write([finding(key: 'k', severity: :error)], tty_io, color: false)
      expect(tty_io.string).not_to include("\e[")
    end
  end
end
