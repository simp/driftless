#!/opt/puppetlabs/puppet/bin/ruby
# frozen_string_literal: true

# module-support-history.rb
#
# Walk the git history of one or more Puppet modules and report the
# most recent tagged version of each that declared support for a target
# (Puppet runtime, OS release, optional dependency, etc.) expressed as
# a dotted metadata.json key-path plus a name and a version_to_check.
#
# Usage:
#   module-support-history.rb <key_path> <name> <version> [<source>]
#

require 'json'
require 'open3'
require 'optparse'
require 'set'
require 'time'
require 'semantic_puppet'

EXIT_OK         = 0
EXIT_FAIL       = 1   # at least one module unsupported or a split-decision
EXIT_USAGE      = 2

KEY_PATH_ALIASES = {
  'os'              => 'operatingsystem_support',
  'operatingsystem' => 'operatingsystem_support',
  'req'             => 'requirements',
  'reqs'            => 'requirements',
  'dep'             => 'dependencies',
  'deps'            => 'dependencies',
}.freeze

# ---------------------------------------------------------------------------
# Cli
# ---------------------------------------------------------------------------
module Cli
  module_function

  def parse_args(argv)
    opts = {
      all_anomalies:     false,
      sort_by_date:      false,
      hide_requirements: false,
      hide_tags:         false,
      hide_notes:        false,
      fetch:             false,
      earliest:          false,
      show_latest_tag:   false,
      hide_unsupported:  false,
    }

    parser = OptionParser.new do |o|
      o.banner = <<~BANNER
        Usage:
          #{File.basename($0)} [options] <KEY_PATH> <NAME> <version> [<source>]

        Arguments:
          KEY_PATH   Dot-separated path into metadata.json (e.g. "requirements",
                     "simp.optional_dependencies", "operatingsystem_support").
          NAME       Name/Regex to look up inside the arrays under <KEY_PATH>.
          version    Version string (e.g. "7", "8.19", "7.5"). Padded to x.y.z
                     SemVer-shape checks are padded to x.y.z
                     operatingsystem_support versions are free-form/Regex
          source     Optional. One of:
                       - path to an environment.conf file
                       - a colon-separated modulepath of existing directories
                       - a single module directory (contains metadata.json)
                       - a tree of module directories (each child with metadata.json)
                     If omitted, looks for ./environment.conf, then ./modules/,
                     then ./metadata.json.

        Examples:
          # What version of each module last supported Puppet 7?
            #{File.basename($0)} requirements puppet 7

          # When did each module first add Puppet 8 support?
            #{File.basename($0)} --earliest requirements 'puppet|openvox' 8

          # Last versions of each module that supported RedHat 6?  (prefix-matches '6', '6.x', '6.1', ...)
            #{File.basename($0)} operatingsystem_support RedHat 6

          # Which modules depend on puppetlabs/stdlib >= 9?
            #{File.basename($0)} dependencies puppetlabs/stdlib 9

          # SIMP-specific: modules listing simp/auditd 10 as an optional dependency?
          # (Fetches most recent tags from repo before checking)
            #{File.basename($0)} simp.optional_dependencies simp/auditd 10 --fetch-tags

        Options:
      BANNER

      o.on('-a', '--all-anomalies',
           "Show ALL tag-history anomalies, even if they aren't relevent to the query.",
            'Useful for debugging repo weirdness or this tool.  WARNNG: can make tables VERY busy') { opts[:all_anomalies] = true }

      o.on('-d', '--sort-by-date',
           'Sort rows by matching tag date, newest first.',) { opts[:sort_by_date] = true }
      o.on('-e', '--earliest',
           "Find the _earliest_ (instead of latest) tagged release when metadata.json claimed",
           'support for VERSION of KEY_PATH: NAME'){ opts[:earliest] = true }

      o.on('-f', '--fetch-tags',
           'Run `git fetch --tags` in each repo before walking, to reflect the latest upstream truth',
           'Requires network/access to git remotes.') { opts[:fetch] = true }

      o.on('-L', '--show-latest-tag',
           "In the *unmatched* modules table, include columns for",
           "each module's latest SemVer-ish tag and its date.  Sometimes useful to judge module staleness") { opts[:show_latest_tag] = true }

      o.on('-R', '--hide-requirements',
           'Omit "Version Requirements" column from results tables.') { opts[:hide_requirements] = true }

      o.on('-T', '--hide-tags',
           'Omit "Tag" column from results tables.') { opts[:hide_tags] = true }

      o.on('-N', '--hide-notes',
           'Omit "Notes" column from results tables.') { opts[:hide_notes] = true }

      o.on('-U', '--hide-unsupported',
           'Omit the unmatched-modules table entirely;',
           '(Unmatched modules are still reflected in summary and exit code.') { opts[:hide_unsupported] = true }
    end

    begin
      rest = parser.parse(argv)
    rescue OptionParser::InvalidOption => e
      warn "error: #{e}"
      warn parser.help
      exit EXIT_USAGE
    end

    if rest.size < 3 || rest.size > 4
      warn parser.help
      exit EXIT_USAGE
    end

    key_path, name_arg, version_arg, source = *rest
    key_path = KEY_PATH_ALIASES.fetch(key_path, key_path)

    # NAME: normalize || → | (backward compat), then compile as anchored regex
    name_str = name_arg.gsub('||', '|')
    if name_str.empty?
      warn "error: <name> is empty"
      warn parser.help
      exit EXIT_USAGE
    end
    name_pattern = compile_name_pattern(name_str, parser)

    # VERSION: split on | for multiple alternatives; other regex metacharacters rejected
    versions = version_arg.split('|').map(&:strip)
    versions = [''] if versions.empty?
    versions.each do |v|
      next if v.empty?
      if v.match?(/[*?()\[\]{}^$\\]/)
        warn "error: version #{v.inspect} contains regex metacharacters; only '|' is supported as a delimiter in version (use '' for any version)"
        warn parser.help
        exit EXIT_USAGE
      end
    end

    opts.merge(
      key_path:     key_path,
      name_str:     name_str,
      name_pattern: name_pattern,
      version:      version_arg,
      versions:     versions,
      source:       source,
    )
  end

  def compile_name_pattern(s, parser = nil)
    # Auto-anchor with \A(?:...)\z unless the user already anchored one or both ends.
    # Wrapping in (?:...) ensures | alternation is scoped correctly.
    pat = s.start_with?('\A', '^') ? s : "\\A(?:#{s})"
    pat = pat.end_with?('\z', '\Z', '$') ? pat : "#{pat}\\z"
    Regexp.new(pat, Regexp::IGNORECASE)
  rescue RegexpError => e
    warn "error: invalid name pattern #{s.inspect}: #{e.message}"
    warn parser.help if parser
    exit EXIT_USAGE
  end
