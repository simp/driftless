require 'digest'
require 'open3'

require 'pupgrade/logging'

module Pupgrade
  # The remote a `--repo` names in a deployed clone, and a ref fetched from
  # it. `REMOTE` is one the clone has; `URL` is reused when a remote has
  # it, else added as `pupgrade-<8 hex of the URL>`; `URL,REMOTE` adds
  # REMOTE at URL, or points an existing REMOTE there with a notice. r10k's
  # `cache` and `origin` are never changed. A remote added stays: it is
  # not made `origin`, and nothing is removed afterwards.
  class CloneRemote
    class Error < StandardError; end

    # Remotes r10k owns.
    RESERVED = %w[cache origin].freeze

    # One remote of the clone.
    #
    # @!attribute [r] name
    #   @return [String]
    # @!attribute [r] url
    #   @return [String]
    Remote = Data.define(:name, :url)

    # @param dir [String] the clone
    def initialize(dir)
      @dir = dir
    end

    # @param spec [String] `URL[,REMOTE]` or `REMOTE`
    # @return [Remote]
    # @raise [Error] for a reserved name, a remote the clone lacks, or git
    #   failing
    def resolve(spec)
      url, _, name = spec.partition(',')
      return named(url) if name.empty? && remotes.key?(url)
      return by_url(url) if name.empty?

      raise Error, "remote #{name.inspect} is r10k's; it is not changed" if RESERVED.include?(name)

      current = remotes[name]
      if current.nil?
        git('remote', 'add', name, url, why: "adding remote #{name}")
        Pupgrade.logger.notice("remote: #{@dir}: added #{name} at #{url}")
      elsif current != url
        git('remote', 'set-url', name, url, why: "pointing remote #{name} at #{url}")
        Pupgrade.logger.notice("remote: #{@dir}: #{name} now points at #{url}, not #{current}")
      end
      Remote.new(name: name, url: url)
    end

    # Fetches one ref from the remote.
    #
    # @return [String] the sha it names
    # @raise [Error] when the remote has no such ref
    def fetch(remote, ref)
      git('fetch', '--quiet', '--no-tags', remote.name, ref, why: "fetching #{ref} from #{remote.name}") or
        raise Error, "#{remote.name} (#{remote.url}) has no ref #{ref.inspect}"
      git('rev-parse', 'FETCH_HEAD^{commit}', why: 'the commit fetched') or raise Error, "#{ref} fetched from #{remote.name} is not a commit"
    end

    # Fetches every tag and branch of the remote into a namespace of its
    # own, `refs/pupgrade/NAME/{tags,heads}/`, pruned to what the remote
    # has now. Tags are global in git: fetched as tags, another repo's
    # would stay in the clone's `refs/tags` for good.
    #
    # @return [String] the namespace, `refs/pupgrade/NAME`
    # @raise [Error] when the fetch fails
    def fetch_refs(remote)
      space = namespace(remote)
      git('fetch', '--quiet', '--prune', '--no-tags', remote.name, "+refs/tags/*:#{space}/tags/*", "+refs/heads/*:#{space}/heads/*",
          why: "fetching the refs of #{remote.name}") or raise Error, "fetching #{remote.name} (#{remote.url}) failed"
      space
    end

    # @return [String] where {#fetch_refs} puts the remote's refs
    def namespace(remote)
      "refs/pupgrade/#{remote.name}"
    end

    # @return [Hash{String => String}] name to fetch URL
    def remotes
      out = git('remote', '-v', why: 'listing remotes') || ''
      out.lines.filter_map { |l| (m = l.match(/\A(\S+)\s+(\S+)\s+\(fetch\)/)) && [m[1], m[2]] }.to_h
    end

    private

    def named(name)
      Remote.new(name: name, url: remotes.fetch(name))
    end

    # The remote at the URL, or a new one named after it.
    def by_url(url)
      found = remotes.find { |_, u| u == url }
      return Remote.new(name: found.first, url: url) if found

      name = "pupgrade-#{Digest::SHA1.hexdigest(url)[0, 8]}"
      git('remote', 'add', name, url, why: "adding remote #{name}")
      Pupgrade.logger.notice("remote: #{@dir}: added #{name} at #{url}")
      Remote.new(name: name, url: url)
    end

    def git(*args, why: nil)
      out, err, status = Open3.capture3({ 'GIT_TERMINAL_PROMPT' => '0' }, 'git', '-C', @dir, *args)
      Pupgrade.logger.trace("git -C #{@dir} #{args.join(' ')}#{" (#{why})" if why}: exit #{status.exitstatus}#{"; #{err.strip.lines.last.strip}" unless err.strip.empty?}")
      return out.strip if status.success?
      return nil if %w[fetch rev-parse].include?(args.first)

      raise Error, "git #{args.first} in #{@dir}: #{(err.lines.find { |l| l.start_with?('fatal:', 'error:') } || err.lines.last).to_s.strip}"
    rescue Errno::ENOENT
      raise Error, 'git is not installed'
    end
  end
end
