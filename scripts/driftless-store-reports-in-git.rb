#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Ship a driftless collector session directory to a git repo as a
# force-pushed single commit on a per-contributor branch. No history —
# each push replaces the branch with a fresh single-commit tree. See
# claude-memory/project_driftless_collector_design.md.

require 'fileutils'
require 'json'
require 'logger'
require 'optparse'
require 'shellwords'
require 'time'
require 'tmpdir'

opts = {
  repo:          nil,
  branch_prefix: 'contributor',
  author:        'driftless-store',
  email:         'driftless-store@localhost',
  dry_run:       false,
  log_level:     Logger::INFO,
}

OptionParser.new do |o|
  o.banner = "Usage: #{$PROGRAM_NAME} [options] <session-dir>"
  o.on('--repo URL',             'Git remote URL to push to (required)')                              { |v| opts[:repo] = v }
  o.on('--branch-prefix PREFIX', "Per-contributor branch prefix (default '#{opts[:branch_prefix]}')") { |v| opts[:branch_prefix] = v }
  o.on('--author NAME',          "Git author/committer name (default '#{opts[:author]}')")            { |v| opts[:author] = v }
  o.on('--email ADDR',           "Git author/committer email (default '#{opts[:email]}')")            { |v| opts[:email] = v }
  o.on('--dry-run',              'Build the commit locally but do not push')                          { opts[:dry_run] = true }
  o.on('-v', '--verbose',        'Log git commands and per-file staging')                             { opts[:log_level] = Logger::DEBUG }
  o.on('-h', '--help')           { puts o; exit 0 }
end.parse!

session_dir = ARGV.shift
if session_dir.nil? || !File.directory?(session_dir)
  warn 'error: <session-dir> is required and must be a directory'
  exit 2
end
if opts[:repo].nil? && !opts[:dry_run]
  warn 'error: --repo is required (unless --dry-run)'
  exit 2
end

log = Logger.new($stderr)
log.level = opts[:log_level]
log.formatter = ->(sev, t, _p, msg) { "#{t.iso8601} #{sev} #{msg}\n" }

summary_path = File.join(session_dir, '_summary.json')
unless File.file?(summary_path)
  log.error("missing _summary.json in #{session_dir}")
  exit 2
end

summary     = JSON.parse(File.read(summary_path))
contributor = summary.fetch('contributor')
session_id  = summary.fetch('session_id')
branch      = "#{opts[:branch_prefix]}/#{contributor}"

log.info("session: #{session_id}")
log.info("contributor: #{contributor}")
log.info("target: #{opts[:repo] || '(dry-run)'} branch #{branch}")

git_env = {
  'GIT_AUTHOR_NAME'     => opts[:author],
  'GIT_AUTHOR_EMAIL'    => opts[:email],
  'GIT_COMMITTER_NAME'  => opts[:author],
  'GIT_COMMITTER_EMAIL' => opts[:email],
}

run_git = lambda do |workdir, *args|
  cmd = ['git', '-C', workdir, *args]
  log.debug("$ #{cmd.shelljoin}")
  system(git_env, *cmd) or raise "git #{args.first} failed (exit #{$?.exitstatus})"
end

workdir = Dir.mktmpdir('driftless-store-')
begin
  run_git.call(workdir, 'init', '-q')
  run_git.call(workdir, 'checkout', '-q', '--orphan', branch)

  summary.fetch('reports').each do |report_name, entry|
    src = File.join(session_dir, entry.fetch('file'))
    unless File.file?(src)
      log.warn("report #{report_name}: file missing at #{src}; skipping")
      next
    end
    dst_dir  = File.join(workdir, 'incoming', report_name)
    dst_path = File.join(dst_dir, "#{contributor}--#{session_id}.ndjson")
    FileUtils.mkdir_p(dst_dir)
    FileUtils.cp(src, dst_path)
    log.debug("staged incoming/#{report_name}/#{contributor}--#{session_id}.ndjson")
  end

  summary_out_dir = File.join(workdir, 'summary')
  FileUtils.mkdir_p(summary_out_dir)
  FileUtils.cp(summary_path, File.join(summary_out_dir, "#{contributor}--#{session_id}.json"))
  log.debug("staged summary/#{contributor}--#{session_id}.json")

  run_git.call(workdir, 'add', '.')
  run_git.call(workdir, 'commit', '-q', '-m', "driftless session #{session_id} for #{contributor}")

  if opts[:dry_run]
    log.info("dry-run: prepared branch #{branch} in #{workdir}; skipping push")
  else
    run_git.call(workdir, 'push', '--force', opts[:repo], "#{branch}:#{branch}")
    log.info("pushed #{branch} to #{opts[:repo]}")
  end
ensure
  FileUtils.remove_entry(workdir) if !opts[:dry_run] && File.directory?(workdir)
end
