---
title: A variadic CLI flag silently swallowed the prompt
date: 2026-08-20
category: integration-issues
module: omavet
problem_type: integration_issue
component: tooling
symptoms:
  - "Agent CLI opens at its welcome screen with no prompt and no error"
  - "The feature does nothing, and nothing is logged, because nothing failed"
root_cause: wrong_api
resolution_type: code_fix
severity: high
tags: [cli, argv, claude-code, codex, variadic, silent-failure]
---

# A variadic CLI flag silently swallowed the prompt

## Problem

Omavet's "Review with claude" button launched the agent CLI, which opened a
normal interactive session in an empty scratch directory and sat there. No
review ran. No error appeared anywhere.

## Symptoms

- A terminal opens, the CLI starts cleanly, and waits at its welcome screen.
- Nothing is written to any log, because no command failed.
- The user reports "it does nothing" — the hardest bug report to act on.

## What Didn't Work

Reading the code proved nothing: the invocation looked obviously correct.

```bash
exec claude --add-dir "$dir" "$prompt"   # reads as: grant this dir, then prompt
```

Reviewing it did not help either — a 29-agent review pass had already read this
exact line, including a dimension dedicated to the agent-review path, and every
reviewer accepted it. The line is only wrong if you know one fact about the
flag, and the source does not contain that fact.

## Solution

`--add-dir` is **variadic**:

```
--add-dir <directories...>    Additional directories to allow tool access to
```

The `...` means it keeps consuming arguments until it meets something
option-shaped. The prompt does not start with `-`, so it was consumed as a
**second directory**, leaving no positional prompt at all. The CLI then did
exactly what it should with no prompt: start an interactive session.

Separate the prompt from the variadic list with `--`:

```bash
exec claude --permission-mode plan --add-dir "$dir" -- "$prompt"
```

`codex` needs the opposite treatment — its `--add-dir` takes a single `<DIR>`,
and its parser reads `--` as a stdin redirect (it hangs on "Reading additional
input from stdin"):

```bash
exec codex --sandbox read-only --add-dir "$dir" "$prompt"
```

Two CLIs, two different correct shapes. Comment the difference at the call site
or someone will "fix" the inconsistency later.

## Why This Works

`--` is the POSIX end-of-options marker: everything after it is positional, so a
variadic option cannot reach past it. It also protects a prompt that happens to
begin with `-`.

## Prevention

Assert the **shape of argv the tool actually receives**, not that the code
contains a flag. Stub the CLI, capture `"$@"`, and pin the exact positions:

```bash
cat > "$TMP/stub/claude" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$STUB_ARGV"
STUB

assert_eq "${argv[0]}" "--permission-mode"  "runs in a restricted mode"
assert_eq "${argv[2]}" "--add-dir"          "gets the plugin dir"
case "${argv[3]}" in */reviewme) ;; *) fail "wrong directory" ;; esac
assert_eq "${argv[4]}" "--"                 "prompt separated from the variadic flag"
assert_eq "${#argv[@]}" 6                   "no stray args"
```

Assert the **value** as well as the flag: a reviewer pointed at the wrong
directory would audit the wrong plugin while every flag still looked right.

Two general rules earned here:

1. **Read the flag's arity before trusting an invocation.** `<dir>` and
   `<dirs...>` behave differently and look identical at a glance.
2. **A silent no-op is the worst failure mode** — no exception, no exit code, no
   log. Nothing surfaces it except using the feature. This one was found by the
   user clicking the button.

Related: [A QML edit is not live until proven live](../developer-experience/qml-hot-reload-serves-a-stale-panel.md)
— same shape, different layer.
