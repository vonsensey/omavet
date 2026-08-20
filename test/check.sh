#!/bin/bash

# Plain bash asserts for bin/omavet-scan. No framework. Must exit 0.

set -u
cd "$(dirname "$0")/.." || exit 1
SCAN="$(pwd)/bin/omavet-scan"

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
# the sanitized stem carries a short hash suffix (the id needed sanitizing)
mkdir -p "$TMP/plugins/weird name plugin"
printf 'eval(atob("x"))\n' >"$TMP/plugins/weird name plugin/a b.js"
OMAVET_PLUGINS_DIR="$TMP/plugins" OMAVET_STATE_DIR="$STATE" bin/omavet-scan || fail "weird-name scan exited non-zero"
weird=$(ls "$STATE"/weird_name_plugin*.json 2>/dev/null | head -1)
[[ -n $weird && -f $weird ]] || fail "weird-name record missing"
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
GIT() { git -C "$TMP/plugins/benign-clock" -c user.email=t@t -c user.name=t "$@"; }
GIT init -q
GIT add -A
GIT commit -qm init
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

GIT add -A
GIT commit -qm update
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
  "$SCAN" >/dev/null 2>&1 ) || fail "scan crashed on a hostile manifest id (\$TMP cwd)"
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

# --- leading-dash manifest id: record must survive the scan+prune pass -------
# An id like "-evil" turns the record stem into something every tool reads as
# an option. The prune grep must not eat it (scanner evasion) and the stem
# must never begin with '-' or '.'.
mkdir -p "$TMP/plugins/dash-evil"
cat >"$TMP/plugins/dash-evil/manifest.json" <<'JSON'
{"schemaVersion":1,"id":"-evil","name":"dash","version":"1","kinds":["bar-widget"],"entryPoints":{"barWidget":"W.qml"}}
JSON
printf 'import QtQuick\nItem{}\n' >"$TMP/plugins/dash-evil/W.qml"
OMAVET_PLUGINS_DIR="$TMP/plugins" OMAVET_STATE_DIR="$STATE" bin/omavet-scan || fail "dash-id scan exited non-zero"
dashrec=""
for f in "$STATE"/*.json; do
  [[ $(jq -r .id "$f") == "-evil" ]] && dashrec="$f"
done
[[ -n $dashrec ]] || fail "leading-dash id record missing after scan+prune"
case "$(basename "$dashrec")" in
-* | .*) fail "leading-dash id produced an option/hidden record name: $dashrec" ;;
esac
PASS=$((PASS + 2))

# --- NUL byte in a source file: finding evidence must not vanish -------------
# grep treats NUL-containing files as binary and hides match lines; the scan
# must still report both the capability count AND the finding rows.
mkdir -p "$TMP/plugins/nul-plugin"
printf 'fetch("https://evil.example/x")\n\0\n' >"$TMP/plugins/nul-plugin/payload.js"
OMAVET_PLUGINS_DIR="$TMP/plugins" OMAVET_STATE_DIR="$STATE" bin/omavet-scan || fail "nul scan exited non-zero"
nul="$STATE/nul-plugin.json"
[[ -f $nul ]] || fail "nul-plugin record missing"
jq -e '.capabilities.network >= 1' "$nul" >/dev/null || fail "NUL byte hid the network capability"
jq -e '.findings | length >= 1' "$nul" >/dev/null || fail "NUL byte hid the finding rows"
PASS=$((PASS + 2))

# --- colliding ids: distinct ids sanitizing to one stem get distinct records --
# "a/b" and "a b" both sanitize to "a_b"; neither may mask the other.
mkdir -p "$TMP/plugins/col-one" "$TMP/plugins/col-two"
cat >"$TMP/plugins/col-one/manifest.json" <<'JSON'
{"schemaVersion":1,"id":"a/b","name":"one","version":"1","kinds":["bar-widget"],"entryPoints":{"barWidget":"W.qml"}}
JSON
cat >"$TMP/plugins/col-two/manifest.json" <<'JSON'
{"schemaVersion":1,"id":"a b","name":"two","version":"1","kinds":["bar-widget"],"entryPoints":{"barWidget":"W.qml"}}
JSON
printf 'import QtQuick\nItem{}\n' >"$TMP/plugins/col-one/W.qml"
printf 'import QtQuick\nItem{}\n' >"$TMP/plugins/col-two/W.qml"
OMAVET_PLUGINS_DIR="$TMP/plugins" OMAVET_STATE_DIR="$STATE" bin/omavet-scan || fail "collision scan exited non-zero"
jq -r .id "$STATE"/a_b*.json 2>/dev/null | grep -qxF -e 'a/b' || fail "record for id 'a/b' masked by collision"
jq -r .id "$STATE"/a_b*.json 2>/dev/null | grep -qxF -e 'a b' || fail "record for id 'a b' masked by collision"
PASS=$((PASS + 2))

# --- duplicate manifest ids: neither plugin may hide behind the other -------
# A hostile author ships two dirs claiming ONE id: a payload that sorts first
# and an empty decoy that sorts last. With one record per id the decoy's clean
# record overwrites the payload's — the capabilities vanish from the panel.
# Both must keep their own record, and both must say so.
mkdir -p "$TMP/plugins/aaa-payload" "$TMP/plugins/zzz-decoy"
for d in aaa-payload zzz-decoy; do
  cat >"$TMP/plugins/$d/manifest.json" <<'JSON'
{"schemaVersion":1,"id":"dup.plugin","name":"Twin","version":"1","kinds":["bar-widget"],"entryPoints":{"barWidget":"W.qml"}}
JSON
done
printf 'import QtQuick\nItem{ property string u: "https://evil.example/x"\n function go(){ eval(atob("ZQ==")) } }\n' \
  >"$TMP/plugins/aaa-payload/W.qml"
printf 'import QtQuick\nItem{}\n' >"$TMP/plugins/zzz-decoy/W.qml"

dup_records() { # sets $payload / $decoy to the record file for each twin dir
  payload=""; decoy=""
  for f in "$STATE"/*.json; do
    case "$(jq -r .path "$f" 2>/dev/null)" in
    */aaa-payload) payload="$f" ;;
    */zzz-decoy) decoy="$f" ;;
    esac
  done
}

