import QtQuick
import Quickshell
import Quickshell.Io

// Omavet service: the display side of the plugin capability scan. All
// scanning lives behind bin/omavet-scan (plain bash, testable without the
// shell), which writes one JSON record per installed plugin into the state
// dir; this file only schedules those scans, discovers the records, watches
// them for changes, and aggregates the numbers the bar widget binds to.
Item {
  id: root
  visible: false

  property var shell: null
  property var manifest: null
  // Services receive no settings injection; the bar widget pushes its
  // settings object here so refreshIntervalSec has one source of truth.
  property var settings: ({})

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/omavet"
  readonly property string pluginDir: manifest && manifest.__sourceDir
    ? manifest.__sourceDir
    : home + "/.config/omarchy/plugins/io.github.vonsensey.omavet"
  readonly property string scanBin: pluginDir + "/bin/omavet-scan"

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property int refreshIntervalSec: {
    var n = Number(setting("refreshIntervalSec", 3600))
    if (!isFinite(n)) n = 3600
    return Math.min(86400, Math.max(300, Math.round(n)))
  }

  // ------------------------------------------------------------- discovery

  property var recordIds: []
  property int dataRevision: 0

  Process {
    id: listProcess
    running: false
    command: ["find", root.stateDir, "-maxdepth", "1", "-name", "*.json", "-printf", "%f\n"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyListing(text)
    }
  }

  function rescanRecords() {
    if (!listProcess.running) listProcess.running = true
  }

  function applyListing(output) {
    var ids = []
    var lines = String(output || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var name = lines[i].trim()
      if (name.slice(-5) === ".json") ids.push(name.slice(0, -5))
    }
    ids.sort()
    // Same list: keep the FileViews alive instead of rebuilding identical ones.
    if (JSON.stringify(ids) !== JSON.stringify(recordIds)) recordIds = ids
  }

  Instantiator {
    id: recordInstantiator
    model: root.recordIds

    delegate: Record {
      required property var modelData
      recordKey: modelData
      path: root.stateDir + "/" + modelData + ".json"
      onRecordChanged: root.bumpRevision()
    }

    onObjectAdded: (index, object) => root.bumpRevision()
    onObjectRemoved: (index, object) => root.bumpRevision()
  }

  function bumpRevision() { dataRevision++ }

  // ------------------------------------------------------------ aggregates

  // All plugin records, worst trust first — the order the panel lists them in.
  readonly property var plugins: {
    var rev = dataRevision
    var out = []
    for (var i = 0; i < recordInstantiator.count; i++) {
      var item = recordInstantiator.objectAt(i)
      if (item && item.record && item.record.id) out.push(item.record)
    }
    out.sort(function(a, b) {
      var d = Number(a.trustScore || 0) - Number(b.trustScore || 0)
      return d !== 0 ? d : String(a.name || a.id).localeCompare(String(b.name || b.id))
    })
    return out
  }

  readonly property int pluginCount: plugins.length
  // -1 = nothing scanned yet (the widget dims instead of pretending 100).
  readonly property int worstTrustScore: plugins.length > 0 ? Number(plugins[0].trustScore || 0) : -1
  readonly property int unreviewedCount: {
    var n = 0
    for (var i = 0; i < plugins.length; i++) {
      if (plugins[i].git && plugins[i].git.unreviewed === true) n++
    }
    return n
  }
  readonly property int findingCount: {
    var n = 0
    for (var i = 0; i < plugins.length; i++) {
      n += Array.isArray(plugins[i].findings) ? plugins[i].findings.length : 0
    }
    return n
  }

  // ---------------------------------------------------------------- scans

  readonly property bool scanning: scanProcess.running

  Process {
    id: scanProcess
    running: false
    onExited: root.rescanRecords()

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("omavet", text.trim())
    }
  }

  function scanNow() {
    if (scanProcess.running) return
    scanProcess.command = [root.scanBin]
    scanProcess.running = true
  }

  Process {
    id: acceptProcess
    running: false
    onExited: root.rescanRecords()
  }

  // Mark a plugin's current git HEAD as reviewed and refresh its record.
  function acceptPlugin(pluginId) {
    if (acceptProcess.running) return
    acceptProcess.command = [root.scanBin, "--accept", String(pluginId)]
    acceptProcess.running = true
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.scanNow()
  }

  // --------------------------------------------------------- agent CLI

  // Which agent CLI "Review with agent" would use — probed once at startup,
  // empty when neither claude nor codex is installed.
  property string reviewCli: ""

  Process {
    id: cliProbe
    running: false
    command: ["bash", "-c", "command -v claude || command -v codex || true"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var first = String(text || "").split("\n")[0].trim()
        root.reviewCli = first === "" ? "" : first.split("/").pop()
      }
    }
  }

  Component.onCompleted: {
    cliProbe.running = true
    rescanRecords()
  }
}
