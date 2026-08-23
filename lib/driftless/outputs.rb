require 'driftless/config_keys'
require 'driftless/outputs/json_writer'
require 'driftless/outputs/text_writer'

module Driftless
  # Owns the choice of output format: which formats exist, which writer renders
  # each, and what to fall back to when the caller did not pick one.
  module Outputs
    extend ConfigKeys::DSL

    WRITERS = {
      'json' => JsonWriter,
      'text' => TextWriter,
    }.freeze

    # Format chosen when nothing else decides. Text reads well to a person at a
    # terminal; anything else is presumed to be feeding a program.
    TTY_FORMAT     = 'text'.freeze
    PIPED_FORMAT   = 'json'.freeze

    config_key 'output.format', type: :string, default: nil, example: 'text',
               about: 'json or text (default: text on a TTY, json otherwise)'
    config_key 'output.default_file', type: :string, default: nil, example: 'findings.json',
               about: 'Write output here instead of stdout; a .json name also selects json'
    config_key 'output.tabularize', type: :boolean, default: true,
               about: 'Align finding messages in a column'
    config_key 'output.color', type: :boolean, default: nil, example: true,
               about: 'Colorize output (default: on when the destination is a TTY). ' \
                      'NO_COLOR overrides this; --color / --no-color override both'

    module_function

    def formats
      WRITERS.keys
    end

    def format?(name)
      WRITERS.key?(name.to_s)
    end

    def default_format(io)
      (io.respond_to?(:tty?) && io.tty?) ? TTY_FORMAT : PIPED_FORMAT
    end

    # The format a destination filename implies, or nil when it implies nothing.
    def format_for_filename(path)
      'json' if path.to_s.match?(/\.json\z/i)
    end

    def write(findings, io, format:, color: nil, tabularize: true)
      writer = WRITERS.fetch(format.to_s) do
        raise ArgumentError, "unknown output format #{format.inspect} (known: #{formats.join(', ')})"
      end
      writer.write(findings, io, color: color, tabularize: tabularize)
    end
  end
end
