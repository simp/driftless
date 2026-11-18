require 'driftless/git_clone'

module Driftless
  # The control repo a document is about: where it is, which revision, what
  # its Puppetfile deployed under it, and the hierarchy it declares. The
  # scan and params documents both carry it as `repo`.
  module RepoData
    module_function

    # @param corpus [Corpus]
    # @return [Hash] string-keyed: `dir`, `git`, `deployments`, `hierarchy`
    def describe(corpus)
      {
        'dir'         => corpus.repo_dir,
        'git'         => git_revision(corpus.repo_dir),
        'deployments' => deployments(corpus),
        'hierarchy'   => hierarchy(corpus.hiera_tiers),
      }
    end

    # The repos the Puppetfile deployed under the control repo, keyed by the
    # repo-relative path each occupies. Forge modules have no remote and are
    # left out.
    #
    # @return [Hash{String => Hash}] `{ remote, ref, ref_type, sha }`: ref and
    #   ref_type as the Puppetfile declares them while the clone at that path
    #   sits on that ref, else a branch whose tip the clone sits on, else nil;
    #   sha read from the clone, nil when there is none
    def deployments(corpus)
      puppetfile = corpus.puppetfile
      return {} unless puppetfile&.exists?

      puppetfile.modules.select(&:git).to_h do |m|
        clone = clone_at(corpus.repo_dir, m)
        ref   = deployed_ref(m, clone)
        [m.path, { 'remote' => m.git, 'ref' => ref, 'ref_type' => (ref == m.ref) ? m.ref_type : 'branch', 'sha' => clone&.sha }]
      end
    end

    # One sentence per git module whose clone does not sit on the ref the
    # Puppetfile declares. A Puppetfile that computes its refs (from the
    # environment, from `git ls-remote`) can evaluate differently here than
    # it did under r10k.
    #
    # @param puppetfile [Inputs::Puppetfile::Result, nil]
    # @return [Array<String>]
    def deployment_warnings(repo_dir, puppetfile)
      return [] unless puppetfile&.exists?

      puppetfile.modules.select(&:git).filter_map do |m|
        clone = clone_at(repo_dir, m)
        next if clone.nil? || !m.ref.is_a?(String) || on_declared_ref?(m, clone)

        branch = clone.branch_at_head(prefer: m.default_branch)
        at     = branch ? "branch '#{branch}'" : "commit #{clone.sha.to_s[0, 12]}"
        "Puppetfile declares #{m.ref_type} '#{m.ref}' for #{m.path}, but the clone there is on #{at}; links follow the clone"
      end
    end

    # Only a directory holding its own `.git` is asked, so a module that is
    # not a clone does not answer with the enclosing control repo's sha.
    #
    # @return [GitClone, nil]
    def clone_at(repo_dir, mod)
      clone = GitClone.new(File.join(repo_dir, mod.path))
      clone.own? ? clone : nil
    end

    # The ref a deployment is linked at.
    #
    # @return [String, nil]
    def deployed_ref(mod, clone)
      # What r10k deployed for :control_branch depends on how it ran:
      # the control repo's branch under `deploy environment`, the
      # default_branch under `puppetfile install`. The clone knows which.
      return clone&.branch_at_head(prefer: mod.default_branch) if mod.ref == :control_branch
      return mod.ref if clone.nil? || mod.ref.nil? || on_declared_ref?(mod, clone)

      clone.branch_at_head(prefer: mod.default_branch)
    end

    # Whether the clone's HEAD is the commit the declared ref names in it.
    def on_declared_ref?(mod, clone)
      sha = clone.sha
      !sha.nil? && clone.resolve(mod.ref) == sha
    end

    # The tiers as hiera.yaml declares them, so a reader can show every tier —
    # not only those a finding mentions — with the variables it interpolates.
    def hierarchy(tiers)
      tiers.map do |t|
        { 'name' => t.name, 'backend' => t.backend.to_s, 'line' => t.source_line,
          'paths' => t.path_templates, 'vars' => t.interpolation_vars }
      end
    end

    # @return [Hash, nil] `{ sha, branch, remote }`; nil when the directory
    #   is not a work tree
    def git_revision(dir)
      return nil unless dir && File.directory?(dir)

      clone = GitClone.new(dir)
      sha   = clone.sha
      sha ? { 'sha' => sha, 'branch' => clone.current_branch, 'remote' => clone.remote } : nil
    end
  end
end
