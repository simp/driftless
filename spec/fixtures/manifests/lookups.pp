class profile::example {
  $simple     = lookup('simple::key')
  $with_dflt  = lookup('with::default', String, 'first', 'fallback')
  $legacy     = hiera('legacy::key')
  $dynamic    = lookup($some_var)
  $not_lookup = notice('hello')
}
