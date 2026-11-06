require 'fileutils'

require 'pupgrade/cli/base'
require 'pupgrade/cli/config'
require 'pupgrade/config'
require 'pupgrade/config_validator'
require 'pupgrade/config_keys'

module Pupgrade
  module CLI
    class Config
      # `pupgrade config new`
      #
      # A pupgrade.yaml listing every known key under its subsystem, each
      # commented out with its default or an example, or set live by a
      # `<subsystem.key>=<value>` argument. The file is inert as written.
      # `--dir` writes the whole `pupgrade/` tree around it, each file a
      # skeleton of comments, and `--gitignore` lists what the tree writes
      # during runs in the control repo's .gitignore.
      class New < Base
        register_command name: 'new', subcommand_of: Config
        desc 'Write a pupgrade.yaml listing every known key (commented out, or set by key=value arguments), or the whole pupgrade/ tree'
        skip_config_load # so a broken pupgrade.yaml can be replaced
        positional '[<subsystem.key>=<value> ...]'

        # Section order of the generated file; a subsystem not listed here
        # follows alphabetically.
        SUBSYSTEM_ORDER = %w[compile lookup surface modules solve impact output logging].freeze

        # The files `--dir` writes beside pupgrade.yaml, each inert: comments
        # and the README's example of it.
        SKELETONS = {
          'compiler/enc.yaml' => <<~'YAML',
            # What an ENC would tell the compiler about each node: top-scope
            # variables and classes, from rules applied in order, later ones winning.
            # A value interpolates ${certname}, ${facts.a.b}, ${trusted.a.b}, and
            # ${vars.name}, each with an optional [/regexp/, n] taking a capture.
            #
            # rules:
            #   - set:                              # every node
            #       role: role::base
            #   - when:
            #       certname: 'pup*'                # a glob on the certname
            #     set:
            #       role: role::puppetserver
            #     classes: [profile::puppetserver]
            #   - when:
            #       facts.os.family: [RedHat]       # a fact, any of the values
            #     set:
            #       pkg_manager: dnf
            #   - set:
            #       site: '${certname[/\A[^.]+\.([^.]+)\./, 1]}'   # a regexp capture
            #       family: '${facts.os.family}'
          YAML
          'compiler/mocks.yaml' => <<~'YAML',
            # Answers for what module code asks the system while compiling: commands
            # (the first entry whose match fits and whose when holds), facts merged
            # over the factset's per node, and Puppet functions answered without
            # running. `pupgrade catalog compile --show-default-mocks` prints the
            # mocks pupgrade applies after yours.
            #
            # commands:
            #   - match: '^hostname'                  # a regexp against the command line
            #     stdout: "${facts.networking.fqdn}\n" # may reference the node's facts
            #   - match: '\Asystemctl is-active '
            #     exit: 3                             # a mocked exit status
            #     when:                               # only on nodes whose facts match
            #       os.family: [RedHat, Debian]
            #   - match: 'systemctl list-unit-files'
            #     action: allow                       # run it for real, but record it
            # facts:                                  # merged over the factset's facts, per node
            #   fips_enabled: false
            # functions:                              # Puppet functions answered without running
            #   - name: puppetdb_query
            #     returns: []
            #     when:
            #       os.family: RedHat
          YAML
          'compiler/mocks.rb' => <<~'RUBY',
            # Plain Ruby for what the YAML cannot say, loaded after enc.yaml; each
            # block gets the node as resolved so far. A block returning nil declines.
            #
            # variable(:tenant) { |node| node['site'] == 'b' ? 'blue' : 'green' }
            # classes  { |node| ['profile::el'] if node.fact('os.family') == 'RedHat' }
            # mock(/\Arpm -q (\S+)\z/) { |node, m| "#{m[1]}-1.0-1.el9\n" }
            # function('puppetdb_query') { |node, query| [] if node.certname.start_with?('db') }
            # fact('os.selinux.enabled') { |node| false if node.fact('os.family') == 'Debian' }
          RUBY
          'compiler/before.pp' => <<~'PP',
            # Puppet code evaluated before the manifest (or --code), for the resources
            # only production has; a site or error in it reads before.pp:LINE.
            #
            # $site_region = 'us-east'
          PP
          'branches.yaml' => <<~'YAML',
            # The branch each tag-pinned module follows, for solve, module releases,
            # and module info (config: modules.branchfile). `module releases MODULE
            # --branch B` records a line here.
            #
            # puppetlabs-stdlib: main
            # acme-maint: 1.x
          YAML
        }.freeze

        # Directories `--dir` creates empty, and `--gitignore` lists.
        WRITTEN_DIRS = %w[cache logs].freeze

        def execute(argv)
          @given = assignments(argv)
          return scaffold(@options[:dir]) if @options[:dir]

          fatal!('config new: --gitignore goes with --dir', help: true) if @options[:gitignore]
          path = @options[:path] || ::Pupgrade::Config.project_path

          if path.match?(/\A-+\Z/)
            puts render
            exit 0
          end

          if File.exist?(path) && !@options[:force]
            fatal!("#{path} already exists (pass --force to overwrite)", 3)
          end

          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, render)
          puts "wrote #{path}"
          exit 0
        end

        protected

        def configure_parser(o)
          o.on('-p', '--path=PATH',
               'Write to PATH instead of ./pupgrade/pupgrade.yaml (directories are created)',
               "('--' prints to STDOUT)") { |v| @options[:path] = v }
          o.on('--dir [DIR]', 'Write the whole tree under DIR (default: pupgrade): pupgrade.yaml, compiler/{enc.yaml,mocks.yaml,',
               'mocks.rb,before.pp}, branches.yaml as skeletons, cache/ and logs/; a file already there is kept',
               '(give DIR with = when key=value arguments follow)') { |v| @options[:dir] = v || 'pupgrade' }
          o.on('--[no-]gitignore', 'With --dir, list DIR/cache/ and DIR/logs/ in the .gitignore beside DIR, once') { |v| @options[:gitignore] = v }
          o.on('--force', 'Overwrite an existing file') { @options[:force] = true }
          o.separator ''
          o.separator 'Arguments:'
          o.separator '    <subsystem.key>=<value>          Render that key set to <value> instead of'
          o.separator '                                     commented out. Array keys split the value'
          o.separator '                                     on commas: compile.factsets=spec/factsets,more'
        end

        private

        # Writes the tree under `dir`: pupgrade.yaml as rendered, the
        # skeletons, and the empty directories; a file already there is kept
        # unless --force. Lists DIR/cache/ and DIR/logs/ in the .gitignore of
        # DIR's parent when asked, each line once.
        def scaffold(dir)
          fatal!('config new: --dir places pupgrade.yaml in DIR; --path cannot be given with it', help: true) if @options[:path]

          files = { 'pupgrade.yaml' => render }.merge(SKELETONS)
          files.each do |name, content|
            path = File.join(dir, name)
            if File.exist?(path) && !@options[:force]
              puts "kept #{path} (exists; --force overwrites)"
              next
            end
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, content)
            puts "wrote #{path}"
          end
          WRITTEN_DIRS.each do |name|
            path = File.join(dir, name)
            next if File.directory?(path)

            FileUtils.mkdir_p(path)
            puts "created #{path}/"
          end
          gitignore(dir) if @options[:gitignore]
          exit 0
        end

        # Appends `DIR/cache/` and `DIR/logs/` to the .gitignore beside DIR,
        # those not already on a line of their own.
        def gitignore(dir)
          path  = File.join(File.dirname(dir), '.gitignore').delete_prefix('./')
          lines = WRITTEN_DIRS.map { |name| "#{File.basename(dir)}/#{name}/" }
          text  = File.exist?(path) ? File.read(path) : ''
          have  = text.lines.map(&:strip)
          add   = lines.reject { |l| have.include?(l) || have.include?(l.chomp('/')) }
          if add.empty?
            puts "#{path} already lists #{lines.join(', ')}"
            return
          end

          text += "\n" unless text.empty? || text.end_with?("\n")
          File.write(path, text + add.map { |l| "#{l}\n" }.join)
          puts "#{path}: added #{add.join(', ')}"
        end

        # Parses the `<subsystem.key>=<value>` arguments, each value coerced
        # by its key's declared type.
        #
        # @param argv [Array<String>] positionals left after option parsing
        # @return [Hash{String => Hash}] {subsystem => {name => value}},
        #   names kept dotted
        # @raise [SystemExit] on a malformed or undeclared argument, via fatal!
        def assignments(argv)
          given = {}
          argv.each do |arg|
            path, eq, raw      = arg.partition('=')
            subsystem, _, name = path.partition('.')
            if eq.empty? || subsystem.empty? || name.empty?
              fatal!("config new: expected <subsystem.key>=<value>, got #{arg.inspect}", help: true)
            end
            (given[subsystem] ||= {})[name] = coerce(path, raw)
          end
          check_assignments!(given)
          given
        end

        # Runs the parsed assignments through the validator.
        #
        # @raise [SystemExit] on a key that cannot be set
        def check_assignments!(given)
          return if given.empty?

          merged = given.transform_values do |keys|
            keys.map { |name, value| nested(name, value) }
              .reduce({}) { |acc, h| ::Pupgrade::Config.deep_merge(acc, h) }
          end
          ::Pupgrade::ConfigValidator.new(::Pupgrade::Config.new(merged: merged)).validate!
        rescue ::Pupgrade::ConfigValidationError => e
          fatal!("config new: #{e.message}", help: true)
        end

        # By the key's declared type; an unknown or withheld path keeps the
        # raw string for check_assignments! to reject by name.
        def coerce(path, raw)
          case ::Pupgrade::ConfigKeys[path]&.type
          when :array   then raw.split(',')
          when :boolean then coerce_boolean(path, raw)
          when :integer then coerce_integer(path, raw)
          when :hash    then fatal!("config new: #{path} takes a mapping; set it in the file", help: true)
          else               raw
          end
        end

        def coerce_boolean(path, raw)
          return true  if raw == 'true'
          return false if raw == 'false'

          fatal!("config new: #{path} expects true or false, got #{raw.inspect}", help: true)
        end

        def coerce_integer(path, raw)
          Integer(raw)
        rescue ArgumentError
          fatal!("config new: #{path} expects an integer, got #{raw.inspect}", help: true)
        end

        # Commented-out line(s) at `depth` levels of YAML nesting.
        def comment(depth, text, cols = 80)
          text_prefix = text.start_with?('# ') ? '# ' : ''
          bare_text = text.sub(/\A#{text_prefix}/, '')
          comment_prefix = "# #{'  ' * depth}"
          return comment_prefix.strip if text.empty?

          lines = wrap_text(bare_text, cols - comment_prefix.size).split("\n")
          lines.map { |t| "#{comment_prefix}#{text_prefix}#{t}".strip }.join("\n")
        end

        # {'git' => {'repo' => value}} for a dotted key name; a plain name is
        # a one-level hash.
        def nested(name, value)
          name.to_s.split('.').reverse.reduce(value) { |acc, seg| { seg => acc } }
        end

        # The key/value as YAML body lines, stripped of the document header;
        # a dotted key renders as nested mappings.
        def yaml_body(key, value)
          nested(key, value).to_yaml.sub(/\A---\n/, '').chomp.lines.map(&:chomp)
        end

        # Renders key/value as YAML, then comments every line at `depth`.
        def yaml_lines(key, value, depth)
          yaml_body(key, value).map { |l| comment(depth, l) }
        end

        # Renders key/value as YAML indented `depth` levels, left uncommented.
        def live_lines(key, value, depth)
          yaml_body(key, value).map { |l| "#{'  ' * depth}#{l}" }
        end

        # The about text as an active YAML comment at `depth`, for above a
        # live key: one commenting layer fewer than comment() emits.
        def live_comment(depth, text, cols = 80)
          prefix = "#{'  ' * depth}# "
          wrap_text(text, cols - prefix.size).split("\n").map { |t| "#{prefix}#{t}" }.join("\n")
        end

        # Wraps text at the nearest whitespace to `col` characters.
        def wrap_text(txt, col = 80)
          txt.gsub(
            /(?:((?>.{1,#{col}}(?:(?<=[^\S\r\n])[^\S\r\n]?|(?=\r?\n)|$|[^\S\r\n]))|.{1,#{col}})(?:\r?\n)?|(?:\r?\n|$))/,
            "\\1\n",
          ).chomp
        end

        def render
          require 'time'
          @given ||= {}
          lines = ['## pupgrade configuration file',
                   '## ' + ('-' * 77),
                   '## - All local paths are relative to the control repo (--repo-dir)',
                   '## - Commented-out keys show default or example values',
                   "## - (This files was orignally generated at #{Time.now} by `pupgrade config new`)",
                   '## ' + ('-' * 77)]
          subsystems.each { |name| lines.concat(subsystem_section(name)) }
          lines.concat([comment(0, '')])
          lines = lines.map { |x| x.split("\n") }.flatten
          lines.map! { |x| x.gsub(/\s+$/, '') }
          "#{lines.join("\n")}\n"
        end

        def subsystems
          ::Pupgrade::ConfigKeys.subsystems
            .sort_by { |name| [SUBSYSTEM_ORDER.index(name) || SUBSYSTEM_ORDER.size, name] }
        end

        def subsystem_section(name)
          set   = @given.fetch(name, {})
          lines = ['', set.empty? ? comment(0, "#{name}:") : "#{name}:"]
          ::Pupgrade::ConfigKeys.settable(name).each do |key|
            if set.key?(key.name)
              lines << live_comment(1, key.about) if key.about
              lines.concat(live_lines(key.name, set[key.name], 1))
            else
              lines << comment(1, "# #{key.about}") if key.about
              lines.concat(yaml_lines(key.name, sample_value(key), 1))
            end
          end
          lines << '#'
        end

        # A type-shaped placeholder when a key declares neither a default nor
        # an example.
        def sample_value(key)
          return key.sample unless key.sample.nil?

          case key.type
          when :array   then []
          when :hash    then {}
          when :boolean then false
          when :integer then 0
          else               ''
          end
        end
      end
    end
  end
end
