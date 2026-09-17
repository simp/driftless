require 'fileutils'

require 'driftless/export/factset_serializer'
require 'driftless/export/factsets'
require 'driftless/inputs/node_report_loader'
require 'driftless/logger'
require 'driftless/node_selector'
require 'driftless/scan_error'
require 'driftless/utilization'

module Driftless
  module Export
    # Maintains onceover's per-role factset tree,
    # `<root>/<role::name>/<certname>.json`: one factset per role and
    # collector, kept once chosen and refreshed from each import.
    #
    # A file already in a role directory is rewritten from the current
    # factset of that certname. Only when a collector has fewer files under a
    # role than the limit is a node picked to fill the shortfall. A file
    # whose certname no longer reports, or no longer carries the role, is
    # stale; the run stops on stale files unless told to prune or ignore them.
    class RoleTree
      include FactsetSerializer

      PICKS = %w[random first].freeze

      # @!attribute [rw] written
      #   @return [Integer] files newly picked and written
      # @!attribute [rw] updated
      #   @return [Integer] existing files rewritten
      # @!attribute [rw] pruned
      #   @return [Integer] stale files deleted
      # @!attribute [rw] stale
      #   @return [Integer] stale files found
      # @!attribute [rw] over_limit
      #   @return [Integer] role + collector pairs holding more files than the limit
      Result = Struct.new(:written, :updated, :pruned, :stale, :over_limit, keyword_init: true)

      # @return [Array<String>] warnings the run logged, in emission order
      attr_reader :warnings

      # @param root [String] the tree's root directory
      # @param limit [Integer] factsets per role and collector
      # @param pick [String] "random" or "first" (lowest certname)
      # @param prune [Boolean] delete stale files instead of stopping
      # @param ignore_stale [Boolean] warn about stale files instead of stopping
      # @param selector [NodeSelector, nil] narrows candidate nodes; its roles
      #   also narrow which role directories are maintained
      def initialize(incoming_dir:, root:, limit: 1, pick: 'random', prune: false, ignore_stale: false,
                     selector: nil, environments: nil, proceed_with_subset_of_configured_envs: false)
        raise Error, "unknown pick: #{pick.inspect} (known: #{PICKS.join(', ')})" unless PICKS.include?(pick)

        @loader = Inputs::NodeReportLoader.new(
          incoming_dir: incoming_dir, environments: environments,
          proceed_with_subset_of_configured_envs: proceed_with_subset_of_configured_envs,
        )
        @root          = root
        @limit         = limit
        @pick          = pick
        @prune         = prune
        @ignore_stale  = ignore_stale
        @selector      = selector || NodeSelector.new
        @profile       = 'onceover'
        @serialization = 'json'
        @warnings      = []
      end

      # @return [Result]
      # @raise [Error] on stale files when neither pruning nor ignoring them
      # @raise [ScanError] when the factsets or classes report is absent, or
      #   the environment filter rejects the tree
      def run
        nodes     = @loader.load
        @warnings = @loader.warnings
        nodes     = @selector.select(nodes, @loader.reported) unless @selector.empty?
        nodes     = nodes.reject { |n| n.certname.to_s.empty? }

        roles_of   = roles_by_certname
        candidates = group(nodes, roles_of)
        by_name    = nodes.to_h { |n| [name_for(n), n] }
        result     = Result.new(written: 0, updated: 0, pruned: 0, stale: 0, over_limit: 0)

        existing, stale = read_tree(by_name, roles_of)
        handle_stale(stale, result)

        candidates.each do |role, per_collector|
          per_collector.each do |collector, pool|
            kept = existing.fetch(role, {}).fetch(collector, [])
            kept.each { |node| write(role, node) }
            result.updated += kept.size
            if kept.size > @limit
              result.over_limit += 1
              warn("export factsets: #{role}/ holds #{kept.size} factsets from #{collector}, over the limit of #{@limit}")
              next
            end
            chosen = choose(pool - kept, @limit - kept.size)
            chosen.each do |node|
              Driftless.logger.info("export factsets: #{role}/ picked #{name_for(node)} for #{collector}")
              write(role, node)
            end
            result.written += chosen.size
          end
        end
        result
      end

      private

      def warn(message)
        @warnings << message
        Driftless.logger.warn(message)
      end

      # @return [Hash{String => Array<String>}] certname => roles, from the
      #   classes report, narrowed to the selector's role globs when given
      def roles_by_certname
        reported = @loader.reported
        report   = NodeSelector::CLASSES_REPORT
        raise ScanError, "the role tree needs the #{report} report, which is not loaded" if reported.missing?(report)

        globs = @selector.roles.map(&:downcase)
        reported.report(report).to_h do |node|
          roles = Utilization.names(node, 'roles')
          roles = roles.select { |r| globs.any? { |g| File.fnmatch?(g, r) } } unless globs.empty?
          [node.certname, roles]
        end
      end

      # @return [Hash{String => Hash{String => Array<Node>}}] role => collector => nodes
      def group(nodes, roles_of)
        grouped = Hash.new { |h, role| h[role] = Hash.new { |c, collector| c[collector] = [] } }
        nodes.each do |node|
          roles_of.fetch(node.certname, []).each { |role| grouped[role][node.collector.to_s] << node }
        end
        grouped
      end

      # The tree as it stands: files whose certname still reports with that
      # role, grouped like the candidates, and the paths of those that do not.
      #
      # @return [Array(Hash, Array<String>)]
      def read_tree(by_name, roles_of)
        existing = Hash.new { |h, role| h[role] = Hash.new { |c, collector| c[collector] = [] } }
        stale    = []
        return [existing, stale] unless File.directory?(@root)

        Dir.children(@root).sort.each do |role|
          dir = File.join(@root, role)
          next unless File.directory?(dir)
          Dir.children(dir).sort.each do |file|
            next unless file.end_with?('.json')
            name = File.basename(file, '.json')
            node = by_name[name]
            if node && roles_of.fetch(node.certname, []).include?(role)
              existing[role][node.collector.to_s] << node
            else
              stale << File.join(dir, file)
            end
          end
        end
        [existing, stale]
      end

      def handle_stale(stale, result)
        result.stale = stale.size
        return if stale.empty?

        stale.each do |path|
          reason = @prune ? 'pruned' : 'no reported node carries this role'
          warn("export factsets: stale factset #{path} (#{reason})")
        end
        if @prune
          stale.each { |path| File.delete(path) }
          result.pruned = stale.size
        elsif !@ignore_stale
          raise Error, "#{stale.size} stale factset(s) in #{@root}; pass --prune to delete them " \
                       'or --ignore-stale-factsets to leave them'
        end
      end

      def choose(pool, count)
        return [] if count <= 0 || pool.empty?
        sorted = pool.sort_by { |n| name_for(n) }
        (@pick == 'first') ? sorted.first(count) : sorted.sample(count)
      end

      # The filename stem: trusted.certname, else certname.
      def name_for(node)
        trusted = node.trusted.is_a?(Hash) ? node.trusted['certname'] : nil
        (trusted.to_s.empty? ? node.certname : trusted).to_s
      end

      def write(role, node)
        dir = File.join(@root, role)
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "#{name_for(node)}.json")
        File.write(path, serialize(payload(node)))
        Driftless.logger.info("export factsets: wrote #{path}")
      end
    end
  end
end
