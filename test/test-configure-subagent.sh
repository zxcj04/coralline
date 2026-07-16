#!/usr/bin/env bash
# Unit test for configure.sh's subagent panel toggle: enable/disable write and
# remove .subagentStatusLine in settings.json (backup, other keys preserved,
# broken JSON leaves the original untouched), the shared settings_merge pipeline
# behind every settings.json write, the non-interactive --subagent-rows=on|off
# flag, and the wizard's preview render. Extracts the live functions from
# configure.sh so this test can never drift. Needs bash + jq.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
CONF="$HERE/../configure.sh"

eval "$(sed -n '/^settings_merge() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^subagent_enabled() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^update_settings() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^enable_subagent_statusline() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^disable_subagent_statusline() {/,/^}/p' "$CONF")"

die() { printf 'die: %s\n' "$*" >&2; exit 1; }

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/coralline-subcfg.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT
SETTINGS_FILE="$TMPD/settings.json"
TARGET_DIR="$HOME/.claude/coralline"

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }

# (1) enable with no settings file creates one
subagent_enabled && bad "starts disabled" || ok "starts disabled"
enable_subagent_statusline >/dev/null
jq -e '.subagentStatusLine.type == "command" and (.subagentStatusLine.command | endswith("--subagent"))' \
  "$SETTINGS_FILE" >/dev/null && ok "enable creates entry" || bad "enable creates entry"
subagent_enabled && ok "state reads enabled" || bad "state reads enabled"

# (1b) enabled means a usable command schema, including documented custom configs
MAIN_SETTINGS="$SETTINGS_FILE"
SETTINGS_FILE="$TMPD/schema.json"
printf '%s\n' '{"subagentStatusLine":{"type":"command","command":"CORALLINE_CONFIG=/tmp/sub.conf bash /tmp/statusline.sh --subagent"}}' > "$SETTINGS_FILE"
subagent_enabled && ok "custom subagent command is enabled" || bad "custom subagent command is enabled"
for invalid in \
  '{"subagentStatusLine":true}' \
  '{"subagentStatusLine":"yes"}' \
  '{"subagentStatusLine":{}}' \
  '{"subagentStatusLine":{"type":"prompt","command":"bash x --subagent"}}' \
  '{"subagentStatusLine":{"type":"command","command":true}}' \
  '{"subagentStatusLine":{"type":"command","command":"bash x"}}'
do
  printf '%s\n' "$invalid" > "$SETTINGS_FILE"
  subagent_enabled && bad "invalid subagent schema rejected: $invalid" || ok "invalid subagent schema rejected"
done
SETTINGS_FILE="$MAIN_SETTINGS"

# (2) enable/disable preserve unrelated keys and write a backup
jq '.statusLine = {"type":"command","command":"x"} | .other = 1' "$SETTINGS_FILE" > "$TMPD/t" && mv "$TMPD/t" "$SETTINGS_FILE"
disable_subagent_statusline >/dev/null
jq -e 'has("subagentStatusLine") | not' "$SETTINGS_FILE" >/dev/null && ok "disable removes entry" || bad "disable removes entry"
jq -e '.other == 1 and .statusLine.command == "x"' "$SETTINGS_FILE" >/dev/null && ok "other keys preserved" || bad "other keys preserved"
ls "$SETTINGS_FILE".bak.* >/dev/null 2>&1 && ok "backup written" || bad "backup written"
subagent_enabled && bad "state reads disabled" || ok "state reads disabled"

# (3) broken JSON → die, original untouched
printf '{broken' > "$SETTINGS_FILE"
( enable_subagent_statusline ) >/dev/null 2>&1 && bad "broken json dies" || ok "broken json dies"
[ "$(cat "$SETTINGS_FILE")" = "{broken" ] && ok "original untouched on failure" || bad "original untouched on failure"

# (3b) backup and replacement failures stop before callers can report success
CPD="$TMPD/cp-fail"; mkdir -p "$CPD"; CPFILE="$CPD/settings.json"
printf '{"original":1}\n' > "$CPFILE"
CPOUT=$(
  SETTINGS_FILE="$CPFILE"
  cp() { printf 'partial\n' > "$2"; return 1; }
  enable_subagent_statusline 2>&1
  )
