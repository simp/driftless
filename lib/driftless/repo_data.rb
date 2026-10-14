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
    #   ref_type as the Puppetfile declares them, sha read from the clone at
    #   that path, nil when there is none
    def deployments(corpus)
      puppetfile = corpus.puppetfile
      return {} unless puppetfile&.exists?

      puppetfile.modules.select(&:git).to_h do |m|
        # Only a directory holding its own `.git` is asked, so a module that
        # is not a clone does not answer with the enclosing control repo's sha.
        clone = GitClone.new(File.join(corpus.repo_dir, m.path))
        clone = nil unless clone.own?
        # What r10k deployed for :control_branch depends on how it ran:
        # the control repo's branch under `deploy environment`, the
        # default_branch under `puppetfile install`. The clone knows which.
        ref = (m.ref == :control_branch) ? clone&.branch_at_head(prefer: m.default_branch) : m.ref
        [m.path, { 'remote' => m.git, 'ref' => ref, 'ref_type' => m.ref_type, 'sha' => clone&.sha }]
      end
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
