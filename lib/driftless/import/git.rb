require 'fileutils'
require 'open3'
require 'shellwords'
require 'tmpdir'

require 'driftless/logger'

module Driftless
  module Import
    class Error < StandardError; end unless defined?(Error)

    # Imports collector-produced report sessions from a git remote populated by
    # scripts/driftless-store-reports-in-git.rb. That store script pushes each
    # collector's sessions to its own branch (<branch-prefix>/<collector>) with
    # a tree already shaped in ReportLoader input format, so the import here is
    # a per-branch checkout + directory copy — no format translation.
    #
    # Auth (all optional; reads from env):
    #   DRIFTLESS_REPORT_PULL_USERNAME - HTTPS username (default: x-token-auth)
    #   DRIFTLESS_REPORT_PULL_TOKEN    - HTTPS token/password, - or -
    #   DRIFTLESS_REPORT_PULL_SSH_KEY  - SSH private key (content, not file)
    class Git
      Result = Struct.new(:branches_imported, :reports_copied, :summaries_copied,
                          keyword_init: true)

      def initialize(repo_url:, incoming_dir:, summary_dir: nil,
                     branch_prefix: 'collector', collector: nil, dry_run: false)
        @repo_url      = repo_url
        @incoming_dir  = incoming_dir
        @summary_dir   = summary_dir
        @branch_prefix = branch_prefix
        @collector     = collector
        @dry_run       = dry_run
      end

      def run
        raise Error, 'repo_url required'     if @repo_url.nil?     || @repo_url.empty?
        raise Error, 'incoming_dir required' if @incoming_dir.nil? || @incoming_dir.empty?

        Driftless.logger.info("import git: source #{@repo_url}")
        Driftless.logger.info(
          "import git: target #{@incoming_dir}" \
          "#{" (summaries -> #{@summary_dir})" if @summary_dir}" \
          "#{' (dry-run)' if @dry_run}",
        )

        branches_done   = 0
        reports_copied  = 0
        summaries_copied = 0

        with_git_auth do |env, config_args|
          Dir.mktmpdir('driftless-import-git-') do |workdir|
            clone(env, config_args, workdir)
            branches = list_matching_branches(workdir)
            if branches.empty?
              Driftless.logger.warn("import git: no branches match prefix #{@branch_prefix.inspect}")
            end
            branches.each do |branch|
              Driftless.logger.info("import git: branch #{branch}")
              checkout(workdir, branch)
              r, s = copy_from_branch(workdir)
              reports_copied   += r
              summaries_copied += s
              branches_done    += 1
            end
          end
        end

        Result.new(
          branches_imported: branches_done,
          reports_copied:    reports_copied,
          summaries_copied:  summaries_copied,
        )
      end

      private

      def clone(env, config_args, workdir)
        args = ['git', *config_args, 'clone', '--no-checkout',
                '--filter=blob:none', '--no-single-branch', @repo_url, workdir]
        Driftless.logger.debug("$ #{args.shelljoin}")
        _, err, status = Open3.capture3(env, *args)
        raise Error, "git clone failed: #{err.strip}" unless status.success?
      end

      def list_matching_branches(workdir)
        # remote branches are populated at clone time under refs/remotes/origin/
        cmd = ['git', '-C', workdir, 'for-each-ref', '--format=%(refname:short)',
               "refs/remotes/origin/#{@branch_prefix}/*"]
        out, err, status = Open3.capture3(*cmd)
        raise Error, "git for-each-ref failed: #{err.strip}" unless status.success?

        branches = out.lines.map(&:strip).reject(&:empty?)
          .map { |r| r.sub(%r{\Aorigin/}, '') }
          .reject { |b| b == 'HEAD' }
        return branches unless @collector
        want = "#{@branch_prefix}/#{@collector}"
        branches.select { |b| b == want }
      end

      def checkout(workdir, branch)
        cmd = ['git', '-C', workdir, 'checkout', '--force', '-B', 'driftless-import', "origin/#{branch}"]
        _, err, status = Open3.capture3(*cmd)
        raise Error, "git checkout #{branch} failed: #{err.strip}" unless status.success?
      end

      def copy_from_branch(workdir)
        reports = copy_tree(File.join(workdir, 'incoming'), @incoming_dir)
        summaries = @summary_dir ? copy_tree(File.join(workdir, 'summary'), @summary_dir) : 0
        [reports, summaries]
      end

      # Copies every regular file from src_root into dst_root, preserving
      # relative paths. Returns the count copied. No-op if src_root is absent.
      def copy_tree(src_root, dst_root)
        return 0 unless File.directory?(src_root)
        count = 0
        Dir.glob(File.join(src_root, '**', '*')).each do |src|
          next unless File.file?(src)
          rel = src.sub(%r{\A#{Regexp.escape(src_root)}/?}, '')
          dst = File.join(dst_root, rel)
          if @dry_run
            Driftless.logger.info("import git: would copy #{rel}")
          else
            FileUtils.mkdir_p(File.dirname(dst))
            FileUtils.cp(src, dst)
            Driftless.logger.debug("import git: copied #{rel}")
          end
          count += 1
        end
        count
      end

      # Yields {extra_env, config_args} pre-populated for HTTPS (via
      # DRIFTLESS_REPORT_PULL_TOKEN, optional DRIFTLESS_REPORT_PULL_USERNAME)
      # and/or SSH (via DRIFTLESS_REPORT_PULL_SSH_KEY, loaded into an ephemeral
      # ssh-agent that terminates on block exit).
      def with_git_auth
        extra_env = { 'GIT_TERMINAL_PROMPT' => '0' }
        config_args = []
        agent_pid = nil

        if ENV['DRIFTLESS_REPORT_PULL_TOKEN']
          helper = <<~SH.strip
            !f() { case "$1" in
              get) echo "username=${DRIFTLESS_REPORT_PULL_USERNAME:-x-token-auth}"
                   echo "password=$DRIFTLESS_REPORT_PULL_TOKEN" ;;
            esac; }; f
          SH
          config_args += ['-c', 'credential.helper=', '-c', "credential.helper=#{helper}"]
          Driftless.logger.info('import git: HTTPS auth via DRIFTLESS_REPORT_PULL_TOKEN')
        end

        if (key_material = ENV['DRIFTLESS_REPORT_PULL_SSH_KEY'])
          agent_out, agent_status = Open3.capture2('ssh-agent', '-s')
          raise Error, 'ssh-agent failed to start' unless agent_status.success?
          sock = agent_out[/SSH_AUTH_SOCK=([^;]+);/, 1]
          pid  = agent_out[/SSH_AGENT_PID=(\d+);/, 1]
          raise Error, "could not parse ssh-agent output: #{agent_out.inspect}" unless sock && pid
          agent_pid = pid.to_i

          key_stdin = key_material.end_with?("\n") ? key_material : "#{key_material}\n"
          add_out, add_status = Open3.capture2e({ 'SSH_AUTH_SOCK' => sock },
                                                'ssh-add', '-', stdin_data: key_stdin)
          raise Error, "ssh-add failed to load key: #{add_out.strip}" unless add_status.success?

          extra_env['SSH_AUTH_SOCK'] = sock
          extra_env['SSH_AGENT_PID'] = pid
          Driftless.logger.info('import git: SSH auth via DRIFTLESS_REPORT_PULL_SSH_KEY')
        end

        yield extra_env, config_args
      ensure
        # rubocop:disable Style/RescueModifier -- concise + safe in this context
        if agent_pid
          Process.kill('TERM', agent_pid) rescue nil
          Process.wait(agent_pid)         rescue nil
        end
        # rubocop:enable Style/RescueModifier
      end
    end
  end
end
