require 'driftless/cli/base'
require 'driftless/cli/modules'
require 'driftless/control_repo'
require 'driftless/inputs/branchfile'

module Driftless
  module CLI
    class Modules
      # `driftless modules gitlog`
      #
      # The git log of one deployed module: with a ref, the commits that
      # ref has beyond the clone's HEAD; without one, the branch a
      # branchfile names for the module, else the clone's history.
      class Gitlog < Base
        include Modules::OneModule

        register_command name: 'gitlog', subcommand_of: Modules
        positional '<module>', '[<ref>]'
        desc 'Show a deployed module\'s git log, or what a ref has beyond it'

        def execute(argv)
          fatal!('modules gitlog takes a module and an optional ref', help: true) unless argv.size.between?(1, 2)
          selector, ref = argv
          repo = control_repo!('modules gitlog')
          entry, clone = git_module!('modules gitlog', repo, selector)
          ref ||= branch_from_file(repo, entry)

          if @options[:fetch]
            fatal!("modules gitlog: fetch from #{clone.remote || 'origin'} failed", 3) unless clone.fetch
          end

          args = []
          args.push('-n', @options[:count].to_s) if @options[:count]
          args << '--name-status' if @options[:name_status]
          args << range_for(clone, ref)
          out = clone.log(*args)
          fatal!("modules gitlog: git log failed in #{entry.path}", 3) if out.nil?

          puts out unless out.empty?
          ::Driftless.logger.info("modules gitlog: #{entry.path} at #{clone.tag_at_head || clone.branch_at_head || clone.sha&.slice(0, 12)}")
          exit 0
        end

        protected

        def configure_parser(o)
          declare_repo_option(o)
          o.on('-n', '--count=NUM', Integer, 'Show at most NUM commits') { |v| @options[:count] = v }
          o.on('-f', '--name-status', 'List the files each commit changed') { @options[:name_status] = true }
          o.on('--fetch', 'Fetch origin first, so a branch or tag the clone has not seen shows') { @options[:fetch] = true }
          o.on('--branchfile=FILE',
               'Without <ref>, follow the branch FILE names for the module: YAML of',
               'module to branch, or a Puppetfile overlay of mod entries with :branch',
               '(default: modules.branchfile in driftless.yaml)') { |v| @options[:branchfile] = v }
          o.separator ''
          o.separator '<ref> is a branch, tag, or sha, tried as origin/<ref> first (a deployed clone\'s own'
          o.separator 'branches are stale) and then as given; the log then covers HEAD..<ref>, what the'
          o.separator 'ref has that the clone does not. Without one, the log is the clone\'s history.'
        end

        private

        # The branch the branchfile names for the module, when there is a
        # branchfile and it names one.
        #
        # @return [String, nil]
        def branch_from_file(repo, entry)
          return nil unless @options[:branchfile]

          path   = File.expand_path(@options[:branchfile], repo.dir)
          result = ::Driftless::Inputs::Branchfile.load(path)
          fatal!("modules gitlog: branchfile #{path}: no such file", 3) unless result.exists?
          fatal!("modules gitlog: branchfile #{result.error}", 3) if result.error
          result.warnings.each { |w| ::Driftless.logger.warn(w) }

          branch = [entry.declared&.name, entry.metadata.name, File.basename(entry.path)].compact.filter_map { |n| result.branch_for(n) }.first
          ::Driftless.logger.info("modules gitlog: #{entry.path} follows #{branch} per #{path}") if branch
          branch
        end

        def config_defaults
          { branchfile: ::Driftless.config.dig('modules', 'branchfile') }.compact
        end

        # @return [String] the `git log` revision argument
        def range_for(clone, ref)
          return 'HEAD' if ref.nil?

          candidate = ["origin/#{ref}", ref].find { |r| clone.resolve(r) }
          fatal!("modules gitlog: #{ref.inspect} is not a ref the clone knows (try --fetch)", 3) unless candidate
          "HEAD..#{candidate}"
        end
      end
    end
  end
end
