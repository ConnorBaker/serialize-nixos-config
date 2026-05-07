#!/usr/bin/env bash
# Diff two serialized NixOS configs.
#
# Each positional argument is a Nix installable that `nix eval`
# accepts — a flake URI like `.#foo` or `github:owner/repo#foo`, a
# `path:/dir#attr` reference, or, with `-f FILE`, an attr name inside
# a plain .nix file. Both sides should evaluate to a `serialize`
# output (i.e. the JSON-safe mirror produced by `serialize.nix`).
#
# Formats:
#   --format dyff     (default) per-change stanzas via `dyff between`
#   --format markdown one-row-per-change markdown table
#
# Module-system alias triplication (`jobs.*`, `boot.systemd.*`,
# renamed options like `services.sshd.enable`, etc.) is already
# pruned in the Nix `serialize` function via `collectAliasPaths`, so
# no filtering flags are required here.
#
# Env (set by package.nix when invoked as `nix run`):
#   PATCH_TO_MARKDOWN_JQ   path to patch-to-markdown.jq in the store
#
# Usage:
#   # Two flake installables (works across repos, via any URI nix
#   # eval accepts):
#   nix run .# -- .#myConfigs.foo .#myConfigs.bar
#   nix run .# -- github:owner/repo#foo github:owner/repo#bar
#
#   # Two attrs in a shared .nix file (example structure:
#   #   { foo = serialize { ... }; bar = serialize { ... }; })
#   nix run .# -- -f ./configs.nix foo bar
#   nix run .# -- -f ./configs.nix foo bar --format markdown
#
#   # Extra positional args pass through to the chosen diff tool:
#   nix run .# -- .#foo .#bar -o brief

set -euo pipefail

: "${PATCH_TO_MARKDOWN_JQ:?must be set (normally wired by package.nix)}"

usage() {
  echo "usage: diff-configs [--format=dyff|markdown] [-f FILE] <installable-a> <installable-b> [extra args...]" >&2
  exit 2
}

die() {
  echo "diff-configs: $1" >&2
  exit 2
}

# Pull the value for a --flag that takes an argument. Rejects missing
# values and values that look like the next flag, so `--format .#foo`
# doesn't silently consume `.#foo` and leave the user short a
# positional.
take_value() {
  local flag=$1 next=${2-}
  if [[ -z $next || $next == -* ]]; then
    die "flag $flag requires a value"
  fi
  printf '%s\n' "$next"
}

format=dyff
file=
positional=()

while [[ $# -gt 0 ]]; do
  case $1 in
  --format)
    format=$(take_value "$1" "${2-}")
    shift 2
    ;;
  --format=*)
    format=${1#--format=}
    shift
    ;;
  -f | --file)
    file=$(take_value "$1" "${2-}")
    shift 2
    ;;
  --file=*)
    file=${1#--file=}
    shift
    ;;
  --)
    shift
    positional+=("$@")
    break
    ;;
  -*)
    # Unknown dash-prefixed args *before* any positional are most
    # likely typos (e.g. `--foramt=dyff`). Once we've started
    # collecting installables, fall through so extra args like
    # `-o brief` can be forwarded to the downstream diff tool.
    if ((${#positional[@]} == 0)); then
      die "unknown flag: $1"
    fi
    positional+=("$1")
    shift
    ;;
  *)
    positional+=("$1")
    shift
    ;;
  esac
done

set -- "${positional[@]}"

case $format in
dyff | markdown) ;;
*) die "unknown --format: $format (expected dyff or markdown)" ;;
esac

if [[ $# -lt 2 ]]; then
  usage
fi

a=$1
b=$2
shift 2

if [[ -z $a || -z $b ]]; then
  die "installable arguments must be non-empty"
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

eval_to_json() {
  local target=$1 out=$2
  # --eval-cores 1 and --no-lazy-trees aren't for safety; they're for
  # *consistent output*. With parallel/lazy evaluation, some internal
  # subtrees (notably meta.buildDocsInSandbox) get forced that otherwise
  # wouldn't, adding thousands of spurious `_file` store-path-difference
  # rows to the diff. We trade ~2x wallclock for a much cleaner diff.
  if [[ -n $file ]]; then
    nix eval -f "$file" "$target" \
      --eval-cores 1 \
      --no-lazy-trees \
      --json \
      >"$out"
  else
    nix eval "$target" \
      --eval-cores 1 \
      --no-lazy-trees \
      --json \
      >"$out"
  fi
}

eval_to_json "$a" "$tmpdir/left.json"
eval_to_json "$b" "$tmpdir/right.json"

case $format in
dyff)
  dyff between \
    --use-go-patch-style \
    "$@" \
    "$tmpdir/left.json" \
    "$tmpdir/right.json"
  ;;
markdown)
  # jd emits RFC 6902 patch ops; patch-to-markdown.jq classifies them
  # and renders a markdown row per path. jd exits 1 when there are
  # differences — that's expected, so we tolerate it.
  jd -f patch \
    "$tmpdir/left.json" \
    "$tmpdir/right.json" \
    >"$tmpdir/patch.json" || true

  jq \
    --arg left "$a" \
    --arg right "$b" \
    --raw-output \
    --from-file "$PATCH_TO_MARKDOWN_JQ" \
    "$tmpdir/patch.json"
  ;;
esac
