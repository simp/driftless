require 'spec_helper'

require 'driftless/fail_on'

RSpec.describe Driftless::FailOn do
  def finding(severity: :warning, quality: nil)
    Driftless::Finding.new(key: 'x:y', message: 'm', severity: severity, quality: quality)
  end

  describe '.parse' do
    it 'rejects an empty value' do
      expect { described_class.parse('') }.to raise_error(ArgumentError, /no terms/)
    end

    it 'rejects an unknown term, naming the accepted ones' do
      expect { described_class.parse('bogus') }
        .to raise_error(ArgumentError, /unknown fail-on term "bogus".*error, warning, note.*stale, wrong, weird, impossible/)
    end

    it 'rejects any combined with other terms' do
      expect { described_class.parse('any,error') }
        .to raise_error(ArgumentError, /"any" cannot be combined/)
    end

    it 'rejects none combined with other terms' do
      expect { described_class.parse('none,stale') }
        .to raise_error(ArgumentError, /"none" cannot be combined/)
    end
  end

  describe '#fail?' do
    it 'any: fails when there are findings' do
      rule = described_class.parse('any')
      expect(rule.fail?([finding])).to be true
      expect(rule.fail?([])).to be false
    end

    it 'none: never fails' do
      rule = described_class.parse('none')
      expect(rule.fail?([finding(severity: :error, quality: :impossible)])).to be false
    end

    it 'never: pre-1.0 alias for none' do
      expect(described_class.parse('never').fail?([finding])).to be false
    end

    it 'a severity term matches that severity or worse' do
      rule = described_class.parse('warning')
      expect(rule.fail?([finding(severity: :error)])).to be true
      expect(rule.fail?([finding(severity: :warning)])).to be true
      expect(rule.fail?([finding(severity: :note)])).to be false
    end

    it 'a quality term matches exactly' do
      rule = described_class.parse('stale')
      expect(rule.fail?([finding(quality: :stale)])).to be true
      expect(rule.fail?([finding(quality: :wrong)])).to be false
      expect(rule.fail?([finding(quality: nil)])).to be false
    end

    it 'comma-joined terms OR together' do
      rule = described_class.parse('error,stale,impossible')
      expect(rule.fail?([finding(severity: :error)])).to be true
      expect(rule.fail?([finding(quality: :stale)])).to be true
      expect(rule.fail?([finding(quality: :impossible)])).to be true
      expect(rule.fail?([finding(severity: :warning, quality: :wrong)])).to be false
    end

    it 'tolerates whitespace around terms' do
      rule = described_class.parse(' error , stale ')
      expect(rule.fail?([finding(quality: :stale)])).to be true
    end
  end
end
