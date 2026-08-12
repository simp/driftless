#!/usr/bin/env ruby
# frozen_string_literal: true
#
# ------------------------------------------------------------------------------
# Commit + push a driftless collector session directory to a git repo.
# - branch is unique to collector
# - repo is force-pushed to preserve space (history not important)
# - each push replaces the branch with a fresh single-commit tree
#
# Env vars honored (all optional; no plaintext secret ever written to disk):
#   DRIFTLESS_REPORT_STORE_GITREPO   default for --repo
#   DRIFTLESS_COLLECTOR_REPORTS_DIR  default reports/sessions root
#   DRIFTLESS_REPORT_PUSH_TOKEN      HTTPS token/password (via inline credential helper)
#   DRIFTLESS_REPORT_PUSH_USERNAME   HTTPS username (default: x-token-auth)
#   DRIFTLESS_REPORT_PUSH_SSH_KEY    SSH private key material (via ephemeral ssh-agent)
# ------------------------------------------------------------------------------

require 'fileutils'
require 'json'
require 'logger'
require 'open3'
require 'optparse'
require 'shellwords'
require 'time'
require 'tmpdir'

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

def with_git_auth(log)
  extra_env = { 'GIT_TERMINAL_PROMPT' => '0' }
  extra_config = []
  agent_pid = nil

  if ENV['DRIFTLESS_REPORT_PUSH_TOKEN']
    # Inline helper — no file to exec, so a noexec /tmp is fine. `!` marks a
    # shell command; git appends the action ("get") so $1 inside f is "get".
    # Token stays in the env; only the (env-referencing) helper source is in `ps`.
    helper = <<~SH.strip
      !f() { case "$1" in
        get) echo "username=${DRIFTLESS_REPORT_PUSH_USERNAME:-x-token-auth}"
             echo "password=$DRIFTLESS_REPORT_PUSH_TOKEN" ;;
      esac; }; f
    SH
    extra_config << 'credential.helper='             # clear inherited chain
    extra_config << "credential.helper=#{helper}"    # install ours
    log.info('git auth: HTTPS via DRIFTLESS_REPORT_PUSH_TOKEN (inline credential helper)')
  end

  if (key_material = ENV['DRIFTLESS_REPORT_PUSH_SSH_KEY'])
    agent_out, agent_status = Open3.capture2('ssh-agent', '-s')
    raise 'ssh-agent failed to start' unless agent_status.success?
    sock = agent_out[/SSH_AUTH_SOCK=([^;]+);/, 1]
    pid  = agent_out[/SSH_AGENT_PID=(\d+);/, 1]
    raise "could not parse ssh-agent output: #{agent_out.inspect}" unless sock && pid
    agent_pid = pid.to_i

    key_stdin = key_material.end_with?("\n") ? key_material : "#{key_material}\n"
    add_out, add_status = Open3.capture2e(
      { 'SSH_AUTH_SOCK' => sock },
      'ssh-add', '-',
      stdin_data: key_stdin,
    )
    raise "ssh-add failed to load key: #{add_out.strip}" unless add_status.success?

    extra_env['SSH_AUTH_SOCK'] = sock
    extra_env['SSH_AGENT_PID'] = pid
    log.info('git auth: SSH via ephemeral ssh-agent + DRIFTLESS_REPORT_PUSH_SSH_KEY')
  end

  yield extra_env, extra_config
ensure
  if agent_pid
    Process.kill('TERM', agent_pid) rescue nil
    Process.wait(agent_pid)          rescue nil
  end
end

opts = {
  branch_prefix:    'collector',
  author:           'driftless-collector (%h)',
  email:            'driftless-collector@localhost',
  remote_git_repo:  ENV['DRIFTLESS_REPORT_STORE_GITREPO'],
  reports_dir:      ENV['DRIFTLESS_COLLECTOR_REPORTS_DIR'],
  session:          nil,
  rm_after_push:    false,
  dry_run:          false,
  log_level:        Logger::INFO,
}

