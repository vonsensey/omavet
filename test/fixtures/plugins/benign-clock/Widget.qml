import QtQuick

Text {
  id: label
  text: Qt.formatTime(new Date(), "hh:mm")
  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: label.text = Qt.formatTime(new Date(), "hh:mm")
  }
}
