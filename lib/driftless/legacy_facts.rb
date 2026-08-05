module Driftless
  module LegacyFacts
    # Map of legacy (flat) Facter fact names to their modern (structured)
    # dotted-path equivalents. Curated from the well-known Facter 3→4 renames.
    # Facts still valid in modern Facter (kernel, puppetversion, virtual, etc.)
    # are intentionally omitted.
    #
    # Source: https://www.puppet.com/docs/puppet/latest/core_facts.html
    #
    # Coverage note: this is a high-confidence subset, not exhaustive. Dynamic
    # per-interface facts (ipaddress_eth0, macaddress_eth0, mtu_eth0) are
    # excluded because they can't be enumerated statically.
    MAP = {
      # OS family
      'osfamily'                  => 'os.family',
      'operatingsystem'           => 'os.name',
      'operatingsystemrelease'    => 'os.release.full',
      'operatingsystemmajrelease' => 'os.release.major',
      'architecture'              => 'os.architecture',
      'hardwaremodel'             => 'os.hardware',
      'lsbdistid'                 => 'os.distro.id',
      'lsbdistcodename'           => 'os.distro.codename',
      'lsbdistdescription'        => 'os.distro.description',
      'lsbdistrelease'            => 'os.distro.release.full',
      'lsbmajdistrelease'         => 'os.distro.release.major',
      'lsbminordistrelease'       => 'os.distro.release.minor',
      # Networking
      'fqdn'                      => 'networking.fqdn',
      'hostname'                  => 'networking.hostname',
      'domain'                    => 'networking.domain',
      'ipaddress'                 => 'networking.ip',
      'ipaddress6'                => 'networking.ip6',
      'macaddress'                => 'networking.mac',
      'netmask'                   => 'networking.netmask',
      'netmask6'                  => 'networking.netmask6',
      'network'                   => 'networking.network',
      'network6'                  => 'networking.network6',
      'interfaces'                => 'networking.interfaces',
      # Processors
      'processorcount'            => 'processors.count',
      'physicalprocessorcount'    => 'processors.physicalcount',
      # Memory
      'memorysize'                => 'memory.system.total',
      'memoryfree'                => 'memory.system.available',
      'swapsize'                  => 'memory.swap.total',
      'swapfree'                  => 'memory.swap.available',
      # Uptime
      'uptime'                    => 'system_uptime.uptime',
      'uptime_days'               => 'system_uptime.days',
      'uptime_hours'              => 'system_uptime.hours',
      'uptime_seconds'            => 'system_uptime.seconds',
      # Ruby
      'rubyversion'               => 'ruby.version',
      'rubyplatform'              => 'ruby.platform',
      'rubysitedir'               => 'ruby.sitedir',
      # DMI / hardware
      'bios_release_date'         => 'dmi.bios.release_date',
      'bios_vendor'               => 'dmi.bios.vendor',
      'bios_version'              => 'dmi.bios.version',
      'boardmanufacturer'         => 'dmi.board.manufacturer',
      'boardproductname'          => 'dmi.board.product',
      'boardserialnumber'         => 'dmi.board.serial_number',
      'chassistype'               => 'dmi.chassis.type',
      'manufacturer'              => 'dmi.manufacturer',
      'productname'               => 'dmi.product.name',
      'serialnumber'              => 'dmi.product.serial_number',
      'uuid'                      => 'dmi.product.uuid',
      # SSH host keys
      'sshdsakey'                 => 'ssh.dsa.key',
      'sshecdsakey'               => 'ssh.ecdsa.key',
      'sshed25519key'             => 'ssh.ed25519.key',
      'sshrsakey'                 => 'ssh.rsa.key',
      # Identity
      'id'                        => 'identity.user',
      'gid'                       => 'identity.group',
    }.freeze

    # Given a bare or facts.-prefixed interpolation variable name, returns
    # the legacy name if it's a legacy fact, otherwise nil. Handles both
    # `%{osfamily}` and `%{facts.osfamily}` forms.
    def self.match(interpolation_var)
      candidate = interpolation_var.sub(/\Afacts\./, '')
      MAP.key?(candidate) ? candidate : nil
    end
  end
end
