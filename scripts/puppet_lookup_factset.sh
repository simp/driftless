#!/bin/bash
# Run `puppet lookup` against this control repo's hiera hierarchy, using a
# factset from spec/factsets/ to populate node facts.
#
# Requires: puppet on $PATH (or $PUPPET_BIN), jq.
# If a stray user gem shadows the packaged puppet, scrub GEM_PATH first, e.g.
#   GEM_PATH=$(gem env path | sed -e "s@:\?$(gem env user_gemhome):\?@@g") \
#     ./scripts/hiera_lookup.sh ...

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: hiera_lookup.sh [OPTIONS] FACTSET KEY [-- PUPPET_LOOKUP_ARGS...]

  FACTSET  path to a JSON factset, or a bare name matched uniquely
           against spec/factsets/<name>*.json
  KEY      hiera key to look up (e.g. simp_options::syslog::log_servers)

OPTIONS:
  --[no-]compile          Full catalog compile before lookup (default: on).
                          Required for hiera tiers that reference top-scope
                          vars from manifests/site.pp (compliance_profile,
                          simp_scenario, hostgroup). --no-compile is much
                          faster but silently skips those tiers.
  -e, --environment ENV   Environment name to symlink the repo as
                          (default: production)
  -f, --fake-envdir PATH  Path to model "fake" envdir instead of tmpdir
  -l, --list              List factsets under spec/factsets/ and exit
  -h, --help              Show this help

Anything after `--` is forwarded verbatim to `puppet lookup`. Common
passthrough args: --explain, --merge unique|deep|hash, --type '<type>',
--default <value>, --render-as yaml|json|s.

Examples:
  hiera_lookup.sh coder-christ2 classes
  hiera_lookup.sh coder-christ2 simp_options::syslog::log_servers -- --explain
  hiera_lookup.sh --no-compile ovtest-07 classes -- --merge unique
EOF
}

compile=1
environment=production
fake_envdir=
own=()
passthrough=()
seen_dashdash=0
for a in "$@"; do
  if (( seen_dashdash )); then
    passthrough+=("$a")
  elif [[ $a == -- ]]; then
    seen_dashdash=1
  else
    own+=("$a")
  fi
done
set -- "${own[@]:-}"

positional=()
while (( $# )); do
  case ${1:-} in
    --compile)         compile=1; shift ;;
    --no-compile)      compile=0; shift ;;
    -e|--environment)  environment=$2; shift 2 ;;
    --environment=*)   environment=${1#*=}; shift ;;
    -D|--fake-envdir)  fake_envdir=$2; shift 2 ;;
    --fake-envdir=*)   fake_envdir=${1#*=}; shift ;;
    -l|--list)
                       shopt -s nullglob
                       fs=(spec/factsets/*.json)
                       shopt -u nullglob
                       (( ${#fs[@]} )) || { echo "no factsets found under spec/factsets/" >&2; exit 1; }
                       printf '%s\n' "${fs[@]}"; exit 0 ;;
    -h|--help)         usage; exit 0 ;;
    --)                shift; passthrough+=("$@"); break ;;
    -*)                echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)                 positional+=("$1"); shift ;;
  esac
done

(( ${#positional[@]} == 2 )) || { usage >&2; exit 2; }
factset_arg=${positional[0]}
key=${positional[1]}

command -v jq       >/dev/null || { echo "jq not found on \$PATH" >&2; exit 127; }
PUPPET_BIN=${PUPPET_BIN:-puppet}
command -v "$PUPPET_BIN" >/dev/null || { echo "$PUPPET_BIN not found on \$PATH (set \$PUPPET_BIN)" >&2; exit 127; }
[[ -f hiera.yaml ]] || { echo "no hiera.yaml in $PWD (run from control repo root)" >&2; exit 1; }

# Resolve factset: literal path, else unique glob under spec/factsets/
if [[ -f $factset_arg ]]; then
  factset=$factset_arg
else
  shopt -s nullglob
  matches=(spec/factsets/${factset_arg}*.json)
  shopt -u nullglob
  case ${#matches[@]} in
    0) echo "no factset matches '$factset_arg' under spec/factsets/" >&2; exit 1 ;;
    1) factset=${matches[0]} ;;
    *) { echo "factset '$factset_arg' is ambiguous:"; printf '  %s\n' "${matches[@]}"; } >&2; exit 1 ;;
  esac
fi

# Derive certname: prefer the filename basename, but onceover-style compound
# labels (containing '--') aren't real certnames — fall back to clientcert or
# networking.fqdn inside the factset.
base=$(basename "$factset" .json)
if [[ $base == *--* ]]; then
  certname=$(jq -r '.clientcert // .networking.fqdn // empty' "$factset")
  certname=${certname:-$base}
else
  certname=$base
fi

tmp=$(mktemp -d -t cr-puppet-XXXXXX)
trap 'rm -rf "$tmp"' EXIT INT TERM


# Ephemeral env-path: puppet needs an environments/<env>/ layout.
environmentspath="$tmp/environments"
#[[ -n "$fake_envdir" ]] && environmentspath="$(realpath "$fake_envdir")"
[[ -n "$fake_envdir" ]] && environmentspath="$fake_envdir"
environment_dir="$environmentspath/$environment"

mkdir -p "$environmentspath"
test -L "$environment_dir" && rm -f "$environment_dir"
ln -s "$PWD" "$environment_dir"

# `puppet lookup --facts` refuses unless hostname/domain/fqdn/clientcert are
# all present at top level. Factsets from `puppet facts` only carry clientcert
# plus networking.* — synthesize the missing top-level identity facts.
# Ruby equivalent (if jq isn't available):
#   ruby -rjson -e 'f=JSON.parse(STDIN.read);cn=ARGV[0];fq=f.dig("networking","fqdn")||cn;
#     f["hostname"]  ||= f.dig("networking","hostname")||fq.split(".").first;
#     f["domain"]    ||= f.dig("networking","domain")  ||fq.split(".",2).last;
#     f["fqdn"]      ||= fq; f["clientcert"]||=cn; puts JSON.generate(f)' "$certname" < "$factset"
jq --arg cn "$certname" '
  . as $f
  | ($f.networking.fqdn // $cn) as $fqdn
  | .hostname   //= ($f.networking.hostname // ($fqdn | split(".") | .[0]))
  | .domain     //= ($f.networking.domain   // ($fqdn | split(".") | .[1:] | join(".")))
  | .fqdn       //= $fqdn
  | .clientcert //= $cn
' "$factset" > "$tmp/facts.json"

cmd=(
  "$PUPPET_BIN" lookup
  --environmentpath "$environmentspath"
  --environment     "$environment"
  --node            "$certname"
  --facts           "$tmp/facts.json"
)
(( compile )) && cmd+=(--compile)
cmd+=("${passthrough[@]}" "$key")

echo "+ ${cmd[*]}" >&2
"${cmd[@]}"
