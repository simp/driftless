#!/usr/bin/env ruby
# frozen_string_literal: true
# ------------------------------------------------------------------------------
# Build a `_summary.json` for a hand-collected report session
# ------------------------------------------------------------------------------
# For when no collector ran: someone pasted PQL into the PuppetDB console (or
# ran curl) and saved the answers as files. This describes that directory the
# way driftless-collect-puppetdb-reports.rb would have, so that
# `driftless import local` and driftless-store-reports-in-git.rb accept it:
#
#   <session-dir>/
#   ├── _summary.json                          <- written by this script
#   ├── all-active-nodes.ndjson
#   ├── factsets-for-all-active-nodes.ndjson
#   └── classes-for-all-active-nodes.ndjson
#
# Report names come from file basenames; `--report NAME=FILE` overrides.
#
# Both importers copy each declared report to `<collector>--<session>.ndjson`,
# and the reader parses that name one JSON object per line. A file holding a
# single JSON document (an array, as PuppetDB's API returns) is therefore
# rewritten as newline-delimited rows first: to `<base>.ndjson` for a `.json`
# input, in place for a `.ndjson` one. `--no-convert-json` skips the rewrite and
# declares the file as-is, which stages bytes the reader cannot parse.
#
# Env vars honored (all optional):
#
#   DRIFTLESS_COLLECTOR   default for --collector
#
# Exit status: 0 all reports ok, 1 some report failed, 2 usage error.
# ------------------------------------------------------------------------------

require 'digest'
require 'json'
require 'logger'
require 'optparse'
require 'time'

STAGER_VERSION = '1.0.0'

# Reports Driftless::Inputs::ReportLoader reads. A session missing any of them
# is quarantined by `driftless import cleanup` and refused by `driftless scan`
# unless --accept-partial-report-sessions is passed.
EXPECTED_REPORTS = %w[
  all-active-nodes
  factsets-for-all-active-nodes
  classes-for-all-active-nodes
].freeze

# Report names the collector knows about; anything else is staged with a warning.
KNOWN_REPORTS = (EXPECTED_REPORTS + %w[fips-enabled-nodes]).freeze

# What the collector names a session, and what the importers sort on to pick
# the newest session for a collector.
SESSION_ID_FORMAT = '%Y-%m-%dT%H-%M-%SZ'
SESSION_ID_RE     = /\A\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z\z/.freeze

class StagingError < StandardError; end

# Rows in a report file, whichever way it was saved. Returns
# [rows, :lines | :document]; :document means the bytes on disk are one JSON
# value and need rewriting as ndjson before an importer copies them.
#
# The extension picks which shape to try first, but content decides: a `.json`
# file holding ndjson, or a `.ndjson` file holding a JSON array, both load.
def read_report(path)
  text = File.read(path)
  return [[], :lines] if text.strip.empty?

  attempts = path.end_with?('.ndjson') ? %i[lines document] : %i[document lines]
  errors   = {}
  attempts.each do |mode|
    rows = (mode == :lines ? parse_lines(text) : parse_document(text))
    # A one-line JSON array parses as a single row of the wrong shape, so the
    # row check belongs here: failing it sends the file to the other reader.
    return [check_rows!(rows), mode]
  rescue JSON::ParserError, StagingError => e
    errors[mode] = e.message
  end
  raise StagingError, "cannot read as rows (as a JSON document: #{errors[:document]}; as NDJSON: #{errors[:lines]})"
end

def parse_lines(text)
  rows = []
  text.each_line.with_index(1) do |line, lineno|
    line = line.strip
    next if line.empty?
    begin
      rows << JSON.parse(line)
    rescue JSON::ParserError => e
      raise JSON::ParserError, "line #{lineno}: #{e.message}"
    end
  end
  rows
end

def parse_document(text)
  doc = JSON.parse(text)
  case doc
  when Array then doc
  when Hash  then [doc]
  else raise StagingError, "top-level JSON is #{doc.class}, expected an array of rows or one row object"
  end
end

# PuppetDB rows are objects; anything else will not survive the reader, which
# indexes every row by its 'certname'.
def check_rows!(rows)
  bad = rows.each_with_index.find { |row, _i| !row.is_a?(Hash) }
  raise StagingError, "row #{bad[1] + 1} is #{bad[0].class}, expected a JSON object" if bad
  rows
end

# The ndjson bytes for rows — written on a real run, hashed on a dry one, so
# the summary reports the same checksum either way.
def ndjson_body(rows)
  rows.map { |r| JSON.dump(r) + "\n" }.join
end

