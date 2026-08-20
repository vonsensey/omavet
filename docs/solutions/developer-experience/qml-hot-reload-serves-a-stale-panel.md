---
title: A QML edit is not live until proven live
date: 2026-08-20
category: developer-experience
module: omavet
problem_type: developer_experience
component: development_workflow
applies_when:
  - "Editing QML in an Omarchy/Quickshell plugin and verifying the result by looking at it"
  - "A fix is green in tests but the running UI still shows the old behaviour"
symptoms:
  - "Panel renders the pre-fix behaviour while the deployed file on disk contains the fix"
  - "journalctl logs 'Local plugin changed, reloading' yet nothing on screen changes"
severity: high
tags: [qml, quickshell, omarchy, hot-reload, verification]
---

# A QML edit is not live until proven live

## Context

Omavet's flagship feature — per-finding `file:line` evidence under each plugin
card — did not render. The cause was found, fixed, and covered by tests. After
redeploying, the panel still showed nothing.

What followed cost far more time than the original bug: redeploy, `rescanPlugins`,
disable/enable the plugin, re-read the deployed file to confirm the fix was on
disk (it was), re-read the scan record to confirm the data existed (30 findings,
it did). Every check passed and the screen still disagreed.

## Guidance

**Treat "I edited the file and the UI still looks wrong" as a question about
which code is running, not about whether the fix is correct.** Before debugging
the fix again, prove the running component is the edited one:

```bash
# change something impossible to miss, then look
sed -i 's/text: "Omavet"/text: "RELOAD-TEST"/' Panel.qml
# summon the panel and screenshot it — did the title change?
```

If the visible string does not change, nothing else you observed is evidence
about your fix. Clear the component cache:

```bash
omarchy-restart-shell
```

The shell's hot reload updates the plugin's **service** — the journal even logs
`Local plugin changed, reloading` — while the QML engine keeps serving the
previously compiled **panel** component. The log line is true and misleading at
the same time.

## Why This Matters

Everything that normally counts as verification stays green against stale code.
A Wayland layer surface still appears in `hyprctl layers`. The journal stays
silent. `omarchy plugin validate` still exits 0. The tests pass, because the
tests never ran against the shell at all. The only signal that discriminates is
a **visible change you deliberately introduced**.

The knock-on cost is worse than the delay: every screenshot taken before the
restart documents the old build. In this case a `preview.png` committed as
evidence — and destined for a public marketplace listing — was a picture of the
bug the commit claimed to fix.

## When to Apply

Any time a QML change is verified by looking at the result, and especially
before capturing a screenshot that will be committed or published.

## Examples

The full sequence that finally isolated it:

```
deploy fixed Panel.qml      -> findings still absent
rescanPlugins               -> findings still absent
disable + re-enable plugin  -> findings still absent
grep the DEPLOYED file      -> the fix IS there
inspect the state record    -> 30 findings ARE there
rename the panel title      -> TITLE DID NOT CHANGE   <- the actual signal
omarchy-restart-shell       -> findings render immediately
```

Related: [Agent CLI flags](../integration-issues/variadic-cli-flag-swallowed-the-prompt.md)
is the same failure shape in a different layer — a silent no-op that every
surrounding check reports as healthy.
