#!/bin/bash

set -euo pipefail
. ~/.bashrc
. ~/.bash_aliases
. ~/.bash_functions
pbinpaths_setup
#sanitize_gem_path__remove_gem_home
ssh_agent_idempotent
#ssh-add -l || ssh-add

mapfile -t lines < <(env | grep -E '^RUBY|GEM|SSH|PATH|DRIFTLESS|BUNDLE')
for line in "${lines[@]}"; do
  name=${line%%=*}
  value=${line#*=}
  echo "== env var: $name"
  tmux_env_args+=(-e "$name=$value")
done

tmux new-session "${tmux_env_args[@]}"