# The report files in session_dir, as [{path:, file:, name:}], with names from
# `--report NAME=FILE` taking precedence over the file basename.
def discover_reports(session_dir, name_overrides, log)
  by_file = {}
  Dir.children(session_dir).sort.each do |file|
    next if file.start_with?('.', '_')
    next unless file.end_with?('.json', '.ndjson')
    path = File.join(session_dir, file)
    next unless File.file?(path)
    by_file[file] = { path: path, file: file, name: canonical_name(File.basename(file, '.*')) }
  end

  name_overrides.each do |name, file|
    entry = by_file[file]
    raise StagingError, "--report #{name}=#{file}: no such file in #{session_dir}" unless entry
    log.debug("report name override: #{file} -> #{name}")
    entry[:name] = name
  end

  by_name = by_file.values.group_by { |e| e[:name] }
  by_name.each do |name, entries|
    next if entries.size == 1
    # `<base>.json` beside the `<base>.ndjson` a previous run converted it to:
    # the ndjson is the staged form, so re-running stays idempotent.
    superseded = entries.select { |e| e[:file].end_with?('.json') && entries.any? { |o| o[:file] == "#{File.basename(e[:file], '.json')}.ndjson" } }
    entries.replace(entries - superseded)
    superseded.each { |e| log.warn("report #{name}: ignoring #{e[:file]} in favour of #{File.basename(e[:file], '.json')}.ndjson") }
    next if entries.size == 1

    raise StagingError,
          "#{entries.size} files claim the report name #{name.inspect} (#{entries.map { |e| e[:file] }.join(', ')}); " \
          'disambiguate with --report NAME=FILE'
  end

  by_name.values.flatten.sort_by { |e| e[:name] }
end

# Tolerate the underscore spelling of a known report name; leave anything else
# exactly as the operator named it.
def canonical_name(base)
  dashed = base.downcase.tr('_', '-')
  KNOWN_REPORTS.include?(dashed) ? dashed : base
end

# Both importers build filenames as `<collector>--<session-id>`, and the reader
# splits them back apart on the first '--'.
def check_identifiers!(collector, session_id)
  raise StagingError, 'collector name is empty' if collector.to_s.empty?
  raise StagingError, "collector #{collector.inspect} may not contain '--' (it separates collector from session id)" if collector.include?('--')
  raise StagingError, "collector #{collector.inspect} may not contain '/' or start with '.'" if collector.include?('/') || collector.start_with?('.')
  raise StagingError, 'session id is empty' if session_id.to_s.empty?
  raise StagingError, "session id #{session_id.inspect} may not contain '/' or start with '.'" if session_id.include?('/') || session_id.start_with?('.')
end

opts = {
  collector:    ENV['DRIFTLESS_COLLECTOR'],
  session_id:   nil,
  reports:      {},
  pql:          {},
  convert_json: true,
  force:        false,
  dry_run:      false,
  log_level:    Logger::INFO,
}

OptionParser.new do |o|
  collector_help = 'Contributor name the reports belong to (required; or DRIFTLESS_COLLECTOR)'
  collector_help += " [currently: #{opts[:collector]}]" unless opts[:collector].to_s.empty?

  o.banner = "Usage: #{$PROGRAM_NAME} [options] <session-dir>"
  o.on('--collector NAME',   collector_help) { |v| opts[:collector] = v }
  o.on('--session-id ID',    "Session id (default: session dir name if it looks like #{Time.now.utc.strftime(SESSION_ID_FORMAT)}, else newest report mtime)") { |v| opts[:session_id] = v }
  o.on('--report NAME=FILE', 'Name FILE as report NAME instead of using its basename (repeatable)') do |v|
    name, file = v.split('=', 2)
    raise OptionParser::InvalidArgument, v if file.to_s.empty?
    opts[:reports][name] = file
  end
  o.on('--pql NAME=QUERY',   'Record the PQL a report was collected with (repeatable; default: null)') do |v|
    name, query = v.split('=', 2)
    raise OptionParser::InvalidArgument, v if query.to_s.empty?
    opts[:pql][name] = query
  end
  o.on('--[no-]convert-json', 'Rewrite single-JSON-document reports as NDJSON so importers stage readable rows (default: yes)') { |v| opts[:convert_json] = v }
  o.on('--force',            'Overwrite an existing _summary.json')                    { opts[:force] = true }
  o.on('--dry-run',          'Print the summary to stdout; write and convert nothing') { opts[:dry_run] = true }
  o.on('-v', '--verbose',    'Log per-file decisions')                                 { opts[:log_level] = Logger::DEBUG }
  o.on('-h', '--help')       { puts o; exit 0 }
end.parse!

log = Logger.new($stderr)
log.level = opts[:log_level]
log.formatter = ->(sev, t, _p, msg) { "#{t.iso8601} #{sev} #{msg}\n" }

session_dir = ARGV.shift
if session_dir.nil? || session_dir.empty?
  warn 'error: session dir required (positional arg)'
  exit 2
end
unless File.directory?(session_dir)
  warn "error: not a directory: #{session_dir}"
  exit 2
end
if ARGV.any?
  warn "error: unexpected extra arguments: #{ARGV.join(' ')}"
  exit 2
end

if opts[:collector].to_s.empty?
  warn 'error: --collector is required (or set DRIFTLESS_COLLECTOR)'
  warn '       it names the PuppetDB the reports came from, and is not guessable from a manual dump'
  exit 2
end

summary_path = File.join(session_dir, '_summary.json')
if File.exist?(summary_path) && !opts[:force] && !opts[:dry_run]
  warn "error: #{summary_path} already exists; pass --force to overwrite"
  exit 2
end

