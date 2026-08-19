import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

// Omavet bar widget: a shield tinted by the worst trust score across every
// installed plugin, with a dot when any plugin has unreviewed git changes.
// Left-click toggles the report panel; middle-click rescans now.
BarWidget {
  id: root
  moduleName: "io.github.vonsensey.omavet"

  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor("io.github.vonsensey.omavet") : null
  readonly property int worst: svc ? svc.worstTrustScore : -1
  readonly property int unreviewed: svc ? svc.unreviewedCount : 0
  readonly property int scanned: svc ? svc.pluginCount : 0

  // Services receive no settings injection of their own — the widget owns the
  // manifest schema, so it pushes its settings object into the service.
  onSvcChanged: pushSettings()
  onSettingsChanged: pushSettings()
  Component.onCompleted: pushSettings()
  function pushSettings() {
    if (root.svc) root.svc.settings = root.settings || ({})
  }

  readonly property color barFg: bar ? bar.barForeground : Color.foreground

  // Calm → notice → alarm on theme tokens (never hardcoded): bar foreground
  // while every score holds >= 80, accent from 50–79, urgent below 50.
  // No scan data yet reads as dimmed, not as a verdict.
  readonly property color tint: worst < 0 ? Qt.darker(barFg, 1.5)
    : worst < 50 ? Color.urgent
    : worst < 80 ? Color.accent
    : barFg

  readonly property string summary: scanned > 0
    ? scanned + " plugin" + (scanned === 1 ? "" : "s") + " scanned · worst trust " + worst
      + (unreviewed > 0 ? " · " + unreviewed + " update" + (unreviewed === 1 ? "" : "s") + " unreviewed" : "")
    : "Omavet · no plugins scanned yet"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function togglePanel() {
    if (bar && bar.shell) bar.shell.toggle("io.github.vonsensey.omavet", "{}")
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰒃"
    foreground: root.tint
    useActiveColor: false
    tooltipText: root.summary
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) {
        if (root.svc) root.svc.scanNow()
      } else {
        root.togglePanel()
      }
    }

    Behavior on foreground {
      enabled: !root.bar || root.bar.foregroundAnimationEnabled
      ColorAnimation { duration: 160 }
    }
  }

  // Unreviewed-update badge: a small accent dot pinned to the icon's corner.
  Rectangle {
    visible: root.unreviewed > 0
    width: Math.max(4, Style.space(5))
    height: width
    radius: width / 2
    color: Color.accent
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.topMargin: Style.space(3)
    anchors.rightMargin: Style.space(3)
  }
}
