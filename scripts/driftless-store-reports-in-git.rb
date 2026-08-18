#!/usr/bin/env ruby
# frozen_string_literal: true
# ------------------------------------------------------------------------------
# Send a driftless collector session directory to a git repo as a
# force-pushed single commit on a per-contributor branch
#
# Env vars honored (all optional; no plaintext secret ever shown/saved to disk):
#
#   DRIFTLESS_REPORT_STORE_GITREPO   default for --repo
#   DRIFTLESS_COLLECTOR_REPORTS_DIR  default reports/sessions root
#   DRIFTLESS_REPORT_STORE_TOKEN     HTTPS token/password (via inline credential helper)
#                                    GitLab PAT scopes: write_repository
#                                    (+ read_repository unless --no-check-remote-before-push)
#   DRIFTLESS_REPORT_STORE_USERNAME  HTTPS username (default: x-token-auth)
#   DRIFTLESS_REPORT_STORE_SSH_KEY   SSH private key material (via ephemeral ssh-agent)
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

  if ENV['DRIFTLESS_REPORT_STORE_TOKEN']
    # Git cred helper *function*; will run even when /tmp is mounted 'noexec'.
    # Secrets stay hidden in env; `ps` only shows the (env-referencing) function
    helper = <<~SH.strip
      !f() { case "$1" in
        get) echo "username=${DRIFTLESS_REPORT_STORE_USERNAME:-x-token-auth}"
             echo "password=$DRIFTLESS_REPORT_STORE_TOKEN" ;;
      esac; }; f
    SH
    extra_config << 'credential.helper='             # clear inherited chain
    extra_config << "credential.helper=#{helper}"    # install ours
    log.info('git auth: HTTPS via DRIFTLESS_REPORT_STORE_TOKEN (inline credential helper)')
  end

  if (key_material = ENV['DRIFTLESS_REPORT_STORE_SSH_KEY'])
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
    log.info('git auth: SSH via ephemeral ssh-agent + DRIFTLESS_REPORT_STORE_SSH_KEY')
  end

  yield extra_env, extra_config
ensure
  if agent_pid
    Process.kill('TERM', agent_pid) rescue nil
    Process.wait(agent_pid)          rescue nil
  end
end

# Returns true if the remote branch already carries a session_id >= the local
# one (i.e. force-pushing would overwrite equal-or-newer reports). Uses
# ls-remote + a tree-only partial clone; no blob transfer beyond tree objects.
def remote_branch_is_newer?(remote_url, branch, local_session_id, auth_env, auth_config, log)
  ls_cmd = ['git']
  auth_config.each { |c| ls_cmd += ['-c', c] }
  ls_cmd += ['ls-remote', '--exit-code', remote_url, "refs/heads/#{branch}"]
  log.debug("$ #{ls_cmd.shelljoin}")
  _, ls_status = Open3.capture2(auth_env, *ls_cmd)
  case ls_status.exitstatus
  when 0 then :branch_exists
  when 2
    log.info("remote check: branch #{branch} not on remote; safe to push")
    return false
  else
    raise "git ls-remote failed (exit #{ls_status.exitstatus})"
  end

  Dir.mktmpdir('driftless-check-') do |check_dir|
    clone_cmd = ['git']
    auth_config.each { |c| clone_cmd += ['-c', c] }
    clone_cmd += ['clone', '--quiet', '--depth', '1', '--filter=blob:none', '--no-checkout',
                  '--branch', branch, remote_url, check_dir]
    log.debug("$ #{clone_cmd.shelljoin}")
    clone_out, clone_status = Open3.capture2e(auth_env, *clone_cmd)
    raise "git clone (remote check) failed (exit #{clone_status.exitstatus}): #{clone_out.strip}" unless clone_status.success?

    ls_tree_cmd = ['git', '-C', check_dir, 'ls-tree', '--name-only', branch, 'summary/']
    log.debug("$ #{ls_tree_cmd.shelljoin}")
    ls_tree_out, ls_tree_status = Open3.capture2(*ls_tree_cmd)
    raise "git ls-tree failed (exit #{ls_tree_status.exitstatus})" unless ls_tree_status.success?

    remote_ids = ls_tree_out.lines.map(&:chomp).reject(&:empty?).map do |path|
      base = File.basename(path, '.json')
      _collector, sid = base.split('--', 2)
      sid
    end.compact

    if remote_ids.empty?
      log.warn("remote branch #{branch} has no parseable summary/*.json; treating as safe to push")
      return false
    end

    remote_newest = remote_ids.max
    if remote_newest >= local_session_id
      log.info("remote check: remote session_id=#{remote_newest} >= local session_id=#{local_session_id}")
      true
    else
      log.info("remote check: remote session_id=#{remote_newest} < local session_id=#{local_session_id}; safe to push")
      false
    end
  end
