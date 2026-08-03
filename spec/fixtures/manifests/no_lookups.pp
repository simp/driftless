class role::web {
  include profile::web
  notify { 'boot':
    message => 'starting web',
  }
}
