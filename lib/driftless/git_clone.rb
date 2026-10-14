require 'open3'

module Driftless
  # Reads a git work tree in place: the commit it sits on, the branches whose
  # tips are there, its origin, and what a ref resolves to. Every question is
  # answered with nil when the directory is not a work tree, the ref is
  # unknown, or git is not installed.
  class GitClone
    attr_reader :dir

    # @param dir [String] the work tree
    def initialize(dir)
      @dir = dir
    end

    # Whether the directory holds its own `.git`, rather than sitting inside
    # another work tree.
    def own?
      File.exist?(File.join(@dir, '.git'))
    end

    # @return [String, nil] HEAD's 40-hex sha
    def sha
      output('rev-parse', 'HEAD')
    end

    # @return [String, nil] the checked-out branch, or "HEAD" when detached
    def current_branch
      output('rev-parse', '--abbrev-ref', 'HEAD')
    end

    # @return [String, nil] the `origin` remote's URL
    def remote
      output('remote', 'get-url', 'origin')
    end

    # @return [String, nil] a tag at HEAD, the nearest by name when several
    def tag_at_head
      output('describe', '--tags', '--exact-match', 'HEAD')
    end

    # A branch whose tip is HEAD, from the local and remote-tracking refs:
    # `prefer` when it is one of them, else the first by name.
    #
    # @return [String, nil] nil when no branch tip is at HEAD, as after the
    #   branch moved on
    def branch_at_head(prefer: nil)
      out = output('for-each-ref', '--points-at', 'HEAD', '--format=%(refname:short)', 'refs/heads', 'refs/remotes')
      return nil unless out

      branches = out.lines.map { |l| l.strip.sub(%r{\A[^/]+/}, '') }.reject { |b| b.empty? || b == 'HEAD' }.uniq.sort
      branches.include?(prefer) ? prefer : branches.first
    end

    # The commit a declared ref names in this clone: a sha, tag, or local
    # branch first, then an `origin/` branch.
    #
    # @return [String, nil] its sha; nil when nothing here answers to the ref
    def resolve(ref)
      [ref.to_s, "origin/#{ref}"].each do |candidate|
        sha = output('rev-parse', '--verify', '--quiet', "#{candidate}^{commit}")
        return sha if sha
      end
      nil
    end

    private

    def output(*args)
      out, _err, status = Open3.capture3('git', '-C', @dir, *args)
      status.success? ? out.strip : nil
    rescue Errno::ENOENT
      nil
    end
  end
end
