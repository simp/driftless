# frozen_string_literal: true

# Selective diagnostics for onceover spec runs, loaded from the `before:`
# block of spec/onceover.yaml:
#
#   before:
#     - |
#       require "#{RSpec.configuration.onceover_root}/spec/onceover_probes"
#       OnceoverProbes.exec_trace                       # who launches subprocesses
#       OnceoverProbes.trace_lookups(/^role::x::/)      # explain matching lookup()/APL keys
#       OnceoverProbes.trace_facts('os', /^kernel/)     # reads of matching facts
#       OnceoverProbes.trace_types                      # types/providers loaded and used
#
# The `before:` block runs before every example, so every method here can be
# called repeatedly: hooks are installed once and only the settings refresh.
#
# Output goes through Puppet's logger (visible with SHOW_PUPPET_OUTPUT=true)
# and falls back to stderr when Puppet has no log destination. The exec trace
# additionally writes a full record to a file so the console only carries a
# short summary (CI logs are size-limited).
require 'puppet'
require 'set'

module OnceoverProbes
  GEM_FRAME = %r{/gems/(openvox|puppet|openfact|facter|rspec|onceover|voxpupuli|parallel_tests|rake|bundler|backticks)[-/]|/lib/ruby/\d|<internal:}

  # Facts hash that reports reads of selected keys.
  class TracedFacts < Hash
    def self.wrap(hash)
      traced = new
      hash.each { |k, v| traced[k] = v }
      traced
    end

    def [](key)
      OnceoverProbes.fact_read(key)
      super
    end

    def fetch(key, *rest, &block)
      OnceoverProbes.fact_read(key)
      super
    end

    def dig(key, *rest)
      OnceoverProbes.fact_read(key)
      super
    end
  end

  class << self
    # ------------------------------------------------------------------ output

    def emit(message, level = :notice)
      if Puppet::Util::Log.destinations.empty?
        $stderr.puts "#{level.to_s.capitalize}: #{message}"
      else
        Puppet.send(level, message)
      end
    end

    def example_label
      example = RSpec.current_example if defined?(RSpec) && RSpec.respond_to?(:current_example)
      example ? example.full_description : '(outside any example)'
    end

    # "file:line" of the innermost Puppet function call in progress, or nil.
    # Puppet only records function calls on its stack, so a read inside a
    # class body is reported at the `include`/`notice`/... call surrounding it.
    # The generated test manifest has no file and shows as "test manifest".
    def puppet_location
      top = Puppet::Pops::PuppetStack.top_of_stack
      file, line = top if top.is_a?(Array)
      return nil unless file

      file = file == 'unknown' ? 'test manifest' : short_path(file)
      "#{file}:#{line}"
    rescue StandardError
      nil
    end

    def short_path(path)
      path.to_s.sub(%r{.*/gems/}, '').sub("#{Dir.pwd}/", '')
    end

    def frame_str(frame)
      "#{short_path(frame.path)}:#{frame.lineno} in #{frame.label}"
    end

    # ------------------------------------------------------ subprocess tracing

    # Record every subprocess launch with the Ruby frames that requested it.
    #   file:          full record; default <onceover tempdir>/exec_trace.<pid>.log
    #   only:          Regexp or String; record only commands matching it
    #   summary_lines: cap on unique commands printed at exit
    def exec_trace(file: nil, only: nil, summary_lines: 20)
      @exec_only = only && (only.is_a?(Regexp) ? only : Regexp.new(only.to_s))
      @exec_summary_lines = summary_lines
      @exec_file = file || File.join(default_dir, "exec_trace.#{Process.pid}.log")
      install_exec_hooks unless @exec_hooks_installed
    end

    def default_dir
      RSpec.configuration.respond_to?(:onceover_tempdir) ? RSpec.configuration.onceover_tempdir : Dir.pwd
    end

    def install_exec_hooks
      @exec_hooks_installed = true
      @exec_events = Hash.new(0)
      @exec_total  = 0
      File.open(@exec_file, 'a') { |f| f.puts "# exec trace, pid #{Process.pid}, started #{Time.now}" }

      # Outer hooks mark the thread so the lower-level calls they make
      # (fork/spawn/popen) are not recorded a second time.
      outer = [
        [Puppet::Util::Execution.singleton_class, :execute],
        [Puppet::Util::Execution.singleton_class, :execpipe],
      ]
      if defined?(Facter::Core::Execution)
        outer << [Facter::Core::Execution.singleton_class, :execute]
        outer << [Facter::Core::Execution.singleton_class, :exec]
      end
      leaf = [
        [Kernel, :`], [Kernel, :system], [Kernel, :spawn],
        [Kernel.singleton_class, :`], [Kernel.singleton_class, :system], [Kernel.singleton_class, :spawn],
        [Process.singleton_class, :spawn],
        [IO.singleton_class, :popen],
      ]
      outer.each { |target, meth| target.prepend(exec_hook(meth, mark: true)) }
      leaf.each  { |target, meth| target.prepend(exec_hook(meth, mark: false)) }
      at_exit { exec_summary }
    end

    def exec_hook(meth, mark:)
      Module.new do
        define_method(meth) do |*args, **kwargs, &block|
          call_super = -> { kwargs.empty? ? super(*args, &block) : super(*args, **kwargs, &block) }
          if Thread.current[:onceover_probes_exec]
            call_super.call
          else
            OnceoverProbes.record_exec(meth, args)
            if mark
              begin
                Thread.current[:onceover_probes_exec] = true
                call_super.call
              ensure
                Thread.current[:onceover_probes_exec] = nil
              end
            else
              call_super.call
            end
          end
        end
      end
    end

    def record_exec(meth, args)
      command = args.flatten.reject { |a| a.is_a?(Hash) }.map(&:to_s).join(' ').strip[0, 300]
      return if @exec_only && command !~ @exec_only

      frames = (caller_locations(1, 100) || []).reject { |f| f.path == __FILE__ }
      # origin: the nearest frame outside Puppet/Facter/RSpec; via: the immediate caller
      own = frames.reject { |f| f.path =~ GEM_FRAME }
      origin = own.first || frames.first
      via = frames.first
      top = origin ? frame_str(origin) : ''
      top += " (via #{frame_str(via)})" if via && via != origin

      @exec_events[[command, top]] += 1
      @exec_total += 1
      File.open(@exec_file, 'a') do |f|
        f.puts "#{Time.now.strftime('%H:%M:%S')} #{meth} #{command}"
        f.puts "  example: #{example_label}"
        location = puppet_location
        f.puts "  puppet:  #{location}" if location
        f.puts "  via:     #{frame_str(via)}" if via
        own.first(3).each { |frame| f.puts "  origin:  #{frame_str(frame)}" }
      end
    rescue StandardError => e
      $stderr.puts "[exec-trace] failed to record: #{e.class}: #{e.message}"
    end

    def exec_summary
      return unless @exec_events

      lines = @exec_events.sort_by { |_key, count| -count }
      $stderr.puts "[exec-trace] #{@exec_total} subprocess launches, #{lines.size} unique, pid #{Process.pid}; details in #{@exec_file}"
      lines.first(@exec_summary_lines).each do |(command, top), count|
        $stderr.puts "[exec-trace] #{count}x #{command}"
        $stderr.puts "[exec-trace]     #{top}" unless top.empty?
      end
      hidden = lines.size - @exec_summary_lines
      $stderr.puts "[exec-trace] ... #{hidden} more unique commands in the log" if hidden.positive?
    end

    # --------------------------------------------------------- lookup tracing

    # Explain lookup() calls and automatic parameter lookups whose key matches
    # one of the patterns (Regexp, or String for an exact match).
    #   max_lines: cap on the explanation printed per lookup; multi-line value
    #              dumps (e.g. the whole $facts hash during interpolation) are
    #              always collapsed to one line.
    def trace_lookups(*patterns, level: :notice, max_lines: 40)
      @lookup_patterns = compile_patterns(patterns)
      @lookup_level = level
      @lookup_max_lines = max_lines
      install_lookup_hooks unless @lookup_hooks_installed
    end

    def install_lookup_hooks
      @lookup_hooks_installed = true
      probes = self
      Puppet::Pops::Lookup.singleton_class.prepend(Module.new do
        define_method(:lookup) do |name, value_type, default_value, has_default, merge, invocation, &block|
          probes.explain_lookup('Lookup', name, invocation) do
            super(name, value_type, default_value, has_default, merge, invocation, &block)
          end
        end

        define_method(:search_and_merge) do |name, invocation, merge, apl = true|
          if apl
            probes.explain_lookup('Automatic Parameter Lookup', name, invocation) do
              super(name, invocation, merge, apl)
            end
          else
            super(name, invocation, merge, apl)
          end
        end
      end)
    end

    def explain_lookup(kind, name, invocation)
      names = Array(name)
      return yield unless invocation.explainer.nil? && names.any? { |n| matches?(@lookup_patterns, n) }

      explainer = Puppet::Pops::Lookup::Explainer.new
      invocation.instance_variable_set(:@explainer, explainer)
      begin
        yield
      ensure
        text = String.new
        explainer.dump_on(text, '  ', '  ')
        location = puppet_location
        keys = names.map { |n| "'#{n}'" }.join(', ')
        emit("#{kind} of #{keys}#{location ? " at #{location}" : ''}\n#{condense(text)}", @lookup_level)
      end
    end

    # Collapse multi-line value dumps to one line and cap the total length.
    def condense(text)
      out = []
      skipping_indent = nil
      skipped = 0
      text.each_line do |line|
        line = line.chomp
        if skipping_indent
          if line =~ /\A#{skipping_indent}[\]}]/ && line[/\A */].length == skipping_indent.length
            out[-1] = "#{out[-1]}...#{skipped} lines...#{line.strip}"
            skipping_indent = nil
          else
            skipped += 1
          end
          next
        end
        out << line
        if line =~ /value: [\[{]\z/
          skipping_indent = line[/\A */]
          skipped = 0
        end
      end
      if out.size > @lookup_max_lines
        hidden = out.size - @lookup_max_lines
        out = out.first(@lookup_max_lines) << "  ... #{hidden} more lines (raise max_lines to see them)"
      end
      out.join("\n")
    end

    # ----------------------------------------------------------- fact tracing

    # Report reads of matching facts through $facts[...], %{facts.x} in
    # hiera.yaml, and top-scope variables ($::kernel).
    def trace_facts(*patterns, level: :notice)
      @fact_patterns = compile_patterns(patterns)
      @fact_level = level
      @fact_seen = Set.new
      install_fact_hooks unless @fact_hooks_installed
    end

    def install_fact_hooks
      @fact_hooks_installed = true
      probes = self
      Puppet::Parser::Scope.prepend(Module.new do
        define_method(:set_facts) do |hash|
          super(TracedFacts.wrap(hash))
        end

        define_method(:lookupvar) do |name, options = Puppet::Parser::Scope::EMPTY_HASH|
          if name.to_s =~ /\A(::)?[a-z0-9_]+\z/
            owner = source.respond_to?(:name) ? source.name : nil
            probes.fact_read(name.to_s.sub(/\A::/, ''), 'variable', owner)
          end
          super(name, options)
        end
      end)
    end

    def fact_read(key, how = 'fact', owner = nil)
      return unless @fact_patterns && matches?(@fact_patterns, key)

      location = puppet_location || example_label
      location += " in #{owner}" if owner
      return unless @fact_seen.add?([key, how, location])

      emit("Read of #{how} '#{key}' at #{location}", @fact_level)
    end

    # ----------------------------------------------------- type/provider use

    # Report Puppet types and providers as they are loaded, and the provider
    # each resource type ends up with when rspec-puppet turns the catalog into
    # RAL resources. With per_example: true the "used" lines repeat per example.
    def trace_types(level: :notice, per_example: false)
      @types_level = level
      @types_seen = Set.new if per_example || @types_seen.nil?
      install_type_hooks unless @type_hooks_installed
    end

    def install_type_hooks
      @type_hooks_installed = true
      probes = self
      Puppet::Type.singleton_class.prepend(Module.new do
        define_method(:newtype) do |name, options = {}, &block|
          origin = caller_locations(1, 1).first
          result = super(name, options, &block)
          probes.type_event("Type loaded: #{name} (#{probes.short_path(origin.path)})")
          result
        end

        define_method(:provide) do |name, options = {}, &block|
          origin = caller_locations(1, 1).first
          result = super(name, options, &block)
          probes.type_event("Provider loaded: #{self.name}/#{name} (#{probes.short_path(origin.path)})")
          result
        end
      end)
      Puppet::Type.prepend(Module.new do
        define_method(:provider=) do |name|
          super(name)
          pair = [self.class.name, @provider.class.name]
          probes.type_event("Provider used: #{pair.join('/')} (first on #{ref} in #{probes.example_label})", pair)
        end
      end)
    end

    def type_event(message, once_key = nil)
      return if once_key && !@types_seen.add?(once_key)

      emit(message, @types_level)
    end

    # ---------------------------------------------------------------- helpers

    def compile_patterns(patterns)
      patterns.flatten.map { |p| p.is_a?(Regexp) ? p : /\A#{Regexp.escape(p.to_s)}\z/ }
    end

    def matches?(patterns, value)
      value = value.to_s
      patterns.any? { |p| p.match?(value) }
    end
  end
end
