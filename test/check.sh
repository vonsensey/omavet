#!/bin/bash

# Plain bash asserts for bin/omavet-scan. No framework. Must exit 0.

set -u
cd "$(dirname "$0")/.." || exit 1

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
assert_eq() { # actual expected label
  [[ $1 == "$2" ]] || fail "$3 (got '$1', want '$2')"
  PASS=$((PASS + 1))
}

# Scans run against a throwaway copy so nothing touches the repo fixtures.
cp -r test/fixtures/plugins "$TMP/plugins"
STATE="$TMP/state"

OMAVET_PLUGINS_DIR="$TMP/plugins" OMAVET_STATE_DIR="$STATE" bin/omavet-scan || fail "scan exited non-zero"

benign="$STATE/test.benign-clock.json"
sketchy="$STATE/test.sketchy-exfil.json"
[[ -f $benign ]] || fail "benign record missing"
[[ -f $sketchy ]] || fail "sketchy record missing"

# --- capability counts -------------------------------------------------------
assert_eq "$(jq -r .capabilities.network "$benign")" 0 "benign network"
assert_eq "$(jq -r .capabilities.obfuscation "$benign")" 0 "benign obfuscation"
assert_eq "$(jq -r .capabilities.external "$benign")" 0 "benign external"
assert_eq "$(jq -r .capabilities.fileWrite "$benign")" 0 "benign fileWrite"
assert_eq "$(jq -r .capabilities.process "$benign")" 0 "benign process"

assert_eq "$(jq -r .capabilities.network "$sketchy")" 3 "sketchy network"
assert_eq "$(jq -r .capabilities.obfuscation "$sketchy")" 1 "sketchy obfuscation"
assert_eq "$(jq -r .capabilities.external "$sketchy")" 1 "sketchy external"
assert_eq "$(jq -r .capabilities.process "$sketchy")" 1 "sketchy process"

# --- trust scores ------------------------------------------------------------
b=$(jq -r .trustScore "$benign")
s=$(jq -r .trustScore "$sketchy")
assert_eq "$b" 100 "benign trustScore"
[[ $s -lt $b ]] || fail "sketchy trustScore ($s) not below benign ($b)"
PASS=$((PASS + 1))

# --- findings carry class/file/line/snippet ----------------------------------
jq -e '.findings | map(select(.class == "network")) | length >= 2' "$sketchy" >/dev/null \
  || fail "sketchy should have >= 2 network findings"
jq -e '.findings[0] | has("file") and has("line") and has("snippet") and has("severity")' "$sketchy" >/dev/null \
  || fail "finding record missing fields"
jq -e '.findings | length == 0' "$benign" >/dev/null || fail "benign should have no findings"
PASS=$((PASS + 3))

# --- record metadata ---------------------------------------------------------
assert_eq "$(jq -r .id "$sketchy")" "test.sketchy-exfil" "sketchy id from manifest"
assert_eq "$(jq -r .fileCount "$sketchy")" 2 "sketchy fileCount"

# --- empty plugins dir: exit 0, no records -----------------------------------
mkdir "$TMP/empty"
OMAVET_PLUGINS_DIR="$TMP/empty" OMAVET_STATE_DIR="$TMP/state2" bin/omavet-scan || fail "empty dir scan exited non-zero"
[[ -z $(ls "$TMP/state2"/*.json 2>/dev/null) ]] || fail "records written for empty plugins dir"
PASS=$((PASS + 1))

# --- missing plugins dir: exit 0 ---------------------------------------------
OMAVET_PLUGINS_DIR="$TMP/does-not-exist" OMAVET_STATE_DIR="$TMP/state3" bin/omavet-scan \
  || fail "missing dir scan exited non-zero"
PASS=$((PASS + 1))

# --- weird filenames (spaces, no manifest) -----------------------------------
mkdir -p "$TMP/plugins/weird name plugin"
printf 'eval(atob("x"))\n' >"$TMP/plugins/weird name plugin/a b.js"
OMAVET_PLUGINS_DIR="$TMP/plugins" OMAVET_STATE_DIR="$STATE" bin/omavet-scan || fail "weird-name scan exited non-zero"
weird="$STATE/weird_name_plugin.json"
[[ -f $weird ]] || fail "weird-name record missing"
assert_eq "$(jq -r .capabilities.obfuscation "$weird")" 1 "weird-name obfuscation"

# --- stale record pruning ----------------------------------------------------
rm -rf "$TMP/plugins/sketchy-exfil"
OMAVET_PLUGINS_DIR="$TMP/plugins" OMAVET_STATE_DIR="$STATE" bin/omavet-scan || fail "prune scan exited non-zero"
[[ ! -f $sketchy ]] || fail "stale sketchy record not pruned"
PASS=$((PASS + 1))

# --- diff on a non-git plugin: exit 0 with a clear message -------------------
out=$(OMAVET_PLUGINS_DIR="$TMP/plugins" OMAVET_STATE_DIR="$STATE" bin/omavet-scan --diff test.benign-clock) \
  || fail "--diff on non-git plugin exited non-zero"
case "$out" in
*"not a git checkout"*) PASS=$((PASS + 1)) ;;
*) fail "--diff non-git message unexpected: $out" ;;
esac

# --- git review baseline / unreviewed / accept flow --------------------------
GIT="git -C $TMP/plugins/benign-clock -c user.email=t@t -c user.name=t"
$GIT init -q
$GIT add -A
$GIT commit -qm init
OMAVET_PLUGINS_DIR="$TMP/plugins" OMAVET_STATE_DIR="$STATE" bin/omavet-scan test.benign-clock || fail "git scan failed"
assert_eq "$(jq -r .git.unreviewed "$benign")" "false" "fresh repo baselines as reviewed"

printf '// touched by test\n' >>"$TMP/plugins/benign-clock/Widget.qml"
OMAVET_PLUGINS_DIR="$TMP/plugins" OMAVET_STATE_DIR="$STATE" bin/omavet-scan test.benign-clock || fail "dirty scan failed"
assert_eq "$(jq -r .git.unreviewed "$benign")" "true" "dirty tree flags unreviewed"

out=$(OMAVET_PLUGINS_DIR="$TMP/plugins" OMAVET_STATE_DIR="$STATE" bin/omavet-scan --diff test.benign-clock) \
  || fail "--diff on dirty repo exited non-zero"
case "$out" in
*"Uncommitted working-tree changes"*) PASS=$((PASS + 1)) ;;
*) fail "--diff dirty output unexpected: $out" ;;
esac

$GIT add -A
$GIT commit -qm update
OMAVET_PLUGINS_DIR="$TMP/plugins" OMAVET_STATE_DIR="$STATE" bin/omavet-scan test.benign-clock || fail "post-commit scan failed"
assert_eq "$(jq -r .git.unreviewed "$benign")" "true" "moved HEAD stays unreviewed"

OMAVET_PLUGINS_DIR="$TMP/plugins" OMAVET_STATE_DIR="$STATE" bin/omavet-scan --accept test.benign-clock >/dev/null \
  || fail "--accept failed"
assert_eq "$(jq -r .git.unreviewed "$benign")" "false" "--accept clears unreviewed"

echo "OK: $PASS assertions passed"
exit 0
