import QtQuick

Item {
  function demo(payload) {
    var x = new XMLHttpRequest()
    x.open("GET", "https://example.test/")
    eval(atob(payload))
  }
}
