module Driftless
  # Collapses reported nodes into one representative per distinct set of values
  # for the facts a hierarchy path interpolates.
  #
  # Built once for a whole hierarchy: the node list is walked a single time, and
  # every path's representatives are derived from that walk rather than from
  # another pass over the nodes.
  class NodeGrouping
    # vars is every variable the hierarchy interpolates anywhere.
    def initialize(nodes, vars)
      @nodes = nodes
      @vars  = vars.uniq
      @slot  = @vars.each_with_index.to_h
      @memo  = {}
      walk
    end

    # One node per distinct set of values for vars, in first-seen order.
    #
    # Returns every node when vars names a per-node-unique fact, since each node
    # is then its own group and there is nothing to collapse.
    def representatives(vars)
      vars = vars.uniq
      return @nodes if vars.empty? || vars.any? { |var| @unique_vars.include?(var) }

      @memo[vars] ||= narrow(vars.map { |var| @slot.fetch(var) })
    end

    # The facts held out of the shared table, exposed for reporting and specs.
    attr_reader :unique_vars

    private

    # The one pass over the node list. Everything after this reads the table.
    def walk
      table = @nodes.map { |node| [@vars.map { |var| node.fact(var) }, node] }

      # A fact with a distinct value for every node — certname, fqdn — has one
      # group per node, so there is nothing to collapse. It is held out of the
      # shared table, where it would leave no two rows alike for any varset to
      # narrow, and paths reading it get every node instead.
      @unique_vars = @vars.select do |var|
        column = @slot[var]
        table.map { |values, _node| values[column] }.uniq.size == @nodes.size
      end

      shared = @vars.reject { |var| @unique_vars.include?(var) }.map { |var| @slot[var] }
      rows   = {}
      table.each { |values, node| rows[shared.map { |i| values[i] }] ||= [values, node] }
      @rows = rows.values
    end

    def narrow(columns)
      seen = {}
      @rows.each { |values, node| seen[columns.map { |i| values[i] }] ||= node }
      seen.values
    end
  end
end
