require 'driftless/cli/base'
require 'driftless/cli/config'
require 'driftless/config'
require 'driftless/config_validator'
require 'driftless/detectors'

module Driftless
  module CLI
    class Config
      class New < Base
        register_command name: 'new', subcommand_of: Config
        desc 'Write a driftless.yaml listing every known key, commented out'

        # Subsystems with no registry to introspect: [key, value, comment].
        # Ordered as they appear in the generated file.
        STATIC_SECTIONS = {
          'output' => [
            ['format',       'text',           'Output format: text or json (default: text on a TTY, json otherwise)'],
            ['default_file', 'findings.json',  'Write output here instead of stdout; a .json name also forces format: json'],
            ['tabularize',   true,             'Align finding messages in a column'],
          ],
          'reports' => [
            ['incoming_dir', 'incoming',       'Raw-report landing tree read by scan and other report consumers'],
          ],
          'scan' => [
            ['fail_on',      'any',            'Exit non-zero on findings: any or never'],
          ],
          'logging' => [
            ['level',        'warn',           'debug, info, warn, error, or fatal; -v / -vv / -q override it'],
          ],
        }.freeze

        PUPPET_KEYS = {
          'environments'       => [['production'], 'Puppet environments to scan (required by scan)'],
          'allow_missing_envs' => [false,          'Warn instead of erroring when a listed environment has no reports'],
          'role_regex'         => ['^role::',      'Pattern identifying role classes'],
          'profile_regex'      => ['^profile::',   'Pattern identifying profile classes'],
        }.freeze

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
          lines.concat(puppet_section)
          STATIC_SECTIONS.each { |name, entries| lines.concat(static_section(name, entries)) }
          lines.concat(detectors_section)
          "#{lines.join("\n")}\n"
        end

        def puppet_section
          lines = ['', '## Facts about the control repo being scanned.', comment(0, 'puppet:')]
          PUPPET_KEYS.each do |key, (value, about)|
            lines << comment(1, "# #{about}")
            lines.concat(yaml_lines(key, value, 1))
          end
          lines
        end

        def static_section(name, entries)
          lines = ['', comment(0, "#{name}:")]
          entries.each do |key, value, about|
            lines << comment(1, "# #{about}")
            lines.concat(yaml_lines(key, value, 1))
          end
          lines
        end

        def detectors_section
          sample = ::Driftless::Detectors.registry.map(&:key).sort.first
          lines  = ['',
                    '## `only` and `skip` select which detectors run; `defaults` applies to',
                    '## every detector; a detector key overrides defaults for that one.',
                    comment(0, 'detectors:'),
                    comment(1, '# Run only these detector keys'),
                    *yaml_lines('only', [sample], 1),
                    comment(1, '# Skip these detector keys'),
                    *yaml_lines('skip', [sample], 1),
                    comment(1, 'defaults:')]
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
