#!/usr/bin/env ruby
# frozen_string_literal: true

# Print `gem 'name', 'version'` lines pinning each listed gem to the newest
# release on a rubygems server whose required_ruby_version accepts a target
# Ruby (default 2.7.8).
#
# Stdlib only; runs on Ruby 2.7 and newer.  See --help and README.md.

require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'openssl'
require 'optparse'
require 'rbconfig'
require 'rubygems'
require 'set'
require 'stringio'
require 'tmpdir'
require 'uri'
require 'zlib'

module LatestForRuby
  VERSION = '1.0.0'

  class Error < StandardError; end

  # HTTP GET with a file cache, keep-alive and retries.  Not thread-safe:
  # give each thread its own instance (they can share a cache directory).
  class Fetcher
    RETRYABLE = [
      Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED,
      Errno::EPIPE, Errno::ETIMEDOUT, EOFError, IOError
    ].freeze

    attr_reader :requests

    # policy for #get:
    #   :forever    - use the cached copy whenever it exists (immutable files)
    #   :revalidate - use the cached copy while younger than max_age, then
    #                 send a conditional GET if the server gave validators
    def initialize(base_url, cache_dir:, ca_file: nil, timeout: 120, max_age: 86_400,
                   retries: 3, log: nil)
      @base = URI(base_url.end_with?('/') ? base_url : "#{base_url}/")
      @cache_dir = cache_dir
      @ca_file = ca_file
      @timeout = timeout
      @max_age = max_age
      @retries = retries
      @log = log
      @http = nil
      @requests = 0
    end

    # Returns the body, or nil when the server answers 404/410.
    def get(path, policy)
      file = cache_path(path)
      meta_file = "#{file}.meta.json"
      cached = File.file?(file)
      return File.binread(file) if cached && policy == :forever
      return File.binread(file) if cached && (Time.now - File.mtime(file)) < @max_age

      headers = {}
      if cached && File.file?(meta_file)
        meta = JSON.parse(File.read(meta_file)) rescue {}
        headers['If-None-Match'] = meta['etag'] if meta['etag']
        headers['If-Modified-Since'] = meta['last_modified'] if meta['last_modified']
      end

      res = request(path, headers)
      case res
      when Net::HTTPNotModified
        FileUtils.touch(file)
        File.binread(file)
      when Net::HTTPSuccess
        body = res.body.to_s.b
        store(file, body)
        meta = { 'etag' => res['ETag'], 'last_modified' => res['Last-Modified'] }.reject { |_, v| v.nil? }
        if meta.empty?
          FileUtils.rm_f(meta_file)
        else
          File.write(meta_file, JSON.generate(meta))
        end
        body
      when Net::HTTPNotFound, Net::HTTPGone
        nil
      else
        raise Error, "GET #{url_for(path)}: HTTP #{res.code} #{res.message}"
      end
    end

    def url_for(path)
      URI.join(@base, path).to_s
    end

    def finish
      @http.finish if @http && @http.started?
    rescue IOError
      nil
    ensure
      @http = nil
    end

    private

    def request(path, headers)
      attempt = 0
      begin
        attempt += 1
        @requests += 1
        req = Net::HTTP::Get.new(URI.join(@base, path).request_uri, headers)
        res = connection.request(req)
        raise Error, "HTTP #{res.code}" if res.code.to_i >= 500 || res.code == '429'

        res
      rescue OpenSSL::SSL::SSLError => e
        finish
        raise Error, "TLS error talking to #{@base.host}: #{e.message} " \
                     '(point SSL_CERT_FILE or --ca-file at the CA bundle for this server)'
      rescue *RETRYABLE, Error => e
        finish
        raise Error, "GET #{url_for(path)} failed after #{attempt} attempts: #{e.message}" if attempt > @retries

        delay = 2**attempt
        @log&.call("  retrying #{path} in #{delay}s (#{e.class}: #{e.message})")
        sleep delay
        retry
      end
    end

    def connection
      return @http if @http && @http.started?

      http = Net::HTTP.new(@base.host, @base.port)
      http.use_ssl = @base.scheme == 'https'
      if http.use_ssl?
        # The default cert store honours SSL_CERT_FILE / SSL_CERT_DIR.
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.ca_file = @ca_file if @ca_file
      end
      http.open_timeout = 30
      http.read_timeout = @timeout
      http.keep_alive_timeout = 30
      http.start
      @http = http
    end

    def cache_path(path)
      File.join(@cache_dir, path.gsub(%r{[^A-Za-z0-9._/-]}, '_'))
    end

    def store(file, body)
      FileUtils.mkdir_p(File.dirname(file))
      tmp = "#{file}.#{Process.pid}.#{Thread.current.object_id}.tmp"
      File.binwrite(tmp, body)
      File.rename(tmp, file)
    end
  end

  # Released versions per gem, from specs.4.8.gz.
  class SpecsIndex
    # Returns { name => { Gem::Version => [platform, ...] } } for the wanted names.
    def self.load(data, wanted)
      data = Zlib.gunzip(data.b) if data.getbyte(0) == 0x1f && data.getbyte(1) == 0x8b
      index = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } }
      Marshal.load(data).each do |name, version, platform|
        next unless wanted.include?(name)

        version = Gem::Version.new(version.to_s) unless version.is_a?(Gem::Version)
        next if version.prerelease?

        index[name][version] << platform.to_s
      end
      index
    end
  end

  # Decides which platform variants of a version count.
  class PlatformFilter
    def initialize(extra)
      @extra = extra.map { |p| Gem::Platform.new(p) }
    end

    def accept?(platform)
      return true if platform == 'ruby'

      gp = Gem::Platform.new(platform)
      @extra.any? { |want| gp == want || gp === want }
    end
  end

  # Ruby requirements from /quick/Marshal.4.8/<name>-<version>[-<platform>].gemspec.rz
  class QuickMarshalSource
    def label
      'quick gemspec'
    end

    # Yields [version, platform] candidates newest first; returns the first
    # version whose gemspec accepts target.
    def pick(fetcher, name, versions, platforms, target, log)
      versions.keys.sort.reverse_each do |version|
        versions[version].select { |p| platforms.accept?(p) }.each do |platform|
          req = ruby_requirement(fetcher, name, version, platform, log)
          return version if req && req.satisfied_by?(target)
        end
      end
      nil
    end

    def ruby_requirement(fetcher, name, version, platform, log)
      suffix = platform == 'ruby' ? '' : "-#{platform}"
      path = "quick/Marshal.4.8/#{name}-#{version}#{suffix}.gemspec.rz"
      data = fetcher.get(path, :forever)
      unless data
        log.call("  #{name} #{version} #{platform}: #{path} not found, skipping")
        return nil
      end
      spec = Marshal.load(Zlib::Inflate.inflate(data))
      spec.required_ruby_version || Gem::Requirement.default
    rescue StandardError => e
      raise if e.is_a?(Error)

      log.call("  #{name} #{version} #{platform}: unreadable gemspec (#{e.class}: #{e.message}), skipping")
      nil
    end
  end

  # Ruby requirements from the compact index, /info/<name>: one request per gem.
  class CompactIndexSource
    def initialize(fallback)
      @fallback = fallback
    end

    def label
      'compact index'
    end

    # A compact index info file starts with a "---" line.
    def self.valid?(body)
      !body.nil? && body.start_with?("---\n", "---\r\n")
    end

    # Returns { [Gem::Version, platform] => Gem::Requirement }.
    def self.parse(body)
      result = {}
      body.each_line do |line|
        line = line.chomp
        next if line.empty? || line == '---'

        ver_plat, rest = line.split(' ', 2)
        version, platform = ver_plat.split('-', 2)
        _deps, reqs = (rest || '').split('|', 2)
        result[[Gem::Version.new(version), platform || 'ruby']] = ruby_requirement(reqs)
      end
      result
    end

    # "checksum:abc,ruby:>= 2.7&< 4,rubygems:>= 1.3" -> Gem::Requirement.
    # Tolerates "," between constraints as well as "&".
    def self.ruby_requirement(reqs)
      fields = []
      (reqs || '').split(',').each do |part|
        if part =~ /\A\s*[a-z_]+:/
          fields << part
        elsif fields.any?
          fields[-1] = "#{fields[-1]},#{part}"
        end
      end
      ruby = fields.find { |f| f.start_with?('ruby:') }
      return Gem::Requirement.default unless ruby

      Gem::Requirement.new(*ruby.sub('ruby:', '').split(/[&,]/).map(&:strip))
    end

    def pick(fetcher, name, versions, platforms, target, log)
      body = fetcher.get("info/#{name}", :revalidate)
      unless self.class.valid?(body)
        log.call("  #{name}: no compact index entry, using quick gemspecs")
        return @fallback.pick(fetcher, name, versions, platforms, target, log)
      end
      info = self.class.parse(body)

      versions.keys.sort.reverse_each do |version|
        versions[version].select { |p| platforms.accept?(p) }.each do |platform|
          req = info[[version, platform]]
          # specs.4.8.gz and /info disagree: ask the gemspec.
          req ||= @fallback.ruby_requirement(fetcher, name, version, platform, log)
          return version if req && req.satisfied_by?(target)
        end
      end
      nil
    end
  end

  # Runs `bundle lock` on the pins, with the resolver seeing the target Ruby.
  class DepsolveCheck
    def initialize(source_url, pins, target, ca_file: nil, verbose: false, log:)
      @source_url = source_url
      @pins = pins
      @target = target
      @ca_file = ca_file
      @verbose = verbose
      @log = log
    end

    # Returns true when the pins resolve.
    def run
      Dir.mktmpdir('latest_for_ruby') do |dir|
        gemfile = File.join(dir, 'Gemfile')
        File.write(gemfile, LatestForRuby.gemfile_text(@source_url, @pins))

        env = {
          'BUNDLE_GEMFILE' => gemfile,
          'BUNDLE_APP_CONFIG' => File.join(dir, '.bundle'),
          'BUNDLE_FROZEN' => nil,
          'BUNDLE_DEPLOYMENT' => nil,
          'BUNDLE_BIN_PATH' => nil,
          'BUNDLER_SETUP' => nil,
          'RUBYOPT' => nil
        }
        if @ca_file
          env['BUNDLE_SSL_CA_CERT'] = @ca_file
          env['SSL_CERT_FILE'] = @ca_file
        end
        if Gem::Version.new(RUBY_VERSION) != @target
          shim = File.join(dir, 'ruby_version_shim.rb')
          File.write(shim, <<~RUBY)
            module Gem
              def self.ruby_version
                Gem::Version.new(#{@target.to_s.inspect})
              end
            end
          RUBY
          env['RUBYOPT'] = "-r#{shim}"
          @log.call("depsolve: running Ruby #{RUBY_VERSION}; bundler resolves as Ruby #{@target} via a Gem.ruby_version shim")
        end

        cmd = bundle_command + ['lock']
        @log.call("depsolve: #{cmd.join(' ')} (this fetches the index for every dependency; it can be slow)")
        out, status = Open3.capture2e(env, *cmd, chdir: dir)
        if status.success?
          @log.call('depsolve: OK, the pins resolve together')
          print_lock(File.join(dir, 'Gemfile.lock')) if @verbose
          true
        else
          @log.call("depsolve: FAILED (exit #{status.exitstatus})")
          out.each_line { |l| @log.call("  #{l.chomp}") }
          false
        end
      end
    end

    private

    def bundle_command
      [RbConfig.ruby, Gem.bin_path('bundler', 'bundle')]
    rescue Gem::Exception, LoadError
      ['bundle']
    end

    def print_lock(lockfile)
      pinned = @pins.map(&:first).to_set
      extra = File.readlines(lockfile).filter_map do |l|
        m = l.match(/\A {4}(\S+) \(([^)]+)\)\s*\z/)
        m && !pinned.include?(m[1]) ? "#{m[1]} #{m[2]}" : nil
      end
      @log.call("depsolve: #{extra.size} transitive gems")
      extra.each { |e| @log.call("  #{e}") }
    end
  end

  Result = Struct.new(:name, :version, :error, keyword_init: true)

  module_function

  def gemfile_text(source_url, pins)
    lines = ["source '#{source_url}'", '']
    pins.each { |name, version| lines << "gem '#{name}', '#{version}'" }
    lines.join("\n") + "\n"
  end

  # Gem names from lines of text: one per line, "#" comments, and lines
  # already written as `gem 'name', ...` are accepted.
  def parse_names(text)
    names = []
    text.each_line do |line|
      line = line.sub(/#.*/, '').strip
      next if line.empty?

      m = line.match(/\Agem\s*\(?\s*['"]([^'"]+)['"]/)
      names << (m ? m[1] : line.split(/[\s,]+/).first)
    end
    names.uniq
  end

  def default_cache_dir(source_url)
    base = ENV['XDG_CACHE_HOME'] || File.join(Dir.home, '.cache')
    uri = URI(source_url)
    File.join(base, 'latest_for_ruby', "#{uri.host}_#{uri.port}#{uri.path}".gsub(/[^A-Za-z0-9._-]+/, '_'))
  end

  def parse_options(argv)
    opts = {
      source: ENV['GEM_SOURCE'],
      ruby: '2.7.8',
      platforms: [],
      jobs: 4,
      timeout: 120,
      max_age: 86_400,
      mode: :auto,
      gemfile: false,
      check: false,
      check_verbose: false,
      quiet: false
    }
    parser = OptionParser.new do |o|
      o.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options] [GEMLIST_FILE...]\n" \
                 "Reads gem names (one per line) from the files or stdin and prints\n" \
                 "`gem 'name', 'version'` for the newest release that supports the target Ruby.\n\n"
      o.on('-s', '--source URL', 'Rubygems server (default: $GEM_SOURCE, else first `gem sources` entry)') { |v| opts[:source] = v }
      o.on('-r', '--ruby VERSION', "Target Ruby version (default #{opts[:ruby]})") { |v| opts[:ruby] = v }
      o.on('-p', '--platform PLATFORM', 'Also accept this platform (repeatable); "ruby" is always accepted') { |v| opts[:platforms] << v }
      o.on('--ca-file PATH', 'CA bundle for TLS (otherwise SSL_CERT_FILE / system store)') { |v| opts[:ca_file] = v }
      o.on('-j', '--jobs N', Integer, "Concurrent requests (default #{opts[:jobs]})") { |v| opts[:jobs] = v }
      o.on('--timeout SECONDS', Integer, "HTTP read timeout (default #{opts[:timeout]})") { |v| opts[:timeout] = v }
      o.on('--cache DIR', 'Response cache directory (default ~/.cache/latest_for_ruby/<server>)') { |v| opts[:cache] = v }
      o.on('--max-age SECONDS', Integer, "Reuse cached indexes this long without asking the server (default #{opts[:max_age]})") { |v| opts[:max_age] = v }
      o.on('--refresh', 'Revalidate cached indexes now (same as --max-age 0)') { opts[:max_age] = 0 }
      o.on('--[no-]compact-index', 'Force (or forbid) the /info compact index; default: probe') { |v| opts[:mode] = v ? :compact : :quick }
      o.on('--gemfile', "Print a complete Gemfile (adds the `source` line)") { opts[:gemfile] = true }
      o.on('--check', 'Run `bundle lock` on the result to see whether the pins resolve together') { opts[:check] = true }
      o.on('--check-verbose', 'Like --check, and list the transitive gems') { opts[:check] = opts[:check_verbose] = true }
      o.on('-q', '--quiet', 'Only print warnings and errors on stderr') { opts[:quiet] = true }
      o.on('-v', '--version') { puts VERSION; exit }
    end
    parser.parse!(argv)
    if opts[:ca_file] && !File.file?(opts[:ca_file])
      warn "--ca-file #{opts[:ca_file]}: no such file"
      exit 2
    end
    opts[:source] ||= Gem.sources.first.to_s
    opts[:source] = "#{opts[:source]}/" unless opts[:source].end_with?('/')
    opts[:cache] ||= default_cache_dir(opts[:source])
    opts
  rescue OptionParser::ParseError => e
    warn e.message
    warn parser
    exit 2
  end

  def new_fetcher(opts, log)
    Fetcher.new(opts[:source], cache_dir: opts[:cache], ca_file: opts[:ca_file],
                               timeout: opts[:timeout], max_age: opts[:max_age], log: log)
  end

  # Picks the requirement source.  In :auto mode, probes /info/<name> for a
  # gem that specs.4.8.gz says exists.
  def choose_source(opts, fetcher, index, info, warn_log)
    quick = QuickMarshalSource.new
    compact = CompactIndexSource.new(quick)
    case opts[:mode]
    when :quick then quick
    when :compact then compact
    else
      probe = index.keys.first
      return quick unless probe

      body = begin
        fetcher.get("info/#{probe}", :revalidate)
      rescue Error => e
        warn_log.call("compact index probe failed (#{e.message})")
        nil
      end
      if CompactIndexSource.valid?(body)
        info.call("server has a compact index (/info/#{probe})")
        compact
      else
        info.call("no compact index at /info/#{probe}; using quick gemspecs (one request per version tried)")
        quick
      end
    end
  end

  def main(argv)
    opts = parse_options(argv)
    names = parse_names(ARGF.read)
    if names.empty?
      warn 'no gem names given'
      return 2
    end

    target = Gem::Version.new(opts[:ruby])
    platforms = PlatformFilter.new(opts[:platforms])
    out_lock = Mutex.new
    warn_log = ->(msg) { out_lock.synchronize { warn msg } }
    info = opts[:quiet] ? ->(_msg) {} : warn_log

    info.call("source #{opts[:source]}, target Ruby #{target}, cache #{opts[:cache]}")
    main_fetcher = new_fetcher(opts, warn_log)
    info.call('loading specs.4.8.gz')
    specs = main_fetcher.get('specs.4.8.gz', :revalidate)
    raise Error, "#{main_fetcher.url_for('specs.4.8.gz')} not found" unless specs

    index = SpecsIndex.load(specs, names.to_set)
    source = choose_source(opts, main_fetcher, index, info, warn_log)
    main_fetcher.finish

    results = {}
    queue = Queue.new
    names.each { |n| queue << n }
    done = 0
    workers = Array.new([opts[:jobs], names.size].min) do
      Thread.new do
        fetcher = new_fetcher(opts, warn_log)
        begin
          loop do
            name = begin
              queue.pop(true)
            rescue ThreadError
              break
            end
            result =
              if !index.key?(name)
                Result.new(name: name, error: 'not found on the server')
              else
                begin
                  v = source.pick(fetcher, name, index[name], platforms, target, info)
                  v ? Result.new(name: name, version: v) : Result.new(name: name, error: "no release supports Ruby #{target}")
                rescue Error => e
                  Result.new(name: name, error: e.message)
                end
              end
            out_lock.synchronize do
              results[name] = result
              done += 1
              status = result.version ? "#{result.version} (#{source.label})" : "NOT PINNED: #{result.error}"
              warn "[#{done}/#{names.size}] #{name} -> #{status}" unless opts[:quiet] && result.version
            end
          end
        ensure
          fetcher.finish
        end
      end
    end
    workers.each(&:join)

    pins = []
    lines = []
    lines << "source '#{opts[:source]}'" << '' if opts[:gemfile]
    names.each do |name|
      r = results[name]
      if r.version
        pins << [name, r.version]
        lines << "gem '#{name}', '#{r.version}'"
      else
        lines << "# gem '#{name}' - #{r.error}"
      end
    end
    $stdout.puts lines

    ok = pins.size == names.size
    if opts[:check] && pins.any?
      ok = DepsolveCheck.new(opts[:source], pins, target, ca_file: opts[:ca_file],
                                                          verbose: opts[:check_verbose], log: warn_log).run && ok
    end
    ok ? 0 : 1
  rescue Error => e
    warn "error: #{e.message}"
    3
  end
end

exit LatestForRuby.main(ARGV) if $PROGRAM_NAME == __FILE__
