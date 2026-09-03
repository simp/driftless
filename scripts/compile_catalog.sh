#!/bin/bash
# Compile a catalog for a node using this control repo's code, data, and a
# factset from spec/factsets/. Prints the catalog to stdout (or to --output).
#
# Requires: puppet on $PATH (or $PUPPET_BIN), jq.
# If a stray user gem shadows the packaged puppet, scrub GEM_PATH first, e.g.
#   GEM_PATH=$(gem env path | sed -e "s@:\?$(gem env user_gemhome):\?@@g") \
#     ./scripts/compile_catalog.sh ...

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: compile_catalog.sh [OPTIONS] FACTSET [-- PUPPET_CATALOG_ARGS...]

  FACTSET  path to a JSON factset, or a bare name matched uniquely
           against spec/factsets/<name>*.json

Compiles the catalog for the certname derived from FACTSET, then prints
it. Anything after `--` is forwarded verbatim to `puppet catalog compile`.

OPTIONS:
  -e, --environment ENV  Environment name to symlink the repo as
                         (default: production)
  -r, --render-as FMT    Output format: json|yaml|pson|msgpack|s
                         (default: json)
  -o, --output PATH      Write catalog to PATH instead of stdout
      --verbose          Puppet --verbose (compile diagnostics on stderr)
      --debug            Puppet --debug (very noisy; use with 2>logfile)
  -l, --list             List factsets under spec/factsets/ and exit
  -h, --help             Show this help

Examples:
  compile_catalog.sh coder-christ2 > catalog.json
  compile_catalog.sh --render-as yaml coder-christ2 -o /tmp/cat.yaml
  compile_catalog.sh --debug coder-christ2 2> compile.log
EOF
}

environment=production
render_as=json
output=
verbose=0
debug=0
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
    -e|--environment)  environment=$2; shift 2 ;;
    --environment=*)   environment=${1#*=}; shift ;;
    -r|--render-as)    render_as=$2; shift 2 ;;
    --render-as=*)     render_as=${1#*=}; shift ;;
    -o|--output)       output=$2; shift 2 ;;
    --output=*)        output=${1#*=}; shift ;;
    --verbose)         verbose=1; shift ;;
    --debug)           debug=1; shift ;;
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

(( ${#positional[@]} == 1 )) || { usage >&2; exit 2; }
factset_arg=${positional[0]}

case $render_as in
  json|yaml|pson|msgpack|s) ;;
  *) echo "invalid --render-as '$render_as' (want json|yaml|pson|msgpack|s)" >&2; exit 2 ;;
esac

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

# Ephemeral env-path: puppet needs an environments/<env>/ layout.
tmp=$(mktemp -d -t cr-puppet-XXXXXX)
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/environments" "$tmp/facts.d"
ln -s "$PWD" "$tmp/environments/$environment"

# `puppet catalog compile --facts FILE` sets top-scope $facts for the manifest
# but does NOT push those facts into the hiera interpolation scope — hiera then
# uses the local machine's facter, so `%{facts.os.name}` resolves to the compile
# host's OS instead of the target's, and env/module data lookups miss.
#
# Workaround: drop the factset into a facts.d/ dir and point puppet at it via
# --pluginfactdest. Puppet's facter facts terminus appends pluginfactdest to
# facter's external-facts search path (indirector/facts/facter.rb:96-100), and
# external facts win over facter's built-in resolvers — so `os`, `networking`
# etc. get replaced wholesale by the factset before hiera scope is built.
#
# The identity fixup (hostname/domain/fqdn/clientcert) is still needed because
# factsets from `puppet facts` only carry clientcert + networking.*, and some
# manifests reference the top-level legacy facts.
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
' "$factset" > "$tmp/facts.d/target.json"

cmd=(
  "$PUPPET_BIN" catalog compile "$certname"
  --environmentpath  "$tmp/environments"
  --environment      "$environment"
  --pluginfactdest   "$tmp/facts.d"
  --render-as        "$render_as"
)
(( verbose )) && cmd+=(--verbose)
(( debug ))   && cmd+=(--debug)
cmd+=("${passthrough[@]}")

echo "+ ${cmd[*]}${output:+ > $output}" >&2
if [[ -n $output ]]; then
  "${cmd[@]}" > "$output"
else
  "${cmd[@]}"
fi