OptionParser.new do |o|
  current_repo = opts[:remote_git_repo].to_s.empty? ? nil : "Currently: #{opts[:remote_git_repo]}"


  o.banner = "Usage: #{$PROGRAM_NAME} [options] [<session-or-reports-dir>]"
  o.on('--repo URL',              'Git remote URL to push to (required unless --dry-run)', current_repo )          { |v| opts[:remote_git_repo] = v }
  o.on('--reports-dir PATH',      'Reports root; overrides DRIFTLESS_COLLECTOR_REPORTS_DIR')        { |v| opts[:reports_dir] = v }
  o.on('--session ID',            "Explicit session id, or 'latest' (default: latest)")             { |v| opts[:session] = v }
  o.on('--rm-reports-after-push', 'Remove the session dir after a successful push')                 { opts[:rm_after_push] = true }
  o.on('--branch-prefix PREFIX',  "Per-collector branch prefix (default '#{opts[:branch_prefix]}')") { |v| opts[:branch_prefix] = v }
  o.on('--author NAME',           "Git author/committer name (default '#{opts[:author]}')")         { |v| opts[:author] = v }
  o.on('--email ADDR',            "Git author/committer email (default '#{opts[:email]}')")         { |v| opts[:email] = v }
  o.on('--dry-run',               'Build the commit locally but do not push')                       { opts[:dry_run] = true }
  o.on('-v', '--verbose',         'Log git commands and per-file staging')                          { opts[:log_level] = Logger::DEBUG }
  o.on('-h', '--help')            { puts o; exit 0 }
end.parse!

if opts[:remote_git_repo].nil? && !opts[:dry_run]
  warn 'error: --repo is required (unless --dry-run)'
  exit 2
end

log = Logger.new($stderr)
log.level = opts[:log_level]
log.formatter = ->(sev, t, _p, msg) { "#{t.iso8601} #{sev} #{msg}\n" }

session_dir = discover_session_dir(ARGV.shift, opts[:reports_dir], opts[:session], log)

summary_path = File.join(session_dir, '_summary.json')
unless File.file?(summary_path)
  log.error("missing _summary.json in #{session_dir}")
  exit 2
end

summary    = JSON.parse(File.read(summary_path))
collector  = summary.fetch('collector')
session_id = summary.fetch('session_id')
branch     = "#{opts[:branch_prefix]}/#{collector}"

log.info("session: #{session_id}")
log.info("collector: #{collector}")
log.info("target: #{opts[:remote_git_repo] || '(dry-run)'} branch #{branch}")

opts[:author] = opts[:author].gsub('%h', collector)

git_env = {
  'GIT_AUTHOR_NAME'     => opts[:author],
  'GIT_AUTHOR_EMAIL'    => opts[:email],
  'GIT_COMMITTER_NAME'  => opts[:author],
  'GIT_COMMITTER_EMAIL' => opts[:email],
}

workdir = Dir.mktmpdir('driftless-store-')
push_succeeded = false
begin
  run_git = lambda do |*args|
    cmd = ['git', '-C', workdir, *args]
    log.debug("$ #{cmd.shelljoin}")
    system(git_env, *cmd) or raise "git #{args.first} failed (exit #{$?.exitstatus})"
  end

  run_git.call('init', '-q')
  run_git.call('checkout', '-q', '--orphan', branch)

  summary.fetch('reports').each do |report_name, entry|
    src = File.join(session_dir, entry.fetch('file'))
    unless File.file?(src)
      log.warn("report #{report_name}: file missing at #{src}; skipping")
      next
    end
    dst_dir  = File.join(workdir, 'incoming', report_name)
    dst_path = File.join(dst_dir, "#{collector}--#{session_id}.ndjson")
    FileUtils.mkdir_p(dst_dir)
    FileUtils.cp(src, dst_path)
    log.debug("staged incoming/#{report_name}/#{collector}--#{session_id}.ndjson")
  end

  summary_out_dir = File.join(workdir, 'summary')
  FileUtils.mkdir_p(summary_out_dir)
  FileUtils.cp(summary_path, File.join(summary_out_dir, "#{collector}--#{session_id}.json"))
  log.debug("staged summary/#{collector}--#{session_id}.json")

  run_git.call('add', '.')
  run_git.call('commit', '-q', '-m', "driftless session #{session_id} for #{collector}")

  if opts[:dry_run]
    log.info("dry-run: prepared branch #{branch} in #{workdir}; skipping push")
  else
    with_git_auth(log) do |auth_env, auth_config|
      push_env = git_env.merge(auth_env)
      push_cmd = ['git', '-C', workdir]
      auth_config.each { |c| push_cmd += ['-c', c] }
      push_cmd += ['push', '--force', opts[:remote_git_repo], "#{branch}:#{branch}"]
      log.debug("$ #{push_cmd.shelljoin}")
      system(push_env, *push_cmd) or raise "git push failed (exit #{$?.exitstatus})"
    end
    push_succeeded = true
    log.info("pushed #{branch} to #{opts[:remote_git_repo]}")
  end
ensure
  FileUtils.remove_entry(workdir) if !opts[:dry_run] && File.directory?(workdir)
end

if push_succeeded && opts[:rm_after_push]
  FileUtils.rm_rf(session_dir)
  log.info("removed session dir #{session_dir}")
end
