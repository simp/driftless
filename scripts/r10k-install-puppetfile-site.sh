#!/bin/bash

rc=0
gem env user_gemhome >& /dev/null || rc="$?"
if [[ $rc -eq 0 ]]; then
  export GEM_PATH=$(echo "$(gem env path 2>/dev/null)" | sed -e "s@:\?$(gem env user_gemhome 2>/dev/null):\?@@g")
fi

SIMP_PUPPETFILE=Puppetfile.simp.site.20260818 \
  DEPLOY_SITE="${DEPLOY_SITE:-none}" \
  USE_AIO_VENDOR_MODULES=yes \
  SHOW_PUPPET_OUTPUT=yes \
  DEBUG=yes \
  /opt/puppetlabs/puppet/bin/bundle exec \
  rake r10k:install



###SIMP_PUPPETFILE=Puppetfile.simp.site \
###  USE_AIO_VENDOR_MODULES=yes \
###  SHOW_PUPPET_OUTPUT=yes \
###  DEBUG=yes \
###  GEM_HOME=~/.local/share/gem/ruby/3.2.0/ \
###  /opt/puppetlabs/puppet/bin/bundle exec \
###  rake r10k:install