OMAVET_PLUGINS_DIR="$TMP/plugins" OMAVET_STATE_DIR="$STATE" bin/omavet-scan || fail "duplicate-id scan exited non-zero"
dup_records
[[ -n $payload && -n $decoy ]] || fail "duplicate ids share one record (payload='$payload' decoy='$decoy')"
[[ $payload != "$decoy" ]] || fail "duplicate ids resolved to the same record file"
jq -e '.capabilities.network >= 1' "$payload" >/dev/null || fail "payload capabilities hidden by its twin"
jq -e '.capabilities.obfuscation >= 1' "$payload" >/dev/null || fail "payload obfuscation hidden by its twin"
assert_eq "$(jq -r .idCollision "$payload")" "zzz-decoy" "payload record names its twin"
assert_eq "$(jq -r .idCollision "$decoy")" "aaa-payload" "decoy record names its twin"
PASS=$((PASS + 4))

# scanning one twin directly must not clobber the other's record either
OMAVET_PLUGINS_DIR="$TMP/plugins" OMAVET_STATE_DIR="$STATE" bin/omavet-scan zzz-decoy || fail "single-dir twin scan failed"
dup_records
[[ -n $payload && -n $decoy ]] || fail "single-dir scan of the decoy clobbered the payload record"
jq -e '.capabilities.network >= 1' "$payload" >/dev/null || fail "single-dir decoy scan erased the payload's capabilities"
# --accept on a twin re-baselines only its own record
OMAVET_PLUGINS_DIR="$TMP/plugins" OMAVET_STATE_DIR="$STATE" bin/omavet-scan --accept zzz-decoy >/dev/null \
  || fail "--accept on a twin failed"
dup_records
[[ -n $payload && -n $decoy ]] || fail "--accept on the decoy clobbered the payload record"
jq -e '.capabilities.network >= 1' "$payload" >/dev/null || fail "--accept on the decoy erased the payload's capabilities"
PASS=$((PASS + 4))

echo "OK: $PASS assertions passed"
exit 0
