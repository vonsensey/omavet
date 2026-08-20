---
title: A watcher that never fires looks exactly like nothing happening
date: 2026-08-20
category: integration-issues
module: tooling
problem_type: integration_issue
component: development_workflow
symptoms:
  - "A background monitor polls for a condition and never reports, while the condition is already true"
  - "A gh/jq pipeline returns empty with no error because a version manager printed a banner to stdout first"
root_cause: missing_validation
resolution_type: code_fix
severity: high
tags: [monitoring, polling, gh-cli, jq, mise, stdout, silent-failure]
---

# A watcher that never fires looks exactly like nothing happening

## Problem

A background monitor was set to poll a marketplace issue every 30 seconds and
report when its security-baseline validation passed. It reported nothing. The
validation had, in fact, already passed — the monitor's extraction was broken
and returned empty on every single poll.

The user asked three times to be pinged before anyone checked by hand.

## Symptoms

- The monitor runs, consumes its full timeout, and emits nothing.
- No error, no stderr, no non-zero exit — every poll "succeeds" and finds nothing.
- Silence from a watcher is indistinguishable from the event not having happened.
  That is the entire danger: the failure mode and the normal waiting state
  produce identical output.

## What Didn't Work

Re-arming the monitor, and assuming the upstream bot was slow. Both are the
natural readings of silence, and both are wrong when the watcher itself is
broken. Nothing about the monitor's own behaviour distinguishes the two.

## Solution

The mechanical cause: `mise` prints a banner line to **stdout** before the
wrapped command's output.

```
mise ~/.config/mise/config.toml tools: gh@2.97.0
{ "comments": [ ... ] }
```

So this pipeline feeds `jq` a line of prose before the JSON, and `jq` fails to
parse — silently, because stderr was discarded:

```bash
gh issue view "$n" --json comments 2>/dev/null | jq -r '...' 2>/dev/null   # always empty
```

Let `gh` apply the filter internally, so the banner never reaches a JSON parser:

```bash
gh issue view "$n" --json comments --jq '[.comments[] | select(...)] | last.body'
```

**The banner is still there.** `--jq` fixes the parse, not the stream — `gh`'s
stdout is still `mise …` followed by the result:

```
$ gh issue view 912 --json comments --jq '.comments | length'
mise ~/.config/mise/config.toml tools: gh@2.97.0
2
```

So whatever consumes that output must tolerate it. A `grep -o '<pattern>'` does,
because it only emits matching text — which is why the working version here
survived by accident. A bare `x=$(gh … --jq '.count')` does **not**: `x` becomes
two lines, and a numeric comparison on it fails just as silently as the original
bug. Strip it explicitly when the value is consumed directly:

```bash
x=$(gh … --jq '.count' 2>/dev/null | grep -v '^mise ')
```

## Why This Works

`--jq` runs inside `gh`, applied to the API response before anything is printed,
so a malformed outer stream can no longer break the parse. The banner comes from
the `mise` shim wrapping the binary and is prepended to whatever `gh` writes, so
it remains an output-hygiene problem for every downstream consumer — fixing the
parse and fixing the stream are two separate jobs, and only doing the first is
how this bug half-survives a fix.

## Prevention

**Prove a watcher can report success before trusting its silence.** Arm it
against a condition that is already true and confirm it fires. A monitor that
has never once produced output is not evidence of "nothing happened" — it is
untested code running unattended, and its output is the same either way.

Concretely, when writing a poll loop:

- **Run the extraction once, inline, and look at the result** before wrapping it
  in a loop. One command's output would have exposed this instantly.
- **Do not discard stderr while developing it.** `2>/dev/null` on both the fetch
  and the parse is what turned a loud parse error into silence.
- **Make the loop report what it saw, not only when it matches.** A monitor that
  prints its last observed value on timeout tells you whether it was watching
  correctly or watching nothing.
- **Prefer the tool's own filter** (`gh --jq`, `curl | jq` only when the source
  is known-clean) over piping through an environment that may inject output.

The general rule, which cost time four separate ways in this project: **a check
that cannot fail is not a check.** A stale QML component, a screenshot of an
older build, a guide with outdated numbers, and this monitor were all cases where
every available signal read healthy and none of them were looking at the real
thing.

Related:
[A QML edit is not live until proven live](../developer-experience/qml-hot-reload-serves-a-stale-panel.md)
and [A variadic CLI flag silently swallowed the prompt](variadic-cli-flag-swallowed-the-prompt.md)
— the same silent-no-op shape in the UI and CLI layers.
