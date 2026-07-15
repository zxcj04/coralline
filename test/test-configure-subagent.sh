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
