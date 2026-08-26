require 'rspec'
require 'rspec/its'
require 'driftless'
# Config-key declarations register at class-definition time, so the validator
# only sees a complete set once every owner is loaded. bin/driftless loads the
# CLI tree before validating; specs have to match or results vary by load order.
require 'driftless/cli/root'

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
    Driftless::Ansi.preference = nil
    Driftless::Ansi.configured = nil
  end
end

# Capture what Driftless logs while the block runs, and return it as a string.
#
# The default logger binds $stderr when it is built, so `output(...).to_stderr`
# never sees a log line — swapping the logger is the only way. The production
# formatter comes along, so severity labels are exercised, not reimplemented.
def capture_log(level: Logger::DEBUG)
  captured        = StringIO.new
  original_logger = Driftless.logger
  Driftless.logger           = Logger.new(captured, level: level)
  Driftless.logger.formatter = Driftless::Logging.formatter
  yield
  captured.string
ensure
  Driftless.logger = original_logger
end

# Shared factory for Driftless::Corpus. Data.define is strict about missing
# kwargs, so tests need sensible defaults for every field they don't care
# about. Centralizing here means adding a new Corpus field only requires
# updating this helper, not every spec's hand-rolled builder.
def build_corpus(**overrides)
  defaults = {
    repo_dir:          nil,
    hiera_tiers:       [],
    puppet_classes:    {},
    data_files:        [],
    reported:          Driftless::Reported.new(data: {}),
    code_lookup_calls: [],
    data_lookup_calls: [],
  }
  Driftless::Corpus.new(**defaults, **overrides)
end
