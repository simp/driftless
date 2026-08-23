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

    # A code carrying its own reset cancels a background set before it, so
    # order in the output is not the order of the arguments.
    it 'emits a reset-carrying code ahead of an additive one' do
      expect(described_class.wrap('hi', :on_red, :white))
        .to eq("\e[0;37m\e[41mhi\e[0m")
    end

    it 'raises KeyError on an unknown style' do
      expect { described_class.wrap('hi', :chartreuse) }.to raise_error(KeyError)
    end

    it 'coerces non-string input via to_s' do
      expect(described_class.wrap(42, :cyan)).to eq("\e[0;36m42\e[0m")
    end
  end

  describe '.enabled?' do
    let(:tty)  { instance_double(IO, tty?: true) }
    let(:pipe) { instance_double(IO, tty?: false) }

    around(:each) do |example|
      original = ENV.fetch('NO_COLOR', nil)
      example.run
    ensure
      original.nil? ? ENV.delete('NO_COLOR') : ENV['NO_COLOR'] = original
    end

    it 'follows the stream when no preference and no NO_COLOR' do
      ENV.delete('NO_COLOR')
      expect(described_class.enabled?(tty)).to be(true)
      expect(described_class.enabled?(pipe)).to be(false)
    end

    it 'is off for any stream when NO_COLOR is set' do
      ENV['NO_COLOR'] = '1'
      expect(described_class.enabled?(tty)).to be(false)
    end

    it 'ignores an empty NO_COLOR, per the convention' do
      ENV['NO_COLOR'] = ''
      expect(described_class.enabled?(tty)).to be(true)
    end

    it 'falls back to output.color before consulting the stream' do
      ENV.delete('NO_COLOR')
      described_class.configured = true
      expect(described_class.enabled?(pipe)).to be(true)
      described_class.configured = false
      expect(described_class.enabled?(tty)).to be(false)
    end

    # A driftless.yaml committed to a repo must not force color on someone who
    # opted out globally.
    it 'lets NO_COLOR override output.color' do
      ENV['NO_COLOR'] = '1'
      described_class.configured = true
      expect(described_class.enabled?(tty)).to be(false)
    end

    it 'lets the flag override output.color and NO_COLOR together' do
      ENV['NO_COLOR'] = '1'
      described_class.configured = false
      described_class.preference = true
      expect(described_class.enabled?(pipe)).to be(true)
    end

    it 'lets an explicit preference override NO_COLOR and the stream' do
      ENV['NO_COLOR'] = '1'
      described_class.preference = true
      expect(described_class.enabled?(pipe)).to be(true)
      described_class.preference = false
      expect(described_class.enabled?(tty)).to be(false)
    end

    it 'treats a non-IO destination as not a terminal' do
      expect(described_class.enabled?(StringIO.new)).to be(false)
    end
  end
end
