#!/bin/bash
curl -X DELETE \
  --cert "$(puppet config print hostcert)" \
  --key "$(puppet config print hostprivkey)" \
  --cacert "$(puppet config print localcacert)" \
  "https://$(puppet config print server):$(puppet config print serverport)/puppet-admin-api/v1/environment-cache"
