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
    #   @return [Symbol] :match when the clone's HEAD is the commit the
    #     declared ref names in it, :differ when it is not, :unknown when
    #     nothing is declared from git or there is no clone to ask
    Entry = Data.define(:path, :declared, :metadata, :deployed)

    # @return [Array<String>] what went wrong while loading, in order
    attr_reader :warnings

    # @param repo_dir [String] the control repo
    # @param basemodulepath [Array<String>, nil] overrides $basemodulepath
    def initialize(repo_dir, basemodulepath: nil)
      @repo_dir       = File.expand_path(repo_dir)
      @basemodulepath = basemodulepath
      @warnings       = []
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
      args = @basemodulepath ? { basemodulepath: @basemodulepath } : {}
      Inputs::ModulepathLoader.module_dirs(@repo_dir, **args).map { |d| d.delete_prefix("#{@repo_dir}/") }
    end

    def entry(path, declared)
      dir = File.expand_path(path, @repo_dir)
      Entry.new(path: path, declared: declared, metadata: Inputs::ModuleMetadata.load(dir),
                deployed: deployed(dir, declared))
    end

    # @return [Symbol] see {Entry#deployed}
    def deployed(dir, declared)
      return :unknown unless declared&.git && declared.ref

      clone = GitClone.new(dir)
      return :unknown unless clone.own?

      if declared.ref == :control_branch
        clone.branch_at_head(prefer: declared.default_branch) ? :match : :differ
      else
        sha = clone.resolve(declared.ref)
        (sha && sha == clone.sha) ? :match : :differ
      end
    end
  end
end
