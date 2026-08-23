require 'spec_helper'

require 'driftless/logger'

RSpec.describe Driftless::Logging do
  describe '.format_line' do
    context 'without color' do
      before(:each) { Driftless::Ansi.preference = false }

      it 'prefixes the downcased severity and terminates the line' do
        expect(described_class.format_line('WARN', 'something')).to eq("warn: something\n")
      end

      it 'uppercases fatal with or without color' do
        expect(described_class.format_line('FATAL', 'stopped')).to eq("FATAL: stopped\n")
      end

      it 'emits no escapes for any severity' do
        %w[DEBUG INFO WARN ERROR FATAL].each do |severity|
          expect(described_class.format_line(severity, 'x')).not_to include("\e[")
        end
      end
    end

    context 'with color' do
      before(:each) { Driftless::Ansi.preference = true }

      it 'styles the label through its colon, leaving the message plain' do
        expect(described_class.format_line('WARN', 'something'))
          .to eq("#{Driftless::Ansi.wrap('warn:', :yellow)} something\n")
      end

      it 'gives fatal a background so it survives a wall of help text' do
        expect(described_class.format_line('FATAL', 'x'))
          .to start_with(Driftless::Ansi::CODES[:white] + Driftless::Ansi::CODES[:on_red])
      end

      # Debug is output to skim past, so the whole line recedes rather than
      # the label standing out.
      it 'dims the entire debug line, message included' do
        expect(described_class.format_line('DEBUG', 'noise'))
          .to eq("#{Driftless::Ansi.wrap('debug: noise', :dim)}\n")
      end

      it 'leaves info unstyled' do
        expect(described_class.format_line('INFO', 'milestone')).to eq("info: milestone\n")
      end
    end
  end

  describe '.formatter' do
    it 'is what a captured logger produces, so specs exercise the real shape' do
      Driftless::Ansi.preference = false
      log = capture_log { Driftless.logger.warn('captured') }
      expect(log).to eq("warn: captured\n")
    end
  end
end
