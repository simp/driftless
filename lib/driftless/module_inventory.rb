require 'driftless/git_clone'
require 'driftless/inputs/module_metadata'
require 'driftless/inputs/modulepath_loader'
require 'driftless/inputs/puppetfile'

module Driftless
  # The modules a control repo holds and declares, keyed by repo-relative
  # path: every directory on the modulepath, joined with every Puppetfile
  # entry by the directory r10k deploys it to.
  class ModuleInventory
    # One module, as declared and as found on disk.
    #
    # @!attribute [r] path
    #   @return [String] repo-relative directory; absolute for a modulepath
    #     entry outside the repo
    # @!attribute [r] declared
    #   @return [Inputs::Puppetfile::Module, nil] the Puppetfile entry; nil
    #     for a directory the Puppetfile does not mention
    # @!attribute [r] metadata
    #   @return [Inputs::ModuleMetadata::Result] read from the directory
    # @!attribute [r] deployed
    #   @return [Symbol] how the directory compares with the declaration:
    #     :match when a clone's HEAD is the commit the declared ref names in
    #     it, or a Forge module's metadata.json carries the declared version;
    #     :differ when it is not; :absent when the directory is not there;
    #     :unknown when nothing is declared, or the directory cannot answer
    #     (not a clone, no declared ref, a ref the clone does not know, no
    #     metadata, a Forge version that is not a number)
    # @!attribute [r] found
    #   @return [String, nil] what the directory holds instead, when
    #     :differ: a tag or branch at the clone's HEAD, else its short sha;
    #     a Forge module's metadata.json version. nil otherwise
    Entry = Data.define(:path, :declared, :metadata, :deployed, :found) do
      def initialize(found: nil, **rest)
        super
      end
    end

    # @return [Array<String>] what went wrong while loading, in order
    attr_reader :warnings

    # @param repo_dir [String] the control repo
    def initialize(repo_dir)
      @repo_dir = File.expand_path(repo_dir)
      @warnings = []
    end

    # The module a user names, tried as a deploy path, the last segment of
    # one, a declared name, then a metadata name, with "/" and "-" as one
    # in names.
    #
    # @param selector [String]
    # @return [Entry, nil]
    def find(selector)
      given  = selector.to_s
      wanted = given.tr('/', '-')
      entries.find { |e| e.path.casecmp?(given) } ||
        entries.find { |e| File.basename(e.path).casecmp?(given) } ||
        entries.find { |e| e.declared&.name&.tr('/', '-')&.casecmp?(wanted) } ||
        entries.find { |e| e.metadata.name&.tr('/', '-')&.casecmp?(wanted) }
    end

    # @return [Array<Entry>] sorted by path
    def entries
      @entries ||= begin
        puppetfile = Inputs::Puppetfile.load(@repo_dir)
        @warnings << "Puppetfile: #{puppetfile.error}" if puppetfile.error
        declared = puppetfile.modules.to_h { |m| [m.path, m] }
        (declared.keys | on_disk).sort.map { |path| entry(path, declared[path]) }
      end
    end

    private

    # @return [Array<String>] every module directory on the modulepath
    def on_disk
      Inputs::ModulepathLoader.module_dirs(@repo_dir).map { |d| d.delete_prefix("#{@repo_dir}/") }
    end

    def entry(path, declared)
      dir = File.expand_path(path, @repo_dir)
      metadata = Inputs::ModuleMetadata.load(dir)
      state    = deployed(dir, declared, metadata)
      Entry.new(path: path, declared: declared, metadata: metadata, deployed: state,
                found: (state == :differ) ? found(dir, declared, metadata) : nil)
    end

    # @return [String, nil] see {Entry#found}
    def found(dir, declared, metadata)
      return metadata.version unless declared.git

      clone = GitClone.new(dir)
      clone.tag_at_head || clone.branch_at_head || clone.sha&.slice(0, 12)
    end

    # @return [Symbol] see {Entry#deployed}
    def deployed(dir, declared, metadata)
      return :unknown unless declared
      return :absent unless File.directory?(dir)
      # r10k counts a local module in sync whatever it holds
      return :match if declared.local
      return forge_deployed(declared, metadata) unless declared.git
      return :unknown unless declared.ref

      clone = GitClone.new(dir)
      return :unknown unless clone.own?

      if declared.ref == :control_branch
        clone.branch_at_head(prefer: declared.default_branch) ? :match : :differ
      else
        sha = clone.resolve(declared.ref)
        return :unknown unless sha

        (sha == clone.sha) ? :match : :differ
      end
    end

    # A Forge module is at its declared version when metadata.json says so;
    # `latest` and the like cannot be compared.
    def forge_deployed(declared, metadata)
      return :unknown unless metadata.version && declared.version&.match?(/\A\d/)

      (metadata.version == declared.version) ? :match : :differ
    end
  end
end
