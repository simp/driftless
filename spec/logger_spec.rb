require 'spec_helper'

require 'driftless/logger'

RSpec.describe Driftless::Logging do
  describe '.format_line' do
    context 'without color' do
      before(:each) { Driftless::Ansi.preference = false }

      it 'prefixes the downcased severity and terminates the line' do
        expect(described_class.format_line('WARNING', 'something')).to eq("warning: something\n")
      end

      it 'uppercases fatal with or without color' do
        expect(described_class.format_line('FATAL', 'stopped')).to eq("FATAL: stopped\n")
      end

      it 'emits no escapes for any severity' do
        %w[TRACE DEBUG INFO NOTICE WARNING ERROR FATAL].each do |severity|
          expect(described_class.format_line(severity, 'x')).not_to include("\e[")
        end
      end
    end

    context 'with color' do
      before(:each) { Driftless::Ansi.preference = true }

      it 'styles the label through its colon, leaving the message plain' do
        expect(described_class.format_line('WARNING', 'something'))
          .to eq("#{Driftless::Ansi.wrap('warning:', :yellow)} something\n")
      end

      it 'gives fatal a background so it survives a wall of help text' do
        expect(described_class.format_line('FATAL', 'x'))
          .to start_with(Driftless::Ansi::CODES[:white] + Driftless::Ansi::CODES[:on_red])
      end

      # Debug is output to skim past, so the whole line recedes rather than
      # the label standing out.
      it 'dims the entire debug and trace lines, message included' do
        expect(described_class.format_line('DEBUG', 'noise'))
          .to eq("#{Driftless::Ansi.wrap('debug: noise', :dim)}\n")
        expect(described_class.format_line('TRACE', 'hum'))
          .to eq("#{Driftless::Ansi.wrap('trace: hum', :dim)}\n")
      end

      it 'leaves notice unstyled' do
        expect(described_class.format_line('NOTICE', 'done')).to eq("notice: done\n")
      end

      it 'colours the info label green' do
        expect(described_class.format_line('INFO', 'milestone'))
          .to eq("#{Driftless::Ansi.wrap('info:', :green)} milestone\n")
      end
    end
  end

  describe '.formatter' do
    it 'is what a captured logger produces, so specs exercise the real shape' do
      Driftless::Ansi.preference = false
      log = capture_log { Driftless.logger.warn('captured') }
      expect(log).to eq("warning: captured\n")
    end
  end

  describe Driftless::Logging::Logger do
    let(:out)    { StringIO.new }
    let(:logger) { described_class.new(out).tap { |l| l.formatter = Driftless::Logging.formatter } }

    before(:each) { Driftless::Ansi.preference = false }

    it 'defaults to notice and names its level' do
      expect(logger.level_name).to eq(:notice)
      expect(logger.notice?).to be(true)
      expect(logger.info?).to be(false)
    end

    it 'takes a level by name, number, or the warn spelling, and refuses others' do
      logger.level = :trace
      expect(logger.level).to eq(0)
      logger.level = 'warn'
      expect(logger.level_name).to eq(:warning)
      logger.level = 2
      expect(logger.level_name).to eq(:info)
      expect { logger.level = :loud }.to raise_error(ArgumentError, /loud/)
      expect { logger.level = 9 }.to raise_error(ArgumentError, /9/)
    end

    it 'writes each level above the threshold with its own label' do
      logger.level = :trace
      %i[trace debug info notice warning error fatal].each { |l| logger.public_send(l, l.to_s) }
      logger.warn('spelled warn')
      logger.unknown('odd')
      logger.add(nil, 'nil severity')
      expect(out.string.lines.map(&:chomp)).to eq([
        'trace: trace', 'debug: debug', 'info: info', 'notice: notice', 'warning: warning', 'error: error',
        'FATAL: fatal', 'warning: spelled warn', 'FATAL: odd', 'FATAL: nil severity',
      ])
    end

    it 'drops what is below the threshold, and the bang methods move it' do
      logger.info('hidden')
      logger.info!
      logger.info('shown')
      expect(out.string).to eq("info: shown\n")
    end

    # Ruby's Logger names its severities lexically in every level-aware
    # method, so each must be redefined here; a logger gem that adds one
    # would reintroduce the base numbering silently.
    it 'owns every level-aware method of the base class' do
      %i[debug info warn error fatal unknown add level= debug? info? warn? error? fatal? debug! info! warn! error! fatal!].each do |m|
        expect(described_class.instance_method(m).owner).to eq(described_class), m.to_s
      end
    end
  end
end
