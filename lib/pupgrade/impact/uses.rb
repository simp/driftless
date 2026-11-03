module Pupgrade
  module Impact
    # How the site's uses of one thing are listed: the first {NAMED} of
    # the nodes, resources, or call sites concerned, and a count of the
    # rest. {Analysis} lists the uses of a surface change this way, and
    # {Usage} those of every item of a surface.
    module Uses
      # One kind of use: its first {NAMED} items, and a count of the rest.
      #
      # @!attribute [r] label
      #   @return [String] "nodes", "resources", "code", "hiera", "lookups",
      #     or for a class parameter "set" or "default"
      # @!attribute [r] items
      #   @return [Array<Item>] the first {NAMED}
      # @!attribute [r] more
      #   @return [Integer] how many more there are
      Use = Data.define(:label, :items, :more) do
        def to_s
          "#{label}: #{items.join(', ')}#{" and #{more} more" if more.positive?}"
        end
      end

      # One node, resource, call site, or Hiera file.
      #
      # @!attribute [r] name
      #   @return [String, nil] a resource's "Type[title]", or a file:line;
      #     nil for a node
      # @!attribute [r] certname
      #   @return [String, nil] the node; nil for a file:line
      Item = Data.define(:name, :certname) do
        def to_s
          [name, certname].compact.join(' on ')
        end
      end

      # How many names a use lists before counting instead.
      NAMED = 3

      module_function

      # @param certnames [Array<String>, nil]
      # @return [Array<Use>] one use of the nodes, or none
      def nodes(certnames, label: 'nodes')
        return [] if certnames.nil? || certnames.empty?

        [list(label, certnames.map { |c| Item.new(name: nil, certname: c) })]
      end

      # @param pairs [Array<Array(String, Hash)>, nil] certname and resource
      # @return [Array<Use>] one "resources" use, or none
      def resources(pairs)
        return [] if pairs.nil? || pairs.empty?

        [list('resources', pairs.map { |certname, r| Item.new(name: "#{r['type']}[#{r['title']}]", certname: certname) })]
      end

      # @param sites [Array<String>, nil] each a file:line
      # @return [Array<Use>] one "code" use, or none
      def sites(sites)
        return [] if sites.nil? || sites.empty?

        [list('code', sites)]
      end

      # @param items [Array<Item, String>] a String is a file:line
      # @return [Use]
      def list(label, items)
        items = items.map { |i| i.is_a?(Item) ? i : Item.new(name: i, certname: nil) }.uniq
        Use.new(label: label, items: items.first(NAMED), more: [items.size - NAMED, 0].max)
      end
    end
  end
end
