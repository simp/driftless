# Loads Puppet/OpenVox, which driftless treats as provided by the host rather
# than as a gem dependency (see driftless.gemspec for why).
begin
  require 'puppet'
rescue LoadError => e
  raise LoadError, <<~MSG
    driftless needs Puppet/OpenVox but could not load it (#{e.message}).
    Either run it with the openvox-agent Ruby (/opt/puppetlabs/puppet/bin/ruby),
    or install the `openvox` gem into the Ruby you are using.
  MSG
end
