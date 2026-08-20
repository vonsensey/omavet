# preview.png

Captured live on 2026-08-20 from the running `omarchy-shell`, with the network
signal drilled into (`1`) so the shot shows what the panel is actually for:
every line behind a capability, with `file:line` and the matching source.

Everything in it is real scan output. Omavet's own low score is honest — it
greps files, spawns processes, and reads other plugins' source by design, and
several of the network lines shown are its own detection-pattern table and test
fixtures. The vet does not exempt itself.

To recapture:

```bash
omarchy plugin enable io.github.vonsensey.omavet
omarchy-shell shell toggle io.github.vonsensey.omavet
wtype "1"                                   # drill into the network signal
GEO=$(hyprctl layers -j | jq -r '.. | objects
  | select(.namespace? == "omarchy-omavet") | "\(.x),\(.y) \(.w)x\(.h)"' | head -1)
grim -g "$GEO" full.png                      # the layer is the whole screen
# then crop to the centred card (the panel anchors all four edges, so the
# layer geometry is NOT the card geometry)
```

A QML change is not live until proven live — the shell can serve a cached
compiled component while hot-reload reports success. Restart the shell before
capturing, or the screenshot documents the previous build. See
`docs/solutions/developer-experience/qml-hot-reload-serves-a-stale-panel.md`.
