require 'spec_helper'
require 'driftless/finding'

RSpec.describe Driftless::Finding do
  describe 'severity' do
    it 'defaults to :warning when omitted' do
      f = described_class.new(key: 'k', message: 'm')
      expect(f.severity).to eq(:warning)
    end

    it 'accepts :error, :warning, :note' do
      %i[error warning note].each do |s|
        expect { described_class.new(key: 'k', message: 'm', severity: s) }
          .not_to raise_error
      end
    end

    it 'rejects an out-of-set symbol' do
      expect { described_class.new(key: 'k', message: 'm', severity: :fatal) }
        .to raise_error(ArgumentError, /invalid Finding severity :fatal/)
    end

    it 'rejects nil (severity is required)' do
      expect { described_class.new(key: 'k', message: 'm', severity: nil) }
        .to raise_error(ArgumentError, /invalid Finding severity nil/)
    end
  end

  describe 'quality' do
    it 'defaults to nil (unlabelled) when omitted' do
      f = described_class.new(key: 'k', message: 'm')
      expect(f.quality).to be_nil
    end

    it 'accepts :stale, :wrong, :weird, :impossible' do
      %i[stale wrong weird impossible].each do |q|
        expect { described_class.new(key: 'k', message: 'm', quality: q) }
          .not_to raise_error
      end
    end

    it 'accepts nil explicitly' do
      f = described_class.new(key: 'k', message: 'm', quality: nil)
      expect(f.quality).to be_nil
    end

    it 'rejects an out-of-set symbol' do
      expect { described_class.new(key: 'k', message: 'm', quality: :dangerous) }
        .to raise_error(ArgumentError, /invalid Finding quality :dangerous/)
    end
  end
end