begin
  found = discover_reports(session_dir, opts[:reports], log)
  if found.empty?
    if File.directory?(File.join(session_dir, 'sessions'))
      raise StagingError, "no .json/.ndjson report files in #{session_dir}; it looks like a reports root — point this at one of its sessions/<id> dirs"
    end
    raise StagingError, "no .json/.ndjson report files in #{session_dir}"
  end

  session_id =
    if opts[:session_id]
      log.debug('session id: from --session-id')
      opts[:session_id]
    elsif File.basename(File.expand_path(session_dir)).match?(SESSION_ID_RE)
      log.debug('session id: from session dir name')
      File.basename(File.expand_path(session_dir))
    else
      newest = found.map { |e| File.mtime(e[:path]) }.max.utc
      log.debug("session id: from newest report mtime (#{newest.iso8601})")
      newest.strftime(SESSION_ID_FORMAT)
    end

  check_identifiers!(opts[:collector], session_id)
  unless session_id.match?(SESSION_ID_RE)
    log.warn("session id #{session_id.inspect} is not in #{SESSION_ID_FORMAT} form; importers order sessions lexicographically, so it may not compare correctly against collector-produced ids")
  end

  log.info("session #{session_id} ← #{session_dir}")
  log.info("collector: #{opts[:collector]}")

  mtimes  = []
  reports = {}
  found.each do |entry|
    name = entry[:name]
    file = entry[:file]
    path = entry[:path]
    mtimes << File.mtime(path)
    log.warn("report #{name}: not a report name the collector produces (known: #{KNOWN_REPORTS.join(', ')})") unless KNOWN_REPORTS.include?(name)

    begin
      rows, mode = read_report(path)

      checksum = nil
      if mode == :document && opts[:convert_json]
        converted = File.join(session_dir, "#{File.basename(file, '.*')}.ndjson")
        body      = ndjson_body(rows)
        checksum  = Digest::SHA256.hexdigest(body)
        if opts[:dry_run]
          log.info("report #{name}: would rewrite #{file} as #{File.basename(converted)} (#{rows.size} rows, one per line)")
        else
          File.write(converted, body)
          if converted == path
            log.warn("report #{name}: #{file} held one JSON document; rewrote it in place as NDJSON")
          else
            log.info("report #{name}: wrote #{File.basename(converted)} from #{file} (#{rows.size} rows)")
          end
        end
        path = converted
        file = File.basename(converted)
        entry[:staged_from] = entry[:file] unless entry[:file] == file
      elsif mode == :document
        log.warn("report #{name}: #{file} holds one JSON document, not NDJSON; --no-convert-json was given, so importers will stage bytes the reader cannot parse")
      end

      log.info("report #{name}: #{rows.size} rows ← #{file}")
      log.warn("report #{name}: no rows") if rows.empty?
      reports[name] = {
        'file'               => file,
        'file_checksum'      => checksum || Digest::SHA256.file(path).hexdigest,
        'file_checksum_type' => 'SHA256',
        'pql'                => opts[:pql][name],
        'rows'               => rows.size,
        'status'             => 'ok',
        'source'             => 'manual',
      }
      reports[name]['staged_from'] = entry[:staged_from] if entry[:staged_from]
    rescue StagingError, JSON::ParserError, SystemCallError => e
      log.error("report #{name}: #{file}: #{e.message}")
      reports[name] = {
        'file'               => file,
        'file_checksum'      => (File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil),
        'file_checksum_type' => 'SHA256',
        'pql'                => opts[:pql][name],
        'rows'               => 0,
        'status'             => 'failed',
        'source'             => 'manual',
        'error'              => e.message,
      }
    end
  end

  missing = EXPECTED_REPORTS.reject { |r| reports[r] && reports[r]['status'] == 'ok' }
  unless missing.empty?
    log.warn("session has no usable #{missing.join(', ')}; `driftless import cleanup` will quarantine it and `driftless scan` will refuse it unless --accept-partial-report-sessions is passed")
  end

  now     = Time.now.utc
  summary = {
    'session_id'     => session_id,
    'collector'      => opts[:collector],
    'source'         => 'manual',
    'staged_by'      => "#{File.basename($PROGRAM_NAME)} #{STAGER_VERSION}",
    'staged_at'      => now.iso8601,
    'started_at'     => (mtimes.min || now).utc.iso8601,
    'completed_at'   => (mtimes.max || now).utc.iso8601,
    'reports'        => reports,
  }

  failed = reports.values.count { |r| r['status'] == 'failed' }

  if opts[:dry_run]
    log.info("dry-run: would write #{summary_path}")
    puts JSON.pretty_generate(summary)
  else
    File.write(summary_path, JSON.pretty_generate(summary) + "\n")
    log.info("wrote #{summary_path}")
  end

  log.info("done: #{reports.size} reports (#{failed} failed), #{reports.values.sum { |r| r['rows'] }} rows total")
  if failed.zero?
    log.info("stage with: driftless import local #{session_dir}")
  end
  exit(failed.zero? ? 0 : 1)
rescue StagingError => e
  warn "error: #{e.message}"
  exit 2
end