end

# ---------------------------------------------------------------------------
# EnvironmentConf
# ---------------------------------------------------------------------------
module EnvironmentConf
  module_function

  # Parse an environment.conf file and return the modulepath entries
  # (after dropping $-interpolated tokens such as $basemodulepath).
  # Also returns warnings about dropped or missing paths.
  def modulepath_from(path)
    content = File.read(path)
    line = content.lines.find { |l| l =~ /^\s*modulepath\s*=/ }
    raise "no modulepath= directive found in #{path}" if line.nil?

    rhs = line.sub(/^\s*modulepath\s*=\s*/, '').strip
    # Strip wrapping quotes if any
    rhs = rhs.sub(/\A(['"])(.*)\1\z/, '\2')
    raw_entries = rhs.split(':').map(&:strip).reject(&:empty?)

    warnings = []
    kept = []
    raw_entries.each do |entry|
      if entry.start_with?('$')
        warnings << "environment.conf: dropping interpolated entry #{entry} (e.g. $basemodulepath)"
        next
      end
      # Resolve relative paths against the environment.conf's directory
      resolved = File.expand_path(entry, File.dirname(File.expand_path(path)))
      if !File.directory?(resolved)
        warnings << "environment.conf: modulepath entry does not exist: #{entry}"
        next
      end
      kept << resolved
    end
    [kept, warnings]
  end
end

# ---------------------------------------------------------------------------
# SourceResolver
# ---------------------------------------------------------------------------
module SourceResolver
  module_function

  # Resolve a source argument (or auto-detect from cwd) into:
  #   [module_dirs, info_messages, warnings]
  def resolve(source)
    info = []
    warnings = []

    if source.nil? || source.empty?
      source = autodetect(info)
    elsif File.directory? source
      # Check if directory is a control repo, etc
      refined_source=autodetect(info,source)
      source = refined_source if (refined_source != source)
    end

    if File.file?(source) && source.end_with?('.conf')
      paths, w = EnvironmentConf.modulepath_from(source)
      warnings.concat(w)
      info << "source: environment.conf #{source} -> modulepath: #{paths.join(':')}"
      modules = paths.flat_map { |p| modules_under(p) }
      return [modules.uniq, info, warnings]
    end

    if source.include?(':')
      parts = source.split(':').map(&:strip).reject(&:empty?)
      parts.reject! { |p| p.start_with?('$') }
      missing = parts.reject { |p| File.directory?(p) }
      warnings.concat(missing.map { |p| "modulepath entry does not exist: #{p}" })
      good = parts - missing
      info << "source: modulepath -> #{good.join(':')}"
      modules = good.flat_map { |p| modules_under(p) }
      return [modules.uniq, info, warnings]
    end

    unless File.directory?(source)
      raise "source is not a file or directory: #{source}"
    end

    abs = File.expand_path(source)
    if File.file?(File.join(abs, 'metadata.json'))
      info << "source: single module #{abs}"
      return [[abs], info, warnings]
    end

    found = modules_under(abs)
    info << "source: tree under #{abs} -> #{found.size} modules"
    [found, info, warnings]
  end

  def autodetect(info, path=Dir.pwd)
    env = File.join(path, 'environment.conf')
    mods = File.join(path, 'modules')
    md = File.join(path, 'metadata.json')
    if File.file?(env)
      info << "[INFO] source omitted; using ./environment.conf"
      return env
    end
    if File.directory?(mods)
      info << "[INFO] source omitted; using ./modules/"
      return mods
    end
    if File.file?(md)
      info << "[INFO] source omitted; using ./ (single module)"
      return path
    end
    warn "error: no source argument given and no environment.conf, modules/, or metadata.json found in #{path}"
    exit EXIT_USAGE
  end

  def modules_under(dir)
    return [] unless File.directory?(dir)
    Dir.children(dir).sort.map { |c| File.join(dir, c) }
       .select { |p| File.directory?(p) && File.file?(File.join(p, 'metadata.json')) }
  end
end

# ---------------------------------------------------------------------------
# GitRepo
# ---------------------------------------------------------------------------
module GitRepo
  module_function

  def repo?(dir)
    File.exist?(File.join(dir, '.git'))
  end

  # [{name:, date:, sha:}, ...]  sha is the commit SHA (deref'd for annotated)
  def tags(dir)
    out, err, status = Open3.capture3(
      'git', 'for-each-ref', 'refs/tags',
      '--format=%(refname:short)|%(creatordate:iso-strict)|%(objectname)|%(*objectname)',
      chdir: dir,
    )
    unless status.success?
      raise "git for-each-ref failed in #{dir}: #{err.strip}"
    end
    out.each_line.map do |l|
      name, date_s, obj, deref = l.chomp.split('|', 4)
      sha = (deref && !deref.empty?) ? deref : obj
      date = begin
        Time.parse(date_s)
      rescue ArgumentError
        nil
      end
      { name: name, date: date, sha: sha }
    end
  end

  def show_file(dir, ref, path)
    out, _err, status = Open3.capture3('git', 'show', "#{ref}:#{path}", chdir: dir)
    status.success? ? out : nil
  end

  def head_sha(dir)
    out, _err, status = Open3.capture3('git', 'rev-parse', 'HEAD', chdir: dir)
    status.success? ? out.strip : nil
  end

  def has_remote?(dir)
    out, _e, st = Open3.capture3('git', 'remote', chdir: dir)
    st.success? && !out.strip.empty?
  end

  # Returns [:ok, nil] or [:failed, reason_string]. Call has_remote? first.
  def fetch_tags(dir)
    _o, err, status = Open3.capture3('git', 'fetch', '--tags', '--quiet', chdir: dir)
    status.success? ? [:ok, nil] : [:failed, err.lines.first&.chomp || 'unknown error']
  end
end

# ---------------------------------------------------------------------------
# TagClassifier
# ---------------------------------------------------------------------------
module TagClassifier
  SEMVERISH_RE = /(\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.\-+]+)?)/.freeze

  module_function

  # Input: array of {name:, date:, sha:}
  # Returns:
  #   {
  #     ordered:   [tag-with-version-or-nil, ...] in descending order to walk,
  #     semver:    [{...tag, version:}],
  #     other:     [{...tag}],
  #     anomalies: [warning strings],
  #     fallback:  bool,
  #   }
  def classify(tags)
    semver = []
    other  = []
    tags.each do |t|
      m = t[:name].match(SEMVERISH_RE)
      parsed = m && begin
        SemanticPuppet::Version.parse(m[1])
      rescue StandardError
        nil
      end
      if parsed
        semver << t.merge(version: parsed)
      else
        other << t
      end
    end

    anomalies = []
    fallback = false

    if semver.empty?
      ordered = tags.sort_by { |t| t[:date] || Time.at(0) }.reverse
      fallback = true
      anomalies << "no SemVer-ish tags; falling back to date-descending order" unless tags.empty?
    else
      ordered = semver.sort_by { |t| t[:version] }.reverse
      # Within each major version, flag *definite* disagreements: a higher
      # version that was actually tagged before a lower version. Equal dates
      # (commits made within the same second) are not anomalies, and pairs
      # of tags that parse to the SAME SemVer (e.g. "v2.2.0" and "2.2.0",
      # which are conventional aliases for the same release) are not either.
      ordered.group_by { |t| t[:version].major }.each do |major, group|
        next if group.size < 2
        group.each_cons(2) do |higher, lower|
          next if higher[:date].nil? || lower[:date].nil?
          next if higher[:version] == lower[:version]
          if higher[:date] < lower[:date]
            anomalies << {
              text:            "tag order anomaly in major #{major}: #{higher[:name]} (#{higher[:date].iso8601}) is a higher version than #{lower[:name]} (#{lower[:date].iso8601}) but was tagged earlier",
              latest_version:  higher[:version],
              latest_date:     [higher[:date], lower[:date]].compact.max,
              involved_majors: Set[major],
            }
          end
        end
      end
    end

    {
      ordered:   ordered,
      semver:    semver,
      other:     other,
      anomalies: anomalies,
      fallback:  fallback,
    }
  end
end

# ---------------------------------------------------------------------------
# SupportCheck
# ---------------------------------------------------------------------------
module SupportCheck
  module_function

  # check(metadata_hash, key_path, name_pattern, versions)
  # =>
  #   {
  #     status:   :supported | :not_supported | :not_present | :split | :error,
  #     shape:    :requirement | :os | nil,
  #     matches:  [{name:, requirement: or releases:, supports: bool}, ...],
  #     warnings: [str, ...],
  #     error:    optional error string,
  #   }
  def check(metadata, key_path, name_pattern, versions)
    arr = navigate(metadata, key_path)
    if arr.nil?
      return { status: :not_present, shape: nil, matches: [], warnings: [], error: nil }
    end
    unless arr.is_a?(Array) && arr.all? { |e| e.is_a?(Hash) }
      return { status: :error, shape: nil, matches: [], warnings: [],
               error: "value at #{key_path.inspect} is not an array of hashes" }
    end
    return { status: :not_present, shape: nil, matches: [], warnings: [], error: nil } if arr.empty?

    sample = arr.first
    if sample.key?('version_requirement')
      check_requirement_shape(arr, name_pattern, versions)
    elsif sample.key?('operatingsystem')
      check_os_shape(arr, name_pattern, versions)
    else
      { status: :error, shape: nil, matches: [], warnings: [],
        error: "entries at #{key_path.inspect} lack both 'version_requirement' and 'operatingsystem'" }
    end
  end

  def navigate(obj, dotted)
    cur = obj
    dotted.split('.').each do |seg|
      return nil unless cur.is_a?(Hash) && cur.key?(seg)
      cur = cur[seg]
    end
    cur
  end

  def normalize_name(s)
    s.to_s.downcase.tr('/', '-')
  end

  def pad_version(v)
    return v if v =~ /\A\d+\.\d+\.\d+/
    parts = v.split('-', 2)
    head = parts[0]
    tail = parts[1] ? "-#{parts[1]}" : ''
    nums = head.split('.')
    nums << '0' while nums.size < 3
    nums.first(3).join('.') + tail
  end

  def check_requirement_shape(arr, name_pattern, versions)
    any_version = versions.all?(&:empty?)
    target_vers = unless any_version
      versions.filter_map { |v|
        begin
          SemanticPuppet::Version.parse(pad_version(v))
        rescue StandardError => e
          return { status: :error, shape: :requirement, matches: [], warnings: [],
                   error: "cannot parse target version #{v.inspect}: #{e.message}" }
        end
      }
    end

    matches = []
    warnings = []

    arr.each do |entry|
      next unless entry['name']
      raw = entry['name'].to_s
      # Match against both raw name and normalized form (handles / vs - in module names)
      next unless name_pattern.match?(raw) || name_pattern.match?(normalize_name(raw))
      req_str = entry['version_requirement'].to_s
      supports = if any_version
        true
      else
        range = begin
          SemanticPuppet::VersionRange.parse(req_str)
        rescue StandardError => e
          warnings << "cannot parse version_requirement #{req_str.inspect} for #{raw}: #{e.message}"
          nil
        end
        range ? target_vers.any? { |tv| range.include?(tv) } : false
      end
      matches << { name: raw, requirement: req_str, supports: supports }
    end

    return { status: :not_present, shape: :requirement, matches: [], warnings: warnings, error: nil } if matches.empty?

    if matches.size >= 2
      uniq_reqs = matches.map { |m| canonicalise(m[:requirement]) }.uniq
      if uniq_reqs.size > 1
        warnings << "ranges differ across matched names: #{matches.map { |m| "#{m[:name]}=#{m[:requirement]}" }.join(', ')}"
      end
    end

    accepts = matches.count { |m| m[:supports] }
    status = if accepts == 0
      :not_supported
    elsif accepts == matches.size
      :supported
    else
      :split
    end

    { status: status, shape: :requirement, matches: matches, warnings: warnings, error: nil }
  end

  def canonicalise(req_str)
    SemanticPuppet::VersionRange.parse(req_str.to_s).to_s
  rescue StandardError
    req_str.to_s
  end

  def check_os_shape(arr, name_pattern, versions)
    any_version = versions.all?(&:empty?)

    matches = []
    arr.each do |entry|
      next unless entry['operatingsystem']
      next unless name_pattern.match?(entry['operatingsystem'].to_s)
      releases = entry['operatingsystemrelease']
      releases = [] unless releases.is_a?(Array)
      matched = if any_version
        releases
      else
        releases.select { |r| versions.any? { |v| os_release_matches?(v, r.to_s) } }
      end
      matches << {
        name:     entry['operatingsystem'],
        releases: releases,
        matched:  matched,
        supports: any_version ? true : !matched.empty?,
      }
    end

    return { status: :not_present, shape: :os, matches: [], warnings: [], error: nil } if matches.empty?
    if matches.any? { |m| m[:supports] }
      { status: :supported, shape: :os, matches: matches, warnings: [], error: nil }
    else
      { status: :not_supported, shape: :os, matches: matches, warnings: [], error: nil }
    end
  end

  # Prefix-aware: target "X" matches releases "X", "X.x", "X.<anything>".
  # Target "X.Y" matches "X.Y", "X.Y.x", "X.Y.<anything>", and also
  # the whole-major covers: "X" or "X.x".
  def os_release_matches?(target, release)
    t = target.to_s
    r = release.to_s
    return true if r == t
    return true if r == "#{t}.x"
    return true if r.start_with?("#{t}.")

    # whole-major coverage when target is X.Y
    if t =~ /\A(\d+)\.\d+/
      major = Regexp.last_match(1)
      return true if r == major || r == "#{major}.x"
    end
    false
  end
end

# ---------------------------------------------------------------------------
# Module processing
# ---------------------------------------------------------------------------
module ModuleProcessor
  module_function

  # Returns a row hash + global escalations:
  #   {
  #     module_name:    str,
  #     last_version:   str|nil,           # metadata 'version' at the supporting tag
  #     last_tag:       str|nil,           # the tag's git name
  #     date:           Time|nil,
  #     reqs_cell:      str,               # display content for "Version Requirements"
  #     notes:          [str, ...],        # always shown
  #     scoped_notes:   [{text:, latest_version:, latest_date:}, ...]
  #                                        # shown only if --all-anomalies, or if
  #                                        # latest_version/date >= the match
  #     status:         :supported | :unsupported | :split | :error,
  #     big_warnings:   [{text:, latest_version:, latest_date:}, ...]
  #                                        # surfaces before the table; same
  #                                        # filtering rule as scoped_notes
  #     module_dir:     str,
  #   }
  def process(dir, key_path, name_pattern, versions, fetch: false, earliest: false, all_anomalies: false)
    module_name = read_module_name(dir) || File.basename(dir)
    row = {
      module_name:          module_name,
      last_version:         nil,
      match_version:        nil,
      last_tag:             nil,
      latest_tag_in_repo:   nil,
      earliest_tag_in_repo: nil,
      date:                 nil,
      reqs_cell:            '',
      latest_reqs_cell:     '',
      notes:                [],
      scoped_notes:         [],
      status:               :unsupported,
      big_warnings:         [],
      module_dir:           dir,
    }

    unless GitRepo.repo?(dir)
      row[:notes] << "not a git repo; checked working dir only"
      check_working_dir_only(row, dir, key_path, name_pattern, versions)
      return row
    end

    if fetch && GitRepo.has_remote?(dir)
      $stderr.print "[fetch] #{module_name}: "
      $stderr.flush
      fetch_status, reason = GitRepo.fetch_tags(dir)
      case fetch_status
      when :ok
        $stderr.puts "ok"
      when :failed
        $stderr.puts "FAILED — #{reason}"
        row[:notes] << "git fetch failed (#{reason}); using local tags"
      end
    end

    tags = GitRepo.tags(dir)
    if tags.empty?
      row[:notes] << "no tags in repo"
      check_working_dir(row, dir, key_path, name_pattern, versions, tag_shas: Set.new)
      return row
    end

    cls = TagClassifier.classify(tags)
    latest_obj   = cls[:ordered].first
    earliest_obj = cls[:ordered].last
    row[:latest_tag_in_repo]   = latest_obj   && latest_obj[:name]
    row[:earliest_tag_in_repo] = earliest_obj && earliest_obj[:name]
    # Full tag object kept as a filter anchor when there's no match, and as
    # the row's "current state" cell in the unmatched table.
    row[:latest_tag_obj]       = latest_obj

    if all_anomalies && !cls[:fallback]
      first_chrono = tags.compact.min_by { |t| t[:date] || Time.at(0) }
      if first_chrono && cls[:other].any? { |t| t[:name] == first_chrono[:name] }
        row[:notes] << "first tag chronologically was #{first_chrono[:name]} (non-SemVer-ish; excluded from version-ordered walk)"
      end
    end

    # Flag groups of tags that parse to the same SemVer but whose
    # metadata.json `version` keys disagree — the conventional "v2.2.0" /
    # "2.2.0" alias pair is fine, but if one tag's metadata says "2.2.0"
    # and another's says "2.2.0-pre", that's a real packaging anomaly.
    check_duplicate_version_tags(row, dir, cls)
    cls[:anomalies].each do |a|
      if a.is_a?(Hash)
        row[:scoped_notes] << a
      else
        row[:notes] << a
      end
    end
    row[:notes] << "no SemVer-ish tags; ordered by date" if cls[:fallback]

    walk_order = earliest ? cls[:ordered].reverse : cls[:ordered]
    if !cls[:other].empty? && !cls[:fallback]
      others = cls[:other]
      row[:scoped_notes] << {
        text:            "non-SemVer-ish tags ignored in walk: #{others.map { |t| t[:name] }.join(', ')}",
        latest_version:  nil,
        latest_date:     others.map { |t| t[:date] }.compact.max,
        involved_majors: Set.new,
      }
      check_other_tags_for_orphans(row, dir, cls)
    end

    parse_failures = 0
    # err_msg => [tag, ...]
    error_groups = Hash.new { |h, k| h[k] = [] }
    latest_tag_name = cls[:ordered].first&.[](:name)
    walk_order.each do |t|
      raw = GitRepo.show_file(dir, t[:name], 'metadata.json')
      if raw.nil?
        parse_failures += 1
        next
      end
      md = begin
        JSON.parse(raw)
      rescue JSON::ParserError
        parse_failures += 1
        next
      end
      r = SupportCheck.check(md, key_path, name_pattern, versions)
      if t[:name] == latest_tag_name && row[:latest_reqs_cell].empty? && r[:status] != :error
        row[:latest_reqs_cell] = format_reqs(r)
      end
      case r[:status]
      when :supported, :split
        row[:last_version]  = md['version'] || '(no version)'
        row[:match_version] = t[:version] # nil for non-semver-ordered (date fallback)
        row[:last_tag]      = t[:name]
        row[:date]          = t[:date]
        row[:reqs_cell]     = format_reqs(r)
        row[:notes].concat(r[:warnings])
        row[:status]        = r[:status] == :split ? :split : :supported
        break
      when :error
        error_groups[r[:error]] << t
      end
    end

    error_groups.each do |err, ts|
      row[:scoped_notes] << {
        text:            summarise_tag_error(err, ts.map { |t| t[:name] }),
        latest_version:  ts.map { |t| t[:version] }.compact.max,
        latest_date:     ts.map { |t| t[:date] }.compact.max,
        involved_majors: ts.map { |t| t[:version]&.major }.compact.to_set,
      }
    end

    if parse_failures == walk_order.size && walk_order.any?
      row[:notes] << "metadata.json missing or unparseable at every walked tag"
    end

    tag_shas = tags.map { |t| t[:sha] }.to_set
    check_working_dir(row, dir, key_path, name_pattern, versions, tag_shas: tag_shas)
    row
  end

  def summarise_tag_error(err, tag_names)
    if tag_names.size <= 3
      "#{tag_names.size} tag(s) (#{tag_names.join(', ')}): #{err}"
    else
      "#{tag_names.size} tag(s) (e.g. #{tag_names.first(3).join(', ')}, +#{tag_names.size - 3} more): #{err}"
    end
  end

  def read_module_name(dir)
    md_path = File.join(dir, 'metadata.json')
    return nil unless File.file?(md_path)
    JSON.parse(File.read(md_path))['name']
  rescue StandardError
    nil
  end

  def format_reqs(check_result)
    case check_result[:shape]
    when :requirement
      check_result[:matches].map { |m|
        "#{m[:name]}: #{m[:requirement]}"
      }.join('; ')
    when :os
      check_result[:matches].map { |m|
        "#{m[:name]}: [#{m[:releases].join(', ')}]"
      }.join('; ')
    else
      ''
    end
  end

  def check_working_dir(row, dir, key_path, name_pattern, versions, tag_shas:)
    md_path = File.join(dir, 'metadata.json')
    return unless File.file?(md_path)
    head = GitRepo.head_sha(dir)
    on_tag = head && tag_shas.include?(head)
    return if on_tag # HEAD is already covered by the tag walk
    md = JSON.parse(File.read(md_path))
    r = SupportCheck.check(md, key_path, name_pattern, versions)
    short = head ? head[0, 7] : '??'
    case r[:status]
    when :supported
      row[:notes] << "working dir (HEAD #{short}) also supports"
    when :split
      row[:notes] << "working dir (HEAD #{short}) split-decision: #{r[:warnings].join('; ')}"
      row[:status] = :split if row[:status] == :supported || row[:status] == :unsupported
    when :not_supported
      row[:notes] << "working dir (HEAD #{short}) does NOT support" if row[:status] != :supported
    end
  rescue JSON::ParserError => e
    row[:notes] << "working dir metadata.json unparseable: #{e.message}"
  end

  def check_working_dir_only(row, dir, key_path, name_pattern, versions)
    md_path = File.join(dir, 'metadata.json')
    unless File.file?(md_path)
      row[:notes] << "no metadata.json found"
      return
    end
    md = JSON.parse(File.read(md_path))
    r = SupportCheck.check(md, key_path, name_pattern, versions)
    case r[:status]
    when :supported, :split
      row[:last_version] = md['version'] || '(no version)'
      row[:last_tag]     = '(working dir)'
      row[:date]         = nil
      row[:reqs_cell]    = format_reqs(r)
      row[:status]       = r[:status] == :split ? :split : :supported
      row[:notes].concat(r[:warnings])
    end
  rescue JSON::ParserError => e
    row[:notes] << "metadata.json unparseable: #{e.message}"
  end

  def check_duplicate_version_tags(row, dir, cls)
    cls[:semver].group_by { |t| t[:version] }.each do |ver, group|
      next if group.size < 2
      md_versions = group.map { |t|
        raw = GitRepo.show_file(dir, t[:name], 'metadata.json')
        v = begin
          raw && JSON.parse(raw)['version'].to_s
        rescue JSON::ParserError
          nil
        end
        [t[:name], v]
      }
      uniq = md_versions.map(&:last).compact.uniq
      next if uniq.size <= 1
      row[:scoped_notes] << {
        text:            "tags #{group.map { |t| t[:name] }.join(', ')} all parse to SemVer #{ver}, but their metadata.json version keys disagree: #{md_versions.map { |n, v| "#{n}=#{v.inspect}" }.join(', ')}",
        latest_version:  ver,
        latest_date:     group.map { |t| t[:date] }.compact.max,
        involved_majors: Set[ver.major],
      }
    end
  end

  # Detect "orphan" non-SemVer tags whose metadata.json version isn't represented
  # in the SemVer tag set; emit a BIG WARNING.
  def check_other_tags_for_orphans(row, dir, cls)
    semver_versions = cls[:semver].map { |t| t[:version] }.to_set
    cls[:other].each do |t|
      raw = GitRepo.show_file(dir, t[:name], 'metadata.json')
      next if raw.nil?
      md = begin
        JSON.parse(raw)
      rescue JSON::ParserError
        next
      end
      v_str = md['version'].to_s
      next if v_str.empty?
      parsed = begin
        SemanticPuppet::Version.parse(SupportCheck.pad_version(v_str))
      rescue StandardError
        nil
      end
      if parsed.nil? || !semver_versions.include?(parsed)
        row[:big_warnings] << {
          text:            "non-SemVer tag #{t[:name]} in #{File.basename(dir)} has metadata.json version #{v_str.inspect} not represented by any SemVer-ish tag",
          latest_version:  parsed,
          latest_date:     t[:date],
          involved_majors: parsed ? Set[parsed.major] : Set.new,
        }
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Reporter
# ---------------------------------------------------------------------------
module Reporter
  module_function

  def emit(rows, name_str, version, key_path, info_messages, source_warnings,
           all_anomalies: false, sort_by_date: false,
           hide_requirements: false, hide_tags: false, hide_notes: false,
           fetched: false, earliest: false, show_latest_tag: false,
           hide_unsupported: false)
    info_messages.each { |m| puts m }
    source_warnings.each { |m| puts "[WARN] #{m}" }
    puts unless info_messages.empty? && source_warnings.empty?

    big_pairs = rows.flat_map { |r| r[:big_warnings].map { |bw| [r, bw] } }
    visible_big = big_pairs.select { |r, bw| scoped_visible?(bw, r, all_anomalies) }
    suppressed_big = big_pairs.size - visible_big.size
    unless visible_big.empty?
      puts '!' * 78
      visible_big.each { |_r, bw| puts "[BIG WARNING] #{scoped_text(bw)}" }
      puts '!' * 78
      puts
    end

    matched_rows   = rows.select { |r| [:supported, :split].include?(r[:status]) }
    unmatched_rows = rows.reject { |r| [:supported, :split].include?(r[:status]) }

    if sort_by_date
      matched_rows   = stable_sort_desc(matched_rows)   { |r| r[:date] }
      unmatched_rows = stable_sort_desc(unmatched_rows) { |r| r[:latest_tag_obj] && r[:latest_tag_obj][:date] }
    end

    suppressed_scoped = 0
    suppressed_scoped += emit_matched_table(matched_rows, name_str, version, key_path,
                                            all_anomalies: all_anomalies,
                                            hide_requirements: hide_requirements,
                                            hide_tags: hide_tags,
                                            hide_notes: hide_notes,
                                            fetched: fetched,
                                            earliest: earliest)
    unless hide_unsupported
      suppressed_scoped += emit_unmatched_table(unmatched_rows, name_str, version, key_path,
                                                all_anomalies: all_anomalies,
                                                earliest: earliest,
                                                show_latest_tag: show_latest_tag,
                                                hide_requirements: hide_requirements,
                                                hide_notes: hide_notes)
    end

    if !all_anomalies && (suppressed_scoped + suppressed_big) > 0
      puts "Note: suppressed #{suppressed_scoped} note(s) and #{suppressed_big} BIG WARNING(s) about tags in unrelated major versions. Pass -a/--all-anomalies to see them."
    end

    summary(rows)
    exit_code(rows)
  end

  def emit_matched_table(rows, name_str, version, key_path,
                         all_anomalies:, hide_requirements:, hide_tags:, hide_notes:,
                         fetched:, earliest:)
    return 0 if rows.empty?

    title_prefix = earliest ? 'Earliest' : 'Latest'
    vdisplay = version.empty? ? '(any version)' : version
    puts "## #{title_prefix} version of each Puppet module to support #{name_str} #{vdisplay} (per metadata.json:#{key_path})"
    annotated = earliest ? '"(latest)" / "(oldest)"' : '"(latest)"'
    described = earliest ? 'newest / oldest' : 'newest'
    puts "_#{annotated} annotates the matched tag when it is the #{described} SemVer-ish tag in the repo. Based on local tag refs only#{fetched ? ' (refreshed via git fetch this run)' : '; pass -f/--fetch to refresh from remotes first'}._"
    puts

    # (latest) shows in any mode; (oldest) is contingent on --earliest because
    # outside that mode it raises more questions than it answers. Both can
    # co-fire (e.g. a single-tag repo in --earliest mode).
    extreme_suffix = ->(r) {
      parts = []
      parts << '(latest)' if r[:last_tag] && r[:latest_tag_in_repo]   && r[:last_tag] == r[:latest_tag_in_repo]
      if earliest && r[:last_tag] && r[:earliest_tag_in_repo] && r[:last_tag] == r[:earliest_tag_in_repo]
        parts << '(oldest)'
      end
      parts.empty? ? '' : ' ' + parts.join(' ')
    }

    columns = [
      ['Module name',          ->(r) { r[:module_name] || '' }],
      ['Version',              ->(r) { (r[:last_version] || '—').to_s + extreme_suffix.call(r) }],
      ['Tag',                  ->(r) { (r[:last_tag]     || '—').to_s }, :tag],
      ['Date',                 ->(r) { r[:date] ? r[:date].strftime('%Y-%m-%d') : '—' }],
      ['Version Requirements', ->(r) { r[:reqs_cell].to_s.empty? ? '—' : r[:reqs_cell] }, :reqs],
      ['Notes',                nil, :notes],
    ]
    columns.reject! { |c| (hide_tags && c[2] == :tag) || (hide_requirements && c[2] == :reqs) || (hide_notes && c[2] == :notes) }
    suppressed = render_table(columns, rows, all_anomalies)
    puts
    suppressed
  end

  def emit_unmatched_table(rows, name_str, version, key_path,
                           all_anomalies:, earliest:, show_latest_tag:, hide_requirements:, hide_notes:)
    return 0 if rows.empty?

    vdisplay = version.empty? ? '(any version)' : version
    puts "## #{rows.size} module(s) without any tag supporting `#{key_path}: #{name_str} #{vdisplay}`"
    puts

    columns = [['Module name', ->(r) { r[:module_name] || '' }]]
    if show_latest_tag
      columns << ['Latest tag',           ->(r) { (r[:latest_tag_obj] && r[:latest_tag_obj][:name]) || '—' }]
      columns << ['Date',                 ->(r) { r[:latest_tag_obj] && r[:latest_tag_obj][:date] ? r[:latest_tag_obj][:date].strftime('%Y-%m-%d') : '—' }]
      unless hide_requirements
        columns << ['Version Requirements', ->(r) { r[:latest_reqs_cell].to_s.empty? ? '—' : r[:latest_reqs_cell] }]
      end
    end
    columns << ['Notes', nil, :notes] unless hide_notes

    suppressed = render_table(columns, rows, all_anomalies)
    puts
    puts "(To include each module's most recent SemVer-ish tag and version requirements, for context, run with `-L`/`--show-latest-tag` )" unless show_latest_tag
    puts
    suppressed
  end

  # Render a GFM table (left-aligned columns; last column ragged for notes).
  # `columns` is [[header, ->(row){cell}, opt_id], ...] with the LAST column
  # having a nil callable — it gets populated from the row's notes here.
  # Returns the count of scoped notes that were suppressed by the filter.
  def render_table(columns, rows, all_anomalies)
    headers   = columns.map(&:first)
    notes_idx = columns.find_index { |_, fn, _id| fn.nil? }
    suppressed = 0

    data_rows = rows.map { |r|
      visible_scoped = (r[:scoped_notes] || []).select { |sn| scoped_visible?(sn, r, all_anomalies) }
      suppressed += (r[:scoped_notes] || []).size - visible_scoped.size
      all_notes = r[:notes] + visible_scoped.map { |sn| scoped_text(sn) }
      cells = columns.map { |_h, fn, _id| fn ? fn.call(r) : '' }
      cells[notes_idx] = all_notes.empty? ? '' : all_notes.join('; ') if notes_idx
      cells.map { |c| escape_cell(c) }
    }

    # Every column gets a minimum width of its header length. Non-last columns
    # also grow to fit their widest cell; the Notes column (always last when
    # present) is left at header width so short rows line up but long notes
    # still extend past it naturally.
    last_idx = headers.size - 1
    widths = headers.map.with_index do |h, i|
      i == last_idx && i == notes_idx ? h.length : [h.length, *data_rows.map { |dr| dr[i].length }].max
    end
    separator_cells = widths.map { |w| '-' * w }

    puts format_row(headers, widths)
    puts format_row(separator_cells, widths)
    data_rows.each { |dr| puts format_row(dr, widths) }
    suppressed
  end

  def stable_sort_desc(rows)
    rows.each_with_index.sort_by { |r, i|
      d = yield(r)
      [d.nil? ? 1 : 0, d ? -d.to_f : 0, i]
    }.map(&:first)
  end

  # A scoped note (or big_warning) is visible if ANY of:
  #   - --all-anomalies was passed
  #   - the note involves the anchor tag's SemVer major version (anomalies
  #     in other majors are usually independent release lines)
  #   - the note's latest involved tag was dated on/after the anchor tag
  #     (recent activity in any major is still worth surfacing)
  #   - the note has no version OR date info at all (hiding would be silent)
  #
  # Anchor = the matched tag (when found), else the latest known SemVer tag,
  # so unmatched rows still get noise-filtered (e.g. major-1 anomalies hide
  # for a repo whose latest tag is in major 8).
  def scoped_visible?(scoped, row, all_anomalies)
    return true if all_anomalies

    anchor_major, anchor_date = anchor(row)
    return true if anchor_major.nil? && anchor_date.nil?

    involved_majors = scoped[:involved_majors]
    if anchor_major && involved_majors && involved_majors.include?(anchor_major)
      return true
    end
    if anchor_date && scoped[:latest_date] && scoped[:latest_date] >= anchor_date
      return true
    end

    scoped[:latest_version].nil? && scoped[:latest_date].nil?
  end

  def anchor(row)
    return [row[:match_version].major, row[:date]] if row[:match_version]
    return [nil, row[:date]] if row[:date] # match without parsed version
    lt = row[:latest_tag_obj]
    return [nil, nil] unless lt
    [lt[:version]&.major, lt[:date]]
  end

  def scoped_text(scoped)
    scoped.is_a?(Hash) ? scoped[:text] : scoped.to_s
  end

  def escape_cell(s)
    s.to_s.gsub('|', '\\|').gsub("\n", ' ')
  end

  def format_row(cells, widths)
    '| ' + cells.each_with_index.map { |c, i|
      widths[i] ? c.ljust(widths[i]) : c
    }.join(' | ') + ' |'
  end

  def summary(rows)
    total = rows.size
    by_status = rows.group_by { |r| r[:status] }
    sup   = (by_status[:supported]   || []).size
    split = (by_status[:split]       || []).size
    err   = (by_status[:error]       || []).size
    unsup = (by_status[:unsupported] || []).size
    puts "Processed #{total} module(s): #{sup} supporting, #{split} split-decision, #{unsup} unsupported, #{err} error."
  end

  def exit_code(rows)
    bad = rows.any? { |r| r[:status] == :unsupported || r[:status] == :split || r[:status] == :error }
    exit(bad ? EXIT_FAIL : EXIT_OK)
  end
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
module Main
  module_function

  def run(argv)
    args = Cli.parse_args(argv)
    modules, info, warnings = SourceResolver.resolve(args[:source])

    if modules.empty?
      warn "error: no modules resolved from source"
      exit EXIT_USAGE
    end

    rows = modules.map { |dir|
      begin
        ModuleProcessor.process(dir, args[:key_path], args[:name_pattern], args[:versions],
                                fetch:         args[:fetch],
                                earliest:      args[:earliest],
                                all_anomalies: args[:all_anomalies])
      rescue StandardError => e
        {
          module_name:          File.basename(dir),
          last_version:         nil, last_tag: nil, date: nil,
          latest_tag_in_repo:   nil,
          earliest_tag_in_repo: nil,
          latest_tag_obj:       nil,
          match_version:        nil,
          reqs_cell:            '',
          notes:                ["ERROR: #{e.class}: #{e.message}"],
          scoped_notes:         [],
          status:               :error,
          big_warnings:         [],
          module_dir:           dir,
        }
      end
    }

    Reporter.emit(rows, args[:name_str], args[:version], args[:key_path], info, warnings,
                  all_anomalies:     args[:all_anomalies],
                  sort_by_date:      args[:sort_by_date],
                  hide_requirements: args[:hide_requirements],
                  hide_tags:         args[:hide_tags],
                  hide_notes:        args[:hide_notes],
                  fetched:           args[:fetch],
                  earliest:          args[:earliest],
                  show_latest_tag:   args[:show_latest_tag],
                  hide_unsupported:  args[:hide_unsupported])
  end
end

Main.run(ARGV) if $PROGRAM_NAME == __FILE__
