require 'driftless/cli/base'
require 'driftless/cli/modules'
require 'driftless/control_repo'

module Driftless
  module CLI
    class Modules
      # `driftless modules gitlog`
      #
      # The git log of one deployed module: with a ref, the commits that
      # ref has beyond the clone's HEAD; without one, the clone's history.
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
          o.separator ''
          o.separator '<ref> is a branch, tag, or sha, tried as origin/<ref> first (a deployed clone\'s own'
          o.separator 'branches are stale) and then as given; the log then covers HEAD..<ref>, what the'
          o.separator 'ref has that the clone does not. Without one, the log is the clone\'s history.'
        end

        private

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
