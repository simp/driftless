#!/usr/bin/env ruby
# frozen_string_literal: true
#
# puppetfile_tool.rb -- compare, translate, expand, list, and check Puppetfiles.
#
#   puppetfile_tool.rb list      PUPPETFILE           modules by install location
#   puppetfile_tool.rb compare   OLD NEW              diff two Puppetfiles by install location;
#                                                     flags major upgrades and ownership changes
#   puppetfile_tool.rb translate PUPPETFILE [opts]    rewrite repo URLs using explicit rules (--rule)
#                                                     and/or rules inferred from a reference (--infer-from)
#   puppetfile_tool.rb expand    PUPPETFILE           evaluate Ruby logic and print a flat,
#                                                     g10k-compatible Puppetfile
#   puppetfile_tool.rb check     PUPPETFILE           verify that each git repo exists (git ls-remote)
#
# Every subcommand accepts -h.  PUPPETFILE may be '-' to read stdin.
# Needs only MRI Ruby (>= 2.7) and its standard library; 'check', and reading
# metadata.json from git repos, also need git.
#
# Puppetfiles are evaluated as Ruby (like r10k does), so Puppetfiles that
# contain Ruby logic work everywhere.  A module's "install location" is
# <moduledir>/<basename> (or <install_path>/<basename>), where basename is the
# last '-' or '/' separated part of the declared name, matching r10k's behavior.
#
# A module's canonical name (and so its owner, the 'group' in 'group-modulename')
# is the 'name' key of its metadata.json at the declared ref.  'list' and
# 'compare' read metadata.json from the checkout under --basedir when that
# checkout is at the declared ref, and with --fetch also from the git repo
# (cached under --cache-dir).  Without either, the name declared in the
# Puppetfile is used.  Forge modules are identified by their slug, so the
# declared name is used unless a checkout is present.

require 'optparse'
require 'json'
require 'open3'
require 'tmpdir'
require 'digest'
require 'fileutils'

