require 'spec_helper'
require 'driftless/ansi'

RSpec.describe Driftless::Ansi do
  describe '.wrap' do
    it 'returns the string unchanged when no styles are given' do
      expect(described_class.wrap('hello')).to eq('hello')
    end

    it 'wraps with a single style code + reset' do
      expect(described_class.wrap('hi', :red)).to eq("\e[0;31mhi\e[0m")
    end

    it 'concatenates multiple style codes before the string' do
      out = described_class.wrap('hi', :red, :bold)
      expect(out).to start_with("\e[0;31m\e[1m")
      expect(out).to end_with("hi\e[0m")
    end

    it 'raises KeyError on an unknown style' do
      expect { described_class.wrap('hi', :chartreuse) }.to raise_error(KeyError)
    end

    it 'coerces non-string input via to_s' do
      expect(described_class.wrap(42, :cyan)).to eq("\e[0;36m42\e[0m")
    end
  end
end
