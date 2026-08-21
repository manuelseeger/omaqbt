import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root
  property var settings: ({})

  property bool api: false
  property bool altSpeed: false
  property real dlSpeed: 0
  property real upSpeed: 0
  property var torrents: []
  property var files: []
  property string lastError: ""
  property string actionStatus: ""
  property string clipboardText: ""
  property bool initialized: false
  property string statusConnectionKey: ""
  property string actionConnectionKey: ""
  property string filesConnectionKey: ""

  readonly property string baseUrl: {
    var value = String(settings && settings.baseUrl != null ? settings.baseUrl : "").trim()
    return value === "" ? "http://127.0.0.1:8080" : value
  }
  readonly property string username: String(settings && settings.username != null ? settings.username : "")
  readonly property string connectionKey: baseUrl + "\u0000" + username
  readonly property int refreshIntervalSec: {
    var n = parseInt(String(settings && settings.refreshIntervalSec != null ? settings.refreshIntervalSec : 5), 10)
    if (!isFinite(n)) n = 5
    if (n < 5) n = 5
    if (n > 3600) n = 3600
    return n
  }
  readonly property string helperPath: {
    var value = Qt.resolvedUrl("qbt").toString()
    if (value.indexOf("file://") === 0) return decodeURIComponent(value.substring(7))
    return value
  }
  readonly property bool busy: statusProcess.running || actionProcess.running || filesProcess.running || clipProcess.running
  readonly property bool ready: api
  readonly property bool transferring: Model.anyActive(torrents)
  readonly property bool warning: !api

  function helperCommand(name, args) {
    var command = [helperPath, "--base-url", baseUrl, "--username", username, name]
    var values = args || []
    for (var i = 0; i < values.length; i++) command.push(String(values[i]))
    return command
  }

  function clearError() { lastError = "" }

  function clearRemoteState() {
    api = false
    altSpeed = false
    dlSpeed = 0
    upSpeed = 0
    torrents = []
    files = []
  }

  function connectionChanged() {
    clearRemoteState()
    lastError = ""
    actionStatus = ""
    refresh()
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatusJson(raw)
    if (!parsed.ok) {
      clearRemoteState()
      lastError = "Failed to read qBittorrent status"
      return
    }
    var finished = parsed.api ? Model.newlyCompleted(torrents, parsed.torrents) : []
    api = parsed.api
    altSpeed = parsed.api ? parsed.altSpeed : false
    dlSpeed = parsed.api ? parsed.dlSpeed : 0
    upSpeed = parsed.api ? parsed.upSpeed : 0
    torrents = parsed.api ? parsed.torrents : []
    if (!parsed.api) files = []
    lastError = Model.nextStatusError(parsed, lastError)
    if (finished.length > 0) notify(Model.completionText(finished))
  }

  function notify(text) {
    if (!text || notifyProcess.running) return
    notifyProcess.command = ["notify-send", "-a", "OmaqBT", "OmaqBT", text]
    notifyProcess.running = true
  }

  function refresh() {
    if (statusProcess.running) return
    statusConnectionKey = connectionKey
    statusProcess.command = helperCommand("status", [])
    statusProcess.running = true
  }

  function readClipboard() {
    clipboardText = ""
    clipProcess.command = ["wl-paste", "--no-newline"]
    clipProcess.running = true
  }

  function runAction(name, args, status) {
    if (actionProcess.running) return false
    clearError()
    actionStatus = status || ""
    actionConnectionKey = connectionKey
    actionProcess.command = helperCommand(name, args)
    actionProcess.running = true
    return true
  }

  function addTarget(target, stopped, savePath) {
    var value = String(target || "").trim()
    if (!Model.isAddableTarget(value)) {
      lastError = "Paste a magnet, a .torrent URL, or a .torrent file path."
      return
    }
    var args = []
    if (stopped) args.push("--stopped")
    var directory = String(savePath || "").trim()
    if (directory !== "") { args.push("--savepath"); args.push(directory) }
    args.push(value)
    runAction("add", args, stopped ? "Adding torrent (stopped)…" : "Adding torrent…")
  }

  function addUrl(url) { addTarget(url, false, "") }
  function startHash(hash) { runAction("start", [hash], "") }
  function stopHash(hash) { runAction("stop", [hash], "") }

  function toggleHash(hash) {
    var row = null
    for (var i = 0; i < torrents.length; i++) if (torrents[i].hash === hash) row = torrents[i]
    if (!row) return
    var bucket = Model.classifyState(row.state, row.progress)
    if (bucket === "paused" || bucket === "completed") startHash(hash)
    else stopHash(hash)
  }

  function toggleAll() {
    if (Model.anyActive(torrents)) stopHash("all")
    else startHash("all")
  }

  function deleteHash(hash, withFiles) {
    var args = [hash]
    if (withFiles) args.push("--files")
    runAction("delete", args, withFiles ? "Deleting torrent and files…" : "Removing torrent…")
  }

  function loadFiles(hash) {
    files = []
    if (filesProcess.running) return
    filesConnectionKey = connectionKey
    filesProcess.command = helperCommand("files", [hash])
    filesProcess.running = true
  }

  function setPrio(hash, index, prio) { runAction("prio", [hash, index, prio], "") }
  function toggleTurtle() { runAction("turtle", [], "") }
  function setLimit(hash, kind, bytes) { runAction("limit", [hash, kind, bytes], "") }
  function toggleSequential(hash) { runAction("sequential", [hash], "") }
  function setShareRatio(hash, ratio) { runAction("sharelimit", [hash, ratio], "") }

  onBaseUrlChanged: if (initialized) connectionChanged()
  onUsernameChanged: if (initialized) connectionChanged()
  Component.onCompleted: {
    initialized = true
    refresh()
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (root.statusConnectionKey !== root.connectionKey) {
        Qt.callLater(root.refresh)
        return
      }
      if (exitCode === 0) {
        root.applyStatus(statusOut.text)
      } else {
        root.clearRemoteState()
        root.lastError = Model.sanitizeError(statusErr.text || "Remote Web API is not reachable")
      }
    }
  }

  Process {
    id: notifyProcess
    running: false
    command: []
    onExited: function() {}
  }

  Process {
    id: clipProcess
    running: false
    command: []
    stdout: StdioCollector { id: clipOut; waitForEnd: true }
    onExited: function() { root.clipboardText = String(clipOut.text || "") }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.actionStatus = ""
      if (root.actionConnectionKey !== root.connectionKey) {
        Qt.callLater(root.refresh)
        return
      }
      if (exitCode !== 0) {
        root.lastError = Model.sanitizeError(actionErr.text || actionOut.text || "qBittorrent command failed")
        return
      }
      root.refresh()
    }
  }

  Process {
    id: filesProcess
    running: false
    command: []
    stdout: StdioCollector { id: filesOut; waitForEnd: true }
    stderr: StdioCollector { id: filesErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (root.filesConnectionKey !== root.connectionKey) {
        root.files = []
        return
      }
      if (exitCode !== 0) {
        root.lastError = Model.sanitizeError(filesErr.text || "Could not read files")
        root.files = []
        return
      }
      try { root.files = JSON.parse(String(filesOut.text || "[]")) }
      catch (error) { root.files = [] }
    }
  }
}
