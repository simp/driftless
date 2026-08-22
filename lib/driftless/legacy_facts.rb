module Driftless
  module LegacyFacts
    # Mapping from legacy Facter facts to modern structured facts paths
    #
    # Derived from https://www.puppet.com/docs/puppet/latest/core_facts.html
    # and historical core factsets from FacterDB
    #
    # - Absent on purpose, because no direct equivalent could be found:
    #   - blockdevices (string)      vs disks (map)
    #   - dhcp_servers (per-IF hash) vs networking.dhcp (default interface only)
    #   - zones (count)              vs solaris_zones.zones (map)
    #   - sshfp_<algo> (SSHFP lines) vs ssh.<algo>.fingerprints (map)
    #   - uniqueid, ps, gem_version:  no modern counterpart
    # - Also absent: custom facts, and dynamic per-instance facts
    #   (ipaddress_<interface>, blockdevice_<devicename>_model), which can't be
    #   determined statically.
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
      'lsbrelease'                => 'os.distro.specification',
      # macOS
      'macosx_buildversion'        => 'os.macosx.build',
      'macosx_productname'         => 'os.macosx.product',
      'macosx_productversion'      => 'os.macosx.version.full',
      'macosx_productversion_major' => 'os.macosx.version.major',
      'macosx_productversion_minor' => 'os.macosx.version.minor',
      'macosx_productversion_patch' => 'os.macosx.version.patch',
      # Windows
      'windows_edition_id'        => 'os.windows.edition_id',
      'windows_installation_type' => 'os.windows.installation_type',
      'windows_product_name'      => 'os.windows.product_name',
      'windows_release_id'        => 'os.windows.release_id',
      'system32'                  => 'os.windows.system32',
      # SELinux
      'selinux'                   => 'os.selinux.enabled',
      'selinux_config_mode'       => 'os.selinux.config_mode',
      'selinux_config_policy'     => 'os.selinux.config_policy',
      'selinux_current_mode'      => 'os.selinux.current_mode',
      'selinux_enforced'          => 'os.selinux.enforced',
      'selinux_policyversion'     => 'os.selinux.policy_version',
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
      'scope6'                    => 'networking.scope6',
      # Processors
      'processorcount'            => 'processors.count',
      'physicalprocessorcount'    => 'processors.physicalcount',
      'hardwareisa'               => 'processors.isa',
      # Memory
      'memorysize'                => 'memory.system.total',
      'memorytotal'               => 'memory.system.total',
      'memoryfree'                => 'memory.system.available',
      'swapsize'                  => 'memory.swap.total',
      'swapfree'                  => 'memory.swap.available',
      'memorysize_mb'             => 'memory.system.total_bytes',
      'memoryfree_mb'             => 'memory.system.available_bytes',
      'swapsize_mb'               => 'memory.swap.total_bytes',
      'swapfree_mb'               => 'memory.swap.available_bytes',
      'swapencrypted'             => 'memory.swap.encrypted',
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
      'type'                      => 'dmi.chassis.type',
      'boardassettag'             => 'dmi.board.asset_tag',
      'chassisassettag'           => 'dmi.chassis.asset_tag',
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
      # Name unchanged
      'facterversion'             => 'facterversion',
      'filesystems'               => 'filesystems',
      'is_virtual'                => 'is_virtual',
      'kernel'                    => 'kernel',
      'kernelmajversion'          => 'kernelmajversion',
      'kernelrelease'             => 'kernelrelease',
      'kernelversion'             => 'kernelversion',
      'path'                      => 'path',
      'timezone'                  => 'timezone',
      'virtual'                   => 'virtual',
      # Solaris zones / Xen / Augeas
      'zonename'                  => 'solaris_zones.current',
      'xendomains'                => 'xen.domains',
      'augeasversion'             => 'augeas.version',
    }.freeze

    # Whether `name` is a legacy fact. Takes a bare name: callers strip any
    # scope prefix first, and decide which prefixes are worth inspecting.
    def self.match(name)
      MAP.key?(name) ? name : nil
    end
  end
end
