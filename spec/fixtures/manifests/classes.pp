class profile::example (
  String  $vhost         = 'localhost',
  Boolean $ssl           = false,
          $untyped_param = undef,
) {
  notify { "vhost=${vhost}": }
}

class role::web {
  include profile::example
}

class basename::role::nested { }

class util::helpers { }

define profile::vhost (
  String $servername,
) {
  notify { $title: }
}
