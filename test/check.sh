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
# benign ships refresh.sh (a `#!/bin/bash` shebang script). A shebang declares
# an interpreter; it must NOT read as a /bin/ process spawn, or every plugin
# with a hook script would be inflated. This asserts the shebang is ignored.
assert_eq "$(jq -r .capabilities.process "$benign")" 0 "benign process (shebang not a spawn)"

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

# no finding anywhere may be a shebang line — proves the sanitizer, generally
for rec in "$benign" "$sketchy"; do
  jq -e '.findings | map(select(.snippet | startswith("#!"))) | length == 0' "$rec" >/dev/null \
    || fail "shebang leaked into findings in $rec"
done
# sketchy's process finding must be a real spawn, not an interpreter line
jq -e '.findings | any(.class == "process" and (.snippet | test("sh -c")))' "$sketchy" >/dev/null \
  || fail "sketchy process finding should be a real spawn (sh -c)"
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

# --- hostile manifest id: no path traversal, no command execution ------------
# Omavet inspects untrusted plugins; a manifest id is attacker-controlled.
mkdir -p "$TMP/plugins/evil"
cat >"$TMP/plugins/evil/manifest.json" <<'JSON'
{"schemaVersion":1,"id":"../../pwned; touch EVIL_MARK","name":"evil","version":"1","kinds":["bar-widget"],"entryPoints":{"barWidget":"W.qml"}}
JSON
printf 'import QtQuick\nItem{}\n' >"$TMP/plugins/evil/W.qml"
HSTATE="$TMP/hstate"
( cd "$TMP" && OMAVET_PLUGINS_DIR="$TMP/plugins" OMAVET_STATE_DIR="$HSTATE" \
  "$OLDPWD/bin/omavet-scan" >/dev/null 2>&1 ) || true
OLDPWD_KEEP=$(pwd)
OMAVET_PLUGINS_DIR="$TMP/plugins" OMAVET_STATE_DIR="$HSTATE" bin/omavet-scan >/dev/null 2>&1 \
  || fail "scan crashed on a hostile manifest id"
# every state file must stay inside the state dir (record_name sanitized the id)
esc=$(find "$HSTATE" -type f 2>/dev/null | grep -vE "^$HSTATE/" | head -1 || true)
[[ -z $esc ]] || fail "hostile id escaped the state dir: $esc"
[[ ! -e "$TMP/EVIL_MARK" && ! -e ./EVIL_MARK ]] || fail "hostile id executed a command"
PASS=$((PASS + 2))
# --diff with a hostile id must not execute it either
OMAVET_PLUGINS_DIR="$TMP/plugins" OMAVET_STATE_DIR="$HSTATE" \
  bin/omavet-scan --diff '$(touch EVIL2); x' >/dev/null 2>&1
[[ ! -e ./EVIL2 && ! -e "$TMP/EVIL2" ]] || fail "--diff executed a hostile id"
PASS=$((PASS + 1))

echo "OK: $PASS assertions passed"
exit 0
