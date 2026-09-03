#!/bin/bash
#SPEC_OPTS=--format=documentation \
  USE_AIO_VENDOR_MODULES=yes \
  SHOW_PUPPET_OUTPUT=yes \
  DEBUG=yes \
  bundle exec onceover run spec --trace --skip_r10k


####SPEC_OPTS=--format=documentation \
###  USE_AIO_VENDOR_MODULES=yes \
###  SHOW_PUPPET_OUTPUT=yes \
###  DEBUG=yes \
###  GEM_HOME=~/.local/share/gem/ruby/3.2.0/ \
###  /opt/puppetlabs/puppet/bin/bundle exec \
###    onceover run spec --trace --skip_r10k
