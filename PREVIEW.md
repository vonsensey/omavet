# preview.png

Captured live on 2026-08-20 from the running `omarchy-shell`: plugin enabled,
panel summoned via `omarchy-shell shell summon io.github.vonsensey.omavet '{}'`,
screenshot taken with `grim`. The panel's layer spans the whole screen (the
PanelWindow anchors all four edges: centered card plus scrim), so `grim`
captures the full screen and the image is then cropped down to the centered
card. The scores shown are real scan output (omavet honestly reports its own
capabilities — the vet does not exempt itself).

To recapture:

```bash
omarchy plugin enable io.github.vonsensey.omavet
omarchy-shell shell summon io.github.vonsensey.omavet '{}'
grim -g "$(hyprctl layers -j | jq -r '.. | objects | select(.namespace? == "omarchy-omavet") | "\(.x),\(.y) \(.w)x\(.h)"')" full.png
# full.png is the whole screen (card + scrim); crop it to the centered card,
# e.g. with `magick full.png -crop WxH+X+Y preview.png` or any image editor.
```
