import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "marcuspelo.omarqui"
  ipcTarget: "marcuspelo.omarqui"

  readonly property string baseUrl: {
    var v = settings ? settings.baseUrl : undefined
    return (typeof v === "string" && v.length > 0) ? v : "http://localhost:7476"
  }
  readonly property int pollInterval: {
    var v = settings ? settings.refreshIntervalSec : undefined
    return (typeof v === "number" && v >= 5) ? v : 10
  }

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.45)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : "JetBrainsMono Nerd Font"
  readonly property string barIcon: "󰇚"

  property string apiKey: ""
  property bool apiKeyLoaded: false
  property var stats: ({})
  property var instances: []
  property bool loading: false
  property bool hasError: false
  property string errorText: ""

  property var rawTorrents: []
  property bool torrentsLoading: false
  property string searchQuery: ""
  property int selectedInstanceId: -1
  property string statusFilter: ""
  property string actionInProgress: ""
  property string confirmDeleteHash: ""

  property var torrents: {
    var list = root.rawTorrents
    if (root.selectedInstanceId !== -1)
      list = list.filter(function(t) { return t.instance_id === root.selectedInstanceId })
    if (root.statusFilter)
      list = list.filter(function(t) { return root.matchesStatusFilter(t.state, root.statusFilter) })
    return list
  }

  property string viewMode: "list"
  property var categories: []
  property int addInstanceId: -1
  property string addCategory: ""
  property string addSource: ""
  property bool addPaused: false
  property bool addSubmitting: false
  property string addStatusText: ""
  property bool addStatusError: false

  property string draftBaseUrl: ""
  property int draftRefreshIntervalSec: 10
  property string settingsStatusText: ""

  function formatSpeed(bytesPerSec) {
    var v = Number(bytesPerSec) || 0
    if (v < 1024) return v.toFixed(0) + " B/s"
    if (v < 1024 * 1024) return (v / 1024).toFixed(0) + " K/s"
    return (v / 1024 / 1024).toFixed(1) + " M/s"
  }

  function formatBytes(bytes) {
    var v = Number(bytes) || 0
    if (v < 1024) return v.toFixed(0) + " B"
    if (v < 1024 * 1024) return (v / 1024).toFixed(0) + " KB"
    if (v < 1024 * 1024 * 1024) return (v / 1024 / 1024).toFixed(1) + " MB"
    return (v / 1024 / 1024 / 1024).toFixed(1) + " GB"
  }

  function stateLabel(state) {
    var s = String(state || "")
    if (s.indexOf("error") !== -1 || s === "missingFiles" || s === "unknown") return "error"
    if (s.indexOf("checking") !== -1) return "checking"
    if (s.indexOf("paused") === 0 || s.indexOf("stopped") === 0) return "paused"
    if (s === "downloading" || s.indexOf("DL") !== -1 || s === "allocating" || s === "metaDL") return "downloading"
    if (s === "uploading" || s.indexOf("UP") !== -1) return "seeding"
    return s || "—"
  }

  function stateColor(state) {
    var s = String(state || "")
    if (s.indexOf("error") !== -1 || s === "missingFiles" || s === "unknown") return Color.urgent
    if (s.indexOf("paused") === 0 || s.indexOf("stopped") === 0) return root.dim
    if (s === "downloading" || s.indexOf("DL") !== -1 || s === "allocating" || s === "metaDL") return "#7aa2f7"
    if (s === "uploading" || s.indexOf("UP") !== -1) return "#8fd694"
    return root.dim
  }

  function isPaused(state) {
    var s = String(state || "")
    return s.indexOf("paused") === 0 || s.indexOf("stopped") === 0
  }

  function matchesStatusFilter(state, filter) {
    var s = String(state || "")
    if (filter === "downloading") return s === "downloading" || s.indexOf("DL") !== -1 || s === "allocating" || s === "metaDL"
    if (filter === "seeding") return s === "uploading" || s.indexOf("UP") !== -1
    if (filter === "paused") return s.indexOf("paused") === 0 || s.indexOf("stopped") === 0
    if (filter === "error") return s.indexOf("error") !== -1 || s === "missingFiles" || s === "unknown"
    return true
  }

  function toggleStatusFilter(key) {
    root.statusFilter = root.statusFilter === key ? "" : key
  }

  function parseEnv(raw) {
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line || line.indexOf("#") === 0) continue
      var eq = line.indexOf("=")
      if (eq < 0) continue
      var key = line.substring(0, eq).trim()
      var value = line.substring(eq + 1).trim().replace(/^["']|["']$/g, "")
      if (key === "API_KEY") root.apiKey = value
    }
    apiKeyLoaded = true
  }

  function refresh() {
    if (!apiKeyLoaded) return
    if (!apiKey) {
      hasError = true
      errorText = "API key not configured in .env"
      return
    }
    if (!statsProc.running) {
      loading = true
      statsProc.command = ["curl", "-fsS", "--max-time", "6",
        "-H", "X-API-Key: " + apiKey,
        root.baseUrl + "/api/torrents/cross-instance?limit=1"]
      statsProc.running = true
    }
    if (!instancesProc.running) {
      instancesProc.command = ["curl", "-fsS", "--max-time", "6",
        "-H", "X-API-Key: " + apiKey,
        root.baseUrl + "/api/instances"]
      instancesProc.running = true
    }
  }

  function handleStats(raw) {
    loading = false
    try {
      var data = JSON.parse(String(raw || ""))
      stats = data.stats || {}
      hasError = false
      errorText = ""
    } catch (e) {
      hasError = true
      errorText = "Failed to read Qui response"
    }
  }

  function handleInstances(raw) {
    try {
      instances = JSON.parse(String(raw || "")) || []
    } catch (e) {
      instances = []
    }
  }

  function fetchTorrents() {
    if (!apiKey || torrentsProc.running) return
    torrentsLoading = true
    var url = root.baseUrl + "/api/torrents/cross-instance?limit=500&sort=added_on&order=desc"
    if (searchQuery) url += "&search=" + encodeURIComponent(searchQuery)
    torrentsProc.command = ["curl", "-fsS", "--max-time", "8",
      "-H", "X-API-Key: " + apiKey, url]
    torrentsProc.running = true
  }

  function handleTorrents(raw) {
    torrentsLoading = false
    try {
      var data = JSON.parse(String(raw || ""))
      rawTorrents = data.cross_instance_torrents || []
    } catch (e) {
      rawTorrents = []
    }
  }

  function selectInstance(id) {
    root.selectedInstanceId = id
    root.fetchTorrents()
  }

  function torrentAction(torrent, action) {
    if (!torrent || actionProc.running) return
    root.actionInProgress = torrent.hash + ":" + action
    actionProc.command = ["curl", "-fsS", "--max-time", "8", "-X", "POST",
      "-H", "X-API-Key: " + root.apiKey,
      "-H", "Content-Type: application/json",
      "-d", JSON.stringify({ action: action, hashes: [torrent.hash] }),
      root.baseUrl + "/api/instances/" + torrent.instance_id + "/torrents/bulk-action"]
    actionProc.running = true
  }

  function triggerPress(button) {
    if (button === Qt.MiddleButton) { refresh(); return }
    if (opened) close(); else { open(); refresh() }
  }

  function openAddView() {
    root.viewMode = "add"
    root.addStatusText = ""
    root.addStatusError = false
    if (root.addInstanceId === -1 && root.instances.length > 0)
      root.addInstanceId = root.instances[0].id
    if (root.addInstanceId !== -1) root.fetchCategories(root.addInstanceId)
  }

  function closeAddView() {
    root.viewMode = "list"
  }

  function openSettingsView() {
    root.viewMode = "settings"
    root.draftBaseUrl = root.baseUrl
    root.draftRefreshIntervalSec = root.pollInterval
    root.settingsStatusText = ""
  }

  function closeSettingsView() {
    root.viewMode = "list"
  }

  function canPersistSettings() {
    return !!(root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
  }

  function saveSettings() {
    var url = String(root.draftBaseUrl || "").trim()
    if (!url) url = "http://localhost:7476"
    var interval = Math.max(5, Math.min(300, Math.round(Number(root.draftRefreshIntervalSec) || 10)))
    var next = { baseUrl: url, refreshIntervalSec: interval }

    root.draftBaseUrl = url
    root.settings = next

    if (root.canPersistSettings()) {
      root.bar.shell.updateEntryInline(root.moduleName, next)
      root.settingsStatusText = "Saved"
    } else {
      root.settingsStatusText = "Saved for this session only (bar unavailable)"
    }

    root.hasError = false
    root.errorText = ""
    root.refresh()
    root.fetchTorrents()
  }

  function selectAddInstance(id) {
    root.addInstanceId = id
    root.addCategory = ""
    root.fetchCategories(id)
  }

  function fetchCategories(instanceId) {
    if (!apiKey || categoriesProc.running) return
    categoriesProc.command = ["curl", "-fsS", "--max-time", "6",
      "-H", "X-API-Key: " + apiKey,
      root.baseUrl + "/api/instances/" + instanceId + "/categories"]
    categoriesProc.running = true
  }

  function handleCategories(raw) {
    try {
      var data = JSON.parse(String(raw || "")) || {}
      categories = Object.keys(data).sort()
    } catch (e) {
      categories = []
    }
  }

  function submitAddTorrent() {
    if (addTorrentProc.running) return
    var src = String(root.addSource || "").trim()
    if (!src) {
      root.addStatusError = true
      root.addStatusText = "Paste a magnet link or provide the path to a .torrent file"
      return
    }
    if (root.addInstanceId === -1) {
      root.addStatusError = true
      root.addStatusText = "Choose an instance"
      return
    }
    root.addSubmitting = true
    root.addStatusError = false
    root.addStatusText = ""

    var args = ["curl", "-s", "--max-time", "20", "-X", "POST",
      "-H", "X-API-Key: " + root.apiKey,
      "-F", "paused=" + (root.addPaused ? "true" : "false")]
    if (root.addCategory) args = args.concat(["-F", "category=" + root.addCategory])

    var isRemote = src.indexOf("magnet:") === 0 || src.indexOf("http://") === 0 || src.indexOf("https://") === 0
    if (isRemote) {
      args = args.concat(["-F", "urls=" + src])
    } else {
      var path = src.indexOf("~/") === 0 ? (Quickshell.env("HOME") + src.substring(1)) : src
      args = args.concat(["-F", "torrent=@" + path + ";type=application/x-bittorrent"])
    }
    args = args.concat(["-w", "\n---HTTP:%{http_code}",
      root.baseUrl + "/api/instances/" + root.addInstanceId + "/torrents"])

    addTorrentProc.command = args
    addTorrentProc.running = true
  }

  function handleAddTorrentResult(raw) {
    root.addSubmitting = false
    var text = String(raw || "")
    var marker = text.lastIndexOf("\n---HTTP:")
    var status = 0
    var body = text
    if (marker !== -1) {
      status = parseInt(text.substring(marker + 9)) || 0
      body = text.substring(0, marker)
    }
    if (status >= 200 && status < 300) {
      root.addStatusError = false
      root.addStatusText = "Torrent added!"
      root.addSource = ""
      root.refresh()
      root.fetchTorrents()
      addSuccessTimer.restart()
    } else {
      root.addStatusError = true
      var msg = body.trim()
      try {
        var parsed = JSON.parse(body)
        msg = parsed.error || parsed.message || msg
      } catch (e) {}
      root.addStatusText = msg || ("Failed to add torrent (HTTP " + status + ")")
    }
  }

  component StatChip: Text {
    id: chip
    property string filterKey: ""
    property string label: ""
    property int count: 0

    text: count + " " + label
    color: root.statusFilter === filterKey ? Color.accent : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.underline: root.statusFilter === filterKey

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleStatusFilter(chip.filterKey)
    }
  }

  FileView {
    id: envFile
    path: Quickshell.env("HOME") + "/.config/omarqui/.env"
    watchChanges: true
    printErrors: false
    onLoaded: root.parseEnv(text())
    onLoadFailed: {
      root.apiKeyLoaded = true
      root.hasError = true
      root.errorText = "~/.config/omarqui/.env not found (see README)"
    }
  }

  Process {
    id: statsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleStats(text)
    }
    onExited: function(code) {
      if (code !== 0) {
        root.loading = false
        root.hasError = true
        root.errorText = "Qui unavailable at " + root.baseUrl
      }
    }
  }

  Process {
    id: instancesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleInstances(text)
    }
  }

  Process {
    id: torrentsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleTorrents(text)
    }
    onExited: function(code) {
      if (code !== 0) root.torrentsLoading = false
    }
  }

  Process {
    id: actionProc
    onExited: function(code) {
      root.actionInProgress = ""
      root.confirmDeleteHash = ""
      if (code === 0) {
        actionRefreshTimer.restart()
        actionRefreshTimer2.restart()
      }
    }
  }

  // qBittorrent/Qui take a moment to actually apply pause/resume/delete
  // before it shows up in the torrent list, so a single quick refetch
  // right after the request often still reads the old state. Refetch
  // twice: once past the typical ~1.5-2s lag, and once more as a safety
  // net for slower instances.
  Timer {
    id: actionRefreshTimer
    interval: 2000
    onTriggered: {
      root.fetchTorrents()
      root.refresh()
    }
  }

  Timer {
    id: actionRefreshTimer2
    interval: 4000
    onTriggered: {
      root.fetchTorrents()
      root.refresh()
    }
  }

  Process {
    id: categoriesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleCategories(text)
    }
  }

  Process {
    id: addTorrentProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleAddTorrentResult(text)
    }
    onExited: function(code) {
      if (code !== 0) {
        root.addSubmitting = false
        root.addStatusError = true
        if (!root.addStatusText) root.addStatusText = "Failed to connect to Qui"
      }
    }
  }

  Timer {
    id: addSuccessTimer
    interval: 1200
    onTriggered: root.viewMode = "list"
  }

  Timer {
    id: pollTimer
    interval: root.pollInterval * 1000
    running: root.apiKeyLoaded
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.refresh()
      if (root.opened) root.fetchTorrents()
    }
  }

  Timer {
    id: searchDebounce
    interval: 400
    onTriggered: root.fetchTorrents()
  }

  onOpenedChanged: {
    if (opened) {
      root.viewMode = "list"
      root.fetchTorrents()
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.hasError
      ? root.barIcon + " !"
      : root.barIcon + " " + root.formatSpeed(root.stats.totalDownloadSpeed)
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(78)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    tooltipText: root.hasError
      ? root.errorText
      : ("↓ " + root.formatSpeed(root.stats.totalDownloadSpeed)
        + "   ↑ " + root.formatSpeed(root.stats.totalUploadSpeed)
        + "\n" + (root.stats.downloading || 0) + " downloading · "
        + (root.stats.seeding || 0) + " seeding")
    onPressed: function(b) { root.triggerPress(b) }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus || sourceField.activeFocus || baseUrlField.activeFocus
      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "r" || t === "R") { root.refresh(); root.fetchTorrents() }
      }

      ColumnLayout {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        RowLayout {
          Layout.fillWidth: true
          spacing: 8

          Text {
            text: root.barIcon + "  " + (root.viewMode === "add" ? "Add torrent" : root.viewMode === "settings" ? "Settings" : "Qui Torrents")
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            Layout.fillWidth: true
          }

          Button {
            visible: root.viewMode === "list"
            text: "+ Add"
            foreground: root.fg
            accent: Color.accent
            tooltipText: "Add a new torrent"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.openAddView()
          }

          Button {
            visible: root.viewMode === "list"
            text: (root.loading || root.torrentsLoading) ? "Refreshing…" : "Refresh"
            foreground: root.fg
            tooltipText: "Refresh now"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            active: root.loading || root.torrentsLoading
            onClicked: { root.refresh(); root.fetchTorrents() }
          }

          Button {
            visible: root.viewMode === "list"
            text: "⚙"
            foreground: root.fg
            tooltipText: "Settings"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.openSettingsView()
          }

          Button {
            visible: root.viewMode === "add" || root.viewMode === "settings"
            text: "Back"
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.viewMode === "settings" ? root.closeSettingsView() : root.closeAddView()
          }
        }

        ColumnLayout {
          visible: root.viewMode === "settings"
          Layout.fillWidth: true
          spacing: Style.space(10)

          Text {
            text: "Qui base URL"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          TextField {
            id: baseUrlField
            Layout.fillWidth: true
            placeholderText: "http://localhost:7476"
            foreground: root.fg
            text: root.draftBaseUrl
            onTextChanged: root.draftBaseUrl = text
          }

          NumberField {
            label: "Refresh interval (seconds)"
            value: root.draftRefreshIntervalSec
            from: 5
            to: 300
            stepSize: 5
            foreground: root.fg
            accent: Color.accent
            fontFamily: root.fontFamily
            onModified: function(v) { root.draftRefreshIntervalSec = v }
          }

          Text {
            visible: root.settingsStatusText !== ""
            Layout.fillWidth: true
            text: root.settingsStatusText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Button {
            text: "Save"
            foreground: root.fg
            accent: Color.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.saveSettings()
          }

          Text {
            Layout.fillWidth: true
            text: "The API key stays in ~/.config/omarqui/.env and is not editable here."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        ColumnLayout {
          visible: root.viewMode === "add"
          Layout.fillWidth: true
          spacing: Style.space(10)

          Text {
            text: "Instance"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Flow {
            Layout.fillWidth: true
            spacing: 6

            Repeater {
              model: root.instances
              delegate: Button {
                required property var modelData
                text: modelData.name
                foreground: root.fg
                accent: Color.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                selected: root.addInstanceId === modelData.id
                onClicked: root.selectAddInstance(modelData.id)
              }
            }
          }

          Dropdown {
            Layout.fillWidth: true
            label: "Category"
            value: root.addCategory
            options: [{ value: "", label: "No category" }].concat(root.categories)
            foreground: root.fg
            accent: Color.accent
            fontFamily: root.fontFamily
            onChanged: function(v) { root.addCategory = v }
          }

          TextField {
            id: sourceField
            Layout.fillWidth: true
            placeholderText: "magnet:?xt=... or ~/Downloads/file.torrent"
            foreground: root.fg
            text: root.addSource
            onTextChanged: root.addSource = text
          }

          RowLayout {
            spacing: 8
            ToggleSwitch {
              foreground: root.fg
              accent: Color.accent
              checked: root.addPaused
              onToggled: root.addPaused = !root.addPaused
            }
            Text {
              text: "Start paused"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            visible: root.addStatusText !== ""
            Layout.fillWidth: true
            text: root.addStatusText
            color: root.addStatusError ? Color.urgent : "#8fd694"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Button {
            text: root.addSubmitting ? "Adding…" : "Add torrent"
            foreground: root.fg
            accent: Color.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            active: root.addSubmitting
            onClicked: root.submitAddTorrent()
          }

          Text {
            Layout.fillWidth: true
            text: "Paste a magnet link, or provide the path to a local .torrent file (e.g. ~/Downloads/name.torrent)."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        Text {
          visible: root.hasError && root.viewMode === "list"
          text: root.errorText
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          Layout.fillWidth: true
        }

        RowLayout {
          visible: !root.hasError && root.viewMode === "list"
          Layout.fillWidth: true
          spacing: Style.space(24)

          ColumnLayout {
            spacing: 2
            Text {
              text: root.formatSpeed(root.stats.totalDownloadSpeed)
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }
            Text {
              text: "download"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          ColumnLayout {
            spacing: 2
            Text {
              text: root.formatSpeed(root.stats.totalUploadSpeed)
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }
            Text {
              text: "upload"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        RowLayout {
          visible: !root.hasError && root.viewMode === "list"
          Layout.fillWidth: true
          spacing: 4

          StatChip { filterKey: "downloading"; label: "downloading"; count: root.stats.downloading || 0 }
          Text { text: "·"; color: root.dim; font.pixelSize: Style.font.caption }
          StatChip { filterKey: "seeding"; label: "seeding"; count: root.stats.seeding || 0 }
          Text { text: "·"; color: root.dim; font.pixelSize: Style.font.caption }
          StatChip { filterKey: "paused"; label: "paused"; count: root.stats.paused || 0 }
          Text {
            visible: (root.stats.error || 0) > 0 || root.statusFilter === "error"
            text: "·"
            color: root.dim
            font.pixelSize: Style.font.caption
          }
          StatChip {
            visible: (root.stats.error || 0) > 0 || root.statusFilter === "error"
            filterKey: "error"
            label: "errored"
            count: root.stats.error || 0
          }
          Item { Layout.fillWidth: true }
        }

        Flow {
          visible: !root.hasError && root.viewMode === "list"
          Layout.fillWidth: true
          Layout.topMargin: 4
          spacing: 6

          Button {
            text: "All"
            foreground: root.fg
            accent: Color.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            selected: root.selectedInstanceId === -1
            onClicked: root.selectInstance(-1)
          }

          Repeater {
            model: root.instances
            delegate: Button {
              required property var modelData
              text: (modelData.connected ? "● " : "○ ") + modelData.name
              foreground: modelData.connected ? root.fg : Color.urgent
              accent: Color.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              selected: root.selectedInstanceId === modelData.id
              onClicked: root.selectInstance(modelData.id)
            }
          }
        }

        TextField {
          id: searchField
          visible: root.viewMode === "list"
          Layout.fillWidth: true
          placeholderText: "Search torrents…"
          foreground: root.fg
          text: root.searchQuery
          onTextChanged: { root.searchQuery = text; searchDebounce.restart() }
          Keys.onEscapePressed: text = ""
        }

        Text {
          visible: root.viewMode === "list" && !root.torrentsLoading && root.torrents.length === 0
          Layout.fillWidth: true
          Layout.topMargin: 8
          horizontalAlignment: Text.AlignHCenter
          text: root.rawTorrents.length === 0 ? "No torrents found" : "No torrents match the filter"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        ListView {
          id: torrentList
          visible: root.viewMode === "list" && root.torrents.length > 0
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(360)
          clip: true
          spacing: Style.space(8)
          model: root.torrents
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          delegate: ColumnLayout {
            id: row
            required property var modelData
            width: torrentList.width
            height: implicitHeight
            spacing: 3

            readonly property bool confirming: root.confirmDeleteHash === modelData.hash
            readonly property bool busy: root.actionInProgress.indexOf(modelData.hash + ":") === 0

            Text {
              Layout.fillWidth: true
              text: row.modelData.name
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              elide: Text.ElideRight
            }

            Rectangle {
              Layout.fillWidth: true
              height: 4
              radius: 2
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.15)

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: parent.width * Math.max(0, Math.min(1, row.modelData.progress || 0))
                radius: 2
                color: root.stateColor(row.modelData.state)
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: 6

              Text {
                text: root.stateLabel(row.modelData.state) + " · "
                  + Math.round((row.modelData.progress || 0) * 100) + "% · "
                  + root.formatBytes(row.modelData.size)
                  + (row.modelData.dlspeed > 0 ? " · ↓" + root.formatSpeed(row.modelData.dlspeed) : "")
                  + (row.modelData.upspeed > 0 ? " · ↑" + root.formatSpeed(row.modelData.upspeed) : "")
                color: root.stateColor(row.modelData.state)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                Layout.fillWidth: true
              }

              RowLayout {
                visible: !row.confirming
                spacing: 4

                Button {
                  text: row.busy ? "…" : (root.isPaused(row.modelData.state) ? "Resume" : "Pause")
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: {
                    if (row.busy) return
                    root.torrentAction(row.modelData, root.isPaused(row.modelData.state) ? "resume" : "pause")
                  }
                }

                Button {
                  text: "Delete"
                  foreground: Color.urgent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: { if (!row.busy) root.confirmDeleteHash = row.modelData.hash }
                }
              }

              RowLayout {
                visible: row.confirming
                spacing: 4

                Text {
                  text: "Delete:"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Button {
                  text: "keep files"
                  foreground: Color.urgent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: root.torrentAction(row.modelData, "delete")
                }
                Button {
                  text: "+ files"
                  foreground: Color.urgent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: root.torrentAction(row.modelData, "deleteWithFiles")
                }
                Button {
                  text: "cancel"
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: root.confirmDeleteHash = ""
                }
              }
            }
          }
        }

        Text {
          Layout.fillWidth: true
          Layout.topMargin: 4
          text: "r refresh · esc close"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
