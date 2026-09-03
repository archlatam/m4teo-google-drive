import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})

  property bool installed: false
  property bool checking: false
  property bool syncing: false
  property bool downloading: false
  property var files: []
  property int selectedCount: 0
  property int localCount: 0
  property string status: "idle" // idle | syncing | error
  property string statusText: "Ready"
  property string lastError: ""
  property string lastRun: ""
  property bool lastOk: false

  // Cola reactiva de descargas
  property var downloadQueue: []
  property int queuePending: downloadQueue.length

  // Telemetría en vivo
  property bool progressActive: false
  property string currentTransferTarget: ""
  property string currentTransferFile: ""
  property double progressPercent: 0
  property string progressSpeed: ""
  property string progressEta: ""
  property string progressBytes: ""

  // Actividad visible en el panel: none | downloading | deleting | syncing
  property string activity: "none"
  property string activityName: ""

  readonly property bool busy: checkProcess.running || listProcess.running || downloadProcess.running || syncProcess.running
  readonly property bool actionBusy: setProcess.running
  readonly property int pollIntervalSec: intSetting("pollIntervalSec", 60, 10, 3600)
  readonly property bool notificationsEnabled: setting("notificationsEnabled", true) !== false
  readonly property string helperPath: localPath(Qt.resolvedUrl("sync.sh"))
  // This setting is defined in manifest.json; omit the colon because the
  // helper consistently adds it when forming rclone paths.
  readonly property string remoteName: String(setting("remoteName", "gdrive")).trim().replace(/:$/, "") || "gdrive"

  property string _listOutput: ""
  property string _listError: ""
  property string _statusOutput: ""
  property string _statusError: ""
  property string _downloadOutput: ""
  property string _downloadError: ""
  property string _syncOutput: ""
  property string _syncError: ""
  property string _setOutput: ""
  property string _setError: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    return decodeURIComponent(value)
  }

  function elide(text) {
    // rclone writes this deprecation notice on stderr even when an operation
    // succeeds. Do not let it hide the actionable error that may follow it.
    var lines = String(text || "").split("\n")
    var useful = []
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].indexOf("shared Google Drive client_id") === -1) useful.push(lines[i])
    }
    var value = useful.join(" ").replace(/\s+/g, " ").trim()
    return value.length > 200 ? value.substring(0, 197) + "…" : value
  }

  function refreshList() {
    if (listProcess.running || helperPath === "") return
    _listOutput = ""
    _listError = ""
    listProcess.command = ["bash", helperPath, "--remote", remoteName, "list"]
    listProcess.running = true
  }

  function refreshStatus() {
    if (checkProcess.running || helperPath === "") return
    _statusOutput = ""
    _statusError = ""
    checkProcess.command = ["bash", helperPath, "--remote", remoteName, "status"]
    checkProcess.running = true
  }

  function refresh() {
    refreshList()
    refreshStatus()
  }

  function applyList(raw) {
    checking = false
    var list = Model.parseList(raw)
    files = list
    var selected = 0
    var downloaded = 0
    for (var i = 0; i < list.length; i++) {
      if (list[i].selected === 1 || Model.isLocal(list[i])) selected++
      if (Model.isLocal(list[i])) downloaded++
    }
    selectedCount = selected
    localCount = downloaded
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    lastRun = String(parsed.lastRun || "")
    lastOk = parsed.ok === true
    lastError = String(parsed.error || "")

    var prog = parsed.progress || {}
    if (prog.active === true) {
      progressActive = true
      progressPercent = Number(prog.percent || 0)
      progressSpeed = String(prog.speed || prog.stats || "")
      progressEta = Model.formatEta(String(prog.eta || ""))
      currentTransferTarget = String(prog.target || activityName || "")
      currentTransferFile = Model.formatFileName(String(prog.currentFile || currentTransferTarget))
      progressBytes = String(prog.bytesDone && prog.bytesTotal ? (prog.bytesDone + " / " + prog.bytesTotal) : "")
    } else {
      progressActive = false
      progressPercent = 0
      progressSpeed = ""
      progressEta = ""
      progressBytes = ""
      if (!downloading && !syncing) {
        currentTransferFile = ""
        currentTransferTarget = ""
      }
    }

    if (!lastOk && !downloading && !syncing) {
      status = "error"
      statusText = "Sync error"
    } else if (syncing) {
      statusText = "Syncing…"
    } else if (downloading || progressActive) {
      statusText = "Downloading…"
    } else {
      statusText = lastRun === "" ? "Not synced yet" : "Synced " + friendlyDate(lastRun)
    }
  }

  function friendlyDate(iso) {
    var value = String(iso || "")
    if (value.length < 16) return value
    try { return value.substring(0, 16).replace("T", " ") } catch (e) { return value }
  }

  function setSelected(name, selected) {
    name = String(name || "").trim()
    if (!name) return

    // Actualización visual inmediata en memoria para alta responsividad
    for (var i = 0; i < files.length; i++) {
      if (files[i].name === name) {
        files[i].selected = selected ? 1 : 0
        if (!selected) {
          files[i].local = false
        }
        break
      }
    }

    if (selected) {
      enqueueDownload(name)
    } else {
      dequeueDownload(name)
      activity = "deleting"
      activityName = name
      var dlCount = 0
      for (var k = 0; k < files.length; k++) {
        if (Model.isLocal(files[k])) dlCount++
      }
      localCount = dlCount
    }

    // Persistir selección en el backend de forma asíncrona
    _setOutput = ""
    _setError = ""
    setProcess.command = ["bash", helperPath, "--remote", remoteName, "set", name, selected ? "1" : "0"]
    setProcess.running = true
  }

  function enqueueDownload(name) {
    name = String(name || "").trim()
    if (!name) return
    for (var i = 0; i < downloadQueue.length; i++) {
      if (downloadQueue[i] === name) return // ya en cola
    }
    var q = downloadQueue.slice()
    q.push(name)
    downloadQueue = q
    queuePending = downloadQueue.length
    processQueue()
  }

  function dequeueDownload(name) {
    name = String(name || "").trim()
    var q = []
    for (var i = 0; i < downloadQueue.length; i++) {
      if (downloadQueue[i] !== name) q.push(downloadQueue[i])
    }
    downloadQueue = q
    queuePending = downloadQueue.length
    if (activityName === name && activity === "downloading" && downloadQueue.length === 0) {
      activity = "none"
      activityName = ""
    }
  }

  function processQueue() {
    if (downloadProcess.running || syncProcess.running) return
    if (downloadQueue.length === 0) {
      downloading = false
      progressActive = false
      currentTransferFile = ""
      currentTransferTarget = ""
      if (activity === "downloading") {
        activity = "none"
        activityName = ""
      }
      return
    }

    var nextItem = downloadQueue[0]
    downloading = true
    activity = "downloading"
    activityName = nextItem
    currentTransferTarget = nextItem
    currentTransferFile = nextItem
    progressActive = true

    _downloadOutput = ""
    _downloadError = ""
    downloadProcess.command = ["bash", helperPath, "--remote", remoteName, "download", nextItem]
    downloadProcess.running = true
    progressTimer.start()
  }

  function sync() {
    if (syncProcess.running || downloadProcess.running) return
    syncing = true
    activity = "syncing"
    activityName = ""
    status = "syncing"
    statusText = "Syncing…"
    _syncOutput = ""
    _syncError = ""
    syncProcess.command = ["bash", helperPath, "--remote", remoteName, "sync"]
    syncProcess.running = true
    progressTimer.start()
  }

  function notifyDone(ok, message) {
    if (!notificationsEnabled) return
    var body = ok
      ? "Sync completed. " + (message || "")
      : "Sync failed. " + (message || "")
    Quickshell.execDetached(["notify-send", "Rclone Drive Sync", body])
  }

  Component.onCompleted: {
    installedProcess.command = ["sh", "-c", "command -v rclone"]
    installedProcess.running = true
  }

  Process {
    id: installedProcess
    running: false
    command: []
    onExited: function(exitCode) {
      installed = exitCode === 0
      if (installed) {
        refresh()
        pollTimer.start()
      } else {
        status = "error"
        statusText = "rclone is not installed"
        lastError = "rclone is not installed"
        checking = false
      }
    }
  }

  Process {
    id: listProcess
    running: false
    command: []
    stdout: StdioCollector { id: listStdout; waitForEnd: true; onStreamFinished: root._listOutput = text }
    stderr: StdioCollector { id: listStderr; waitForEnd: true; onStreamFinished: root._listError = text }
    onExited: function(exitCode) {
      checking = false
      var stdout = String(listStdout.text || root._listOutput || "")
      var stderr = String(listStderr.text || root._listError || "")
      if (exitCode === 0) {
        root.lastError = ""
        root.applyList(stdout)
      } else root.lastError = root.elide(stderr || stdout || "Could not list Drive files")
      root._listOutput = ""
      root._listError = ""
    }
  }

  Process {
    id: checkProcess
    running: false
    command: []
    stdout: StdioCollector { id: checkStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
    stderr: StdioCollector { id: checkStderr; waitForEnd: true; onStreamFinished: root._statusError = text }
    onExited: function(exitCode) {
      var stdout = String(checkStdout.text || root._statusOutput || "")
      if (exitCode === 0) root.applyStatus(stdout)
      root._statusOutput = ""
      root._statusError = ""
    }
  }

  Process {
    id: setProcess
    running: false
    command: []
    stdout: StdioCollector { id: setStdout; waitForEnd: true; onStreamFinished: root._setOutput = text }
    stderr: StdioCollector { id: setStderr; waitForEnd: true; onStreamFinished: root._setError = text }
    onExited: function(exitCode) {
      var stdout = String(setStdout.text || root._setOutput || "")
      var stderr = String(setStderr.text || root._setError || "")
      if (exitCode !== 0) root.lastError = root.elide(stderr || stdout || "Could not change the selection")
      if (root.activity === "deleting") {
        root.activity = "none"
        root.activityName = ""
      }
      root._setOutput = ""
      root._setError = ""
      root.refresh()
    }
  }

  Process {
    id: downloadProcess
    running: false
    command: []
    stdout: StdioCollector { id: dlStdout; waitForEnd: true; onStreamFinished: root._downloadOutput = text }
    stderr: StdioCollector { id: dlStderr; waitForEnd: true; onStreamFinished: root._downloadError = text }
    onExited: function(exitCode) {
      var stdout = String(dlStdout.text || root._downloadOutput || "")
      var stderr = String(dlStderr.text || root._downloadError || "")
      var finishedItem = root.downloadQueue.length > 0 ? root.downloadQueue[0] : ""

      if (root.downloadQueue.length > 0) {
        root.downloadQueue = root.downloadQueue.slice(1)
        root.queuePending = root.downloadQueue.length
      }

      root.downloading = false
      root.progressActive = false
      root._downloadOutput = ""
      root._downloadError = ""

      if (exitCode !== 0) {
        root.lastError = root.elide(stderr || stdout || ("Could not download " + finishedItem))
      }

      root.refresh()
      root.processQueue()
    }
  }

  Process {
    id: syncProcess
    running: false
    command: []
    stdout: StdioCollector { id: syncStdout; waitForEnd: true; onStreamFinished: root._syncOutput = text }
    stderr: StdioCollector { id: syncStderr; waitForEnd: true; onStreamFinished: root._syncError = text }
    onExited: function(exitCode) {
      var stdout = String(syncStdout.text || root._syncOutput || "")
      var stderr = String(syncStderr.text || root._syncError || "")
      root.syncing = false
      root.activity = "none"
      root.activityName = ""
      root.status = "idle"

      if (exitCode === 0) {
        var parsed = Model.parseStatus(stdout)
        root.lastOk = parsed.ok === true
        root.lastRun = String(parsed.lastRun || "")
        root.notifyDone(parsed.ok === true, parsed.error || "")
        if (parsed.ok !== true) root.lastError = root.elide(parsed.error || stderr || "Sync failed")
      } else {
        root.status = "error"
        root.statusText = "Sync error"
        root.lastError = root.elide(stderr || stdout || "Sync failed")
        root.notifyDone(false, root.lastError)
      }

      root._syncOutput = ""
      root._syncError = ""
      root.refresh()
      root.processQueue()
    }
  }

  Timer {
    id: pollTimer
    interval: root.pollIntervalSec * 1000
    repeat: true
    triggeredOnStart: false
    onTriggered: root.refreshList()
  }

  // Actualiza el progreso en vivo (~1s) mientras descarga o sincroniza
  Timer {
    id: progressTimer
    interval: 1000
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (root.syncing || root.downloading || root.progressActive) root.refreshStatus()
      else stop()
    }
  }

  onSyncingChanged: { if (syncing) progressTimer.start(); }
  onDownloadingChanged: { if (downloading) progressTimer.start(); }
}
