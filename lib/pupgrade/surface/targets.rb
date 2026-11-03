require 'digest'
require 'fileutils'
require 'json'
require 'open3'

require 'driftless/inputs/module_metadata'
require 'driftless/module_inventory'
require 'pupgrade/surface'

module Pupgrade
  module Surface
    # What `surface` and `module diff` are pointed at, and how each becomes
    # a document: a module directory, a module on the control repo's
    # modulepath by name, either at a ref of its own clone, a document file,
    # or a git remote at a ref. Documents are kept in a cache directory,
    # named by module, version, and the commit read (see {#file_name}), and
    # read from there unless refreshed.
    class Targets
      class Error < StandardError; end

      # One thing to read.
      #
      # @!attribute [r] spec
      #   @return [String] as given
      # @!attribute [r] dir
      #   @return [String, nil] the module directory; nil for a file or a remote
      # @!attribute [r] ref
      #   @return [String, nil] a ref of the directory's clone or of the remote
      # @!attribute [r] file
      #   @return [String, nil] a document file
      # @!attribute [r] git
      #   @return [String, nil] a remote URL
      Target = Data.define(:spec, :dir, :ref, :file, :git) do
        def initialize(dir: nil, ref: nil, file: nil, git: nil, **rest)
          super
        end
      end

      # @param repo_dir [String, nil] the control repo, for names and the modulepath
      # @param cache_dir [String] where documents are kept
      # @param fetch [Boolean] whether to fetch a clone's origin before reading a ref
      # @param refresh [Boolean, Symbol] `:all` (or true) to extract again
      #   whatever the cache holds; `:schema` (the least, and the default
      #   behaviour) to extract again only a document of an older schema
      # @param logger [#debug, #info]
      def initialize(repo_dir: nil, cache_dir:, fetch: false, refresh: false, logger: Pupgrade.logger)
        @repo_dir  = repo_dir && File.expand_path(repo_dir)
        @cache_dir = File.expand_path(cache_dir, @repo_dir || Dir.pwd)
        @fetch     = fetch
        @refresh   = (refresh == true) ? :all : refresh
        @logger    = logger
      end

      # @return [Driftless::ModuleInventory, nil]
      def inventory
        return nil unless @repo_dir

        @inventory ||= ::Driftless::ModuleInventory.new(@repo_dir)
      end

      # @return [Array<String>] the repo's module directories, from where its
      #   modules sit
      def modulepath
        return [] unless inventory

        inventory.entries.map { |e| File.expand_path(File.dirname(e.path), @repo_dir) }.uniq
      end

      # Every module on the repo's modulepath, as targets.
      #
      # @return [Array<Target>]
      def all
        raise Error, 'reading every module needs a control repo (--repo-dir)' unless inventory

        inventory.entries.select { |e| e.metadata.name && File.directory?(File.expand_path(e.path, @repo_dir)) }
          .map { |e| Target.new(spec: e.path, dir: File.expand_path(e.path, @repo_dir)) }
      end

      # @param spec [String] `DIR`, `DIR:REF`, `NAME`, `NAME:REF`, or a document file
      # @param ref [String, nil] a ref for a spec that names none
      # @return [Target]
      # @raise [Error] when nothing answers to the spec
      def resolve(spec, ref: nil)
        return Target.new(spec: spec, file: File.expand_path(spec)) if File.file?(spec)

        path, given = split_ref(spec)
        ref = given || ref
        if File.directory?(path)
          return Target.new(spec: spec, dir: File.expand_path(path), ref: ref)
        end

        entry = inventory&.find(path)
        raise Error, "#{path}: no such directory, and #{inventory ? 'no such module on the modulepath' : 'no control repo to look it up in (--repo-dir)'}" unless entry

        dir = File.expand_path(entry.path, @repo_dir)
        raise Error, "#{entry.path}: not deployed" unless File.directory?(dir)

        Target.new(spec: spec, dir: dir, ref: ref)
      end

      # @param url [String]
      # @param ref [String]
      # @return [Target]
      def remote(url, ref)
        Target.new(spec: "#{url}@#{ref}", git: url, ref: ref)
      end

      # The target's document: a file as it is, else from the cache when it
      # is there, of this schema, and not refreshed, else extracted and
      # cached.
      #
      # A git-backed target is looked up by its commit, whatever name the
      # file carries; a module directory with no git by its version alone;
      # a dirty working tree is never served from the cache, since what is
      # in it is not what the commit holds.
      #
      # @return [Array(Hash, String, Boolean)] the document, the file it is
      #   in, and whether it was read from the cache
      def document(target)
        return [Surface.load(target.file), target.file, false] if target.file

        commit = commit_of(target)
        path   = commit ? cached_at(commit, short_name_of(target)) : versioned_path(target)
        if path && File.file?(path) && @refresh != :all && !commit&.dirty
          begin
            doc = Surface.load(path)
            @logger.debug("surface: #{target.spec}: cached at #{path}")
            return [doc, path, true]
          rescue Surface::StaleSchema => e
            @logger.info("surface: #{target.spec}: extracting again; #{e.message}")
          end
        end

        doc = extract(target)
        Array(doc['errors']).each { |e| @logger.warn("surface: #{target.spec}: #{e}") }
        doc['source'] = source_of(doc, commit) if commit
        path = commit ? File.join(@cache_dir, file_name(short_name_of(target, doc), doc.dig('module', 'version'), commit)) : path
        path ||= File.join(@cache_dir, file_name(short_name_of(target, doc), doc.dig('module', 'version'), nil))
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(doc) + "\n")
        remember(path)
        @logger.debug("surface: #{target.spec}: wrote #{path}")
        [doc, path, false]
      rescue Surface::Error => e
        raise Error, e.message
      end

      # How many characters of a commit's sha name a cache file. A fixed
      # prefix of the full sha, not `rev-parse --short`, whose length varies
      # by repository.
      SHA_LENGTH = 10

      # The commit a target reads, when git knows it before anything is
      # fetched or extracted.
      #
      # @!attribute [r] sha
      #   @return [String] the full sha
      # @!attribute [r] name
      #   @return [String, nil] the tag or branch read at, or that the
      #     checkout sits on; for the human sorting the cache directory
      # @!attribute [r] tags
      #   @return [Array<String>] every tag at the commit
      # @!attribute [r] dirty
      #   @return [Boolean] a working tree with changes past the commit
      Commit = Data.define(:sha, :name, :tags, :dirty) do
        def short
          sha[0, SHA_LENGTH]
        end
      end

      # "stdlib-9.6.0--v9.6.0__3f2a9c1e4b.json": the module's short name,
      # its version, the tag or branch it was read at when it has one, and
      # the commit's sha. The commit is what the cache is matched on; the
      # name is for the human sorting the directory. "stdlib-9.6.0.json"
      # for a module directory that is not a git checkout, keyed on its
      # version alone.
      def file_name(name, version, commit)
        short = name.to_s.split(%r{[-/]}).last
        base  = "#{short}-#{version || 'unversioned'}"
        base += "--#{commit.name.tr('/', '-')}" if commit&.name
        base += "__#{commit.short}#{'-dirty' if commit.dirty}" if commit
        "#{base}.json"
      end

      private

      # "stdlib:v9.0.0" splits at the last colon; a Windows-free world lets
      # a path keep its colons only when nothing follows that could be a ref.
      def split_ref(spec)
        base, sep, ref = spec.rpartition(':')
        return [spec, nil] if sep.empty? || ref.empty? || ref.include?('/') && File.exist?(spec)

        [base, ref]
      end

      # A shallow checkout has no tag of its own, so the ref read at is
      # written into the document's source.
      def extract(target)
        if target.git
          @logger.info("surface: fetching #{target.git} at #{target.ref}")
          return at_ref(target.git, target.ref)
        end
        if target.ref
          fetch!(target.dir)
          @logger.info("surface: reading #{target.dir} at #{target.ref}")
          return at_ref(target.dir, target.ref)
        end
        @logger.info("surface: reading #{target.dir}")
        Surface.extract(target.dir, modulepath: modulepath)
      end

      def at_ref(url, ref)
        doc = Surface.checkout(url, ref) { |dir| Surface.extract(dir, modulepath: modulepath) }
        doc['source'] = (doc['source'] || {}).merge('ref' => ref, 'from' => url)
        doc
      end

      # Once per clone, when asked to.
      def fetch!(dir)
        return unless @fetch

        (@fetched ||= {})[dir] ||= begin
          @logger.info("surface: #{dir}: fetching origin")
          _out, err, status = Open3.capture3({ 'GIT_TERMINAL_PROMPT' => '0' }, 'git', '-C', dir, 'fetch', '--quiet', '--tags', 'origin')
          @logger.trace("git -C #{dir} fetch --quiet --tags origin (fetching origin): exit #{status.exitstatus}")
          raise Error, "#{dir}: fetch failed: #{err.lines.last.to_s.strip}" unless status.success?

          true
        end
      end

      # The document's source with what the commit adds: every tag at it,
      # and whether the tree was dirty.
      def source_of(doc, commit)
        source = (doc['source'] || {}).merge('sha' => commit.sha)
        source['tags']  = commit.tags unless commit.tags.empty?
        source['dirty'] = true if commit.dirty
        source
      end

      # ---- the commit a target reads ----------------------------------------

      # @return [Commit, nil] nil when git cannot say before reading: a
      #   directory that is no checkout, a ref the clone does not know, a
      #   remote ref that `ls-remote` does not list
      def commit_of(target)
        return remote_commit(target.git, target.ref) if target.git

        if target.ref
          fetch!(target.dir)
          return clone_commit(target.dir, target.ref)
        end
        checkout_commit(target.dir)
      end

      # A module directory: the last commit touching it, so a module that
      # is a subdirectory of a larger repository (a site module in the
      # control repo) is keyed on its own changes, not on every commit of
      # the repository. Named after the tag the checkout sits at, else its
      # branch. A tree is dirty when it differs from the commit in anything
      # but a removed `spec/`, which r10k removes from every module it
      # deploys (`exclude_spec`, its default).
      def checkout_commit(dir)
        sha = git(dir, 'log', '-1', '--format=%H', '--', '.', why: 'the commit the module is at')
        return nil if sha.nil? || sha.empty?

        name = git(dir, 'describe', '--tags', '--exact-match', sha, why: 'the tag at it')
        name ||= git(dir, 'symbolic-ref', '--short', '-q', 'HEAD', why: 'the branch checked out')
        changes = git(dir, 'status', '--porcelain', '--', '.', why: 'uncommitted changes').to_s.lines.map(&:strip)
        dirty   = changes.reject { |line| line.match?(::Driftless::GitClone::R10K_REMOVED_SPEC) }.any?
        Commit.new(sha: sha, name: name, tags: tags_at(dir, sha), dirty: dirty)
      end

      # A ref of a clone, named after the ref.
      def clone_commit(dir, ref)
        sha = git(dir, 'rev-parse', '--verify', '--quiet', "#{ref}^{commit}", why: "resolving #{ref}")
        return nil if sha.nil? || sha.empty?

        Commit.new(sha: sha, name: ref, tags: tags_at(dir, sha), dirty: false)
      end

      # A ref of a remote, from what `ls-remote` advertises: a tag (peeled
      # to its commit when annotated), a branch, or a full sha. Named after
      # the ref.
      def remote_commit(url, ref)
        out = git(nil, 'ls-remote', '--tags', '--heads', url, why: "listing #{url}")
        return nil unless out

        refs = {}
        out.each_line do |line|
          sha, name = line.split("\t", 2).map(&:strip)
          next unless sha && name

          refs[name.delete_suffix('^{}')] = sha if name.end_with?('^{}') || !refs.key?(name)
        end
        sha = refs["refs/tags/#{ref}"] || refs["refs/heads/#{ref}"] || refs[ref]
        sha = ref if sha.nil? && ref.match?(/\A[0-9a-f]{40}\z/)
        return nil unless sha

        tags = refs.select { |name, at| name.start_with?('refs/tags/') && at == sha }.keys.map { |n| n.delete_prefix('refs/tags/') }.sort
        Commit.new(sha: sha, name: ref, tags: tags, dirty: false)
      end

      def tags_at(dir, sha)
        git(dir, 'tag', '--points-at', sha, why: 'the tags at it').to_s.split("\n").map(&:strip).reject(&:empty?).sort
      end

      def git(dir, *args, why:)
        argv = dir ? ['git', '-C', dir, *args] : ['git', *args]
        out, err, status = Open3.capture3({ 'GIT_TERMINAL_PROMPT' => '0' }, *argv)
        @logger.trace("#{argv.join(' ')} (#{why}): exit #{status.exitstatus}#{"; #{err.strip.lines.last.to_s.strip}" unless err.strip.empty?}")
        status.success? ? out.strip : nil
      rescue Errno::ENOENT
        nil
      end

      # ---- the cache -----------------------------------------------------------

      # The cache file holding the commit, if any: the files whose name
      # ends in its sha, narrowed to the module's when the name is known,
      # and told apart by the full sha in the document when more than one
      # remains. A dirty file is never served.
      #
      # @return [String, nil]
      def cached_at(commit, short)
        found = index.fetch(commit.short, [])
        found = found.select { |f| f.start_with?("#{short}-") } if short && found.size > 1
        found = found.select { |f| JSON.parse(File.read(File.join(@cache_dir, f))).dig('source', 'sha') == commit.sha } if found.size > 1
        found.first && File.join(@cache_dir, found.first)
      rescue JSON::ParserError
        nil
      end

      # Cache file names by the sha they end in, read once.
      def index
        @index ||= begin
          names = File.directory?(@cache_dir) ? Dir.children(@cache_dir) : []
          names.each_with_object(Hash.new { |h, k| h[k] = [] }) do |name, by_sha|
            sha = name[/__([0-9a-f]+)\.json\z/, 1]
            by_sha[sha] << name if sha
          end
        end
      end

      def remember(path)
        name = File.basename(path)
        sha  = name[/__([0-9a-f]+)\.json\z/, 1]
        index[sha] << name if sha && !index[sha].include?(name)
      end

      # The cache file for a module directory that is no checkout, named by
      # its metadata's version alone.
      #
      # @return [String, nil] nil when the metadata gives no name
      def versioned_path(target)
        file = File.join(target.dir, 'metadata.json')
        return nil unless File.file?(file)

        metadata = ::Driftless::Inputs::ModuleMetadata.parse(File.read(file), path: 'metadata.json')
        return nil if metadata.error || metadata.name.nil?

        File.join(@cache_dir, file_name(metadata.name, metadata.version, nil))
      end

      # The module's short name: from the document when there is one, else
      # from the directory's metadata, else from the directory or URL.
      def short_name_of(target, doc = nil)
        name = doc&.dig('module', 'name')
        name ||= Surface.module_name_in(target.dir) if target.dir && !target.ref
        name ||= File.basename(target.dir || target.git.to_s, '.git')
        name.to_s.split(%r{[-/]}).last
      end
    end
  end
end
