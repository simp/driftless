require 'driftless/cli/base'
require 'driftless/cli/config'
require 'driftless/config'
require 'driftless/config_validator'
require 'driftless/config_keys'
require 'driftless/detectors'

module Driftless
  module CLI
    class Config
      class New < Base
        register_command name: 'new', subcommand_of: Config
        desc 'Write a driftless.yaml listing every known key, commented out'

        # detectors last: it is by far the longest section.
        SUBSYSTEM_ORDER = ->(name) { [(name == 'detectors') ? 1 : 0, name] }

        def execute(_argv)
          path = @options[:path] || ::Driftless::Config.project_path

          if path.match? /\A-+\Z/
            puts render
            exit 0
          end

          if File.exist?(path) && !@options[:force]
            fatal!("#{path} already exists (pass --force to overwrite)", 3)
          end

          File.write(path, render)
          puts "wrote #{path}"
          exit 0
        end

        protected

        def configure_parser(o)
          o.on('-p', '--path=PATH',
               'Write to PATH instead of ./driftless.yaml',
               "('--' prints to STDOUT)") { |v| @options[:path] = v }
          o.on('--force', 'Overwrite an existing file') { @options[:force] = true }
        end

        private

        # Return commented-out line(s) at `depth` levels of YAML nesting
        def comment(depth, text, cols = 80)
          text_prefix = text.start_with?('# ') ? '# ' : ''
          bare_text = text.sub(/\A#{text_prefix}/,'')
          comment_prefix = "# #{'  ' * depth}"
          return comment_prefix.strip if text.empty?
          padding = comment_prefix.size
          lines = wrap_text(bare_text,cols-comment_prefix.size).split("\n")
          lines.map { |t| "#{comment_prefix}#{text_prefix}#{t}".strip }.join("\n")
        end

        # Renders key/value as YAML, then comments every line at `depth`. Multi-line
        # values (sequences, mappings) keep their relative indentation.
        def yaml_lines(key, value, depth)
          body = { key.to_s => value }.to_yaml.sub(/\A---\n/, '').chomp
          body.lines.map { |l| comment(depth, l.chomp) }
        end

        # Wrap at text at nearest whitespace to <col> characters
        def wrap_text(txt, col = 80)
          txt.gsub(
            /(?:((?>.{1,#{col}}(?:(?<=[^\S\r\n])[^\S\r\n]?|(?=\r?\n)|$|[^\S\r\n]))|.{1,#{col}})(?:\r?\n)?|(?:\r?\n|$))/,
            "\\1\n"
          ).chomp
        end

        def render
          require 'time'
          lines = ['## driftless configuration file',
                   '## ' + '-'*77,
                   "## Generated at #{Time.now} by `driftless config new`",
                   '##',
                   '## Every key starts commented out, showing its default/an illustrative value.',
                   '##',
                   '## Config file search order:',
                   *::Driftless::Config.search_chain.map { |p| "##   #{p}" },
                   '## `--config PATH` replaces that chain; `--no-config` skips it.',
                   '## ' + '-'*77,
          ]
          subsystems.each { |name| lines.concat(subsystem_section(name)) }
          lines.concat(detectors_section)
          lines.concat([comment(0,'')])
          # lines.concat(withheld_section)
          lines = lines.map { |x| x.split(/\n/) }.flatten
          lines.map! { |x| x.gsub(/\s+$/, '') }
          "#{lines.join("\n")}\n"
        end

        def subsystems
          (::Driftless::ConfigKeys.subsystems - ['detectors']).sort_by(&SUBSYSTEM_ORDER)
        end

        def subsystem_section(name)
          lines = ['', comment(0, "#{name}:")]
          ::Driftless::ConfigKeys.settable(name).each do |key|
            lines << comment(1, "# #{key.about}") if key.about
            lines.concat(yaml_lines(key.name, sample_value(key), 1))
          end
          lines << '#'
        end

        # Withheld keys are listed once at the end rather than in each section
        # they could plausibly be written under.
        def withheld_section
          groups = ::Driftless::ConfigKeys.withheld.group_by(&:because)
          return [] if groups.empty?

          lines = ['', '## Rejected if set — the validator explains why:']
          groups.each do |because, keys|
            lines << "##   #{keys.map(&:path).join(', ')}"
            lines.concat(wrap(because, '##     '))
          end
          lines
        end

        def wrap(text, prefix, width: 78)
          # rubocop:disable Style/MultilineBlockChain -- succint
          text.split.each_with_object(['']) { |word, acc|
            if acc.last.empty? then acc[-1] = word
            elsif acc.last.length + 1 + word.length <= width - prefix.length then acc[-1] += " #{word}"
            else acc << word
            end
          }.map { |line| "#{prefix}#{line}" }
          # rubocop:enable Style/MultilineBlockChain
        end

        # Falls back to a type-shaped placeholder when a key declares neither a
        # default nor an example.
        def sample_value(key)
          return key.sample unless key.sample.nil?
          case key.type
          when :array   then []
          when :boolean then false
          when :integer then 0
          else               ''
          end
        end

        def detectors_section
          sample = ::Driftless::Detectors.registry.map(&:key).sort.first
          lines  = ['',
                    '#',
                    '## ' + '-'*77,
                    '##' + 'DETECTORS'.center(78),
                    '## ' + '-'*77,
                    '## - `only` and `skip` select which detectors run',
                    '## = `defaults` applies to every detector',
                    '## - A per-detector key overrides its defaults',
                    '## ' + '-'*77,
                    comment(0, 'detectors:')]
          ::Driftless::ConfigKeys.settable('detectors').each do |key|
            lines << comment(1, "# #{key.about}") if key.about
            lines.concat(yaml_lines(key.name, [sample], 1))
          end
          lines << comment(1, 'defaults:')
          base_options.each { |opt| lines.concat(option_lines(opt, 2)) }

          ::Driftless::Detectors.registry.sort_by(&:key).each do |klass|
            lines << '#'
            lines << comment(1, "# #{klass.about}")
            lines << comment(1, "#{klass.key}:")
            klass.config_options.each_value do |opt|
              lines.concat(option_lines(opt, 2,
                base_options.map { |x| x[:name]}))
            end
          end
          lines
        end

        def base_options
          ::Driftless::Detectors::Base.config_options.values
        end

        def option_lines(opt, depth, exclude_comments=[])
          lines = []
          unless exclude_comments.include?(opt[:name])
            lines << comment(depth, "# #{opt[:about]}") if opt[:about]
          end
          lines.concat(yaml_lines(opt[:name], opt[:default], depth))
          lines
        end
      end
    end
  end
end
