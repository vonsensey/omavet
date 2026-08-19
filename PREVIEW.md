# preview.png

`preview.png` (marketplace card image) is best captured from an interactive
Omarchy session — a screencopy screenshot could not be captured from this headless
build/automation context: grim connects to Wayland but the
wlr-screencopy frame never returns here (the GPU render node is present, so
the exact cause is unpinned; it works normally in an interactive session).

To capture it yourself in ~5 seconds:

```bash
omarchy plugin enable io.github.vonsensey.omavet
omarchy-shell shell summon io.github.vonsensey.omavet '{}'   # opens the panel
# press Super+Shift+S (Omarchy's screenshot) and save as preview.png at the repo root
```

Functional proof that the panel renders live (a real Wayland layer surface
`omarchy-omavet`) is recorded in
`../research/BUILD-EVIDENCE.md`.
