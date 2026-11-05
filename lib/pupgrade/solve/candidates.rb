require 'open3'
require 'semantic_puppet'

require 'driftless/inputs/module_metadata'
require 'pupgrade/inputs/branchfile'
require 'pupgrade/logging'

module Pupgrade
  module Solve
    # The versions a deployed git module could move to, read from its clone:
    # the tags past its current version, on its tracking branch when one is
    # known, and the branch's tip when asked for; or every release it has
    # had and could move to. Each carries the metadata.json at that ref.
    class Candidates
      # One version a module could be at.
      #
      # @!attribute [r] ref
      #   @return [String] the tag, or the branch for its tip
      # @!attribute [r] ref_type
      #   @return [String] "tag" or "branch": the Puppetfile option naming it
      # @!attribute [r] version
      #   @return [SemanticPuppet::Version, nil] from the tag name for a tag,
      #     else from the metadata
      # @!attribute [r] metadata
      #   @return [Driftless::Inputs::ModuleMetadata::Result]
      # @!attribute [r] current
      #   @return [Boolean] the version deployed now
      # @!attribute [r] rev
      #   @return [String] what git resolves for it in the clone: the ref
      #     itself, or its full name under another remote's namespace
      Candidate = Data.define(:ref, :ref_type, :version, :metadata, :current, :rev) do
        def initialize(ref:, ref_type:, version:, metadata:, current:, rev: nil)
          super(ref: ref, ref_type: ref_type, version: version, metadata: metadata, current: current, rev: rev || ref)
        end

        def to_s
          current ? "#{ref} (current)" : ref
        end
      end

      # Why a module has no candidates besides its current version.
      Unsolvable = Data.define(:reason)

      # The version at the end of a tag name, after any prefix (`v1.2.0`,
      # `release-1.2.0`), and not part of a longer number (`v1.2.0.1`).
      TAG_VERSION = /(?<![\d.])\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\z/.freeze

      # @param repo_dir [String] the control repo
      # @param branchfile [String, nil] the branchfile naming tracking
      #   branches, relative to the repo
      # @param include_heads [Boolean] whether a tracking branch's tip is a
      #   candidate for a tag-pinned module
      # @param fetch [Boolean] whether to fetch each clone's origin first;
      #   nothing under `remote`, whose refs the caller has fetched
      # @param remote [String, nil] the namespace another remote's refs were
      #   fetched into (`CloneRemote#fetch_refs`): its tags and branches
      #   are read in place of the clone's own
      def initialize(repo_dir, branchfile: nil, include_heads: false, fetch: false, remote: nil)
        @repo_dir      = File.expand_path(repo_dir)
        @include_heads = include_heads
        @fetch         = fetch && remote.nil?
        @remote        = remote
        @branches      = branchfile ? Inputs::Branchfile.load(File.expand_path(branchfile, @repo_dir)) : nil
        @warnings      = []
      end

      # @return [Array<String>]
      attr_reader :warnings

      # @param entry [Driftless::ModuleInventory::Entry]
      # @param branch [String, nil] the branch the module follows, in place
      #   of the one the branchfile names
      # @return [Array<Candidate>, Unsolvable] oldest first, the current
      #   version first of all
      def for(entry, branch: nil)
        dir = clone_of(entry)
        return dir if dir.is_a?(Unsolvable)

        declared = entry.declared
        current  = Candidate.new(ref: declared.ref.to_s, ref_type: declared.ref_type || 'ref', version: parse(entry.metadata.version),
                                 metadata: entry.metadata, current: true)
        branch ||= tracking_branch(entry)
        if declared.ref_type == 'branch'
          tip = tip_of(dir, declared.ref.to_s, entry)
          return [current] if tip.nil? || at_head?(dir, declared.ref.to_s)

          return [current, tip]
        end

        tags = tags_on(dir, branch, entry, past: current.version)
        tips = (@include_heads && branch) ? [tip_of(dir, branch, entry)].compact : []
        list = [current] + tags + tips
        Pupgrade.logger.info("candidates: #{entry.path}: #{list.size - 1} past #{current.ref}" \
                             "#{" on #{branch}" if branch}#{": #{list.drop(1).map(&:ref).join(', ')}" if list.size > 1}")
        list
      end

      # Every release of the module: each tag naming a version on the
      # branch it follows (a branch-pinned module's own branch; any tag of
      # the clone when no branch is known), oldest first, and with
      # include_heads the branch's tip last. The one at the clone's HEAD
      # is current.
      #
      # @param entry [Driftless::ModuleInventory::Entry]
      # @param branch [String, nil] as for {#for}
      # @return [Array<Candidate>, Unsolvable]
      def releases(entry, branch: nil)
        dir = clone_of(entry)
        return dir if dir.is_a?(Unsolvable)

        declared = entry.declared
        branch ||= (declared.ref_type == 'branch') ? declared.ref.to_s : tracking_branch(entry)
        head = git(dir, 'rev-parse', 'HEAD', why: 'sha at HEAD')
        list = tags_on(dir, branch, entry).map { |c| c.with(current: git(dir, 'rev-parse', "#{c.rev}^{commit}", why: "sha of #{c.rev}") == head) }
        if @include_heads && branch && (tip = tip_of(dir, branch, entry))
          list << tip.with(current: at_head?(dir, branch))
        end
        Pupgrade.logger.info("candidates: #{entry.path}: #{list.size} release(s)#{" on #{branch}" if branch}")
        list
      end

      private

      # The module's clone, fetched when asked to.
      #
      # @return [String, Unsolvable] its directory
      def clone_of(entry)
        declared = entry.declared
        return Unsolvable.new(reason: 'not in the Puppetfile') unless declared
        return Unsolvable.new(reason: 'local module') if declared.local
        return Unsolvable.new(reason: 'Forge module') unless declared.git

        dir = File.join(@repo_dir, entry.path)
        return Unsolvable.new(reason: 'not deployed') unless File.directory?(dir)
        return Unsolvable.new(reason: 'not a git clone') unless File.exist?(File.join(dir, '.git'))

        fetch(dir, entry) if @fetch
        dir
      end

      # @return [String, nil] the branch a branchfile names for the module
      def tracking_branch(entry)
        return nil unless @branches

        if @branches.error
          @warnings << "branchfile: #{@branches.error}" unless @warnings.include?("branchfile: #{@branches.error}")
          return nil
        end
        [entry.declared&.name, entry.metadata.name, File.basename(entry.path)].compact.filter_map { |n| @branches.branch_for(n) }.first
      end

      # Tags naming a version, oldest first: on the branch when one is
      # known, else any tag of the clone (or of the remote's namespace);
      # only those past a version when one is given.
      #
      # @return [Array<Candidate>] none current
      def tags_on(dir, branch, entry, past: nil)
        args = @remote ? ['for-each-ref', '--format=%(refname)', "#{@remote}/tags"] : ['tag', '--list']
        args.push('--merged', ref_in_clone(dir, branch)) if branch && ref_in_clone(dir, branch)
        out = git(dir, *args, why: 'listing tags')
        return [] unless out

        out.split("\n").filter_map { |rev|
          tag     = @remote ? rev.delete_prefix("#{@remote}/tags/") : rev
          version = parse(tag[TAG_VERSION])
          if version.nil? || (past && version <= past)
            Pupgrade.logger.debug("candidates: #{entry.path}: tag #{tag} skipped: #{version.nil? ? 'not a version' : "not past #{past}"}")
            next
          end

          metadata = metadata_at(dir, rev, entry)
          next unless metadata

          Candidate.new(ref: tag, ref_type: 'tag', version: version, metadata: metadata, current: false, rev: rev)
        }.sort_by(&:version)
      end

      def tip_of(dir, branch, entry)
        ref = ref_in_clone(dir, branch)
        return nil unless ref

        metadata = metadata_at(dir, ref, entry)
        return nil unless metadata

        Candidate.new(ref: branch, ref_type: 'branch', version: parse(metadata.version), metadata: metadata, current: false, rev: ref)
      end

      # Whether the clone's HEAD is the branch's tip already.
      def at_head?(dir, branch)
        ref = ref_in_clone(dir, branch)
        ref && git(dir, 'rev-parse', ref, why: "sha of #{ref}") == git(dir, 'rev-parse', 'HEAD', why: 'sha at HEAD')
      end

      # The branch as the clone knows it: its remote-tracking ref first; or
      # as the remote's namespace has it.
      def ref_in_clone(dir, branch)
        names = @remote ? ["#{@remote}/heads/#{branch}"] : ["origin/#{branch}", branch]
        names.find { |r| git(dir, 'rev-parse', '--verify', '--quiet', "#{r}^{commit}", why: "resolving #{r}") }
      end

      def metadata_at(dir, ref, entry)
        text = git(dir, 'show', "#{ref}:#{::Driftless::Inputs::ModuleMetadata::FILENAME}", why: "metadata.json at #{ref}")
        if text.nil?
          @warnings << "#{entry.path}: no metadata.json at #{ref}; skipped"
          return nil
        end
        metadata = ::Driftless::Inputs::ModuleMetadata.parse(text, path: "#{entry.path}@#{ref}:metadata.json")
        if metadata.error
          @warnings << "#{entry.path}: #{metadata.error}; #{ref} skipped"
          return nil
        end
        metadata
      end

      def fetch(dir, entry)
        Pupgrade.logger.info("candidates: #{entry.path}: fetching origin")
        @warnings << "#{entry.path}: fetch failed" if git(dir, 'fetch', '--quiet', '--tags', 'origin', why: 'fetching origin').nil?
      end

      def parse(version)
        SemanticPuppet::Version.parse(version.to_s)
      rescue SemanticPuppet::Version::ValidationFailure
        nil
      end

      def git(dir, *args, why: nil)
        out, err, status = Open3.capture3({ 'GIT_TERMINAL_PROMPT' => '0' }, 'git', '-C', dir, *args)
        Pupgrade.logger.trace("git -C #{dir} #{args.join(' ')}#{" (#{why})" if why}: exit #{status.exitstatus}#{"; #{err.strip.lines.last.strip}" unless err.strip.empty?}")
        status.success? ? out.strip : nil
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
