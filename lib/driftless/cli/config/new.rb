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

          if File.exist?(path) && !@options[:force]
            warn "#{path} already exists (pass --force to overwrite)"
            exit 3
          end

          File.write(path, render)
          puts "wrote #{path}"
          exit 0
        end

        protected

        def configure_parser(o)
          o.on('-p', '--path=PATH',
               'Write to PATH instead of ./driftless.yaml') { |v| @options[:path] = v }
          o.on('--force', 'Overwrite an existing file') { @options[:force] = true }
        end

        private

        # One commented-out line at `depth` levels of YAML nesting. Stripping a
        # single leading "# " from every line of the file yields valid YAML, so
        # prose lines carry "##" and stay comments through that transformation.
        def comment(depth, text)
          "# #{'  ' * depth}#{text}"
        end

        # Renders key/value as YAML, then comments every line at `depth`. Multi-line
        # values (sequences, mappings) keep their relative indentation.
        def yaml_lines(key, value, depth)
          body = { key.to_s => value }.to_yaml.sub(/\A---\n/, '').chomp
          body.lines.map { |l| comment(depth, l.chomp) }
        end

        def render
          lines = ['## driftless configuration. Every key is listed commented out,',
                   '## showing its default or an illustrative value.',
                   '##',
                   '## Search order (later wins, arrays union):',
                   *::Driftless::Config.search_chain.map { |p| "##   #{p}" },
                   '## `--config PATH` replaces that chain; `--no-config` skips it.']
          subsystems.each { |name| lines.concat(subsystem_section(name)) }
          lines.concat(detectors_section)
          lines.concat(withheld_section)
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
          lines
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
                    '## `only` and `skip` select which detectors run; `defaults` applies to',
                    '## every detector; a detector key overrides defaults for that one.',
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
            klass.config_options.each_value { |opt| lines.concat(option_lines(opt, 2)) }
          end
          lines
        end

        def base_options
          ::Driftless::Detectors::Base.config_options.values
        end

        def option_lines(opt, depth)
          lines = []
          lines << comment(depth, "# #{opt[:about]}") if opt[:about]
          lines.concat(yaml_lines(opt[:name], opt[:default], depth))
          lines
        end
      end
    end
  end
end
