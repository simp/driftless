# The specs match log and table text, so no terminal may tint it: NO_COLOR
# turns the auto preference off whatever stderr is; `--color` still wins.
ENV['NO_COLOR'] = '1'

require 'rspec'
require 'rspec/its'
require 'pupgrade'
# Config-key declarations register at class-definition time, so the validator
# only sees a complete set once every owner is loaded. bin/pupgrade loads the
# CLI tree before validating; specs have to match or results vary by load order.
require 'pupgrade/cli/root'

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
  config.disable_monkey_patching!

  # Ansi.preference and .configured are process-global, set by CLI::Base from
  # --color and output.color. Reset both so one example can't tint the next.
  config.before(:each) do
    Pupgrade::Ansi.preference = nil
    Pupgrade::Ansi.configured = nil
  end

  # A run attaches its log file as a Tee over whatever `Pupgrade.logger`
  # answers, under `silence_logger` a double of this example's. Close any
  # file still attached and drop the stored logger, so the next example
  # starts from a fresh one and no double outlives its example.
  config.after(:each) do
    logger = Driftless.instance_variable_get(:@logger)
    while logger.is_a?(Pupgrade::Logging::Tee)
      logger.file.close
      logger = logger.terminal
    end
    Driftless.instance_variable_set(:@logger, nil)
  end
end

# Capture what pupgrade (and the driftless code it calls) logs while the
# block runs, and return it as a string.
def capture_log(level: :trace)
  captured = StringIO.new
  original = Driftless.instance_variable_get(:@logger)
  logger   = Driftless::Logging::Logger.new(captured, level: level)
  logger.formatter = Driftless::Logging.formatter
  Pupgrade.logger  = logger
  yield
  captured.string
ensure
  Driftless.instance_variable_set(:@logger, original)
end

# Warnings from driftless's inventory and parsers are noise in the middle of
# RSpec results.
def silence_logger
  fake_logger = instance_double(Driftless::Logging::Logger, trace: true, debug: true, info: true, notice: true,
                                                            warning: true, warn: true, error: true, fatal: true)
  allow(fake_logger).to receive(:level=)
  allow(Driftless).to receive(:logger).and_return(fake_logger)
end
