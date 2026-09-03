#!/bin/bash

factset="$1"
certname=$(jq -r '.clientcert // .networking.fqdn // empty' "$factset")
jq --arg cn "$certname" '
  . as $f
  | ($f.networking.fqdn // $cn) as $fqdn
  | .hostname   //= ($f.networking.hostname // ($fqdn | split(".") | .[0]))
  | .domain     //= ($f.networking.domain   // ($fqdn | split(".") | .[1:] | join(".")))
  | .fqdn       //= $fqdn
  | .clientcert //= $cn
' "$factset"
