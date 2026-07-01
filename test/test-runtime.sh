#!/usr/bin/env bash
# Unit test for runtime_node() / runtime_python() — the per-directory runtime
# detection behind the optional `node` and `python` segments. Extracts the live
# functions from statusline.sh so this test can never drift from the code it checks.
#
#   bash test/test-runtime.sh
#
# Exits non-zero if any case fails. Needs only bash (no jq, no git). The binary
# probe ($VL_RUNTIME_PROBE) is forced off so results never depend on whatever
# node/python happens to be installed on the test host.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"

# Pull just the detection functions out of the real script and define them here.
# Relies on each function's body having its closing brace as the only `}` at
# column 0 (the range ends at the first /^}/ line) — keep nested blocks indented.
eval "$(sed -n '/^runtime_node() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^runtime_python() {/,/^}/p' "$SCRIPT")"

# The helpers assign the label to the global $_RT (fork-free); wrap for readable
# asserts. Env prefixes (VIRTUAL_ENV=…) on a call flow through to the helper.
node_v()   { runtime_node "$1";   printf '%s' "$_RT"; }
python_v() { runtime_python "$1"; printf '%s' "$_RT"; }

export VL_RUNTIME_PROBE=0   # never shell out to a real interpreter in tests

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
check() {  # $1=expected  $2=label  $3=actual
  if [ "$3" = "$1" ]; then
    printf 'ok    %-28s -> %q\n' "$2" "$3"
  else
    printf 'FAIL  %-28s want=%q got=%q\n' "$2" "$1" "$3"; fail=1
  fi
}

# ── Node ─────────────────────────────────────────────────────────────────────
mkdir -p "$TMP/node-nvmrc"; printf '20.11.0\n' > "$TMP/node-nvmrc/.nvmrc"
check "20.11.0" node-nvmrc "$(node_v "$TMP/node-nvmrc")"

# a leading `v` is normalized away so node matches python's bare-version form
mkdir -p "$TMP/node-ver"; printf 'v18.20.0\n' > "$TMP/node-ver/.node-version"
check "18.20.0" node-node-version "$(node_v "$TMP/node-ver")"

# .nvmrc wins over .node-version in the same directory
mkdir -p "$TMP/node-both"
printf '20.11.0\n' > "$TMP/node-both/.nvmrc"
printf '18.0.0\n'  > "$TMP/node-both/.node-version"
check "20.11.0" node-nvmrc-precedence "$(node_v "$TMP/node-both")"

# walk up to an ancestor pin
mkdir -p "$TMP/node-nvmrc/sub/deep"
check "20.11.0" node-ancestor-pin "$(node_v "$TMP/node-nvmrc/sub/deep")"

# surrounding whitespace is trimmed
mkdir -p "$TMP/node-ws"; printf '  v20.0.0  \n' > "$TMP/node-ws/.nvmrc"
check "20.0.0" node-trim-whitespace "$(node_v "$TMP/node-ws")"

# a directory named .nvmrc must not match (and must not emit stderr)
mkdir -p "$TMP/node-dir/.nvmrc"
check "" node-dir-not-a-file "$(node_v "$TMP/node-dir" 2>/dev/null)"

# no pin + probe off -> empty
mkdir -p "$TMP/node-none"
check "" node-none "$(node_v "$TMP/node-none")"

# ── Python ───────────────────────────────────────────────────────────────────
mkdir -p "$TMP/py-none"

check "myenv" py-virtualenv \
  "$(VIRTUAL_ENV="$TMP/envs/myenv" CONDA_DEFAULT_ENV= python_v "$TMP/py-none")"

check "ml" py-conda \
  "$(VIRTUAL_ENV= CONDA_DEFAULT_ENV=ml python_v "$TMP/py-none")"

# $VIRTUAL_ENV wins over conda
check "venv" py-virtualenv-precedence \
  "$(VIRTUAL_ENV=/x/y/venv CONDA_DEFAULT_ENV=ml python_v "$TMP/py-none")"

mkdir -p "$TMP/py-pin"; printf '3.11.4\n' > "$TMP/py-pin/.python-version"
check "3.11.4" py-pyenv-pin \
  "$(VIRTUAL_ENV= CONDA_DEFAULT_ENV= python_v "$TMP/py-pin")"

# pin found via ancestor walk
mkdir -p "$TMP/py-pin/sub"
check "3.11.4" py-ancestor-pin \
  "$(VIRTUAL_ENV= CONDA_DEFAULT_ENV= python_v "$TMP/py-pin/sub")"

# nothing active + probe off -> empty
check "" py-none \
  "$(VIRTUAL_ENV= CONDA_DEFAULT_ENV= python_v "$TMP/py-none")"

# conda `base` is auto-active for most conda users -> treated as "no env"
check "" py-conda-base-ignored \
  "$(VIRTUAL_ENV= CONDA_DEFAULT_ENV=base python_v "$TMP/py-none")"

# ── Regressions ──────────────────────────────────────────────────────────────
# Pin file with no trailing newline: `read` hits EOF and returns non-zero, but
# the value WAS read — a naive `|| v=""` would wrongly discard it.
mkdir -p "$TMP/node-nonl"; printf '21.0.0' > "$TMP/node-nonl/.nvmrc"   # no \n
check "21.0.0" node-no-trailing-newline "$(node_v "$TMP/node-nonl")"

mkdir -p "$TMP/py-nonl"; printf '3.10.0' > "$TMP/py-nonl/.python-version"  # no \n
check "3.10.0" py-no-trailing-newline \
  "$(VIRTUAL_ENV= CONDA_DEFAULT_ENV= python_v "$TMP/py-nonl")"

# A slash-less / relative dir argument must terminate, not spin forever on the
# ancestor walk (`${dir%/*}` is a no-op once there's no slash left). Pure-bash
# watchdog (no `timeout` dependency, so it runs on stock macOS too): background
# the call, and if it is still alive after the grace period, it hung.
( runtime_node relname >/dev/null 2>&1; runtime_python relname >/dev/null 2>&1 ) & wpid=$!
( sleep 5; kill -9 "$wpid" 2>/dev/null ) & kpid=$!
if wait "$wpid" 2>/dev/null; then
  kill "$kpid" 2>/dev/null; wait "$kpid" 2>/dev/null
  printf 'ok    %-28s -> %s\n' relative-dir-terminates "(no hang)"
else
  printf 'FAIL  %-28s hung on a relative dir arg\n' relative-dir-terminates; fail=1
fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
