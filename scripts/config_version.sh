#!/bin/bash
# A robust script to help set the control repo's 'config_version'
# 
# 
environmentpath="$1"
environment="$2"
env_dir="$environmentpath/$environment"

print_help_and_exit() {
  echo "$0: return a useful 'configuration_version' for Puppet catalogs"
  printf "\nUsage:\n\t%s ENVIRONMENTPATH ENVIRONMENT\n" "$0"
  exit 1
}

[[ $# != 2 ]] && print_help_and_exit

if [ ! -d "$env_dir" ]; then
  echo "ERROR: directory does not exist: '$env_dir'"
  print_help_and_exit
fi

hash git ruby 2>/dev/null
git_cmd="${BASH_CMDS[git]}"
ruby_cmd="${BASH_CMDS[ruby]}"

# prefer Puppet AIO ruby to whatever's in the path
for i in /opt/puppetlabs/puppet/bin/ruby /opt/puppetlabs/*/bin/ruby; do
  [ -x "$i" ] && { ruby_cmd="$i"; break; }
done

compiler="${HOSTNAME%%.*}"
[ -z "$compiler" ] && command -v hostname && { compiler="$(hostname -f)";  compiler="${HOSTNAME%%.*}" ; }
[ -z "$compiler" ] && compiler=compiled_from

r10k_deploy_json_file="$env_dir/.r10-deploy.json"
if [ -e /opt/puppetlabs/server/pe_version ]; then
  git_ref="$("$ruby_cmd" -r rugged -e "puts  Rugged::Repository.discover('$env_dir')).head.target_id[0..6]")"
elif [ -e "$r10k_deploy_json_file" ]; then
  git_ref="$("$ruby_cmd" -r json -e "puts JSON.parse(File.read('$r10k_deploy_json_file'))['signature'][0..6]")"
elif [ -n "$git_cmd" ] && "$git_cmd" --version > /dev/null 2>&1 ; then
  git_ref="$("$git_cmd" -C "$env_dir" rev-parse --short HEAD 2>/dev/null)"|| git_ref="$(date +%s)"
else
  git_ref="$(date +%s)"
fi

echo "${compiler}--${environment}--${git_ref}"
