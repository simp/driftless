require 'driftless/git_remote'
require 'driftless/inputs/module_metadata'
require 'driftless/inputs/puppetfile'
require 'driftless/module_inventory'

module Driftless
  # The module inventory as a proposed Puppetfile would leave it: each of
  # its entries replaces the current entry at the same deploy path. Metadata
  # is kept from the clone when it already sits at the proposed ref, and
  # otherwise read from the remote; a Forge entry carries only the name and
  # version the Puppetfile gives it.
  class ModuleProposal
    class Error < StandardError; end

    # @return [Array<String>] metadata that could not be read, in order
    attr_reader :warnings

    # @param inventory [ModuleInventory] the repo as it is
    # @param puppetfile_path [String] the proposed Puppetfile
    # @param remote [#call] builds the {GitRemote} for a URL; injectable
    def initialize(inventory, puppetfile_path, remote: ->(url) { GitRemote.new(url) })
      @inventory = inventory
      @path      = puppetfile_path
      @remote    = remote
      @warnings  = []
    end

    # @return [Array<ModuleInventory::Entry>] sorted by path
    # @raise [Error] when the proposed Puppetfile is absent or does not evaluate
    def entries
      @entries ||= begin
        proposed = Inputs::Puppetfile.load_file(@path)
        raise Error, "#{@path}: no such file" unless proposed.exists?
        raise Error, "#{@path}: #{proposed.error}" if proposed.error

        merged = @inventory.entries.to_h { |e| [e.path, e] }
        proposed.modules.each { |m| merged[m.path] = entry_for(m, merged[m.path]) }
        merged.values.sort_by(&:path)
      end
    end

    private

    def entry_for(declared, current)
      if current && same_source?(declared, current)
        current.with(declared: declared)
      else
        ModuleInventory::Entry.new(path: declared.path, declared: declared, metadata: fetch(declared), deployed: :unknown)
      end
    end

    # Whether the current entry's metadata already describes the proposal:
    # a clone sitting at the same declared ref, or a Forge module at the
    # same declared version.
    def same_source?(declared, current)
      return false unless current.declared
      return current.deployed == :match && current.declared.git == declared.git && current.declared.ref == declared.ref if declared.git

      current.declared.git.nil? && current.declared.version == declared.version && current.metadata.exists?
    end

    def fetch(declared)
      unless declared.git
        @warnings << "#{declared.path}: Forge module #{declared.name} #{declared.version}: metadata not fetched; its dependencies are unknown"
        return Inputs::ModuleMetadata.absent.with(name: declared.name, version: declared.version)
      end

      ref  = fetch_ref(declared)
      text = @remote.call(declared.git).read_file(ref, Inputs::ModuleMetadata::FILENAME,
                                                  immutable: %w[tag commit].include?(declared.ref_type))
      Inputs::ModuleMetadata.parse(text, path: "#{declared.git}@#{ref}:#{Inputs::ModuleMetadata::FILENAME}")
    rescue GitRemote::Error => e
      @warnings << "#{declared.path}: #{e.message}; its version and dependencies are unknown"
      Inputs::ModuleMetadata.absent.with(name: declared.name)
    end

    # What to fetch: the declared ref; the default branch, else HEAD, for
    # `:control_branch`; HEAD when nothing is declared.
    def fetch_ref(declared)
      case declared.ref
      when nil then 'HEAD'
      when :control_branch then declared.default_branch || 'HEAD'
      else declared.ref
      end
    end
  end
end
