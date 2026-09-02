require 'driftless/role_profile'

module Driftless
  # Counts the nodes using each module, role, profile, and class, from the
  # per-node class lists of `classes-for-all-active-nodes`.
  module Utilization
    CATEGORIES = %w[modules roles profiles classes].freeze

    # Key under which nodes with no collector or environment are tallied.
    UNKNOWN = '(unknown)'.freeze

    module_function

    # Tallies the nodes using each name in every category.
    #
    # @param nodes [Array<Node>] rows of `classes-for-all-active-nodes`
    # @return [Hash{String => Array<Hash>}] a name-sorted entry list per
    #   category, each entry { 'name', 'nodes', 'by_collector', 'by_environment' }
    def compute(nodes)
      CATEGORIES.to_h { |category| [category, entries(nodes, category)] }
    end

    def entries(nodes, category)
      users = Hash.new { |h, k| h[k] = [] }
      nodes.each do |node|
        names(node, category).each { |name| users[name] << node }
      end
      users.sort.map do |name, using|
        { 'name'           => name,
          'nodes'          => using.length,
          'by_collector'   => tally(using, &:collector),
          'by_environment' => tally(using, &:environment) }
      end
    end

    # Lists the names a node's class list contributes to one category.
    #
    # @param node [Node] a row of `classes-for-all-active-nodes`
    # @param category [String] one of CATEGORIES
    # @return [Array<String>] unique fqnames (or module names), downcased
    #   from PuppetDB's capitalized titles (`Profile::Base` → `profile::base`)
    def names(node, category)
      fqnames = node.classes.map(&:downcase).uniq
      case category
      when 'classes'  then fqnames
      when 'modules'  then fqnames.map { |fqname| fqname.split('::').first }.uniq
      when 'roles'    then fqnames.select { |fqname| RoleProfile.role?(fqname) }
      when 'profiles' then fqnames.select { |fqname| RoleProfile.profile?(fqname) }
      end
    end

    def tally(rows)
      rows.group_by { |n| yield(n) || UNKNOWN }.sort.to_h.transform_values(&:length)
    end
  end
end
