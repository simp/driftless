require 'semantic_puppet'

require 'driftless/config_keys'
require 'driftless/module_inventory'

module Driftless
  # Checks a control repo's modules against each other's metadata: every
  # dependency present at a version in range, some Puppet version allowed by
  # every requirement, and support declared for the operating systems of
  # interest. Only modules whose metadata names them take part.
  class ModuleResolver
    extend ConfigKeys::DSL

    config_key 'modules.operatingsystems', type: :hash, default: nil,
               example: { 'RedHat' => %w[8 9], 'Ubuntu' => ['22.04'] },
               about: 'Operating systems, with releases, that every module declaring operatingsystem_support ' \
                      'must include. A release matches as written or as the major of a dotted release. ' \
                      'Empty: operating systems are not checked'
    config_key 'modules.requirements', type: :hash, default: nil,
               example: { 'puppet' => '>= 8.0.0 < 9.0.0' },
               about: 'The Puppet versions the control repo itself runs or is moving to, as a module\'s ' \
                      'metadata.json would declare them (`puppet` or `openvox`); a module whose requirement ' \
                      'shares no version with it is a puppet-version conflict'
    config_key 'modules.exclude_modules', type: :array, default: [],
               about: 'Globs (case-insensitive) of module names left out of every check: never a row, ' \
                      'a dependency anyone is held to, or a module another is compared with'
    config_key 'modules.exclude_dependencies', type: :array, default: [],
               about: 'Globs (case-insensitive) dropping dependency conflicts, which are edges, not modules: ' \
                      'matched against the depending module, the dependency, or module:dependency'
    config_key 'modules.exclude_requirements', type: :array, default: [],
               about: 'Globs (case-insensitive) dropping Puppet-version conflicts: matched against the module, ' \
                      'and against each module it disagrees with, which then no longer counts against it'
    config_key 'modules.exclude_operatingsystems', type: :array, default: [],
               about: 'Globs (case-insensitive) dropping operating-system conflicts: matched against the module, ' \
                      '"OS release", or "module:OS release"'

    # A site requirement that does not parse.
    class Error < StandardError; end

    # How the control repo's own requirement is named among a row's
    # counterparts.
    SITE = 'the control repo'.freeze

    KINDS = %w[missing-dependency dependency-version puppet-version operatingsystem].freeze

    # Which exclusion list each kind reads.
    EXCLUDE_LIST = {
      'missing-dependency' => 'dependencies', 'dependency-version' => 'dependencies',
      'puppet-version' => 'requirements', 'operatingsystem' => 'operatingsystems'
    }.freeze

    # @!attribute [r] kind
    #   @return [String] one of {KINDS}
    # @!attribute [r] module
    #   @return [String] the module whose metadata makes the claim, by name
    # @!attribute [r] subject
    #   @return [String] what the claim is about: the dependency's name,
    #     "puppet", or the operating system with its release
    # @!attribute [r] detail
    #   @return [String] the claim and what was found instead
    Conflict = Data.define(:kind, :module, :subject, :detail)

    # @!attribute [r] conflicts
    #   @return [Array<Conflict>] those not excluded, by kind, module, subject
    # @!attribute [r] excluded
    #   @return [Integer] how many the exclusion globs dropped
    # @!attribute [r] puppet_range
    #   @return [String, nil] the Puppet versions every requirement allows;
    #     nil when no version does
    # @!attribute [r] warnings
    #   @return [Array<String>] metadata that could not be compared
    Result = Data.define(:conflicts, :excluded, :puppet_range, :warnings)

    EMPTY = SemanticPuppet::VersionRange::EMPTY_RANGE
    ALL   = SemanticPuppet::VersionRange::ALL_RANGE

    # @param operatingsystems [Hash{String => Array<String>, String, nil}]
    #   `modules.operatingsystems`: OS name => releases of interest, or none
    # @param exclude [Hash{String => Array<String>}] the `modules.exclude_*`
    #   globs, keyed modules, dependencies, requirements, operatingsystems
    # @param requirements [Hash{String => String}] `modules.requirements`:
    #   `puppet` or `openvox` to a version range
    # @raise [Error] on a requirement that does not parse
    def initialize(operatingsystems: {}, exclude: {}, requirements: {})
      @operatingsystems = (operatingsystems || {}).to_h { |os, rel| [os.to_s, Array(rel).map(&:to_s)] }
      @exclude = (exclude || {}).to_h { |list, globs| [list.to_s, Array(globs).map(&:to_s)] }
      @site_range = site_range(requirements || {})
    end

    # @param entries [Array<ModuleInventory::Entry>]
    # @return [Result]
    def resolve(entries)
      mods     = entries.select { |e| e.metadata.name && e.metadata.error.nil? && !excluded_module?(e.metadata.name) }
      warnings = []
      puppet_conflicts, puppet_range, suppressed = puppet(mods, warnings)
      conflicts = dependencies(mods, warnings) + puppet_conflicts + operatingsystems(mods)
      kept, dropped = conflicts.partition { |c| !excluded?(c) }
      Result.new(conflicts: kept.sort_by { |c| [KINDS.index(c.kind), c.module, c.subject] },
                 excluded: dropped.size + suppressed, puppet_range: puppet_range, warnings: warnings)
    end

    private

    def dependencies(mods, warnings)
      by_name = mods.to_h { |e| [normalize(e.metadata.name), e] }
      mods.flat_map do |e|
        e.metadata.dependencies.filter_map do |dep, requirement|
          next if excluded_module?(dep)

          range = range_for(requirement, "#{e.metadata.name}: dependency #{dep}", warnings)
          next unless range

          found = by_name[normalize(dep)]
          if found.nil?
            Conflict.new(kind: 'missing-dependency', module: e.metadata.name, subject: dep,
                         detail: "needs #{dep} #{requirement || '(any version)'}; not on the modulepath")
          else
            version = version_for(found, warnings)
            next if version.nil? || range.include?(version)

            Conflict.new(kind: 'dependency-version', module: e.metadata.name, subject: dep,
                         detail: "needs #{dep} #{requirement}; #{found.path} is #{found.metadata.version}")
          end
        end
      end
    end

    # Each module against the rest, pairwise, the control repo's own
    # requirement among them: a module is in conflict with every one whose
    # Puppet range shares no version with its own, the ones
    # `exclude_requirements` names left out. The control repo gets no row
    # of its own; the modules disagreeing with it are the list.
    #
    # @return [Array(Array<Conflict>, String|nil, Integer)] conflicts, the
    #   range every requirement allows, and how many rows the exclusions
    #   emptied
    def puppet(mods, warnings)
      ranges = mods.filter_map do |e|
        declared = e.metadata.requirements.values_at(*Inputs::ModuleMetadata::PUPPET_REQUIREMENT_NAMES).compact
        parsed   = declared.filter_map { |r| range_for(r, "#{e.metadata.name}: requirement puppet", warnings) }
        [e.metadata.name, parsed.reduce { |a, b| a.intersection(b) }] unless parsed.empty?
      end
      ranges.unshift([SITE, @site_range]) if @site_range
      overall = ranges.map(&:last).reduce(ALL) { |a, b| a.intersection(b) }
      return [[], overall.to_s, 0] unless overall == EMPTY

      suppressed = 0
      conflicts  = ranges.filter_map do |pair|
        name, range = pair
        next if name == SITE

        disagreeing = ranges.reject { |other| other.equal?(pair) || range.intersection(other.last) != EMPTY }
        against     = disagreeing.reject { |other_name, _| matches?('requirements', other_name) }
        suppressed += 1 if against.empty? && disagreeing.any?
        next if against.empty?

        named = against.first(5).map { |other_name, r| "#{other_name} (#{r})" }
        named << "#{against.size - 5} more" if against.size > 5
        Conflict.new(kind: 'puppet-version', module: name, subject: 'puppet',
                     detail: "requires puppet #{range}; no version in common with #{named.join(', ')}")
      end
      [conflicts, nil, suppressed]
    end

    # The control repo's requirement as one range: `puppet` and `openvox`
    # intersected when both are given.
    #
    # @return [SemanticPuppet::VersionRange, nil] nil when none is declared
    def site_range(requirements)
      names    = Inputs::ModuleMetadata::PUPPET_REQUIREMENT_NAMES
      declared = requirements.to_h { |k, v| [k.to_s, v] }.values_at(*names).compact
      return nil if declared.empty?

      declared.map { |r| parse_site_range(r) }.reduce { |a, b| a.intersection(b) }
    end

    def parse_site_range(requirement)
      SemanticPuppet::VersionRange.parse(requirement.to_s)
    rescue ArgumentError
      raise Error, "modules.requirements: cannot parse version requirement #{requirement.inspect}"
    end

    def operatingsystems(mods)
      return [] if @operatingsystems.empty?

      mods.flat_map do |e|
        support = e.metadata.operatingsystem_support
        next [] if support.empty?

        @operatingsystems.flat_map do |os, releases|
          declared = support.find { |name, _| name.casecmp?(os) }&.last
          wanted   = releases.empty? ? [nil] : releases
          wanted.filter_map do |release|
            subject = [os, release].compact.join(' ')
            if declared.nil?
              Conflict.new(kind: 'operatingsystem', module: e.metadata.name, subject: subject,
                           detail: "missing #{os} (declared: #{support.keys.join(', ')})")
            elsif release && !declared.empty? && declared.none? { |d| release_matches?(d, release) }
              Conflict.new(kind: 'operatingsystem', module: e.metadata.name, subject: subject,
                           detail: "missing #{subject} (declared: #{os} #{declared.join(', ')})")
            end
          end
        end
      end
    end

    # "9" matches "9" and "9.2"; "22.04" matches only "22.04".
    def release_matches?(declared, wanted)
      declared == wanted || wanted.start_with?("#{declared}.")
    end

    def excluded?(conflict)
      matches?(EXCLUDE_LIST.fetch(conflict.kind), conflict.module, conflict.subject, "#{conflict.module}:#{conflict.subject}")
    end

    # A module `exclude_modules` names, by either spelling of its name.
    def excluded_module?(name)
      matches?('modules', name, normalize(name))
    end

    # Whether any glob in the named exclusion list matches any candidate.
    def matches?(list, *candidates)
      @exclude.fetch(list, []).any? { |g| candidates.any? { |c| File.fnmatch?(g, c, File::FNM_CASEFOLD) } }
    end

    # Forge names are "owner-module"; dependencies often write "owner/module".
    def normalize(name)
      name.to_s.tr('/', '-').downcase
    end

    # @return [SemanticPuppet::VersionRange, nil] nil, with a warning, when
    #   the requirement does not parse; the whole range when there is none
    def range_for(requirement, what, warnings)
      return ALL if requirement.nil? || requirement.strip.empty?

      SemanticPuppet::VersionRange.parse(requirement)
    rescue ArgumentError
      warnings << "#{what}: cannot parse version requirement #{requirement.inspect}"
      nil
    end

    # @return [SemanticPuppet::Version, nil] nil, with a warning, when the
    #   module's version is missing or not semantic
    def version_for(entry, warnings)
      version = entry.metadata.version
      if version.nil?
        warnings << "#{entry.metadata.name}: version unknown; dependencies on it are not checked"
        return nil
      end
      SemanticPuppet::Version.parse(version)
    rescue SemanticPuppet::Version::ValidationFailure
      warnings << "#{entry.metadata.name}: version #{version.inspect} is not semantic; dependencies on it are not checked"
      nil
    end
  end
end
