import QtQuick
import Quickshell.Io

// One plugin's scan record, read straight off the JSON file that
// bin/omavet-scan maintains. The QML side never learns how the findings
// were made — a record in the state dir is a scanned plugin, full stop.
Item {
  id: root
  visible: false

  property string recordKey: ""
  property string path: ""
  property var record: null

  FileView {
    path: root.path
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parse(text())
    onLoadFailed: root.record = null
  }

  function parse(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      root.record = parsed && typeof parsed === "object" ? parsed : null
    } catch (e) {
      console.warn("omavet", "Ignoring bad scan record", root.path, e)
      root.record = null
    }
  }
}
