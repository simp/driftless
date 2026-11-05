require 'fileutils'
require 'json'
require 'open3'
require 'time'
require 'yaml'

module Pupgrade
  # Builds a control repo to run pupgrade against from a scenario directory:
  # bare git remotes with one commit and tag per release of each module, a
  # deployed environment with every module cloned at the tag its Puppetfile
  # declares, Forge-style modules on disk, and any proposed Puppetfiles.
  #
  # Standard library only, so a sibling fixture repo can load it with the
  # Bolt or agent Ruby and no bundler.
  #
  # A scenario directory holds:
  #
  #   scenario.yaml              the modules, releases, and proposals; below
  #   modules/<owner-module>/
  #     base/                    files every release ships
  #     since/<version>/         files added or replaced from that version on
  #   controlrepo/               copied into the environment as it is:
  #                              environment.conf, hiera.yaml, data/,
  #                              site-modules/, manifests/, factsets/, pupgrade/
  #
  # scenario.yaml:
  #
  #   forge: URL                 the Puppetfile's forge line
  #   epoch: 2024-01-01T00:00:00Z   first commit date (default shown)
  #   release_defaults:          what a release declares when it does not say
  #     puppet: RANGE
  #     operatingsystems: { OS: [releases] }
  #   modules:                   in build order; commit dates count up across
  #     - name: owner-module     the build, so the order is part of every sha
  #       deployed: VERSION      the tag the Puppetfile pins and the clone sits at
  #       branch: main           the default branch: releases are tagged on it
  #                              unless they name another
  #       tag_prefix: v          'v' for v1.2.3, '' for 1.2.3
  #       unreleased: false      one commit past the last tag on the branch
  #       track: false           the Puppetfile follows the branch, not a tag
  #       forge: false           a directory with metadata.json, no remote;
  #                              its one release is the deployed version
  #       releases:
  #         - version: VERSION
  #           dependencies: { owner/module: RANGE }
  #           puppet: RANGE
  #           operatingsystems: { OS: [releases] }
  #           remove: [path]     files gone from this version on
  #           branch: NAME       commit and tag this release on NAME, made
  #                              from the default branch's tip the first time
  #           tag_prefix: v      this release's tag prefix, in place of the
  #                              module's
  #   proposals:                Puppetfiles written beside the deployed one
  #     Puppetfile.proposed:     the versions listed modules move to
  #       owner-module: VERSION
  #
  # Keys starting with `.` are ignored, as a place to hold YAML anchors.
  # Every release also gets a metadata.json, a default manifests/init.pp
  # unless its files include one, and a line appended to CHANGELOG.md.
  # Commits and tags carry fixed authors and dates, so two builds give the
  # same shas, tag objects included.
  class ScenarioBuilder
    # One release of a module: what its metadata.json declares.
    #
    # @!attribute [r] version
    #   @return [String]
    # @!attribute [r] dependencies
    #   @return [Hash{String => String}] dependency name to version range
    # @!attribute [r] puppet
    #   @return [String] the puppet requirement range
    # @!attribute [r] operatingsystems
    #   @return [Hash{String => Array<String>}] OS name to releases
    # @!attribute [r] remove
    #   @return [Array<String>] files gone from this version on
    # @!attribute [r] branch
    #   @return [String, nil] the branch it is tagged on, when not the
    #     module's
    # @!attribute [r] tag_prefix
    #   @return [String, nil] its tag prefix, when not the module's
    Release = Data.define(:version, :dependencies, :puppet, :operatingsystems, :remove, :branch, :tag_prefix) do
      def initialize(remove: [], branch: nil, tag_prefix: nil, **rest)
        super
      end
    end

    # One module of a scenario.
    #
    # @!attribute [r] name
    #   @return [String] "owner-module"
    # @!attribute [r] releases
    #   @return [Array<Release>] oldest first; a Forge module's one release
    # @!attribute [r] deployed
    #   @return [String] the version the Puppetfile pins and the clone sits
    #     at; the Forge version for a Forge module
    # @!attribute [r] branch
    #   @return [String] the branch releases are tagged on
    # @!attribute [r] unreleased
    #   @return [Boolean] whether the branch has a commit past the last tag
    # @!attribute [r] tag_prefix
    #   @return [String] "v" for tags like v1.2.3, "" for 1.2.3
    # @!attribute [r] forge
    #   @return [Boolean] a Forge entry: a directory with metadata.json, no
    #     remote
    # @!attribute [r] track
    #   @return [Boolean] the Puppetfile follows the branch, not a tag
    Mod = Data.define(:name, :releases, :deployed, :branch, :unreleased, :tag_prefix, :forge, :track) do
      def initialize(branch: 'main', unreleased: false, tag_prefix: 'v', forge: false, track: false, **rest)
        super
      end

      def owner
        name.split('-', 2).first
      end

      def short
        name.split('-', 2).last
      end

      def tag(version)
        "#{releases.find { |r| r.version == version }&.tag_prefix || tag_prefix}#{version}"
      end

      def release(version)
        releases.find { |r| r.version == version } or raise ArgumentError, "#{name}: no release #{version}"
      end
    end

    # What {#build} returns.
    #
    # @!attribute [r] dir
    #   @return [String] the control repo (environment) directory
    # @!attribute [r] remotes_dir
    #   @return [String] where the bare module remotes are
    # @!attribute [r] puppetfile
    #   @return [String] the deployed Puppetfile
    # @!attribute [r] proposed
    #   @return [String, nil] Puppetfile.proposed, when the scenario has one
    # @!attribute [r] proposals
    #   @return [Hash{String => String}] every proposal, by file name
    # @!attribute [r] config
    #   @return [String] pupgrade/pupgrade.yaml (present or not)
    # @!attribute [r] factsets
    #   @return [String] the factsets directory
    # @!attribute [r] mocks
    #   @return [String] pupgrade/compiler/mocks.yaml
    Result = Data.define(:dir, :remotes_dir, :puppetfile, :proposed, :proposals, :config, :factsets, :mocks) do
      # @return [String] the full sha of a deployed module's clone at a ref
      def sha(short, ref = 'HEAD')
        out, status = Open3.capture2('git', '-C', File.join(dir, 'modules', short), 'rev-parse', '--verify', "#{ref}^{commit}")
        raise ArgumentError, "#{short}: no #{ref}" unless status.success?

        out.strip
      end

      # The cache file `surface` writes for a deployed module read at a ref
      # (its own tag when none is given).
      def surface_file(short, version, ref = nil)
        "#{short}-#{version}--#{ref || "v#{version}"}__#{sha(short, ref || 'HEAD')[0, 10]}.json"
      end
    end

    # Raised for a scenario directory or scenario.yaml that cannot be built.
    class Error < StandardError; end

    DEFAULT_EPOCH = Time.utc(2024, 1, 1)
    DEFAULT_FORGE = 'https://forge.example.com'.freeze
    MOD_KEYS      = %w[name deployed branch tag_prefix unreleased track forge releases].freeze
    RELEASE_KEYS  = %w[version dependencies puppet operatingsystems remove branch tag_prefix].freeze

    # @return [String] the scenario directory
    attr_reader :scenario_dir

    # @return [Array<Mod>] the scenario's modules, in build order
    attr_reader :modules

    # @param scenario_dir [String] a directory holding scenario.yaml
    # @raise [Error] when scenario.yaml is missing or malformed
    def initialize(scenario_dir)
      @scenario_dir = File.expand_path(scenario_dir)
      path = File.join(@scenario_dir, 'scenario.yaml')
      raise Error, "#{path}: no such file" unless File.file?(path)

      @spec      = YAML.safe_load_file(path, aliases: true) || {}
      @forge_url = @spec.fetch('forge', DEFAULT_FORGE)
      @epoch     = @spec['epoch'] ? Time.parse(@spec['epoch'].to_s).utc : DEFAULT_EPOCH
      @modules   = Array(@spec['modules']).map { |m| read_mod(m) }
      @proposals = (@spec['proposals'] || {}).reject { |name, _| name.to_s.start_with?('.') }
    end

    # @param dir [String] an empty or absent directory
    # @return [Result]
    # @raise [ArgumentError] when the directory is not empty
    def build(dir)
      @dir     = File.expand_path(dir)
      @remotes = File.join(@dir, 'remotes')
      @commits = 0
      raise ArgumentError, "#{@dir}: not empty" if File.directory?(@dir) && Dir.children(@dir).any?

      FileUtils.mkdir_p([@remotes, File.join(@dir, 'modules'), File.join(@dir, 'site-modules'), File.join(@dir, 'data')])
      copy_controlrepo
      @modules.each do |m|
        if m.forge
          write_forge(m)
        else
          build_remote(m)
          deploy(m)
        end
      end
      File.write(File.join(@dir, 'Puppetfile'), puppetfile(@modules.to_h { |m| [m.name, m.deployed] }))
      proposals = @proposals.to_h do |name, moves|
        unknown = moves.keys - @modules.map(&:name)
        raise Error, "#{name}: moves modules the scenario does not have: #{unknown.join(', ')}" unless unknown.empty?

        path = File.join(@dir, name)
        File.write(path, puppetfile(@modules.to_h { |m| [m.name, moves.fetch(m.name, m.deployed).to_s] }))
        [name, path]
      end
      Result.new(dir: @dir, remotes_dir: @remotes, puppetfile: File.join(@dir, 'Puppetfile'),
                 proposed: proposals['Puppetfile.proposed'], proposals: proposals,
                 config: File.join(@dir, 'pupgrade/pupgrade.yaml'), factsets: File.join(@dir, 'factsets'),
                 mocks: File.join(@dir, 'pupgrade/compiler/mocks.yaml'))
    end

    private

    def read_mod(raw)
      raise Error, "a module entry is not a mapping: #{raw.inspect}" unless raw.is_a?(Hash)

      extra = raw.keys - MOD_KEYS
      raise Error, "#{raw['name']}: unknown key(s) #{extra.join(', ')}" unless extra.empty?

      name = raw.fetch('name') { raise Error, "a module entry has no name: #{raw.inspect}" }.to_s
      opts = raw.slice('branch', 'tag_prefix', 'unreleased', 'track', 'forge').transform_keys(&:to_sym)
      opts[:tag_prefix] = opts[:tag_prefix].to_s if opts.key?(:tag_prefix)
      releases = Array(raw['releases']).map { |r| read_release(name, r) }
      raise Error, "#{name}: no releases" if releases.empty?

      mod = Mod.new(name: name, releases: releases, deployed: raw.fetch('deployed').to_s, **opts)
      mod.release(mod.deployed)
      raise Error, "#{name}: a Forge module has exactly one release" if mod.forge && releases.size != 1

      mod
    end

    def read_release(name, raw)
      raw = { 'version' => raw } unless raw.is_a?(Hash)
      extra = raw.keys - RELEASE_KEYS
      raise Error, "#{name} #{raw['version']}: unknown key(s) #{extra.join(', ')}" unless extra.empty?

      defaults = @spec['release_defaults'] || {}
      Release.new(version: raw.fetch('version').to_s,
                  dependencies: (raw['dependencies'] || {}).to_h { |dep, range| [dep.to_s, range.to_s] },
                  puppet: (raw['puppet'] || defaults['puppet']).to_s,
                  operatingsystems: (raw['operatingsystems'] || defaults['operatingsystems'] || {})
                    .to_h { |os, rels| [os.to_s, Array(rels).map(&:to_s)] },
                  remove: Array(raw['remove']).map(&:to_s),
                  branch: raw['branch']&.to_s,
                  tag_prefix: raw.key?('tag_prefix') ? raw['tag_prefix'].to_s : nil)
    end

    def remote_url(mod)
      File.join(@remotes, "#{mod.name}.git")
    end

    def copy_controlrepo
      src = File.join(@scenario_dir, 'controlrepo')
      return unless File.directory?(src)

      Dir.children(src).sort.each { |entry| FileUtils.cp_r(File.join(src, entry), @dir) }
    end

    # One Puppetfile text: git modules at the given versions, Forge modules
    # at theirs, a tracking module on its branch.
    def puppetfile(versions)
      lines = ["forge '#{@forge_url}'", '']
      @modules.each do |m|
        lines << if m.forge
                   "mod '#{m.name}', '#{m.deployed}'"
                 elsif m.track
                   "mod '#{m.name}',\n  git: '#{remote_url(m)}',\n  branch: '#{m.branch}'"
                 else
                   "mod '#{m.name}',\n  git: '#{remote_url(m)}',\n  tag: '#{m.tag(versions.fetch(m.name))}'"
                 end
      end
      lines.join("\n") + "\n"
    end

    def metadata(mod, release)
      {
        'name'         => mod.name,
        'version'      => release.version,
        'author'       => mod.owner,
        'summary'      => "Manages #{mod.short}",
        'license'      => 'Apache-2.0',
        'source'       => "https://git.example.com/#{mod.owner}/#{mod.short}.git",
        'dependencies' => release.dependencies.map { |name, range| { 'name' => name, 'version_requirement' => range } },
        'requirements' => [{ 'name' => 'puppet', 'version_requirement' => release.puppet }],
        'operatingsystem_support' => release.operatingsystems.map do |os, releases|
          { 'operatingsystem' => os, 'operatingsystemrelease' => releases }
        end,
      }
    end

    # JSON.pretty_generate, with empty arrays and objects written `[]` and
    # `{}` whichever json gem is loaded: 2.x (the Bolt and agent Rubies'
    # default) spreads them over two lines, 3.x does not, and the bytes are
    # part of every commit sha.
    def pretty_json(data)
      JSON.pretty_generate(data).gsub(/\[\s*\n\s*\]/, '[]').gsub(/\{\s*\n\s*\}/, '{}') + "\n"
    end

    # Writes one release's files into a work tree.
    def write_release(dir, mod, release)
      FileUtils.mkdir_p(File.join(dir, 'manifests'))
      File.write(File.join(dir, 'metadata.json'), pretty_json(metadata(mod, release)))
      files = release_files(mod, release)
      unless files.key?('manifests/init.pp')
        File.write(File.join(dir, 'manifests/init.pp'), "class #{mod.short} (\n  String $version = '#{release.version}',\n) {\n}\n")
      end
      files.each do |rel, source|
        if source.nil?
          FileUtils.rm_f(File.join(dir, rel))
        else
          FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
          FileUtils.cp(source, File.join(dir, rel))
        end
      end
      File.open(File.join(dir, 'CHANGELOG.md'), 'a') { |f| f.puts "## #{release.version}\n\n- Release #{release.version}\n" }
    end

    # A release's files, by path inside the module, to the source file to
    # copy, or nil for one removed: the base tree, then each since/ tree at
    # or below the release in version order, then the removals declared by
    # releases at or below it.
    def release_files(mod, release)
      root  = File.join(@scenario_dir, 'modules', mod.name)
      files = tree(File.join(root, 'base'))
      at    = Gem::Version.new(release.version)
      since = Dir.glob(File.join(root, 'since', '*')).select { |d| File.directory?(d) }
      since.sort_by { |d| Gem::Version.new(File.basename(d)) }.each do |d|
        files.merge!(tree(d)) if Gem::Version.new(File.basename(d)) <= at
      end
      mod.releases.select { |r| Gem::Version.new(r.version) <= at }.flat_map(&:remove).each { |rel| files[rel] = nil }
      files
    end

    # @return [Hash{String => String}] relative path to absolute source path
    def tree(dir)
      return {} unless File.directory?(dir)

      Dir.glob('**/*', File::FNM_DOTMATCH, base: dir).sort
        .reject { |rel| %w[. ..].include?(File.basename(rel)) || File.directory?(File.join(dir, rel)) }
        .to_h { |rel| [rel, File.join(dir, rel)] }
    end

    # A bare remote with one commit and tag per release on the module's
    # branch, or on the branch a release names, and one more commit on the
    # module's branch when it has unreleased work.
    def build_remote(mod)
      work = File.join(@dir, '.build', mod.name)
      FileUtils.mkdir_p(work)
      git(work, 'init', '-q', '-b', mod.branch)
      branches = [mod.branch]
      on = mod.branch
      mod.releases.each do |release|
        target = release.branch || mod.branch
        if target != on
          # a branch named for the first time starts at the module branch's tip
          git(work, 'checkout', '-q', *(branches.include?(target) ? [target] : ['-b', target, mod.branch]))
          branches |= [target]
          on = target
        end
        write_release(work, mod, release)
        stamp = commit(work, "Release #{release.version}")
        # The tagger date, like the commit dates, is fixed, so the tag
        # object's sha is stable too.
        git(work, 'tag', '-a', '-m', "Release #{release.version}", mod.tag(release.version),
            env: { 'GIT_COMMITTER_DATE' => stamp })
      end
      git(work, 'checkout', '-q', mod.branch) unless on == mod.branch
      if mod.unreleased
        File.write(File.join(work, 'README.md'), "# #{mod.name}\n\nUnreleased fix.\n")
        commit(work, 'Fix a thing after the last release')
      end
      git(work, 'clone', '-q', '--bare', work, remote_url(mod))
      FileUtils.rm_rf(work)
    end

    # Clones the remote into modules/ and leaves it detached at the deployed
    # tag, or at the branch tip for a tracking module, as r10k would.
    def deploy(mod)
      target = File.join(@dir, 'modules', mod.short)
      git(@dir, 'clone', '-q', remote_url(mod), target)
      ref = mod.track ? "origin/#{mod.branch}" : mod.tag(mod.deployed)
      git(target, 'checkout', '-q', '--detach', ref)
    end

    def write_forge(mod)
      write_release(File.join(@dir, 'modules', mod.short), mod, mod.release(mod.deployed))
    end

    # @return [String] the commit's date, ISO 8601
    def commit(dir, message)
      @commits += 1
      stamp = (@epoch + (@commits * 86_400)).iso8601
      git(dir, 'add', '-A')
      git(dir, 'commit', '-q', '-m', message, env: { 'GIT_AUTHOR_DATE' => stamp, 'GIT_COMMITTER_DATE' => stamp })
      stamp
    end

    def git(dir, *args, env: {})
      system(env.merge('GIT_CONFIG_GLOBAL' => '/dev/null', 'GIT_CONFIG_SYSTEM' => '/dev/null'),
             'git', '-C', dir, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.com',
             '-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false', '-c', 'init.defaultBranch=main',
             *args, exception: true)
    end
  end
end
