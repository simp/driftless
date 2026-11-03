require 'set'
require 'semantic_puppet'

require 'driftless/inputs/module_metadata'
require 'driftless/module_inventory'
require 'pupgrade/exclusions'
require 'pupgrade/logging'
require 'pupgrade/module_name'
require 'pupgrade/module_resolver'
require 'pupgrade/solve/candidates'
require 'pupgrade/solve/graph'
require 'pupgrade/solve/pub_grub'

module Pupgrade
  module Solve
    # Picks a version for every module: a set in which every module's
    # dependency ranges, the Puppet requirement, and the operating systems
    # of interest hold, found by PubGrub, each module as far along its
    # candidates as the set allows. What pupgrade decides around the
    # solver: a constraint no release of any module could meet is left out
    # as unresolvable; a hold or a bump is a fact
    # the solver cannot overrule; a module no version of which fits is
    # pinned at its least-broken version and the solve goes on without its
    # constraints. A module short of its newest candidate ("solved") is
    # asked about again, and the solver's explanation becomes its note.
    class Solver
      # Raised when no set fits even with every misfit pinned; carries the
      # derivation for `solve -g`.
      class Error < StandardError
        # @return [Graph::Refusal, nil]
        attr_reader :refusal

        def initialize(message, refusal: nil)
          @refusal = refusal
          super(message)
        end
      end

      ORDERS = %w[newest nearest].freeze
      # The old name of nearest, still taken.
      ORDER_ALIASES = { 'oldest' => 'nearest' }.freeze

      ZERO = SemanticPuppet::Version.parse('0.0.0')

      # What a lever does to its module, in a fact and a finding.
      LEVER_WORDS = { hold: 'held at', bump: 'bumped to' }.freeze

      # One constraint a candidate breaks: what it asks, and what stands in
      # the way.
      #
      # @!attribute [r] key
      #   @return [String] the constraint: the dependency's short name,
      #     "puppet", or "os RedHat"; what the solver is told to drop
      # @!attribute [r] text
      #   @return [String] "needs puppetlabs/stdlib >= 9.0.0 < 10.0.0"
      # @!attribute [r] fault
      #   @return [String] "stdlib is 8.6.0", "stdlib moves to 10.0.0",
      #     "zookeeper is not on the modulepath", "missing RedHat 9"
      # @!attribute [r] exclusion
      #   @return [String] the `modules.exclude_*` entry that would cover it:
      #     "a:b >= 1.0.0" for a dependency, the module for its Puppet
      #     requirement, "a:RedHat 9" for an operating system
      Violation = Data.define(:key, :text, :fault, :exclusion) do
        def to_s
          "#{text}, but #{fault}"
        end

        # Which `modules.exclude_*` list the exclusion belongs in.
        def list
          if key == 'puppet' then 'requirements'
          elsif key.start_with?('os ') then 'operatingsystems'
          else 'dependencies'
          end
        end
      end

      # One module's outcome.
      #
      # @!attribute [r] entry
      #   @return [Driftless::ModuleInventory::Entry]
      # @!attribute [r] candidates
      #   @return [Array<Candidates::Candidate>] oldest first, the current
      #     version first of all
      # @!attribute [r] chosen
      #   @return [Candidates::Candidate]
      # @!attribute [r] violations
      #   @return [Array<Violation>] what the choice breaks that held at the
      #     current versions
      # @!attribute [r] prior
      #   @return [Array<Violation>] what the choice breaks that no release
      #     could have met: unresolvable, kept from the solver, and not
      #     excluded, so still counting against the exit status
      # @!attribute [r] note
      #   @return [String] why this candidate: "newest", "nearest",
      #     "current", "bumped", "held at current"; "solved" when the set
      #     allowed no newer candidate; "unresolved" when no candidate fits
      #     and this one breaks the least; a reason when there were no
      #     candidates to choose from ("Forge module")
      # @!attribute [r] why
      #   @return [String, nil] for a solved module, the constraint of its
      #     own in the way and what stands against it; for a nearest,
      #     what pushed it off its current version
      # @!attribute [r] derivation
      #   @return [String, nil] the solver's whole explanation behind `why`,
      #     or behind an unresolved module's pinning
      # @!attribute [r] refusal
      #   @return [Graph::Refusal, nil] the same derivation, for `solve -g`
      Choice = Data.define(:entry, :candidates, :chosen, :violations, :prior, :note, :why, :derivation, :refusal) do
        def moved?
          !chosen.current
        end

        # Short of its newest candidate.
        def solved?
          note == 'solved'
        end

        # No candidate fits: what the exit status reports.
        def unresolved?
          note.start_with?('unresolved')
        end

        def name
          entry.declared&.name || entry.metadata.name || File.basename(entry.path)
        end
      end

      # The result of a solve.
      #
      # @!attribute [r] choices
      #   @return [Array<Choice>] in dependency order
      # @!attribute [r] pruned
      #   @return [Array<String>] "module:dependency" edges the result
      #     violates among those pruned as unused; the exclusions to record
      # @!attribute [r] implicit
      #   @return [Array<String>] "module -> dependency" uses the evidence
      #     shows that no metadata declares
      # @!attribute [r] warnings
      #   @return [Array<String>] bumps and holds that matched nothing, bump
      #     refs that are not candidates
      Plan = Data.define(:choices, :pruned, :implicit, :warnings)

      # @param operatingsystems [Hash] `modules.operatingsystems`
      # @param requirements [Hash] `modules.requirements`
      # @param exclude [Hash] the `modules.exclude_*` globs
      # @param order [String] one of {ORDERS}: which fitting candidate the
      #   solver prefers, the newest or the nearest to the current
      # @param bumps [Hash{String => String, nil}] modules to move, by any
      #   spelling of the name, to a ref or to their newest candidate
      # @param holds [Array<String>] modules kept at their current version
      # @param evidence [Evidence, nil] what the site uses; with
      #   prune_unused, dependency edges to modules it shows unused are not
      #   constraints
      # @param prune_unused [Boolean]
      def initialize(operatingsystems: {}, requirements: {}, exclude: {}, order: 'newest', bumps: {}, holds: [],
                     evidence: nil, prune_unused: false)
        order = ORDER_ALIASES.fetch(order, order)
        raise ArgumentError, "order must be one of #{ORDERS.join(', ')}" unless ORDERS.include?(order)
        raise ArgumentError, '--prune-unused needs evidence' if prune_unused && evidence.nil?

        @operatingsystems = (operatingsystems || {}).to_h { |os, rel| [os.to_s, Array(rel).map(&:to_s)] }
        @exclude   = (exclude || {}).to_h { |list, globs| [list.to_s, Array(globs).map(&:to_s)] }
        @site      = ModuleResolver.new(requirements: requirements).instance_variable_get(:@site_range)
        @order     = order
        @bumps     = bumps.to_h { |k, v| [k.to_s, v] }
        @holds     = holds.map(&:to_s)
        @evidence  = evidence
        @prune     = prune_unused
      end

      # @param entries [Array<Driftless::ModuleInventory::Entry>]
      # @param candidates [Hash{String => Array<Candidate>, Unsolvable}] by entry path
      # @return [Plan]
      # @raise [Error] when no set can be found even with every misfit pinned
      def solve(entries, candidates)
        entries   = entries.select { |e| e.metadata.name && e.metadata.error.nil? && !excluded_module?(e.metadata.name) }
        @by_name  = index(entries)
        @warnings = []
        @matched  = { bump: [], hold: [] }
        @lists    = {}
        @reasons  = {}
        @by_name.each do |short, entry|
          list = candidates.fetch(entry.path) { Candidates::Unsolvable.new(reason: 'no candidates') }
          @reasons[short] = list.reason if list.is_a?(Candidates::Unsolvable)
          @lists[short]   = list.is_a?(Array) ? list : [current_candidate(entry)]
        end
        @versions = @lists.transform_values { |list| versions_of(list) }
        @current  = @lists.transform_values { |list| list.find(&:current) || list.first }
        @labels   = @lists.to_h { |short, list| [short, label_for(short, list)] }
        @levers   = @by_name.filter_map { |short, entry| (lever = lever_for(entry, @lists[short])) && [short, lever] }.to_h
        unmatched_levers

        state   = @current.transform_values { |c| version_of(c) }
        @prior  = @by_name.to_h { |short, entry| [short, violations(entry, @current[short], state)] }
        ignored = @ignored = Set.new
        @prior.each do |short, broken|
          broken.each do |v|
            if fixable?(short, v.key)
              Pupgrade.logger.debug("solve: #{short}: broken at #{@current[short]}: #{v}; a candidate meets it, so it stays a constraint")
            else
              Pupgrade.logger.debug("solve: #{short}: broken at #{@current[short]}: #{v}; no release meets it: unresolvable, kept from the solver")
              ignored << [short, v.key]
            end
          end
        end

        pinned = {}
        decisions = nil
        loop do
          source = build_source(ignored, pinned)
          decisions, failure = PubGrub.solve(source)
          break if decisions

          short = misfit(failure, source, pinned)
          unless short
            raise Error.new("no set of versions fits, and nothing more can give:\n#{failure.explanation}",
                            refusal: graph_refusal(nil, failure, source, 'no set of versions fits', nil))
          end

          # a lever kept where it puts the module is what does not fit
          kind, candidate = @levers[short]
          finding = kind ? "#{short} cannot be #{LEVER_WORDS[kind]} #{version_of(candidate)}" : "no version of #{short} fits the rest"
          pinned[short] = [pin_for(short, state), refusal(failure, finding, lever_fact(short)), graph_refusal(short, failure, source, finding, lever_fact(short))]
          Pupgrade.logger.info("solve: #{short}: #{kind ? "the --#{kind} does not fit the rest" : 'no version fits the rest'}; " \
                               "kept at #{pinned[short].first}, its constraints set aside")
        end

        choices = ordered.map { |short| choice_for(short, decisions, ignored, pinned) }
        # the ref alone (a Forge module's version), since the note says when it is current
        choices.each { |c| Pupgrade.logger.info("solve: #{c.name}: #{c.chosen.ref.to_s.empty? ? c.chosen.version : c.chosen.ref} (#{c.note})") }
        pruned = @by_name.flat_map { |short, entry| pruned_edges(entry, @lists[short].find { |c| version_of(c) == decisions[short] }, decisions) }
        Plan.new(choices: choices, pruned: pruned.uniq, implicit: implicit(entries), warnings: @warnings)
      end

      private

      # Modules by short name: owners differ between a dependent's metadata
      # and the module's own (`voxpupuli/firewalld` for `puppet-firewalld`),
      # and a modulepath holds one module of a name. Two deployed modules
      # sharing a short name is a warning; the first by path wins.
      def index(entries)
        entries.sort_by(&:path).each_with_object({}) do |e, h|
          k = key(e.metadata.name)
          if h.key?(k)
            Pupgrade.logger.warn("solve: #{e.path} and #{h[k].path} are both #{k}; only #{h[k].path} is considered")
            next
          end
          h[k] = e
        end
      end

      # The deployed version as the one candidate of a module with no
      # others.
      def current_candidate(entry)
        Candidates::Candidate.new(ref: entry.declared&.ref.to_s, ref_type: entry.declared&.ref_type || 'ref',
                                  version: parse(entry.metadata.version), metadata: entry.metadata, current: true)
      end

      def version_of(candidate)
        candidate.version || ZERO
      end

      # A module's versions in the order the solver prefers them: the
      # newest first, or from the current version up. Two candidates of one
      # version (a tag and a branch tip at it) are one version, the first
      # by candidate order.
      def versions_of(list)
        versions = list.map { |c| version_of(c) }.uniq
        (@order == 'newest') ? versions.sort.reverse : versions.sort
      end

      # The module's candidate at a version: the one its lever names when
      # that is at the version (a bump to a branch tip whose version a tag
      # also has), else the first of that version in candidate order.
      def candidate_at(short, version)
        lever = @levers&.dig(short, 1)
        return lever if lever && version_of(lever) == version

        @lists[short].find { |c| version_of(c) == version }
      end

      # ---- levers --------------------------------------------------------------

      # @return [Array(Symbol, Candidate), nil] :hold at the current
      #   candidate, or :bump at the ref named or the newest
      def lever_for(entry, list)
        name = entry.metadata.name
        if (hold = held_by_hand(name))
          @matched[:hold] << hold
          return [:hold, list.find(&:current) || list.first]
        end

        bump = bump_for(name)
        return nil unless bump

        @matched[:bump] << bump.first
        target = bump.last
        return [:bump, list.max_by { |c| [version_of(c), c.current ? 0 : 1] }] if target.nil? || target.empty?

        wanted = list.find { |c| [target, "v#{target}"].include?(c.ref) || c.version.to_s == target.sub(/\Av/, '') }
        return [:bump, wanted] if wanted

        others = list.reject(&:current).map(&:ref).join(', ')
        @warnings << "--bump #{bump.first}=#{target}: #{target} is not a candidate of #{entry.path} " \
                     "(candidates: #{others.empty? ? 'none' : others}; try --fetch)"
        Pupgrade.logger.debug("solve: #{entry.path}: bump #{target} not among #{list.size} candidate(s); solving as usual")
        nil
      end

      # @return [String, nil] the hold glob naming the module
      def held_by_hand(name)
        @holds.find { |g| ModuleName.match?(g, name) }
      end

      # @return [Array(String, String|nil), nil] the bump glob and its ref
      def bump_for(name)
        @bumps.find { |glob, _| ModuleName.match?(glob, name) }
      end

      # A --bump or --hold that named no module is a typo or a module that is
      # not a git clone; either way the user should hear.
      def unmatched_levers
        (@bumps.keys - @matched[:bump]).each { |g| @warnings << "--bump #{g} matches no module" }
        (@holds - @matched[:hold]).each { |g| @warnings << "--hold #{g} matches no module" }
      end

      # Whether a move of the module, or of the dependency a range names,
      # would meet a constraint the module's current version breaks.
      #
      # @return [Boolean] false for what the solve sets aside
      def fixable?(short, key)
        entry = @by_name[short]
        @lists[short].any? do |candidate|
          if key == 'puppet' || key.start_with?('os ')
            site_violations(entry, candidate.metadata).none? { |v| v.key == key }
          else
            next false if @by_name[key].nil?

            dep, requirement = candidate.metadata.dependencies.find { |d, _| key(d) == key }
            next true if dep.nil?

            range = range_for(requirement)
            range.nil? || @versions[key].any? { |v| range.include?(v) }
          end
        end
      end

      # ---- the solver's view -----------------------------------------------------

      # @param ignored [Set<Array(String, String)>] [module, key] constraints
      #   kept from the solver as unresolvable
      # @param pinned [Hash{String => Array(Candidate, String, Graph::Refusal)}]
      #   modules kept at a version whatever they need
      # @param asked [Array<Fact>] more facts, for the second query
      def build_source(ignored, pinned, *asked)
        facts = @levers.keys.map { |short| lever_fact(short) }
        facts += pinned.map do |short, (candidate, _)|
          PubGrub::Fact.new(package: short, range: PubGrub.except(version_of(candidate)), text: "#{short} is kept at #{version_of(candidate)} (no version fits)")
        end
        facts.concat(asked)
        dependencies = ->(short, version) do
          next {} if pinned.key?(short)

          candidate_at(short, version).metadata.dependencies.filter_map { |dep, requirement|
            dep_short = key(dep)
            next if constraint_dropped?(short, dep, dep_short, requirement) || ignored.include?([short, dep_short])

            [dep_short, requirement.to_s.strip.empty? ? nil : range_for(requirement)]
          }.to_h
        end
        reasons = ->(short, version) do
          next [] if pinned.key?(short)

          candidate = candidate_at(short, version)
          site_violations(@by_name[short], candidate.metadata).reject { |v| ignored.include?([short, v.key]) }
            .map { |v| [v.key, "#{short} #{version} #{v}"] }
        end
        PubGrub::Source.new(versions: @versions, dependencies: dependencies, reasons: reasons, facts: facts)
      end

      # An edge the config excludes, or one pruned as unused: to a module
      # the evidence shows unused or nobody deployed, or from one, since
      # what the site never runs needs nothing.
      def constraint_dropped?(short, dep, dep_short, requirement)
        return true if excluded_module?(dep) || Exclusions.dependency?(@exclude['dependencies'], [@by_name[short].metadata.name], [dep], requirement).first

        target = @by_name[dep_short]
        @prune && (target.nil? || !used?(target) || !used?(@by_name[short]))
      end

      # The module to pin when nothing fits, among those whose own
      # constraint is in the derivation: a lever's first, then one broken
      # before the solve that cannot mend itself by moving, then the one
      # with the fewest candidates.
      #
      # @return [String, nil]
      def misfit(failure, source, pinned)
        dependers = PubGrub.leaves(failure.incompatibility).filter_map { |inc| source.keys[inc]&.first }.uniq - pinned.keys
        dependers.min_by { |short| [@levers.key?(short) ? 0 : 1, needs_others?(short) ? 0 : 1, @lists[short].size, short] }
      end

      # Whether a constraint in force broke the module's current version
      # and no candidate of its own meets it against the deployed versions.
      def needs_others?(short)
        entry = @by_name[short]
        state = @current.transform_values { |c| version_of(c) }
        @prior[short].any? do |v|
          !@ignored.include?([short, v.key]) && @lists[short].none? { |c| violations(entry, c, state).none? { |w| w.key == v.key } }
        end
      end

      # The version a misfit is kept at: the lever's, else the candidate
      # breaking the least against the current versions, the current one
      # among equals, then the one preferred by order.
      def pin_for(short, state)
        return @levers[short].last if @levers.key?(short)

        entry = @by_name[short]
        ordered_list = @versions[short].map { |v| candidate_at(short, v) }
        scored = ordered_list.map { |c| [c, violations(entry, c, state)] }
        scored.each { |c, v| Pupgrade.logger.debug("solve: #{short}: #{c}: #{v.empty? ? 'fits the current versions' : v.join('; ')}") }
        scored.min_by.with_index { |(c, v), i| [v.size, c.current ? 0 : 1, i] }.first
      end

      # ---- the outcome ---------------------------------------------------------

      def choice_for(short, decisions, ignored, pinned)
        entry   = @by_name[short]
        chosen  = candidate_at(short, decisions[short])
        broken  = violations(entry, chosen, decisions)
        prior, fresh = broken.partition { |v| ignored.include?([short, v.key]) }
        # a pinned module breaking nothing at the version kept is noted as chosen
        note, why, derivation, refusal = note_for(short, chosen, fresh.empty? ? pinned.except(short) : pinned, decisions)
        Choice.new(entry: entry, candidates: @lists[short], chosen: chosen, violations: fresh, prior: prior,
                   note: note, why: why, derivation: derivation, refusal: refusal)
      end

      # @return [Array(String, String|nil, String|nil, Graph::Refusal|nil)]
      #   note, why, derivation, refusal
      def note_for(short, chosen, pinned, decisions)
        if @levers.key?(short)
          return [(@levers[short].first == :hold) ? 'held at current' : 'bumped', nil, pinned.dig(short, 1), pinned.dig(short, 2)]
        end
        return ["unresolved#{" (#{@reasons[short]})" if @reasons[short]}", nil, pinned[short][1], pinned[short][2]] if pinned.key?(short)
        return [@reasons[short], nil, nil, nil] if @reasons.key?(short)

        newest = @lists[short].map { |c| version_of(c) }.max
        return ['current', nil, nil, nil] if chosen.current && (version_of(chosen) == newest || @order == 'nearest')
        return ['newest', nil, nil, nil] if version_of(chosen) == newest && @order == 'newest'

        if @order == 'nearest'
          # moved the least it could: what pushed it off its current version
          current = version_of(@current[short])
          why, derivation, refusal = because(short, pinned, decisions, "stay at #{current}",
                                             PubGrub::Fact.new(package: short, range: PubGrub.except(current), text: "#{short} is held at #{current} (--explain)"))
          return ['nearest', why, derivation, refusal]
        end

        why, derivation, refusal = because(short, pinned, decisions, "go past #{version_of(chosen)}",
                                           PubGrub::Fact.new(package: short, range: PubGrub.up_to(version_of(chosen)), text: "#{short} is held above #{version_of(chosen)} (--explain)"))
        ['solved', why, derivation, refusal]
      end

      # Why a module is where it is: the solver is asked, under the same
      # facts, for a set with the module elsewhere (past its chosen
      # version, or off its current one), and the leaves of its refusal are
      # the module's own constraint in the way and what stands against it.
      # When such a set exists with the other modules free, it is asked
      # again with them where the chosen set has them, so the refusal names
      # what holds the module in this set.
      #
      # @param decisions [Hash{String => SemanticPuppet::Version}] the set chosen
      # @param move [String] the move asked about: "stay at 10.1.1"
      # @param asked [PubGrub::Fact] the versions ruled out, with its words
      # @return [Array(String, String|nil, Graph::Refusal|nil)] why, the
      #   whole derivation, and the derivation for `solve -g`
      def because(short, pinned, decisions, move, asked)
        source = build_source(@ignored, pinned, asked)
        _decisions, failure = PubGrub.solve(source)
        unless failure
          Pupgrade.logger.info("solve: #{short}: a set exists where it can #{move}; the order chose this one")
          held = decisions.except(short).map { |s, v| PubGrub::Fact.new(package: s, range: PubGrub.except(v), text: "#{s} is #{v} in this set") }
          source = build_source(@ignored, pinned, asked, *held)
          _decisions, failure = PubGrub.solve(source)
          return ["a set exists where it can #{move}", nil, nil] unless failure
        end

        texts   = PubGrub.leaves(failure.incompatibility).map { |inc| source.keys.fetch(inc) { [nil, nil, inc.to_s] } }.uniq
        # the constraint nearest the module: its own, else another module's on it
        own     = texts.select { |depender, _, _| depender == short }.map(&:last)
        own     = texts.select { |_, key, _| key == short }.map(&:last) if own.empty?
        noise   = ->(depender, text) { depender == short || text == asked.text || text.start_with?("no versions satisfy #{short} ") || text.end_with?(' is on the modulepath') || own.include?(text) }
        others  = texts.reject { |depender, _key, text| noise.call(depender, text) }.map(&:last)
        lever   = others.find { |t| t.include?('(--hold)') || t.include?('(--bump)') || t.include?('(no version fits)') }
        why     = [own.first, lever || others.first].compact.join('; ')
        Pupgrade.logger.debug("solve: #{short}: #{asked.text}:\n#{failure.explanation}")
        [why.empty? ? failure.explanation.lines.first.to_s.strip : why, refusal(failure, "#{short} cannot #{move}", asked),
         graph_refusal(short, failure, source, "#{short} cannot #{move}", asked)]
      end

      # The derivation as `solve -g` draws it.
      #
      # @return [Graph::Refusal]
      def graph_refusal(short, failure, source, conclusion, asked)
        Graph::Refusal.new(subject: short, conclusion: conclusion, incompatibility: failure.incompatibility, keys: source.keys,
                           noise: [asked&.text].compact, labels: @labels)
      end

      # A module's node label: its current version, then its candidates
      # past it, the middle elided past three.
      def label_for(short, list)
        current = list.find(&:current)
        rest    = list.reject(&:current).map { |c| version_of(c).to_s }.uniq
        rest    = [rest.first, '…', rest.last] if rest.size > 3
        versions = [current && "#{version_of(current)} (current)", *rest].compact
        versions.empty? ? short : "#{short} #{versions.join(' · ')}"
      end

      # The solver's derivation. When each step adds one leaf, it is the
      # finding and the leaves it rests on; else it is the solver's own
      # steps, closed by the finding.
      #
      # @param conclusion [String] "apache cannot stay at 10.1.1"
      # @param asked [PubGrub::Fact, nil] the version under test, which the
      #   finding already states
      # @return [String]
      def refusal(failure, conclusion, asked = nil)
        incompatibility = failure.incompatibility
        return failure.explanation.sub(/version solving has failed\.\z/, "#{conclusion}.") unless PubGrub.linear?(incompatibility)

        leaves = PubGrub.leaves(incompatibility).map(&:to_s).uniq - [asked&.text]
        ["#{conclusion},", "   because #{leaves.first}", *leaves.drop(1).map { |l| "      and #{l}" }].join("\n")
      end

      # The fact a --hold or --bump states: the module at that version.
      #
      # @return [PubGrub::Fact, nil] nil for a module with no lever
      def lever_fact(short)
        kind, candidate = @levers[short]
        return unless kind

        v = version_of(candidate)
        PubGrub::Fact.new(package: short, range: PubGrub.except(v), text: "#{short} is #{LEVER_WORDS[kind]} #{v} (--#{kind})")
      end

      # ---- constraints -----------------------------------------------------------

      # The constraints a candidate breaks against a state: the versions
      # decided, or the current ones for what is not.
      #
      # @param state [Hash{String => SemanticPuppet::Version}] by short name
      # @return [Array<Violation>]
      def violations(entry, candidate, state)
        metadata = candidate.metadata
        out = []
        metadata.dependencies.each do |dep, requirement|
          dep_short = key(dep)
          next if constraint_dropped?(key(entry.metadata.name), dep, dep_short, requirement)

          target = @by_name[dep_short]
          text   = "needs #{dep} #{requirement || '(any version)'}"
          glob   = "#{entry.metadata.name}:#{dep}#{" #{requirement}" if requirement}"
          if target.nil?
            out << Violation.new(key: dep_short, text: text, fault: "#{dep_short} is not on the modulepath", exclusion: glob)
            next
          end
          range    = range_for(requirement)
          deployed = parse(target.metadata.version)
          version  = state.fetch(dep_short) { deployed }
          next if range.nil? || version.nil? || range.include?(version)

          fault = (version == deployed) ? "#{dep_short} is #{version}" : "#{dep_short} moves to #{version}"
          out << Violation.new(key: dep_short, text: text, fault: fault, exclusion: glob)
        end
        out.concat(site_violations(entry, metadata))
      end

      # What the site asks of every module: its Puppet requirement and the
      # operating systems of interest.
      def site_violations(entry, metadata)
        out = []
        puppet = puppet_range(metadata)
        if puppet && @site && puppet.intersection(@site) == ModuleResolver::EMPTY && !Exclusions.requirement?(@exclude['requirements'], entry.metadata.name)
          out << Violation.new(key: 'puppet', text: "requires puppet #{puppet}", fault: "the control repo requires #{@site}", exclusion: entry.metadata.name)
        end
        out.concat(os_violations(entry, metadata))
      end

      def os_violations(entry, metadata)
        support = metadata.operatingsystem_support
        return [] if @operatingsystems.empty? || support.empty?

        @operatingsystems.flat_map do |os, releases|
          declared = support.find { |n, _| n.casecmp?(os) }&.last
          (releases.empty? ? [nil] : releases).filter_map { |release|
            subject = [os, release].compact.join(' ')
            next if Exclusions.operatingsystem?(@exclude['operatingsystems'], [entry.metadata.name], subject)

            if declared.nil?
              Violation.new(key: "os #{os}", text: "supports #{support.keys.join(', ')}", fault: "missing #{os}", exclusion: "#{entry.metadata.name}:#{os} *")
            elsif release && !declared.empty? && declared.none? { |d| d == release || release.start_with?("#{d}.") }
              Violation.new(key: "os #{os}", text: "supports #{os} #{declared.join(', ')}", fault: "missing #{subject}", exclusion: "#{entry.metadata.name}:#{subject}")
            end
          }.uniq
        end
      end

      # The pruned dependency edges the chosen version violates: what to
      # record as exclusions so `check` agrees with the plan.
      def pruned_edges(entry, chosen, decided)
        return [] unless @prune

        chosen.metadata.dependencies.filter_map do |dep, requirement|
          target = @by_name[key(dep)]
          next if target.nil? || (used?(target) && used?(entry))

          range   = range_for(requirement)
          version = decided.fetch(key(dep)) { parse(target.metadata.version) }
          "#{entry.metadata.name}:#{dep}" if range && version && !range.include?(version)
        end
      end

      # Modules in dependency order: a module after everything its current
      # metadata depends on; a cycle's members follow by name.
      #
      # @return [Array<String>] short names
      def ordered
        remaining = @by_name.dup
        deps_of   = remaining.to_h { |n, e| [n, e.metadata.dependencies.keys.map { |d| key(d) }.select { |d| remaining.key?(d) && d != n }] }
        order = []
        until remaining.empty?
          ready = remaining.keys.select { |n| deps_of[n].none? { |d| remaining.key?(d) } }.sort
          ready = [remaining.keys.min] if ready.empty?
          ready.each do |n|
            order << n
            remaining.delete(n)
          end
        end
        order
      end

      # Functions the evidence shows one module calling from another that
      # the caller's metadata does not depend on.
      def implicit(entries)
        return [] unless @evidence

        by_base = entries.to_h { |e| [File.basename(e.path), e] }
        @evidence.calls.flat_map { |user, providers|
          entry = by_base[user]
          next [] unless entry

          declared = entry.metadata.dependencies.keys.map { |d| key(d) }
          providers.sort.filter_map { |p| "#{entry.metadata.name} -> #{p}" unless declared.include?(p) || p == user }
        }.sort
      end

      def used?(entry)
        return true if entry.nil? || @evidence.nil?

        @evidence.used?(File.basename(entry.path))
      end

      def puppet_range(metadata)
        declared = metadata.requirements.values_at(*::Driftless::Inputs::ModuleMetadata::PUPPET_REQUIREMENT_NAMES).compact
        parsed   = declared.filter_map { |r| range_for(r) }
        parsed.empty? ? nil : parsed.reduce { |a, b| a.intersection(b) }
      end

      def range_for(requirement)
        return ModuleResolver::ALL if requirement.nil? || requirement.strip.empty?

        SemanticPuppet::VersionRange.parse(requirement)
      rescue ArgumentError
        nil
      end

      def parse(version)
        SemanticPuppet::Version.parse(version.to_s)
      rescue SemanticPuppet::Version::ValidationFailure
        nil
      end

      def excluded_module?(name)
        Exclusions.module?(@exclude['modules'], name)
      end

      # The name modules are indexed by.
      def key(name)
        ModuleName.short(name)
      end
    end
  end
end
