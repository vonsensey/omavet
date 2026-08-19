# preview.png

`preview.png` (marketplace card image) is best captured from an interactive
Omarchy session — a screencopy screenshot cannot be taken from the headless
build/automation context (grim's wlr-screencopy needs a GPU render node this
context lacks).

To capture it yourself in ~5 seconds:

```bash
omarchy plugin enable io.github.vonsensey.omavet
omarchy-shell shell summon io.github.vonsensey.omavet '{}'   # opens the panel
# press Super+Shift+S (Omarchy's screenshot) and save as preview.png at the repo root
```

Functional proof that the panel renders live (a real Wayland layer surface
`omarchy-omavet`) is recorded in
`../research/BUILD-EVIDENCE.md`.
