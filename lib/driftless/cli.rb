require 'optparse'
require 'json'

require 'driftless'

module Driftless
  module CLI
    module_function

    def parse(argv)
      argv = argv.dup
      global_opts = {}

      global_parser = OptionParser.new do |o|
        o.banner = 'Usage: driftless [global-options] <subcommand> [subcommand-options]'
        o.separator ''
        o.separator 'Subcommands:'
        o.separator '    scan              Cross-reference control repo against PuppetDB reports'
        o.separator '    list-detectors    Print all detector keys and their descriptions'
        o.separator '    version           Print the driftless version'
        o.separator ''
        o.separator 'Global options:'
        o.on('-v', '--verbose', 'Verbose output')         { global_opts[:verbose] = true }
        o.on('-q', '--quiet',   'Suppress non-error output') { global_opts[:quiet]   = true }
        o.on('-h', '--help',    'Show this help')         { puts o; return 0 }
        o.separator ''
        o.separator 'Run `driftless <subcommand> --help` for subcommand-specific options.'
      end

      begin
        global_parser.order!(argv)
      rescue OptionParser::ParseError => e
        warn e.message
        warn global_parser.help
        return 2
      end

      case (sub = argv.shift)
      when 'scan'                 then run_scan(argv, global_opts)
      when 'list-detectors'       then run_list_detectors(argv, global_opts)
      when 'version', '--version' then puts Driftless::VERSION; 0
      when nil                    then warn global_parser.help; 2
      else                             warn "unknown subcommand: #{sub}"; warn global_parser.help; 2
      end
    end

    def run_scan(argv, _global_opts)
      opts = { fail_on: 'any' }

      parser = OptionParser.new do |o|
        o.banner = 'Usage: driftless scan --repo-dir=DIR --incoming-dir=DIR [options]'
        o.separator ''
        o.separator 'Required:'
        o.on('--repo-dir=DIR',        'Path to the control repo environment')       { |v| opts[:repo_dir]     = v }
        o.on('--incoming-dir=DIR',    'Path to the PuppetDB report intake dir')     { |v| opts[:incoming_dir] = v }
        o.separator ''
        o.separator 'Filtering:'
        o.on('--only=KEYS', Array,    'Run only these detector keys (comma-sep)')   { |v| opts[:only]         = v }
        o.on('--skip=KEYS', Array,    'Skip these detector keys (comma-sep)')       { |v| opts[:skip]         = v }
        o.separator ''
        o.separator 'Output:'
        o.on('--output=FMT', %w[json text], 'Output format: json or text (default: text on TTY, json otherwise)') { |v| opts[:output]      = v }
        o.on('--output-file=PATH',    'Write output to this file instead of stdout') { |v| opts[:output_file]  = v }
        o.separator ''
        o.separator 'Other:'
        o.on('--basemodulepath=PATH', 'Override $basemodulepath (colon-separated)') { |v| opts[:basemodulepath] = v.split(':') }
        o.on('--fail-on=WHEN', %w[any never], 'Exit non-zero on findings: any (default) or never') { |v| opts[:fail_on] = v }
        o.on('-h', '--help',          'Show this help')                             { puts o; return 0 }
      end

      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError => e
        warn e.message
        warn parser.help
        return 2
      end

      unless opts[:repo_dir] && opts[:incoming_dir]
        warn 'scan requires both --repo-dir and --incoming-dir'
        warn parser.help
        return 2
      end

      unless File.directory?(opts[:repo_dir])
        warn "repo-dir not readable: #{opts[:repo_dir]}"
        return 3
      end

      findings = Scan.new(
        repo_dir:       opts[:repo_dir],
        incoming_dir:   opts[:incoming_dir],
        only:           opts[:only],
        skip:           opts[:skip],
        basemodulepath: opts[:basemodulepath],
      ).run

      emit(findings, opts)

      return 0 if opts[:fail_on] == 'never'
      findings.empty? ? 0 : 1
    end

    def run_list_detectors(_argv, _global_opts)
      max_key_length = Detectors.registry.map{ |k| k.key.size }.max
      Detectors.registry.each do |klass|
        puts "#{klass.key.ljust(max_key_length)}   #{klass.about}"
      end
      0
    end

    def emit(findings, opts)
      format = opts[:output] || ($stdout.tty? ? 'text' : 'json')
      out    = opts[:output_file] ? File.open(opts[:output_file], 'w') : $stdout

      case format
      when 'json'
        out.puts JSON.pretty_generate(findings.map(&:to_h))
      else
        if findings.empty?
          out.puts 'no findings'
        else
          findings.each { |f| out.puts "#{f.key}\t#{f.path || '-'}:#{f.line || '-'}\t#{f.message}" }
        end
      end
    ensure
      out.close if out && out != $stdout
    end
  end
end
