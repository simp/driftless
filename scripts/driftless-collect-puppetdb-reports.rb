#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Collect one or more canonical PuppetDB reports in a single session and
# write them to a session directory: one NDJSON per report plus a
# _summary.json describing the run. See
# claude-memory/project_driftless_collector_design.md for the design.

require 'fileutils'
require 'json'
require 'logger'
require 'net/http'
require 'openssl'
require 'optparse'
require 'socket'
require 'stringio'
require 'time'
require 'uri'
require 'zlib'

COLLECTOR_VERSION = '0.1.0'

REPORTS = {
  'all-active-nodes' => {
    kind: :single_shot,
    pql:  'nodes[certname, catalog_environment] { deactivated is null and expired is null order by certname }',
    file: 'all-active-nodes.ndjson',
  },
  'factsets-for-all-active-nodes' => {
    kind: :batched_by_certname,
    pql:  ->(quoted) { "inventory[certname, environment, trusted, facts] { certname in [#{quoted}] }" },
    file: 'factsets-for-all-active-nodes.ndjson',
  },
  'classes-for-all-active-nodes' => {
    kind: :batched_by_certname,
    pql:  ->(quoted) { "resources[certname, title, environment] { type = 'Class' and certname in [#{quoted}] }" },
    file: 'classes-for-all-active-nodes.ndjson',
  },
  'fips-enabled-nodes' => {
    kind: :single_shot,
    pql:  "inventory[certname, environment, facts.selinux_current_mode] { facts.fips_enabled = true }",
    file: 'fips-enabled-nodes.ndjson',
  },
}.freeze

def puppet_defaults
  require 'puppet'
  Puppet.initialize_settings([])
  {
    cert:     Puppet.settings[:hostcert],
    key:      Puppet.settings[:hostprivkey],
    cacert:   Puppet.settings[:localcacert],
    certname: Puppet.settings[:certname],
  }
rescue LoadError, StandardError
  host = Socket.gethostname
  {
    cert:     "/etc/puppetlabs/puppet/ssl/certs/#{host}.pem",
    key:      "/etc/puppetlabs/puppet/ssl/private_keys/#{host}.pem",
    cacert:   '/etc/puppetlabs/puppet/ssl/certs/ca.pem',
    certname: nil,
  }
end

opts = {
  url:         'https://localhost:8081',
  cert:        nil,
  key:         nil,
  cacert:      nil,
  page_size:   500,
  sleep:       0.25,
  jitter:      0.25,
  output_dir:  './driftless-collector-output',
  collector: nil,
  reports:     [],
  timeout:     120,
  attempts:    3,
  log_level:   Logger::INFO,
}

OptionParser.new do |o|
  o.banner = "Usage: #{$PROGRAM_NAME} [options]"
  o.on('--url URL',            "PuppetDB base URL (default #{opts[:url]})")                                    { |v| opts[:url] = v }
  o.on('--cert PATH',          'Client cert (default: from puppet SSL config)')                                { |v| opts[:cert] = v }
  o.on('--key PATH',           'Client key (default: from puppet SSL config)')                                 { |v| opts[:key] = v }
  o.on('--cacert PATH',        'CA bundle (default: from puppet SSL config)')                                  { |v| opts[:cacert] = v }
  o.on('--output-dir PATH',    "Where to write sessions/ (default #{opts[:output_dir]})")                      { |v| opts[:output_dir] = v }
  o.on('--collector NAME',   'Contributor name for _summary.json (default: puppet certname or hostname -f)')  { |v| opts[:collector] = v }
  o.on('--report NAME',        "Report to run (repeatable). Default: all. Known: #{REPORTS.keys.join(', ')}")  { |v| opts[:reports] << v }
  o.on('--page-size N', Integer, "Certnames per batched request (default #{opts[:page_size]})")                { |v| opts[:page_size] = v }
  o.on('--sleep SECS',  Float,   "Base sleep between batched requests (default #{opts[:sleep]})")              { |v| opts[:sleep] = v }
  o.on('--jitter SECS', Float,   "Extra random sleep, 0..jitter (default #{opts[:jitter]})")                   { |v| opts[:jitter] = v }
  o.on('--timeout SECS', Integer, "HTTP read timeout (default #{opts[:timeout]})")                             { |v| opts[:timeout] = v }
  o.on('--attempts N',   Integer, "Retry attempts per request (default #{opts[:attempts]})")                   { |v| opts[:attempts] = v }
  o.on('-v', '--verbose',        'Also log queries and per-request retries')                                   { opts[:log_level] = Logger::DEBUG }
  o.on('-h', '--help')           { puts o; exit 0 }
end.parse!

log = Logger.new($stderr)
log.level = opts[:log_level]
log.formatter = ->(sev, t, _p, msg) { "#{t.iso8601} #{sev} #{msg}\n" }

selected_reports = opts[:reports].empty? ? REPORTS.keys : opts[:reports].uniq
unknown = selected_reports - REPORTS.keys
unless unknown.empty?
  log.error("unknown report(s): #{unknown.join(', ')}. known: #{REPORTS.keys.join(', ')}")
  exit 2
end

uri = URI("#{opts[:url].chomp('/')}/pdb/query/v4")

# Puppet will load iff we need TLS defaults. Same predicate drives both the
# SSL cert bootstrap and the collector default.
puppet_will_load = uri.scheme == 'https' &&
                   (opts[:cert].nil? || opts[:key].nil? || opts[:cacert].nil?)
defaults         = puppet_will_load ? puppet_defaults : nil

http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl            = uri.scheme == 'https'
http.read_timeout       = opts[:timeout]
http.keep_alive_timeout = 30