CPRC=$?
[ "$CPRC" != 0 ] && ok "backup failure exits non-zero" || bad "backup failure exits non-zero"
[ "$(cat "$CPFILE")" = '{"original":1}' ] && ok "backup failure preserves original" || bad "backup failure preserves original"
case "$CPOUT" in (*"Updated "*) bad "backup failure printed success" ;; (*) ok "backup failure prints no success" ;; esac
set -- "$CPFILE".bak.*; [ ! -e "$1" ] && ok "partial backup removed" || bad "partial backup removed"
set -- "$CPD"/.coralline-settings.*; [ ! -e "$1" ] && ok "backup failure temp removed" || bad "backup failure temp removed"

MVD="$TMPD/mv-fail"; mkdir -p "$MVD"; MVFILE="$MVD/settings.json"
printf '{"original":1}\n' > "$MVFILE"
MVOUT=$(
  SETTINGS_FILE="$MVFILE"
  mv() { return 1; }
  enable_subagent_statusline 2>&1
  )
MVRC=$?
[ "$MVRC" != 0 ] && ok "replace failure exits non-zero" || bad "replace failure exits non-zero"
[ "$(cat "$MVFILE")" = '{"original":1}' ] && ok "replace failure preserves original" || bad "replace failure preserves original"
case "$MVOUT" in (*"Updated "*) bad "replace failure printed success" ;; (*) ok "replace failure prints no success" ;; esac
ls "$MVFILE".bak.* >/dev/null 2>&1 && ok "replace failure keeps backup" || bad "replace failure keeps backup"
set -- "$MVD"/.coralline-settings.*; [ ! -e "$1" ] && ok "replace failure temp removed" || bad "replace failure temp removed"

# (3c) two writes in one second preserve both pre-write states
COLLD="$TMPD/collision"; mkdir -p "$COLLD"; COLLFILE="$COLLD/settings.json"
printf '{"step":0}\n' > "$COLLFILE"
(
  SETTINGS_FILE="$COLLFILE"
  date() { printf '20260716123456\n'; }
  settings_merge '.step = 1'
  settings_merge '.step = 2'
) >/dev/null
jq -e '.step == 0' "$COLLFILE.bak.20260716123456" >/dev/null 2>&1 \
  && ok "first same-second backup preserved" || bad "first same-second backup preserved"
jq -e '.step == 1' "$COLLFILE.bak.20260716123456.1" >/dev/null 2>&1 \
  && ok "second same-second backup preserved" || bad "second same-second backup preserved"

# (4) one shared settings.json merge pipeline — update_settings and the subagent
# toggle must go through the same settings_merge helper, not three hand copies
type settings_merge >/dev/null 2>&1 && ok "shared settings_merge helper exists" || bad "shared settings_merge helper exists"
rm -f "$SETTINGS_FILE" "$SETTINGS_FILE".bak.*
update_settings >/dev/null
jq -e '.statusLine.type == "command" and .statusLine.refreshInterval == 1' \
  "$SETTINGS_FILE" >/dev/null && ok "update_settings creates statusLine" || bad "update_settings creates statusLine"
enable_subagent_statusline >/dev/null
jq -e '.statusLine.refreshInterval == 1 and .subagentStatusLine.type == "command"' \
  "$SETTINGS_FILE" >/dev/null && ok "both keys coexist via shared helper" || bad "both keys coexist via shared helper"

# (4b) the non-interactive flag drives the same toggle (AI-install path)
rm -f "$SETTINGS_FILE" "$SETTINGS_FILE".bak.*
CLAUDE_SETTINGS="$SETTINGS_FILE" bash "$CONF" --subagent-rows=on >/dev/null 2>&1
jq -e '.subagentStatusLine.command | endswith("--subagent")' "$SETTINGS_FILE" >/dev/null 2>&1 \
  && ok "--subagent-rows=on registers" || bad "--subagent-rows=on registers"
CLAUDE_SETTINGS="$SETTINGS_FILE" bash "$CONF" --subagent-rows=off >/dev/null 2>&1
jq -e 'has("subagentStatusLine") | not' "$SETTINGS_FILE" >/dev/null 2>&1 \
  && ok "--subagent-rows=off removes" || bad "--subagent-rows=off removes"

# (5) the wizard's preview render shows every segment, including elapsed
installed=0
runtime_statusline() { printf '%s\n' "$HERE/../statusline.sh"; }
CONFIG_FILE=/dev/null
eval "$(sed -n '/^verify_subagent_render() {/,/^}/p' "$CONF")"
PREV=$(verify_subagent_render)
case "$PREV" in (*"⧖"*) ok "preview shows the elapsed segment" ;; (*) bad "preview shows the elapsed segment" ;; esac
case "$PREV" in (*"Haiku 4.5"*"▰"*) ok "preview shows model + gauge" ;; (*) bad "preview shows model + gauge" ;; esac

exit "$fail"