end

# After a successful push, remove now-pushed session and any earlier
# sessions on disk belonging to the same collector.
def prune_previous_sessions(session_dir, collector, pushed_session_id, log)
  sessions_root = File.dirname(session_dir)
  removed = 0

  Dir.children(sessions_root).each do |name|
    path = File.join(sessions_root, name)
    summary_path = File.join(path, '_summary.json')
    next unless File.file?(summary_path)

    begin
      s = JSON.parse(File.read(summary_path))
    rescue JSON::ParserError => e
      log.warn("prune: skipping #{path}: unparseable _summary.json (#{e.message})")
      next
    end
    next unless s['collector'] == collector
    sid = s['session_id']
    next if sid.nil? || sid > pushed_session_id

    FileUtils.rm_rf(path)
    log.info("pruned session #{path}")
    removed += 1
  end

  log.info("prune: removed #{removed} session(s) for collector #{collector}")
end

opts = {
  branch_prefix:              'collector',
  author:                     'driftless-collector (%h)',
  email:                      'driftless-collector@localhost',
  remote_git_repo:            ENV['DRIFTLESS_REPORT_STORE_GITREPO'],
  reports_dir:                ENV['DRIFTLESS_COLLECTOR_REPORTS_DIR'],
  session:                    nil,
  prune_after_push:           false,
  dry_run:                    false,
  check_remote_before_push:   true,
  log_level:                  Logger::INFO,
}

OptionParser.new do |o|
  current_repo = opts[:remote_git_repo].to_s.empty? ? nil : "Currently: #{opts[:remote_git_repo]}"


  o.banner = "Usage: #{$PROGRAM_NAME} [options] [<session-or-reports-dir>]"
  o.on('--repo URL',              'Git remote URL to push to (required unless --dry-run)', current_repo )          { |v| opts[:remote_git_repo] = v }
  o.on('--reports-dir PATH',      'Reports root; overrides DRIFTLESS_COLLECTOR_REPORTS_DIR')        { |v| opts[:reports_dir] = v }
  o.on('--session ID',            "Explicit session id, or 'latest' (default: latest)")             { |v| opts[:session] = v }
  o.on('--prune-sessions-after-push',
       'On successful push, remove the just-pushed session and all previous sessions for this collector') { opts[:prune_after_push] = true }
  o.on('--branch-prefix PREFIX',  "Per-collector branch prefix (default '#{opts[:branch_prefix]}')") { |v| opts[:branch_prefix] = v }
  o.on('--author NAME',           "Git author/committer name (default '#{opts[:author]}')")         { |v| opts[:author] = v }
  o.on('--email ADDR',            "Git author/committer email (default '#{opts[:email]}')")         { |v| opts[:email] = v }
  o.on('--dry-run',               'Build the commit locally but do not push')                       { opts[:dry_run] = true }
  o.on('--[no-]check-remote-before-push',
       'Refuse push if remote branch has a session_id >= local (default: yes)')                     { |v| opts[:check_remote_before_push] = v }
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
      if opts[:check_remote_before_push]
        if remote_branch_is_newer?(opts[:remote_git_repo], branch, session_id, auth_env, auth_config, log)
          log.error("refusing to push: remote #{branch} has session_id >= local (#{session_id})")
          log.error('re-run the collector to produce a fresh session, or pass --no-check-remote-before-push to override')
          exit 1
        end
      else
        log.info('remote check skipped (--no-check-remote-before-push)')
      end

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

if push_succeeded && opts[:prune_after_push]
  prune_previous_sessions(session_dir, collector, session_id, log)
end
