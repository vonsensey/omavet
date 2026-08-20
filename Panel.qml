import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Omavet report panel: one card per installed plugin — a trust dial,
// capability counts, top findings, and actions (agent review, update diff,
// accept). Keyboard-first: arrows/jk move, 1–5 drill into a capability,
// Enter reviews, d diffs, a accepts, r rescans, Esc closes.
Item {
  id: root

  // Injected by the shell's panel loader.
  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false
  property int selectedIndex: 0

  // Capability drill-down: which class the selected card lists in full, and
  // which card it was chosen on. A filter belongs to ONE card, so instead of
  // clearing it when the selection moves, it simply stops applying — no
  // dependence on the order two property changes notify in.
  property string activeClass: ""
  property string activeFor: ""
  readonly property string filterClass: root.activeFor !== "" && root.activeFor === root.selectedKey
    ? root.activeClass : ""

  readonly property var plugins: service ? service.plugins : []
  readonly property int currentIndex: plugins.length > 0
    ? Math.max(0, Math.min(selectedIndex, plugins.length - 1)) : 0
  readonly property var selectedRecord: plugins.length > 0 ? plugins[currentIndex] : null
  // Identity of the selected card. Two installed plugins can claim one id, so
  // the record's directory is what makes a card unique.
  readonly property string selectedKey: selectedRecord
    ? String(selectedRecord.path || selectedRecord.id) : ""

  // Shares the [menu] surface tokens — themes that style the menu style this.
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color scrim: Color.menu.scrim
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property string fontFamily: Style.font.menuFamily
  readonly property color track: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.15)

  function open(payloadJson) {
    root.opened = true
    root.selectedIndex = 0
    root.clearFilter()
    if (root.service) root.service.rescanRecords()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.opened = false }
  function toggle() { root.opened ? close() : open("{}") }

  // Calm → notice → alarm on theme tokens; mirrors the bar widget tint.
  function scoreColor(score) {
    var s = Number(score)
    if (!isFinite(s)) return root.dim
    if (s < 50) return Color.urgent
    if (s < 80) return Color.accent
    return root.foreground
  }

  // A capability filter belongs to the card it was chosen on, so a deliberate
  // move drops it. The filterClass guard covers what this cannot: a rescan
  // re-sorts the list under a fixed index and the selection lands elsewhere.
  function clearFilter() {
    root.activeClass = ""
    root.activeFor = ""
  }

  function moveSelection(delta) {
    if (root.plugins.length === 0) return
    root.selectedIndex = (root.currentIndex + delta + root.plugins.length) % root.plugins.length
    root.clearFilter()
    list.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  // POSIX single-quote escape. Omavet exists to inspect UNTRUSTED plugins, so
  // a plugin id or path is hostile input: a manifest can carry any id string,
  // and this command is run by a shell. Wrap every interpolated value so shell
  // metacharacters (`; | $ \` &`) can never break out of their argument.
  function shquote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

  // Both actions open a normal tiled terminal via omarchy-launch-tui, not the
  // floating presentation wrapper: that wrapper prints the Omarchy logo, floats
  // a small centred window and appends a "done" banner, which suits a transient
  // command but not an agent session the user reads and types into for minutes.
  // launch-tui execs argv directly (-e "$1" "${@:2}"), so the review path passes
  // the untrusted plugin id as its own argument with no shell to escape from.
  function reviewPlugin(pluginId) {
    if (!root.service || root.service.reviewCli === "" || !pluginId) return
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.omavet",
      root.service.pluginDir + "/bin/omavet-review", String(pluginId)])
    root.close()
  }

  // The diff needs a pager, so this one does go through a shell — every
  // interpolated value stays shquote()d.
  function diffPlugin(pluginId) {
    if (!root.service || !pluginId) return
    var cmd = root.shquote(root.service.scanBin) + " --diff "
      + root.shquote(pluginId) + " | less -R"
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.omavet",
      "bash", "-c", cmd])
    root.close()
  }

  function acceptPlugin(pluginId) {
    if (root.service && pluginId) root.service.acceptPlugin(pluginId)
  }

  function reviewSelected() { if (root.selectedRecord) reviewPlugin(root.selectedRecord.id) }
  function diffSelected() {
    var rec = root.selectedRecord
    if (rec && rec.git && rec.git.repo && rec.git.unreviewed) diffPlugin(rec.id)
  }
  function acceptSelected() {
    var rec = root.selectedRecord
    if (rec && rec.git && rec.git.unreviewed) acceptPlugin(rec.id)
  }

  // Chip order is also the 1–5 key order. `cls` is the finding class the chip
  // drills into; `count` is every matching line, which is what the chip shows.
  function capEntries(rec) {
    var caps = rec && rec.capabilities ? rec.capabilities : {}
    return [
      { glyph: "󰖟", label: "network", cls: "network", count: Number(caps.network || 0), alarming: true },
      { glyph: "󰆍", label: "process", cls: "process", count: Number(caps.process || 0), alarming: false },
      { glyph: "󰏫", label: "file writes", cls: "fileWrite", count: Number(caps.fileWrite || 0), alarming: false },
      { glyph: "󰉋", label: "fs reach", cls: "external", count: Number(caps.external || 0), alarming: false },
      { glyph: "󰈉", label: "obfuscation", cls: "obfuscation", count: Number(caps.obfuscation || 0), alarming: true }
    ]
  }

  function classEntry(rec, cls) {
    var entries = root.capEntries(rec)
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].cls === cls) return entries[i]
    }
    return null
  }

  // A record crosses the ListView model boundary as a QVariantMap, so its
  // findings are a QVariantList: no Array methods, index and length only.
  function findingsForClass(rec, cls) {
    var f = rec ? rec.findings : null
    var out = []
    if (!f || !f.length || cls === "") return out
    for (var i = 0; i < f.length; i++) {
      if (f[i].class === cls) out.push(f[i])
    }
    return out
  }

  // Activating a class expands the card, so bring it back into view. A chip
  // at zero has nothing to list and never activates.
  function toggleClass(cls, count) {
    if (!cls || count <= 0) return
    var wasActive = root.filterClass === cls
    root.activeClass = wasActive ? "" : cls
    root.activeFor = wasActive ? "" : root.selectedKey
    // the card grows by the whole listing, so scroll after it has resized
    Qt.callLater(function() { list.positionViewAtIndex(root.currentIndex, ListView.Contain) })
  }

  function toggleClassAt(index) {
    var entries = root.capEntries(root.selectedRecord)
    if (index < 0 || index >= entries.length) return
    root.toggleClass(entries[index].cls, entries[index].count)
  }

  function findingLine(f) {
    return f.file + ":" + f.line + " · " + f.class + " · " + String(f.snippet || "").trim()
  }

  // Inside a class listing the class name is on the header line already.
  function findingDetail(f) {
    return f.file + ":" + f.line + " · " + String(f.snippet || "").trim()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-omavet"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim

      MouseArea {
        anchors.fill: parent
        onClicked: root.close()
      }
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(640), panel.width - Style.gapsOut * 2)
      height: Math.min(Style.space(660), panel.height - Style.gapsOut * 2)
      color: root.background
      borderSpec: root.borderSpec
      radius: Style.cornerRadius
      padding: Style.spacing.panelPadding

      // Swallow clicks so they don't fall through to the scrim.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
      }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveSelection(dy) }
        onActivateRequested: root.reviewSelected()
        onCloseRequested: root.close()
        onTextKey: function(t) {
          if (t === "r" || t === "R") { if (root.service) root.service.scanNow() }
          else if (t === "a" || t === "A") root.acceptSelected()
          else if (t === "d" || t === "D") root.diffSelected()
          // 1–5 pick a capability chip in displayed order; the active one again clears
          else if (t >= "1" && t <= "5") root.toggleClassAt(Number(t) - 1)
        }

        Column {
          anchors.fill: parent
          spacing: Style.space(10)

          // ---------- header ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(headerLabels.implicitHeight, rescanButton.implicitHeight)

            Text {
              id: headerGlyph
              text: "󰒃"
              color: root.plugins.length > 0 ? root.scoreColor(root.plugins[0].trustScore) : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: headerLabels
              anchors.left: headerGlyph.right
              anchors.leftMargin: Style.space(12)
              anchors.right: rescanButton.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Omavet"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                width: parent.width
                text: root.plugins.length > 0
                  ? root.plugins.length + " plugin" + (root.plugins.length === 1 ? "" : "s") + " scanned · worst trust "
                    + root.plugins[0].trustScore
                    + (root.service && root.service.unreviewedCount > 0
                       ? " · " + root.service.unreviewedCount + " update" + (root.service.unreviewedCount === 1 ? "" : "s") + " pending review"
                       : "")
                  : "Local capability scan of installed plugins"
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Button {
              id: rescanButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.service && root.service.scanning ? "Scanning…" : "Rescan"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              enabled: !!root.service && !root.service.scanning
              opacity: enabled ? 1.0 : 0.5
              onClicked: if (root.service) root.service.scanNow()
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---------- empty state ----------
          Text {
            visible: root.plugins.length === 0
            width: parent.width
            topPadding: Style.space(24)
            text: root.service && root.service.scanning
              ? "Scanning installed plugins…"
              : "No plugins scanned yet.\nPlugins installed under ~/.config/omarchy/plugins appear here after the first scan."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---------- plugin report cards ----------
          ListView {
            id: list
            visible: root.plugins.length > 0
            width: parent.width
            height: parent.height - y - footer.implicitHeight - Style.space(10)
            model: root.plugins
            spacing: Style.space(6)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: Rectangle {
              id: row
              required property var modelData
              required property int index

              readonly property var rec: modelData
              readonly property bool selected: index === root.currentIndex
              readonly property bool unreviewed: rec.git && rec.git.unreviewed === true
              // Another installed plugin directory claims this plugin's id.
              // Honest plugins do not share ids, so this is a trust signal in
              // its own right — it is how one plugin hides behind another.
              readonly property string idCollision: rec.idCollision ? String(rec.idCollision) : ""
              // rec crosses the ListView model boundary as a QVariantMap, so
              // rec.findings is a QVariantList — Array.isArray is false on it.
              // Guard on length instead (QVariantList supports length/indexing).
              readonly property var topFindings: {
                var f = rec.findings
                if (!f || !f.length) return []
                var out = []
                for (var i = 0; i < Math.min(3, f.length); i++) out.push(f[i])
                return out
              }
              // Default view: the worst three. With a capability chip active:
              // every finding the scan kept for that one class.
              readonly property var shownFindings: root.filterClass === ""
                ? topFindings : root.findingsForClass(rec, root.filterClass)

              width: list.width
              implicitHeight: rowInner.implicitHeight + Style.space(16)
              radius: Style.cornerRadius
              color: selected ? root.selectedBackground : "transparent"

              MouseArea {
                anchors.fill: parent
                onClicked: {
                  if (root.currentIndex !== row.index) root.clearFilter()
                  root.selectedIndex = row.index
                }
              }

              Column {
                id: rowInner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(6)

                Item {
                  width: parent.width
                  implicitHeight: Math.max(dial.height, headline.implicitHeight)

                  TrustDial {
                    id: dial
                    score: Number(row.rec.trustScore || 0)
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Column {
                    id: headline
                    anchors.left: dial.right
                    anchors.leftMargin: Style.space(12)
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(3)

                    Row {
                      width: parent.width
                      spacing: Style.space(8)

                      Text {
                        // Record strings come from UNTRUSTED plugin manifests
                        // and sources: PlainText everywhere they are shown, so
                        // markup can neither spoof this report nor trigger
                        // rich-text resource loads (e.g. a remote <img src>).
                        textFormat: Text.PlainText
                        text: row.rec.name || row.rec.id
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                        width: Math.min(implicitWidth, parent.width
                          - (updatePill.visible ? updatePill.implicitWidth + Style.space(8) : 0)
                          - (collisionPill.visible ? collisionPill.implicitWidth + Style.space(8) : 0))
                      }

                      Rectangle {
                        id: collisionPill
                        visible: row.idCollision !== ""
                        implicitWidth: collisionPillText.implicitWidth + Style.space(12)
                        implicitHeight: collisionPillText.implicitHeight + Style.space(4)
                        radius: height / 2
                        color: "transparent"
                        border.width: 1
                        border.color: Color.urgent
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                          id: collisionPillText
                          anchors.centerIn: parent
                          textFormat: Text.PlainText
                          text: "duplicate id"
                          color: Color.urgent
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }

                      Rectangle {
                        id: updatePill
                        visible: row.unreviewed
                        implicitWidth: updatePillText.implicitWidth + Style.space(12)
                        implicitHeight: updatePillText.implicitHeight + Style.space(4)
                        radius: height / 2
                        color: "transparent"
                        border.width: 1
                        border.color: Color.accent
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                          id: updatePillText
                          anchors.centerIn: parent
                          text: "update pending review"
                          color: Color.accent
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: (row.rec.version ? "v" + row.rec.version + " · " : "")
                        + (row.rec.author ? row.rec.author + " · " : "")
                        + Number(row.rec.fileCount || 0) + " files scanned"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }

                    Row {
                      spacing: Style.space(8)

                      Repeater {
                        model: root.capEntries(row.rec)

                        Item {
                          id: capChip
                          required property var modelData
                          readonly property bool hot: modelData.count > 0
                          // only the selected card's chips filter anything
                          readonly property bool active: row.selected && root.filterClass === capChip.modelData.cls

                          width: chipRow.implicitWidth + Style.space(10)
                          height: chipRow.implicitHeight + Style.space(4)

                          Rectangle {
                            anchors.fill: parent
                            visible: capChip.active
                            radius: height / 2
                            color: "transparent"
                            border.width: 1
                            border.color: capChip.modelData.alarming ? Color.urgent : Color.accent
                          }

                          Row {
                            id: chipRow
                            anchors.centerIn: parent
                            spacing: Style.space(3)

                            Text {
                              textFormat: Text.PlainText
                              text: capChip.modelData.glyph
                              color: capChip.hot
                                ? (capChip.modelData.alarming ? Color.urgent : root.foreground)
                                : root.track
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.bodySmall
                            }

                            Text {
                              textFormat: Text.PlainText
                              text: capChip.modelData.count
                              color: capChip.hot ? root.foreground : root.track
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.caption
                              anchors.verticalCenter: parent.verticalCenter
                            }
                          }

                          MouseArea {
                            id: capHover
                            anchors.fill: parent
                            hoverEnabled: true
                            // a chip at zero has nothing to list: it stays inert
                            // and the click falls through to selecting the card
                            acceptedButtons: capChip.hot ? Qt.LeftButton : Qt.NoButton
                            onClicked: {
                              root.selectedIndex = row.index
                              root.toggleClass(capChip.modelData.cls, capChip.modelData.count)
                            }
                          }

                          PanelToolTip {
                            visible: capHover.containsMouse
                            // PanelToolTip's Text is AutoText: only literal
                            // labels and numbers may ever reach it, never a
                            // string that came out of a scanned plugin.
                            text: capChip.modelData.label + ": " + capChip.modelData.count + " signal" + (capChip.modelData.count === 1 ? "" : "s")
                              + (capChip.hot ? " · click to list them" : "")
                            fontFamily: root.fontFamily
                          }
                        }
                      }
                    }
                  }
                }

                // ---------- expanded detail on the selected row ----------
                Text {
                  visible: row.selected && row.idCollision !== ""
                  width: parent.width
                  textFormat: Text.PlainText
                  text: "duplicate id: also claimed by the plugin directory " + row.idCollision
                    + " — two installed plugins claim one id; inspect both."
                  color: Color.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Column {
                  visible: row.selected && row.shownFindings.length > 0
                  width: parent.width
                  spacing: Style.space(2)

                  // Which signal is being listed, and how much of it there is:
                  // the scan keeps the first few lines per class, the chip
                  // counts them all, so the two numbers can differ.
                  Text {
                    visible: root.filterClass !== ""
                    width: parent.width
                    textFormat: Text.PlainText
                    text: {
                      var entry = root.classEntry(row.rec, root.filterClass)
                      if (!entry) return ""
                      return entry.label + " · showing " + row.shownFindings.length + " of "
                        + entry.count + " line" + (entry.count === 1 ? "" : "s")
                    }
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Repeater {
                    model: row.shownFindings

                    Text {
                      required property var modelData
                      width: parent.width
                      // finding file/snippet are raw lines of the scanned
                      // plugin's own source — hostile by definition.
                      textFormat: Text.PlainText
                      text: root.filterClass === ""
                        ? root.findingLine(modelData)
                        : root.findingDetail(modelData)
                      color: modelData.severity === "high" ? Color.urgent : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  Text {
                    visible: root.filterClass === ""
                    width: parent.width
                    textFormat: Text.PlainText
                    text: (row.rec.findings && row.rec.findings.length > row.shownFindings.length
                            ? "+ " + (row.rec.findings.length - row.shownFindings.length) + " more · " : "")
                      + "select a signal above (or press 1–5) to list every line it found"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Row {
                  visible: row.selected
                  spacing: Style.space(6)

                  Button {
                    text: root.service && root.service.reviewCli !== ""
                      ? "Review with " + root.service.reviewCli
                      : "Review with agent"
                    bordered: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    enabled: !!root.service && root.service.reviewCli !== ""
                    opacity: enabled ? 1.0 : 0.5
                    onClicked: root.reviewPlugin(row.rec.id)
                  }

                  Button {
                    visible: row.unreviewed && row.rec.git && row.rec.git.repo === true
                    text: "View diff"
                    bordered: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    onClicked: root.diffPlugin(row.rec.id)
                  }

                  Button {
                    visible: row.unreviewed
                    text: "Accept update"
                    bordered: true
                    foreground: Color.accent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    onClicked: root.acceptPlugin(row.rec.id)
                  }

                  Text {
                    visible: !root.service || root.service.reviewCli === ""
                    text: "install claude or codex for agent reviews"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }
          }

          // ---------- footer ----------
          Text {
            id: footer
            width: parent.width
            text: "↑↓ select · 1–5 list a signal · ⏎ agent review · d diff · a accept · r rescan · esc close"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // Speedometer-style trust dial: a 270° sweep from 135°, filled to the
  // score and colored by the same calm/notice/alarm mapping as the bar icon.
  component TrustDial: Item {
    id: dialRoot
    property int score: 0
    readonly property color valueColor: root.scoreColor(score)

    width: Style.space(46)
    height: Style.space(46)

    onScoreChanged: canvas.requestPaint()
    onValueColorChanged: canvas.requestPaint()

    Canvas {
      id: canvas
      anchors.fill: parent
      onVisibleChanged: if (visible) requestPaint()

      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var cx = width / 2
        var cy = height / 2
        var lw = Math.max(3, width * 0.09)
        var r = Math.min(cx, cy) - lw / 2 - 1
        var start = 0.75 * Math.PI
        var span = 1.5 * Math.PI
        ctx.lineWidth = lw
        ctx.lineCap = "round"
        ctx.strokeStyle = root.track
        ctx.beginPath()
        ctx.arc(cx, cy, r, start, start + span, false)
        ctx.stroke()
        var frac = Math.max(0, Math.min(1, dialRoot.score / 100))
        if (frac > 0) {
          ctx.strokeStyle = dialRoot.valueColor
          ctx.beginPath()
          ctx.arc(cx, cy, r, start, start + span * frac, false)
          ctx.stroke()
        }
      }
    }

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: dialRoot.score
      color: dialRoot.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
  }
}
