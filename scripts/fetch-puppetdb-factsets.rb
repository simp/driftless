#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Fetch factsets for every active node from PuppetDB via PQL, streamed to
# NDJSON. Uses cursor pagination (certname > "<last>") + jittered sleep so it
# stays gentle on the server.

require 'json'
require 'logger'
require 'net/http'
require 'openssl'
require 'optparse'
require 'socket'
require 'stringio'
require 'uri'
require 'zlib'

def puppet_defaults
  require 'puppet'
  Puppet.initialize_settings([])
  {
    cert:   Puppet.settings[:hostcert],
    key:    Puppet.settings[:hostprivkey],
    cacert: Puppet.settings[:localcacert],
  }
rescue LoadError, StandardError
  host = Socket.gethostname
  {
    cert:   "/etc/puppetlabs/puppet/ssl/certs/#{host}.pem",
    key:    "/etc/puppetlabs/puppet/ssl/private_keys/#{host}.pem",
    cacert: '/etc/puppetlabs/puppet/ssl/certs/ca.pem',
  }
end

defaults = puppet_defaults

opts = {
  url:       'https://localhost:8081',
  cert:      defaults[:cert],
  key:       defaults[:key],
  cacert:    defaults[:cacert],
  page_size: 500,
  sleep:     0.25,
  jitter:    0.25,
  output:    '-',
  timeout:   120,
  attempts:  3,
  verbose:   false,
}

OptionParser.new do |o|
  o.banner = "Usage: #{$PROGRAM_NAME} [options] > factsets.ndjson"
  o.on('--url URL',        "PuppetDB base URL (default #{opts[:url]})")       { |v| opts[:url] = v }
  o.on('--cert PATH',      "Client cert (default #{opts[:cert]})")            { |v| opts[:cert] = v }
  o.on('--key PATH',       "Client key (default #{opts[:key]})")              { |v| opts[:key] = v }
  o.on('--cacert PATH',    "CA bundle (default #{opts[:cacert]})")            { |v| opts[:cacert] = v }
  o.on('--page-size N',  Integer, "Nodes per page (default #{opts[:page_size]})")  { |v| opts[:page_size] = v }
  o.on('--sleep SECS',   Float,   "Base sleep between pages (default #{opts[:sleep]})")     { |v| opts[:sleep] = v }
  o.on('--jitter SECS',  Float,   "Extra random sleep, 0..jitter (default #{opts[:jitter]})") { |v| opts[:jitter] = v }
  o.on('--output PATH',           "NDJSON output; '-' for stdout (default '-')")            { |v| opts[:output] = v }
  o.on('--timeout SECS', Integer, "HTTP read timeout (default #{opts[:timeout]})")           { |v| opts[:timeout] = v }
  o.on('--attempts N',   Integer, "Retry attempts per page (default #{opts[:attempts]})")    { |v| opts[:attempts] = v }
  o.on('-v', '--verbose',         'Log per-page progress to stderr')                         { opts[:verbose] = true }
  o.on('-h', '--help')            { puts o; exit 0 }
end.parse!

log = Logger.new($stderr)
log.level = opts[:verbose] ? Logger::DEBUG : Logger::INFO
log.formatter = ->(sev, t, _p, msg) { "#{t.iso8601} #{sev} #{msg}\n" }

uri  = URI("#{opts[:url].chomp('/')}/pdb/query/v4")
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl            = uri.scheme == 'https'
http.verify_mode        = OpenSSL::SSL::VERIFY_PEER
http.cert               = OpenSSL::X509::Certificate.new(File.read(opts[:cert]))
http.key                = OpenSSL::PKey::RSA.new(File.read(opts[:key]))
http.ca_file            = opts[:cacert]
http.read_timeout       = opts[:timeout]
http.keep_alive_timeout = 30

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

out = opts[:output] == '-' ? $stdout : File.open(opts[:output], 'w')
out.sync = true

http.start do
  # Phase 1: enumerate certnames of active nodes
  # This allows use to list certnames once and batch-fetch by `certname in [...]`.
  certs_pql = 'nodes[certname] { deactivated is null and expired is null order by certname }'
  log.info('phase 1: listing active certnames')
  certs = query_page.call(certs_pql).map { |r| r.fetch('certname') }
  log.info("phase 1: #{certs.size} active nodes")

  # Phase 2: fetch factsets in batches.
  total = 0
  pages = (certs.size.to_f / opts[:page_size]).ceil
  certs.each_slice(opts[:page_size]).with_index(1) do |batch, page|
    quoted = batch.map { |c| JSON.dump(c) }.join(', ')
    # `in` is index-friendly on PDB
    #  and performant compared to order by + limit
    pql = "inventory[certname, environment, trusted, facts] { certname in [#{quoted}] }"

    rows = query_page.call(pql)
    rows.each { |row| out.puts(JSON.dump(row)) }
    total += rows.size
    log.info("page #{page}/#{pages}: fetched #{rows.size} (total #{total})")

    sleep(opts[:sleep] + rand * opts[:jitter]) unless page == pages
  end

  log.info("done: #{total} factsets written")
end

out.close unless out.equal?($stdout)
