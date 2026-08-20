# preview.png

Captured live on 2026-08-20 from the running `omarchy-shell`: plugin enabled,
panel summoned via `omarchy-shell shell summon io.github.vonsensey.omavet '{}'`,
screenshot taken with `grim` and cropped to the panel bounds. The scores shown
are real scan output (omavet honestly reports its own capabilities — the vet
does not exempt itself).

To recapture:

```bash
omarchy plugin enable io.github.vonsensey.omavet
omarchy-shell shell summon io.github.vonsensey.omavet '{}'
grim -g "$(hyprctl layers -j | jq -r '.. | objects | select(.namespace? == "omarchy-omavet") | "\(.x),\(.y) \(.w)x\(.h)"')" preview.png
```
