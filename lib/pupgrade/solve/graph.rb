require 'set'

require 'pupgrade/solve/pub_grub'

module Pupgrade
  module Solve
    # A solver refusal drawn as a mermaid flowchart: the derivation behind
    # "apache cannot go past 10.1.1", pruned to the modules its leaves name.
    # A run of linear steps is one subgraph titled with its conclusion; a
    # step joining two derived lines nests a subgraph per line. Edges are a
    # version's dependency on a range; facts (a lever, a version nobody has,
    # a Puppet or OS reason) are stadium nodes beside their module.
    #
    # Colors: the subject module's own edges green; an edge onto the same
    # module as one of those, which is what stands against it, red, as is a
    # fact closing a gap; a `--bump`/`--hold` fact blue; other modules gray,
    # lighter the farther from the subject along the edges drawn.
    module Graph
      # One refusal to draw.
      #
      # @!attribute [r] subject
      #   @return [String] the module's short name
      # @!attribute [r] conclusion
      #   @return [String] "apache cannot go past 10.1.1"
      # @!attribute [r] incompatibility
      #   @return [PubGrub::LIB::Incompatibility] the derivation's root
      # @!attribute [r] keys
      #   @return [Hash{Incompatibility => Array}] the source's leaf index
      # @!attribute [r] noise
      #   @return [Array<String>] leaf texts left out: the version under test
      # @!attribute [r] labels
      #   @return [Hash{String => String}] a module's node label, when one
      #     says more than the name: "stdlib 8.6.0 (current) · 9.0.0 … 9.6.0"
      Refusal = Data.define(:subject, :conclusion, :incompatibility, :keys, :noise, :labels)

      CLASSES = <<~MERMAID.freeze
        classDef subject  fill:#e8f5e9,stroke:#2e7d32,color:#1b5e20
        classDef near     fill:#fafafa,stroke:#757575,color:#424242
        classDef far      fill:#fafafa,stroke:#bdbdbd,color:#757575
        classDef lever    fill:#e3f2fd,stroke:#1565c0,color:#0d47a1
        classDef conflict fill:#ffebee,stroke:#c62828,color:#b71c1c
      MERMAID

      EDGE_STYLE = { subject: 'stroke:#2e7d32,color:#2e7d32', conflict: 'stroke:#c62828,color:#c62828', other: 'stroke:#9e9e9e,color:#616161' }.freeze

      module_function

      # @param refusals [Array<Refusal>]
      # @return [String] one `flowchart TB`
      def mermaid(refusals)
        out = ['flowchart TB', *CLASSES.lines.map { |l| "  #{l.chomp}" }, '']
        return (out << '  %% nothing stood in the way').join("\n") + "\n" if refusals.empty?

        edges = []
        refusals.each_with_index { |r, i| out.concat(Tree.new(r, i, edges).lines) }
        EDGE_STYLE.each do |style, css|
          indexes = edges.each_index.select { |i| edges[i] == style }
          out << "  linkStyle #{indexes.join(',')} #{css}" unless indexes.empty?
        end
        out.join("\n") + "\n"
      end

      # Mermaid's entity codes for what a quoted label cannot hold.
      def escape(text)
        text.to_s.gsub('"', '#quot;').gsub('<', '#lt;').gsub('>', '#gt;')
      end

      # One refusal's subgraph.
      class Tree
        # @param edges [Array<Symbol>] every edge's style, in order of
        #   appearance across the chart, for `linkStyle`
        def initialize(refusal, index, edges)
          @refusal = refusal
          @index   = index
          @edges   = edges
          @nodes   = {}   # id => [label, kind, package]; kind :module, :lever, :conflict
          @links   = []   # [from, to, label, style]
          @ids     = Hash.new(0)
          @subject_targets = Set.new
          @body = []
        end

        # @return [Array<String>]
        def lines
          body = container(@refusal.conclusion, unfold(@refusal.incompatibility), "r#{@index}", 1)
          style!
          out = ["  subgraph r#{@index} [\"#{Graph.escape(@refusal.conclusion)}\"]", '    direction TB']
          out.concat(@nodes.map { |id, (label, kind, _)| "    #{node_text(id, label, kind)}" })
          out.concat(body)
          out << '  end'
          @links.each { |_, _, _, style| @edges << style }
          out
        end

        private

        # The derivation as runs: the leaves a linear run gathers, and the
        # derived lines a branching step joins, each unfolded in turn.
        #
        # @return [Hash] leaves: [Incompatibility], branches: [[Incompatibility, Hash]]
        def unfold(inc)
          return { leaves: [inc], branches: [] } unless inc.conflict?

          derived, leaves = [inc.cause.conflict, inc.cause.other].partition(&:conflict?)
          return { leaves: leaves, branches: derived.map { |d| [d, unfold(d)] } } if derived.size == 2

          sub = derived.first ? unfold(derived.first) : { leaves: [], branches: [] }
          { leaves: leaves + sub[:leaves], branches: sub[:branches] }
        end

        # @return [Array<String>] the edges and nested subgraphs of a run;
        #   the nodes are gathered for the chart's head
        def container(_title, run, id, depth)
          pad = '  ' * (depth + 1)
          out = run[:leaves].flat_map { |inc| leaf(inc) }.map { |l| "#{pad}#{l}" }
          run[:branches].each_with_index do |(inc, sub), i|
            sub_id = "#{id}_#{i}"
            out << "#{pad}subgraph #{sub_id} [\"#{Graph.escape(inc.to_s)}\"]"
            out << "#{pad}  direction TB"
            out.concat(container(inc.to_s, sub, sub_id, depth + 1))
            out << "#{pad}end"
          end
          out
        end

        # @return [Array<String>] the edge lines of a leaf, none for a fact
        #   drawn as a node or left out
        def leaf(inc)
          text = inc.to_s
          return [] if @refusal.noise.include?(text) || text.end_with?(' is on the modulepath')

          depender, key, = @refusal.keys[inc]
          if inc.cause == :dependency
            left, right = text.split(' depends on ', 2)
            from = node(depender, left)
            to   = node(key, @refusal.labels.fetch(key, key))
            style = (depender == @refusal.subject) ? :subject : :other
            @subject_targets << key if style == :subject
            @links << [from, to, "depends on #{right}", style]
            return ["#{from} -- \"#{Graph.escape("depends on #{right}")}\" --> #{to}"]
          end

          package = inc.terms.first&.package.to_s
          kind    = text.include?('(--') ? :lever : :conflict
          fact    = node(nil, text, kind: kind)
          anchor  = node(package, @refusal.labels.fetch(package, package)) unless package.empty?
          return [] unless anchor

          @links << [anchor, fact, nil, (kind == :lever) ? :other : :conflict]
          ["#{anchor} --- #{fact}"]
        end

        # A node for a module at a constraint ("apache >= 11.0.0"), one per
        # distinct label, or a fact.
        #
        # @return [String] its id
        def node(package, label, kind: :module)
          found = @nodes.find { |_, (l, k, _)| l == label && k == kind }
          return found.first if found

          base = (package || 'fact').gsub(/[^A-Za-z0-9]/, '_')
          @ids[base] += 1
          id = "r#{@index}_#{base}#{"_#{@ids[base]}" if @ids[base] > 1}"
          @nodes[id] = [label, kind, package]
          id
        end

        def node_text(id, label, kind)
          text = Graph.escape(label)
          case kind
          when :module then "#{id}[\"#{text}\"]:::#{@classes.fetch(id, 'far')}"
          else "#{id}([\"#{text}\"]):::#{kind}"
          end
        end

        # Edges onto a module the subject's own edges reach are what stands
        # against it; module nodes are classed by distance from the subject.
        def style!
          @links.each { |l| l[3] = :conflict if l[3] == :other && @nodes.dig(l[1], 1) == :module && @subject_targets.include?(@nodes.dig(l[1], 2)) }
          @classes = {}
          subject  = @nodes.select { |_, (_, kind, package)| kind == :module && package == @refusal.subject }.keys
          distance = subject.to_h { |id| [id, 0] }
          queue    = subject.dup
          until queue.empty?
            here = queue.shift
            @links.each do |from, to, _, _|
              next unless [from, to].include?(here)

              other = (from == here) ? to : from
              next if distance.key?(other)

              distance[other] = distance[here] + 1
              queue << other
            end
          end
          @nodes.each do |id, (_, kind, _)|
            next unless kind == :module

            @classes[id] = case distance[id]
                           when 0 then 'subject'
                           when 1 then 'near'
                           else 'far'
                           end
          end
        end
      end
    end
  end
end