if http.use_ssl?
  opts[:cert]   ||= defaults[:cert]
  opts[:key]    ||= defaults[:key]
  opts[:cacert] ||= defaults[:cacert]
  http.verify_mode = OpenSSL::SSL::VERIFY_PEER
  http.cert        = OpenSSL::X509::Certificate.new(File.read(opts[:cert]))
  http.key         = OpenSSL::PKey::RSA.new(File.read(opts[:key]))
  http.ca_file     = opts[:cacert]
end

collector = opts[:collector] ||
              (puppet_will_load && defaults[:certname]) ||
              `hostname -f`.chomp

session_started = Time.now.utc
session_id      = session_started.strftime('%Y-%m-%dT%H-%M-%SZ')
session_dir     = File.join(opts[:output_dir], 'sessions', session_id)
FileUtils.mkdir_p(session_dir)
log.info("session #{session_id} → #{session_dir}")
log.info("collector: #{collector}")

query_page = lambda do |pql|
  req = Net::HTTP::Post.new(uri)
  req['Content-Type']    = 'application/json'
  req['Accept']          = 'application/json'
  req['Accept-Encoding'] = 'gzip'
  req.body = JSON.dump(query: pql)

  tries = 0
  begin
    tries += 1
    log.debug("POST #{uri} attempt=#{tries} query=#{pql}")
    res = http.request(req)
    raise "PuppetDB HTTP #{res.code}: #{res.body.to_s[0, 500]}" unless res.code == '200'

    body = res.body
    body = Zlib::GzipReader.new(StringIO.new(body)).read if res['content-encoding'] == 'gzip'
    JSON.parse(body)
  rescue => e
    raise if tries >= opts[:attempts]
    backoff = 2**tries
    log.warn("query failed (#{e.class}: #{e.message}); retrying in #{backoff}s")
    sleep backoff
    retry
  end
end

# Phase 1 (list active certnames) is shared by every :batched_by_certname
# report. Load it lazily on first demand; cache for reuse.
certnames       = nil
phase_1_summary = nil
ensure_certnames = lambda do
  return certnames if certnames
  pql = 'nodes[certname] { deactivated is null and expired is null order by certname }'
  log.info('phase 1: listing active certnames')
  started = Time.now
  rows = query_page.call(pql)
  certnames = rows.map { |r| r.fetch('certname') }
  phase_1_summary = {
    'pql'              => pql,
    'certnames_count'  => certnames.size,
    'duration_seconds' => (Time.now - started).round(2),
  }
  log.info("phase 1: #{certnames.size} active nodes")
  certnames
end

http.start do
  report_summaries = {}

  selected_reports.each do |name|
    spec           = REPORTS[name]
    started        = Time.now
    file_path      = File.join(session_dir, spec[:file])
    rows_written   = 0
    pql_for_summary = spec[:kind] == :single_shot ? spec[:pql] : spec[:pql].call('<BATCH>')

    begin
      case spec[:kind]
      when :single_shot
        log.info("report #{name}: single-shot")
        rows = query_page.call(spec[:pql])
        File.open(file_path, 'w') { |f| rows.each { |r| f.puts(JSON.dump(r)) } }
        rows_written = rows.size
        log.info("report #{name}: #{rows_written} rows")

      when :batched_by_certname
        certs = ensure_certnames.call
        pages = certs.empty? ? 0 : (certs.size.to_f / opts[:page_size]).ceil
        File.open(file_path, 'w') do |f|
          certs.each_slice(opts[:page_size]).with_index(1) do |batch, page|
            quoted = batch.map { |c| JSON.dump(c) }.join(', ')
            pql    = spec[:pql].call(quoted)
            log.debug("report #{name}: page #{page.to_s.ljust(pages.to_s.size)}/#{pages}: pql='#{pql}'")
            rows = query_page.call(pql)
            rows.each { |r| f.puts(JSON.dump(r)) }
            rows_written += rows.size
            log.info("report #{name}: page #{page}/#{pages} fetched #{rows.size} (total #{rows_written})")
            sleep(opts[:sleep] + rand * opts[:jitter]) unless page == pages
          end
        end
      end

      report_summaries[name] = {
        'file'             => spec[:file],
        'pql'              => pql_for_summary,
        'rows'             => rows_written,
        'duration_seconds' => (Time.now - started).round(2),
        'status'           => 'ok',
      }
    rescue => e
      log.error("report #{name} failed: #{e.class}: #{e.message}")
      report_summaries[name] = {
        'file'             => spec[:file],
        'pql'              => pql_for_summary,
        'rows'             => rows_written,
        'duration_seconds' => (Time.now - started).round(2),
        'status'           => 'failed',
        'error'            => "#{e.class}: #{e.message}",
      }
    end
  end

  summary = {
    'session_id'        => session_id,
    'collector'         => collector,
    'pdb_url'           => opts[:url],
    'collector_version' => COLLECTOR_VERSION,
    'started_at'        => session_started.iso8601,
    'completed_at'      => Time.now.utc.iso8601,
    'params'            => {
      'page_size' => opts[:page_size],
      'sleep'     => opts[:sleep],
      'jitter'    => opts[:jitter],
    },
    'phase_1'           => phase_1_summary,
    'reports'           => report_summaries,
  }
  File.write(File.join(session_dir, '_summary.json'), JSON.pretty_generate(summary) + "\n")

  failed = report_summaries.values.count { |r| r['status'] == 'failed' }
  log.info("done: #{report_summaries.size} reports (#{failed} failed) → #{session_dir}")
  exit(failed.zero? ? 0 : 1)
end
