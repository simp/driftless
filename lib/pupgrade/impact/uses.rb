module Pupgrade
  module Impact
    # How the site's uses of one thing are listed: the first {NAMED} of
    # the nodes, resources, or call sites concerned, and a count of the
    # rest. {Analysis} lists the uses of a surface change this way, and
    # {Usage} those of every item of a surface.
    module Uses
      # One kind of use: every item of it; shown as the first {NAMED} and
      # a count of the rest.
      #
      # @!attribute [r] label
      #   @return [String] "nodes", "resources", "code", "hiera", "lookups",
      #     or for a class parameter "set" or "default"
      # @!attribute [r] items
      #   @return [Array<Item>] unique
      Use = Data.define(:label, :items) do
        # @return [Array<Item>] the first {NAMED}
        def named
          items.first(NAMED)
        end

        # @return [Integer] how many items follow the named ones
        def more
          [items.size - NAMED, 0].max
        end

        def to_s
          "#{label}: #{named.join(', ')}#{" and #{more} more" if more.positive?}"
        end
      end

      # One node, resource, call site, or Hiera file.
      #
      # @!attribute [r] name
      #   @return [String, nil] a resource's "Type[title]", or a file:line;
      #     nil for a node
      # @!attribute [r] certname
      #   @return [String, nil] the node; nil for a file:line
      # @!attribute [r] file
      #   @return [String, nil] where a resource was declared, relative to
      #     the repo; nil for anything else
      Item = Data.define(:name, :certname, :file) do
        def initialize(name: nil, certname: nil, file: nil)
          super
        end

        def to_s
          [name, certname].compact.join(' on ')
        end

        # The code the item points at: a resource's declaring file, a call
        # site, or nothing for a node.
        #
        # @return [String, nil] "path:line" or "path"
        def site
          file || (certname ? nil : name)
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

        [list('resources', pairs.map { |certname, r| Item.new(name: "#{r['type']}[#{r['title']}]", certname: certname, file: r['file']) })]
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
        Use.new(label: label, items: items.map { |i| i.is_a?(Item) ? i : Item.new(name: i, certname: nil) }.uniq)
      end
    end
  end
end
