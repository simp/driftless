#!/usr/bin/env ruby
# frozen_string_literal: true
#
# ------------------------------------------------------------------------------
# Copy a local collector session's report files into the driftless incoming/
# tree (`<incoming-dir>/<query>/<collector>--<session-id>.ndjson`), so a local
# `driftless scan -i <incoming-dir>` can consume them directly
#
# Env vars honored (all optional):
#   DRIFTLESS_INCOMING_DIR           default for --incoming-dir
#   DRIFTLESS_COLLECTOR_REPORTS_DIR  default reports/sessions root
# ------------------------------------------------------------------------------

require 'fileutils'
require 'json'
require 'logger'
require 'optparse'
require 'time'

def discover_session_dir(positional, reports_dir, session_pref, log)
  path = positional || reports_dir
  if path.nil? || path.empty?
    warn 'error: session or reports dir required (positional arg, --reports-dir, or DRIFTLESS_COLLECTOR_REPORTS_DIR)'
    exit 2
  end
  unless File.directory?(path)
    warn "error: not a directory: #{path}"
    exit 2
  end

  if File.file?(File.join(path, '_summary.json'))
    log.info("session dir: #{path}")
    return path
  end

  sessions_root = File.join(path, 'sessions')
  unless File.directory?(sessions_root)
    warn "error: no _summary.json in #{path} and no sessions/ subdir either"
    exit 2
  end

  candidates = Dir.children(sessions_root).select do |name|
    File.file?(File.join(sessions_root, name, '_summary.json'))
  end.sort

  if candidates.empty?
    warn "error: no sessions with _summary.json under #{sessions_root}"
    exit 2
  end

  chosen = (session_pref.nil? || session_pref == 'latest') ? candidates.last : session_pref
  unless candidates.include?(chosen)
    tail = candidates.last(5).join(', ')
    tail += ', ...' if candidates.size > 5
    warn "error: session #{chosen} not found under #{sessions_root} (have: #{tail})"
    exit 2
  end

  selected = File.join(sessions_root, chosen)
  log.info("selected session #{chosen} from #{sessions_root}")
  selected
end

opts = {
  incoming_dir:    ENV['DRIFTLESS_INCOMING_DIR'] || './incoming',
  reports_dir:     ENV['DRIFTLESS_COLLECTOR_REPORTS_DIR'],
  session:         nil,
  rm_after:        false,
  dry_run:         false,
  log_level:       Logger::INFO,
}

OptionParser.new do |o|
  o.banner = "Usage: #{$PROGRAM_NAME} [options] [<session-or-reports-dir>]"
  o.on('--incoming-dir PATH',      "Target incoming dir (default: #{opts[:incoming_dir]})")           { |v| opts[:incoming_dir] = v }
  o.on('--reports-dir PATH',       'Reports root; overrides DRIFTLESS_COLLECTOR_REPORTS_DIR')       { |v| opts[:reports_dir] = v }
  o.on('--session ID',             "Explicit session id or 'latest' (default: latest)")            { |v| opts[:session] = v }
  o.on('--rm-session-after',       'Remove the session dir after a successful materialize')        { opts[:rm_after] = true }
  o.on('--dry-run',                'Print what would be copied without touching the filesystem')   { opts[:dry_run] = true }
  o.on('-v', '--verbose',          'Log per-file operations')                                      { opts[:log_level] = Logger::DEBUG }
  o.on('-h', '--help')             { puts o; exit 0 }
end.parse!

log = Logger.new($stderr)
log.level = opts[:log_level]
log.formatter = ->(sev, t, _p, msg) { "#{t.iso8601} #{sev} #{msg}\n" }

session_dir  = discover_session_dir(ARGV.shift, opts[:reports_dir], opts[:session], log)
summary_path = File.join(session_dir, '_summary.json')
unless File.file?(summary_path)
  log.error("missing _summary.json in #{session_dir}")
  exit 2
end

summary    = JSON.parse(File.read(summary_path))
collector  = summary.fetch('collector')
session_id = summary.fetch('session_id')

log.info("session: #{session_id}")
log.info("collector: #{collector}")
log.info("target: #{opts[:incoming_dir]}#{opts[:dry_run] ? ' (dry-run)' : ''}")

copied   = 0
missing  = 0
summary.fetch('reports').each do |report_name, entry|
  src = File.join(session_dir, entry.fetch('file'))
  unless File.file?(src)
    log.warn("report #{report_name}: file missing at #{src}; skipping")
    missing += 1
    next
  end
  dst_dir  = File.join(opts[:incoming_dir], report_name)
  dst_path = File.join(dst_dir, "#{collector}--#{session_id}.ndjson")

  if opts[:dry_run]
    log.info("would copy #{src} → #{dst_path}")
  else
    FileUtils.mkdir_p(dst_dir)
    FileUtils.cp(src, dst_path)
    log.debug("copied #{report_name}/#{collector}--#{session_id}.ndjson")
  end
  copied += 1
end

log.info("materialized #{copied} report(s) into #{opts[:incoming_dir]}#{missing.zero? ? '' : " (#{missing} missing at source)"}")

if opts[:rm_after] && !opts[:dry_run] && copied.positive?
  FileUtils.rm_rf(session_dir)
  log.info("removed session dir #{session_dir}")
end