module PuppetfileTool
  VERSION = '0.2.0'
  DEFAULT_MODULEDIR = 'modules'
  DEFAULT_CACHE_DIR = File.join(ENV['XDG_CACHE_HOME'] || File.join(Dir.home, '.cache'), 'puppetfile_tool')

  class Error < StandardError; end

  # Runs a command with a timeout. Returns [stdout, stderr, status_or_nil]; status is nil on timeout.
  module Cmd
    def self.run(cmd, timeout: 30, env: {}, chdir: nil)
      spawn_opts = chdir ? { chdir: chdir } : {}
      Open3.popen3(env, *cmd, **spawn_opts) do |stdin, stdout, stderr, wait|
        stdin.close
        out_t = Thread.new { stdout.read }
        err_t = Thread.new { stderr.read }
        unless wait.join(timeout)
          begin
            Process.kill('KILL', wait.pid)
          rescue StandardError
            nil
          end
          wait.join
          return [out_t.value.to_s, "timed out after #{timeout}s", nil]
        end
        [out_t.value.to_s, err_t.value.to_s, wait.value]
      end
    rescue Errno::ENOENT => e
      ['', e.message, nil]
    end

    GIT_ENV = { 'GIT_TERMINAL_PROMPT' => '0' }.freeze

    def self.git_env
      env = GIT_ENV.dup
      env['GIT_SSH_COMMAND'] = 'ssh -o BatchMode=yes -o ConnectTimeout=10' unless ENV.key?('GIT_SSH_COMMAND')
      env
    end

    # Runs git non-interactively. Returns [stdout, error_line_or_nil].
    def self.git(args, timeout: 30, chdir: nil)
      out, err, status = run(['git'] + args, timeout: timeout, env: git_env, chdir: chdir)
      return [out, nil] if status && status.success?

      line = err.lines.find { |l| l.start_with?('fatal:') } || err.lines.last || "exit #{status && status.exitstatus}"
      [out, line.strip]
    end

    # Yields each item on up to +concurrency+ threads; exceptions propagate after all finish.
    def self.parallel_each(items, concurrency)
      queue = Queue.new
      items.each { |i| queue << i }
      errors = []
      workers = Array.new([concurrency, 1].max) do
        Thread.new do
          loop do
            item = begin
              queue.pop(true)
            rescue ThreadError
              break
            end
            begin
              yield item
            rescue StandardError => e
              errors << e
            end
          end
        end
      end
      workers.each(&:join)
      raise errors.first if errors.any?
    end
  end

  # Parses git-ish repo URLs: scheme://[user@]host/path, scp-like [user@]host:path, and plain paths.
  class RepoUrl
    URL_RE = %r{\A(?<scheme>[a-z][a-z0-9+.-]*)://(?:(?<user>[^@/]+)@)?(?<host>[^/]*)(?<path>/.*)?\z}i.freeze
    SCP_RE = %r{\A(?:(?<user>[^@/]+)@)?(?<host>[^:/]+):(?<path>[^/].*)\z}.freeze

    attr_reader :raw, :scheme, :user, :host, :path

    def initialize(raw)
      @raw = raw.to_s
      if (m = URL_RE.match(@raw))
        @scheme = m[:scheme].downcase
        @user = m[:user]
        @host = m[:host]
        @path = m[:path].to_s
      elsif (m = SCP_RE.match(@raw))
        @scheme = 'ssh'
        @user = m[:user]
        @host = m[:host]
        @path = m[:path]
      else
        @scheme = 'file'
        @user = nil
        @host = nil
        @path = @raw
      end
    end

    def segments
      @path.split('/').reject(&:empty?)
    end

    # Repository basename without a trailing .git
    def repo_name
      segments.last.to_s.sub(/\.git\z/, '')
    end

    def transport
      case scheme
      when 'http', 'https' then 'https'
      when 'ssh', 'git+ssh', 'ssh+git' then 'ssh'
      when 'git' then 'git'
      else 'local'
      end
    end

    def to_s
      raw
    end
  end

  # Where a module's metadata.json came from, or why it could not be read.
  MetadataResult = Struct.new(:data, :source, :error, keyword_init: true) do
    def name
      data && data['name']
    end

    def version
      data && data['version']
    end
  end

  # One `mod` declaration.
  class Mod
    URL_KEYS = %i[git svn tarball].freeze
    VERSION_KEYS = %i[tag ref commit branch version rev].freeze
    COVERED_KEYS = (URL_KEYS + VERSION_KEYS + %i[install_path default_branch local]).freeze

    attr_reader :name, :args, :moduledir, :line
    attr_accessor :metadata

    def initialize(name, args, moduledir, line = nil)
      @name = name.to_s
      @args = args.is_a?(Hash) ? args.transform_keys(&:to_sym) : args
      @moduledir = moduledir.to_s
      @line = line
      @metadata = nil
    end

    def opts
      args.is_a?(Hash) ? args : {}
    end

    # r10k installs 'owner-name' and 'owner/name' as just 'name'
    def basename
      name.split(%r{[-/]}).last
    end

    def self.owner_of(full_name)
      parts = full_name.to_s.split(%r{[-/]}, 2)
      parts.length == 2 ? parts.first : nil
    end

    # The 'group' of the name declared in the Puppetfile
    def declared_owner
      Mod.owner_of(name)
    end

    # metadata.json 'name' when known, otherwise the declared name
    def canonical_name
      (metadata && metadata.name) || name
    end

    def canonical_owner
      Mod.owner_of(canonical_name)
    end

    def name_mismatch?
      metadata && metadata.name && !metadata.name.tr('/', '-').casecmp?(name.tr('/', '-'))
    end

    # Human-readable observations about this module (empty when all is well)
    def notes
      n = []
      if metadata && metadata.error
        n << "metadata.json unavailable: #{metadata.error}"
      elsif name_mismatch?
        n << "Puppetfile name '#{name}' disagrees with metadata.json name '#{metadata.name}'"
      end
      n
    end

    def type
      return :git     if opts.key?(:git)
      return :svn     if opts.key?(:svn)
      return :tarball if opts.key?(:tarball)
      return :local   if opts[:local]

      :forge
    end

    def url_key
      URL_KEYS.find { |k| opts.key?(k) }
    end

    def url
      url_key && opts[url_key]
    end

    def repo
      @repo ||= type == :git ? RepoUrl.new(url) : nil
    end

    # URL with a trailing '.git' removed; 'a/b' and 'a/b.git' name the same repository
    def url_normalized
      url && url.sub(/\.git\z/, '')
    end

    def install_path
      base = opts.key?(:install_path) ? opts[:install_path].to_s : moduledir
      File.join(base, basename)
    end

    # The git ref r10k would check out
    def git_ref
      k = %i[tag ref commit branch].find { |key| opts[key] }
      (k ? opts[k] : (opts[:default_branch] || 'HEAD')).to_s
    end

    # Number of major versions between this module and +other+ (positive = upgrade), or nil
    def major_delta_from(other)
      ov = other.semver
      nv = semver
      ov && nv ? nv[0] - ov[0] : nil
    end

    # ['tag', 'v1.2.3'], ['version', '1.2.3'], ['branch', 'main'], ['version', 'latest'], ...
    def version
      case type
      when :forge
        v = args.is_a?(Hash) ? opts[:version] : args
        v = 'latest' if v.nil? || v == :latest
        ['version', v.to_s]
      when :git
        k = %i[tag ref commit branch].find { |key| opts[key] }
        k ? [k.to_s, opts[k].to_s] : ['branch', git_ref]
      else
        v = opts[:ref] || opts[:rev] || opts[:version]
        v ? ['ref', v.to_s] : ['ref', 'HEAD']
      end
    end

    def version_s
      version.join(' ')
    end

    def semver
      Mod.semver(version[1])
    end

    def self.semver(str)
      m = /\Av?(\d+)\.(\d+)\.(\d+)/.match(str.to_s)
      m && m.captures.map(&:to_i)
    end

    def summary
      s = "#{type} #{name} #{version_s}"
      s += " #{url}" if url
      s
    end

    def to_h
      {
        name: name,
        canonical_name: canonical_name,
        install_path: install_path,
        moduledir: moduledir,
        type: type,
        declared_owner: declared_owner,
        canonical_owner: canonical_owner,
        url: url,
        url_host: repo && repo.host,
        url_transport: repo && repo.transport,
        version_kind: version[0],
        version: version[1],
        metadata_name: metadata && metadata.name,
        metadata_version: metadata && metadata.version,
        metadata_source: metadata && metadata.source,
        notes: notes,
        line: line,
        opts: opts,
      }
    end

    # Rendered in the subset of the DSL that g10k understands.
    def to_puppetfile
      head = "mod #{Puppetfile.literal(name)}"
      if args.is_a?(Hash)
        return "#{head}\n" if args.empty?

        lines = [head] + args.map { |k, v| "  :#{k} => #{Puppetfile.literal(v)}" }
        "#{lines.join(",\n")}\n"
      elsif args.nil?
        "#{head}\n"
      else
        "#{head}, #{Puppetfile.literal(args)}\n"
      end
    end

    def with_url(new_url)
      Mod.new(name, opts.merge(url_key => new_url), moduledir, line)
    end
  end

  class Puppetfile
    attr_reader :path, :source, :modules, :forge_url, :default_moduledir

    def self.load(path, **kw)
      if path == '-'
        new($stdin.read, path: '(stdin)', **kw)
      else
        new(File.read(path), path: path, **kw)
      end
    rescue SystemCallError => e
      raise Error, e.message
    end

    def initialize(source, path: 'Puppetfile', default_moduledir: DEFAULT_MODULEDIR)
      @source = source
      @path = path
      @default_moduledir = default_moduledir
      @moduledir = default_moduledir
      @modules = []
      @forge_url = nil
      begin
        DSL.new(self).instance_eval(source, path.to_s, 1)
      rescue StandardError, ScriptError => e
        raise Error, "#{path}: #{e.class}: #{e.message}"
      end
    end

    def add_module(name, args, line)
      @modules << Mod.new(name, args, @moduledir, line)
    end

    def set_forge(url)
      @forge_url = url
    end

    def set_moduledir(dir)
      @moduledir = dir.to_s
    end

    def by_install_path
      @modules.each_with_object({}) do |m, h|
        if h.key?(m.install_path)
          warn "#{path}: duplicate install location #{m.install_path} (#{h[m.install_path].name}, #{m.name}); keeping the last"
        end
        h[m.install_path] = m
      end
    end

    def to_g10k
      out = []
      out << "forge #{Puppetfile.literal(forge_url)}\n\n" if forge_url
      current_dir = nil
      modules.each do |m|
        if m.moduledir != current_dir
          out << "moduledir #{Puppetfile.literal(m.moduledir)}\n\n"
          current_dir = m.moduledir
        end
        out << m.to_puppetfile << "\n"
      end
      out.join
    end

    def self.literal(v)
      case v
      when Symbol then ":#{v}"
      when String then "'#{v.gsub(/(['\\])/) { "\\#{Regexp.last_match(1)}" }}'"
      when nil then 'nil'
      else v.to_s
      end
    end

    # The subset of the r10k Puppetfile DSL we understand.
    class DSL
      def initialize(pf)
        @pf = pf
      end

      def mod(name, args = nil)
        @pf.add_module(name, args, caller_locations(1, 1).first.lineno)
      end

      def forge(url)
        @pf.set_forge(url)
      end

      def moduledir(dir)
        @pf.set_moduledir(dir)
      end

      def method_missing(method, *_args)
        raise NoMethodError, "unrecognized Puppetfile declaration '#{method}'"
      end

      def respond_to_missing?(*)
        false
      end
    end
  end

  # ----------------------------------------------------------- metadata.json

  module Metadata
    Options = Struct.new(:basedir, :fetch, :cache_dir, :concurrency, :timeout, keyword_init: true) do
      def self.defaults
        new(basedir: nil, fetch: false, cache_dir: DEFAULT_CACHE_DIR, concurrency: 4, timeout: 60)
      end
    end

    # Populates Mod#metadata for every module in +pf+.  Modules whose metadata.json
    # was never looked for (no --basedir, no --fetch) keep metadata = nil and get no note.
    def self.resolve_all(pf, options, io: $stderr)
      if options.basedir
        pf.modules.each do |m|
          result = from_disk(m, options.basedir)
          m.metadata = result if result && (result.data || !options.fetch)
        end
      end
      return pf unless options.fetch

      pending = pf.modules.select { |m| m.metadata.nil? && m.type == :git }
      uncached = pending.reject { |m| cache_file(options.cache_dir, m) && File.file?(cache_file(options.cache_dir, m)) }
      io.puts "#{pf.path}: fetching metadata.json for #{uncached.length} git module(s)" if uncached.any?
      Cmd.parallel_each(pending, options.concurrency) { |m| m.metadata = from_git(m, options) }
      pf
    end

    # Reads <basedir>/<install_path>/metadata.json.  Returns nil when there is no checkout,
    # and a MetadataResult with an error when the checkout is not at the declared ref/version.
    def self.from_disk(mod, basedir)
      dir = File.join(basedir, mod.install_path)
      file = File.join(dir, 'metadata.json')
      return nil unless File.file?(file)

      begin
        data = JSON.parse(File.read(file))
      rescue JSON::ParserError => e
        return MetadataResult.new(error: "#{file}: #{e.message.lines.first.to_s.strip}")
      end

      case mod.type
      when :git
        return MetadataResult.new(error: "#{dir} is not a git checkout") unless File.exist?(File.join(dir, '.git'))

        head, = Cmd.git(%w[rev-parse HEAD], chdir: dir)
        want, err = Cmd.git(['rev-parse', '--verify', '--quiet', "#{mod.git_ref}^{commit}"], chdir: dir)
        return MetadataResult.new(error: "#{dir} does not contain #{mod.git_ref}") if err
        return MetadataResult.new(error: "#{dir} is at #{head.strip[0, 12]}, not #{mod.git_ref}") if head.strip != want.strip
      when :forge
        declared = mod.version[1]
        unless declared == 'latest' || data['version'] == declared
          return MetadataResult.new(error: "#{dir} is version #{data['version']}, not #{declared}")
        end
      end
      MetadataResult.new(data: data, source: file)
    end

    def self.cache_file(cache_dir, mod)
      return nil unless cache_dir

      File.join(cache_dir, "#{Digest::SHA256.hexdigest("#{mod.url}\n#{mod.git_ref}")[0, 32]}.json")
    end

    # Fetches metadata.json from the repo at the declared ref with a depth-1 fetch into a temp dir.
    def self.from_git(mod, options)
      cache = cache_file(options.cache_dir, mod)
      label = "#{mod.url}@#{mod.git_ref}"
      if cache && File.file?(cache)
        return MetadataResult.new(data: JSON.parse(File.read(cache)), source: "cache #{label}")
      end

      Dir.mktmpdir('puppetfile_tool') do |tmp|
        _, err = Cmd.git(%w[init --quiet], chdir: tmp, timeout: options.timeout)
        return MetadataResult.new(error: err) if err

        _, err = Cmd.git(['fetch', '--quiet', '--depth', '1', mod.url, mod.git_ref], chdir: tmp, timeout: options.timeout)
        return MetadataResult.new(error: "fetch #{label}: #{err}") if err

        json, err = Cmd.git(%w[cat-file -p FETCH_HEAD:metadata.json], chdir: tmp, timeout: options.timeout)
        return MetadataResult.new(error: "no metadata.json in #{label}") if err

        data = JSON.parse(json)
        if cache
          FileUtils.mkdir_p(File.dirname(cache))
          File.write(cache, json)
        end
        MetadataResult.new(data: data, source: label)
      end
    rescue JSON::ParserError => e
      MetadataResult.new(error: "metadata.json in #{label} is not valid JSON: #{e.message.lines.first.to_s.strip}")
    end
  end

  # ------------------------------------------------------------------ compare

  class Comparison
    Entry = Struct.new(:install_path, :status, :old, :new, :changes, :flags, :notes, keyword_init: true) do
      def to_h
        {
          install_path: install_path,
          status: status,
          flags: flags,
          notes: notes,
          changes: changes.map { |field, o, n, note| { field: field, old: o, new: n, note: note }.compact },
          old: old && old.to_h,
          new: new && new.to_h,
        }
      end

      def mod
        new || old
      end

      def change(field)
        changes.find { |c| c[0] == field }
      end

      def major_delta
        old && new ? new.major_delta_from(old) : nil
      end
    end

    # Output sections, in display order.  Status sections list modules by what happened to
    # them; flag sections list modules that deserve attention regardless of status.
    SECTIONS = {
      added: { title: 'Added', status: :added, default: true },
      removed: { title: 'Removed', status: :removed, default: true },
      changed: { title: 'Changed', status: :changed, default: true },
      moved: { title: 'Moved', status: :moved, default: true },
      unchanged: { title: 'Unchanged', status: :unchanged, default: false },
      upgrades: { title: 'Major version upgrades', flag: :major_upgrade, default: true },
      downgrades: { title: 'Major version downgrades', flag: :major_downgrade, default: true },
      owners: { title: 'Ownership changes (group in metadata.json name, or declared name without metadata)', flag: :owner_change, default: true },
      types: { title: 'Source type changes (forge/git/...)', flag: :type_change, default: true },
      transports: { title: 'URL transport changes (https/ssh/...)', flag: :transport_change, default: true },
      notes: { title: 'Notes', default: true },
    }.freeze

    DEFAULT_SECTIONS = SECTIONS.select { |_, s| s[:default] }.keys.freeze

    attr_reader :entries

    def initialize(old_pf, new_pf, strict_urls: false)
      @strict_urls = strict_urls
      @entries = build(old_pf, new_pf)
    end

    def differences?
      entries.any? { |e| e.status != :unchanged }
    end

    def counts
      c = Hash.new(0)
      entries.each { |e| c[e.status] += 1 }
      c
    end

    def to_h
      { summary: counts, entries: entries.map(&:to_h) }
    end

    def to_text(sections: DEFAULT_SECTIONS)
      out = []
      c = counts
      out << "Summary: #{%i[added removed changed moved unchanged].map { |s| "#{c[s]} #{s}" }.join(', ')}"

      sections.each do |key|
        spec = SECTIONS.fetch(key)
        lines =
          if spec[:status]
            status_section(spec[:status])
          elsif spec[:flag]
            flag_section(spec[:flag])
          else
            notes_section
          end
        next if lines.empty?

        out << '' << "#{spec[:title]}:"
        out.concat(lines)
      end
      "#{out.join("\n")}\n"
    end

    private

    # -- text rendering

    def status_section(status)
      entries.select { |e| e.status == status }.flat_map do |e|
        case status
        when :added, :unchanged then ["  #{e.install_path}  #{e.new.summary}"] + note_lines(e)
        when :removed then ["  #{e.install_path}  #{e.old.summary}"]
        else changed_lines(e)
        end
      end
    end

    def flag_section(flag)
      rows = entries.select { |e| e.flags.include?(flag) }.map do |e|
        [e.install_path, e.mod.name] + flag_columns(flag, e)
      end
      columns(rows)
    end

    # The 'from -> to' summary (and any extra column) for one flagged entry
    def flag_columns(flag, e)
      case flag
      when :major_upgrade, :major_downgrade
        d = e.major_delta
        ["#{e.old.version[1]} -> #{e.new.version[1]}", format('%+d major', d)]
      when :owner_change
        ["#{e.old.canonical_owner} -> #{e.new.canonical_owner}", "#{e.old.canonical_name} -> #{e.new.canonical_name}"]
      when :type_change
        ["#{e.old.type} -> #{e.new.type}", "#{e.old.url || 'forge'} -> #{e.new.url || 'forge'}"]
      when :transport_change
        ["#{e.old.repo.transport} -> #{e.new.repo.transport}", "#{e.old.url} -> #{e.new.url}"]
      else
        []
      end
    end

    def notes_section
      columns(entries.reject { |e| e.notes.empty? }.flat_map { |e| e.notes.map { |n| [e.install_path, n] } })
    end

    def columns(rows, indent: '  ')
      return [] if rows.empty?

      widths = rows.first.each_index.map { |i| rows.map { |r| r[i].to_s.length }.max }
      rows.map { |r| indent + r.each_with_index.map { |c, i| c.to_s.ljust(widths[i]) }.join('  ').rstrip }
    end

    def flag_suffix(e)
      shown = e.flags - %i[version_change url_change moved]
      shown.empty? ? '' : "  [#{shown.map { |f| f.to_s.upcase }.join(', ')}]"
    end

    def note_lines(e)
      e.notes.map { |n| "    note: #{n}" }
    end

    def changed_lines(e)
      lines = ["  #{e.install_path}  (#{e.new.name})#{flag_suffix(e)}"]
      e.changes.each do |field, o, n, note|
        lines << "    #{field}: #{plain(o)} -> #{plain(n)}#{note ? "  (#{note})" : ''}"
      end
      lines + note_lines(e)
    end

    def plain(v)
      v.nil? ? '(none)' : v.to_s
    end

    # -- comparison

    def build(old_pf, new_pf)
      olds = old_pf.by_install_path
      news = new_pf.by_install_path
      entries = []

      (olds.keys & news.keys).each { |k| entries << pair(k, olds[k], news[k]) }

      removed = olds.reject { |k, _| news.key?(k) }
      added   = news.reject { |k, _| olds.key?(k) }

      # A module that disappeared from one install location and appeared at another with the same basename
      removed.each do |k, o|
        nk, n = added.find { |_, cand| cand.basename == o.basename }
        next unless n

        added.delete(nk)
        moved = pair(nk, o, n)
        moved.status = :moved
        moved.flags.unshift(:moved)
        moved.changes.unshift(['install_path', k, nk])
        entries << moved
        removed.delete(k)
      end

      removed.each { |k, o| entries << Entry.new(install_path: k, status: :removed, old: o, new: nil, changes: [], flags: [], notes: []) }
      added.each { |k, n| entries << Entry.new(install_path: k, status: :added, old: nil, new: n, changes: [], flags: [], notes: n.notes) }

      entries.sort_by(&:install_path)
    end

    def url_changed?(o, n)
      @strict_urls ? o.url != n.url : o.url_normalized != n.url_normalized
    end

    def pair(k, o, n)
      changes = []
      flags = []

      changes << ['name', o.name, n.name] if o.name != n.name
      changes << ['metadata.json name', o.canonical_name, n.canonical_name] if o.canonical_name != n.canonical_name

      if o.canonical_owner != n.canonical_owner
        changes << ['owner', o.canonical_owner, n.canonical_owner]
        flags << :owner_change
      end

      if o.type != n.type
        changes << ['type', o.type, n.type]
        flags << :type_change
      end

      if url_changed?(o, n)
        notes = []
        if o.repo && n.repo
          notes << "transport #{o.repo.transport} -> #{n.repo.transport}" if o.repo.transport != n.repo.transport
          notes << "host #{plain(o.repo.host)} -> #{plain(n.repo.host)}" if o.repo.host != n.repo.host
          notes << "repo #{o.repo.repo_name} -> #{n.repo.repo_name}" if o.repo.repo_name != n.repo.repo_name
          flags << :transport_change if o.repo.transport != n.repo.transport
        end
        changes << ['url', o.url, n.url, notes.empty? ? nil : notes.join(', ')]
        flags << :url_change
      end

      if o.version != n.version
        changes << ['version', o.version_s, n.version_s]
        flags << :version_change
        d = n.major_delta_from(o)
        flags << :major_upgrade if d && d.positive?
        flags << :major_downgrade if d && d.negative?
      end

      ((o.opts.keys | n.opts.keys) - Mod::COVERED_KEYS).each do |key|
        changes << ["opt #{key}", o.opts[key], n.opts[key]] if o.opts[key] != n.opts[key]
      end

      Entry.new(install_path: k, status: changes.empty? ? :unchanged : :changed,
                old: o, new: n, changes: changes, flags: flags.uniq, notes: n.notes)
    end
  end

  # ---------------------------------------------------------------- translate

  # A URL rewrite rule: either a literal prefix substitution or a /regex/ with replacement.
  class Rule
    attr_reader :from, :to, :count, :regex

    def self.parse(spec)
      from, to = spec.split('=', 2)
      raise Error, "bad rule '#{spec}': expected FROM=TO" if from.nil? || to.nil? || from.empty?

      new(from, to)
    end

    def initialize(from, to, count: 1)
      @from = from
      @to = to
      @count = count
      @regex = nil
      if (m = %r{\A/(.*)/([imx]*)\z}m.match(from))
        flags = 0
        flags |= Regexp::IGNORECASE if m[2].include?('i')
        flags |= Regexp::MULTILINE if m[2].include?('m')
        flags |= Regexp::EXTENDED if m[2].include?('x')
        @regex = Regexp.new(m[1], flags)
      end
    end

    def apply(url)
      if regex
        regex.match?(url) ? url.sub(regex, to) : nil
      elsif url.start_with?(from)
        to + url[from.length..-1]
      end
    end

    def to_s
      "#{from} => #{to}#{count > 1 ? "  (seen #{count}x)" : ''}"
    end
  end

  class Translator
    attr_reader :rules

    def initialize(rules)
      @rules = rules
    end

    # First matching rule wins; callers order explicit rules before inferred ones.
    def apply(url)
      rules.each do |r|
        result = r.apply(url)
        return result if result
      end
      nil
    end

    # Infer prefix-substitution rules by pairing modules in +src+ with modules in +ref+
    # and taking the longest common '/'-delimited URL suffix of each pair.
    def self.infer(src, ref, warnings: [])
      tally = Hash.new(0)
      match_modules(src, ref).each do |s, r|
        next unless s.url && r.url
        next if s.url == r.url

        rule = common_suffix_rule(s.url, r.url)
        if rule
          tally[rule] += 1
        else
          warnings << "no common URL suffix for #{s.name}: #{s.url} vs #{r.url}"
        end
      end
      tally.map { |(from, to), n| Rule.new(from, to, count: n) }
           .sort_by { |r| [-r.from.length, -r.count, r.from] }
    end

    def self.common_suffix_rule(a, b)
      as = a.split('/')
      bs = b.split('/')
      n = 0
      n += 1 while n < as.length && n < bs.length && as[-1 - n] == bs[-1 - n]
      return nil if n.zero?

      suffix_len = as.last(n).join('/').length
      from = a[0, a.length - suffix_len]
      to   = b[0, b.length - suffix_len]
      return nil if from.empty?

      [from, to]
    end

    # Pair each module in +src+ with one in +ref+: by install location, then git repo name, then basename.
    def self.match_modules(src, ref)
      ref_by_path = ref.by_install_path
      remaining = ref.modules.dup
      pairs = []
      src.modules.each do |s|
        r = ref_by_path[s.install_path]
        r = nil unless r && remaining.include?(r)
        r ||= remaining.find { |m| m.repo && s.repo && m.repo.repo_name == s.repo.repo_name }
        r ||= remaining.find { |m| m.basename == s.basename }
        next unless r

        remaining.delete(r)
        pairs << [s, r]
      end
      pairs
    end
  end

  # -------------------------------------------------------------------- check

  module RepoCheck
    # Returns [:ok | :missing | :error, detail]
    def self.exists?(url, timeout: 30)
      _, err, status = Cmd.run(['git', 'ls-remote', '--exit-code', url, 'HEAD'], timeout: timeout, env: Cmd.git_env)
      return [:error, err] if status.nil?

      case status.exitstatus
      when 0 then [:ok, nil]
      when 2 then [:missing, 'no HEAD ref (empty repository?)']
      else
        detail = (err.lines.find { |l| l.start_with?('fatal:') } || err.lines.last).to_s.strip
        [err =~ /not found|does not exist|Could not read from remote|No such|denied|repository .* not found/i ? :missing : :error,
         detail]
      end
    end

    # urls -> { url => [status, detail] }, checked concurrently.
    def self.check_all(urls, concurrency: 4, timeout: 30)
      results = {}
      mutex = Mutex.new
      Cmd.parallel_each(urls.uniq, concurrency) do |url|
        res = exists?(url, timeout: timeout)
        mutex.synchronize { results[url] = res }
      end
      results
    end

    def self.report(results, io: $stderr)
      results.sort_by { |u, _| u }.each do |url, (status, detail)|
        io.puts format('  %-8s %s%s', status.to_s.upcase, url, detail ? "  (#{detail})" : '')
      end
      c = Hash.new(0)
      results.each_value { |(s, _)| c[s] += 1 }
      io.puts "  #{c[:ok]} ok, #{c[:missing]} missing, #{c[:error]} error"
      c[:missing].zero? && c[:error].zero?
    end
  end

  # ---------------------------------------------------------------------- CLI

  class CLI
    USAGE = <<~USAGE
      Usage: #{File.basename($PROGRAM_NAME)} COMMAND [options] ARGS

      Commands:
        list      PUPPETFILE       modules by install location
        compare   OLD NEW          diff two Puppetfiles by install location
        translate PUPPETFILE       rewrite repo URLs with --rule and/or --infer-from
        expand    PUPPETFILE       print a flat g10k-compatible Puppetfile
        check     PUPPETFILE       verify git repos exist (git ls-remote)

      PUPPETFILE may be '-' for stdin.  Run 'COMMAND -h' for options.
    USAGE

    def self.run(argv)
      new(argv).run
    rescue Error => e
      warn "error: #{e.message}"
      exit 2
    end

    def initialize(argv)
      @argv = argv.dup
      @opts = { moduledir: DEFAULT_MODULEDIR }
      @meta = Metadata::Options.defaults
    end

    def run
      cmd = @argv.shift
      case cmd
      when 'list' then cmd_list
      when 'compare' then cmd_compare
      when 'translate' then cmd_translate
      when 'expand' then cmd_expand
      when 'check' then cmd_check
      when '--version' then puts VERSION
      when nil, '-h', '--help' then puts USAGE
      else
        warn "unknown command '#{cmd}'\n\n#{USAGE}"
        exit 2
      end
    end

    private

    def parser(banner)
      OptionParser.new do |o|
        o.banner = banner
        o.on('--moduledir DIR', "default moduledir before any 'moduledir' declaration (#{DEFAULT_MODULEDIR})") { |v| @opts[:moduledir] = v }
        yield o if block_given?
        o.on('-h', '--help', 'show this help') do
          puts o
          exit
        end
      end
    end

    def git_options(o)
      o.on('-j', '--jobs N', Integer, 'concurrent git operations (4)') { |v| @meta.concurrency = v }
      o.on('--timeout SECONDS', Integer, "per-repository git timeout (#{@meta.timeout})") { |v| @meta.timeout = v }
    end

    def metadata_options(o)
      o.separator ''
      o.separator 'metadata.json options (canonical module name and owner):'
      o.on('--basedir DIR', 'directory holding the checked-out moduledirs; metadata.json is read from',
           'a checkout there when it is at the declared ref/version') { |v| @meta.basedir = v }
      o.on('--fetch', 'fetch metadata.json from git repos at the declared ref when no',
           'usable checkout is found (off by default; without it the declared name is used)') { @meta.fetch = true }
      o.on('--cache-dir DIR', "cache fetched metadata.json under DIR (#{DEFAULT_CACHE_DIR})") { |v| @meta.cache_dir = v }
      o.on('--no-cache', 'do not read or write the metadata.json cache') { @meta.cache_dir = nil }
      git_options(o)
    end

    def positional(parser, count)
      parser.parse!(@argv)
      if @argv.length != count
        warn parser
        exit 2
      end
      @argv
    end

    def load(path)
      Puppetfile.load(path, default_moduledir: @opts[:moduledir])
    end

    def load_with_metadata(path)
      Metadata.resolve_all(load(path), @meta)
    end

    def cmd_list
      p = parser('Usage: list [options] PUPPETFILE') do |o|
        o.on('--json', 'JSON output') { @opts[:json] = true }
        metadata_options(o)
      end
      (path,) = positional(p, 1)
      pf = load_with_metadata(path)
      if @opts[:json]
        puts JSON.pretty_generate(pf.modules.map(&:to_h))
        return
      end
      rows = pf.modules.sort_by(&:install_path).map do |m|
        [m.install_path, m.type.to_s, m.name, (m.metadata && m.metadata.name).to_s, m.version_s, m.url.to_s]
      end
      header = %w[INSTALL_PATH TYPE NAME METADATA_NAME VERSION URL]
      widths = header.each_index.map { |i| ([header[i]] + rows.map { |r| r[i] }).map(&:length).max }
      ([header] + rows).each do |r|
        puts r.each_with_index.map { |c, i| c.ljust(widths[i]) }.join('  ').rstrip
      end
      noted = pf.modules.sort_by(&:install_path).reject { |m| m.notes.empty? }
      return if noted.empty?

      puts '', 'Notes:'
      noted.each { |m| m.notes.each { |n| puts "  #{m.install_path}  #{n}" } }
    end

    def cmd_compare
      sections = Comparison::DEFAULT_SECTIONS.dup
      names = Comparison::SECTIONS.keys.join(',')
      p = parser('Usage: compare [options] OLD_PUPPETFILE NEW_PUPPETFILE') do |o|
        o.on('--json', 'JSON output') { @opts[:json] = true }
        o.on('--exit-code', 'exit 1 when the Puppetfiles differ (like diff)') { @opts[:exit_code] = true }
        o.on('--strict-urls', "treat a present/missing '.git' suffix as a URL change") { @opts[:strict_urls] = true }
        o.separator ''
        o.separator "output sections (default: #{Comparison::DEFAULT_SECTIONS.join(',')}):"
        o.on('--only LIST', Array, 'show only these sections') { |v| sections = section_names(v) }
        o.on('--show LIST', Array, 'add sections to the default set') { |v| sections |= section_names(v) }
        o.on('--hide LIST', Array, 'remove sections from the default set') { |v| sections -= section_names(v) }
        o.on('-a', '--all', 'show every section') { sections = Comparison::SECTIONS.keys }
        o.separator "  sections: #{names}"
        metadata_options(o)
      end
      old_path, new_path = positional(p, 2)
      cmp = Comparison.new(load_with_metadata(old_path), load_with_metadata(new_path), strict_urls: @opts[:strict_urls])
      if @opts[:json]
        puts JSON.pretty_generate(cmp.to_h)
      else
        print cmp.to_text(sections: Comparison::SECTIONS.keys & sections)
      end
      exit 1 if @opts[:exit_code] && cmp.differences?
    end

    def section_names(list)
      list.map do |name|
        key = name.strip.downcase.to_sym
        raise Error, "unknown section '#{name}' (choose from #{Comparison::SECTIONS.keys.join(', ')})" unless Comparison::SECTIONS.key?(key)

        key
      end
    end

    def cmd_expand
      p = parser('Usage: expand [options] PUPPETFILE')
      (path,) = positional(p, 1)
      print load(path).to_g10k
    end

    def cmd_check
      p = parser('Usage: check [options] PUPPETFILE') do |o|
        git_options(o)
      end
      (path,) = positional(p, 1)
      pf = load(path)
      urls = pf.modules.select { |m| m.type == :git }.map(&:url)
      warn "Checking #{urls.uniq.length} git repositories:"
      ok = RepoCheck.report(RepoCheck.check_all(urls, concurrency: @meta.concurrency, timeout: @meta.timeout))
      exit(ok ? 0 : 1)
    end

    def cmd_translate
      rules = []
      p = parser('Usage: translate [options] PUPPETFILE') do |o|
        o.on('-r', '--rule FROM=TO', 'rewrite URLs starting with FROM to start with TO;',
             'FROM may be a /regex/ and TO may use \\1 backreferences (repeatable)') { |v| rules << Rule.parse(v) }
        o.on('-i', '--infer-from REFERENCE', 'infer rules from a Puppetfile whose URLs are already translated') { |v| @opts[:infer] = v }
        o.on('--show-rules', 'print the effective rules and exit') { @opts[:show_rules] = true }
        o.on('-e', '--expand', 'emit a flat g10k-compatible Puppetfile instead of editing the source text') { @opts[:expand] = true }
        o.on('-o', '--output FILE', 'write the result to FILE instead of stdout') { |v| @opts[:output] = v }
        o.on('--check', 'verify every resulting git repo exists (git ls-remote)') { @opts[:check] = true }
        git_options(o)
      end
      (path,) = positional(p, 1)
      pf = load(path)

      warnings = []
      if @opts[:infer]
        inferred = Translator.infer(pf, load(@opts[:infer]), warnings: warnings)
        warn "inferred #{inferred.length} rule(s) from #{@opts[:infer]}" if inferred.empty? || @opts[:show_rules]
        rules.concat(inferred)
      end
      warnings.each { |w| warn "warning: #{w}" }
      raise Error, 'no rules: give --rule and/or --infer-from' if rules.empty?

      if @opts[:show_rules]
        rules.each { |r| puts r }
        return
      end

      translator = Translator.new(rules)
      rewritten = []
      unmatched = []
      pf.modules.each do |m|
        next unless m.url

        new_url = translator.apply(m.url)
        if new_url.nil?
          unmatched << m
        elsif new_url != m.url
          rewritten << [m, m.url, new_url]
        end
      end

      unmatched.each { |m| warn "warning: no rule matched #{m.name}: #{m.url}" }

      result =
        if @opts[:expand]
          translated = Puppetfile.new('', path: pf.path, default_moduledir: pf.default_moduledir)
          translated.set_forge(pf.forge_url)
          pf.modules.each do |m|
            change = rewritten.find { |(mod, _, _)| mod.equal?(m) }
            translated.set_moduledir(m.moduledir)
            translated.add_module(m.name, change ? m.with_url(change[2]).opts : m.args, m.line)
          end
          translated.to_g10k
        else
          text = pf.source.dup
          rewritten.each do |m, old_url, new_url|
            n = 0
            text = text.gsub(/(['"])#{Regexp.escape(old_url)}\1/) do
              n += 1
              "#{Regexp.last_match(1)}#{new_url}#{Regexp.last_match(1)}"
            end
            warn "warning: #{m.name}: URL #{old_url} is not a string literal in #{pf.path}; use --expand to translate it" if n.zero?
          end
          text
        end

      warn "rewrote #{rewritten.length} URL(s), #{unmatched.length} unmatched"

      if @opts[:output]
        File.write(@opts[:output], result)
      else
        print result
      end

      return unless @opts[:check]

      final_urls = pf.modules.select { |m| m.type == :git }.map do |m|
        change = rewritten.find { |(mod, _, _)| mod.equal?(m) }
        change ? change[2] : m.url
      end
      warn "Checking #{final_urls.uniq.length} git repositories:"
      ok = RepoCheck.report(RepoCheck.check_all(final_urls, concurrency: @meta.concurrency, timeout: @meta.timeout))
      exit 1 unless ok
    end
  end
end

PuppetfileTool::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
