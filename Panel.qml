import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Prayer times for one place: a signed counter in the bar, and a panel with
// the current prayer, today's Starts / Jamaat / Ends, the last 30 days and a
// settings page. Times are calculated locally in Model.js. The only network
// use is finding the place: geo.omarchy.org (Automatic) and the Open-Meteo
// city search, the same services Omarchy's weather widget uses.
//
// Look and spacing come from the shell: Style.spacing / Style.font tokens,
// Commons.Color and the qs.Ui kit, so themes and `omarchy font set` apply.
Panel {
  id: root
  moduleName: "abdulroufsidhu.awqat"
  ipcTarget: "abdulroufsidhu.awqat"
  manageIpc: false

  // omarchy-shell abdulroufsidhu.awqat open|close|toggle|settings|record <status>|stopAzan
  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function settings(): void { root.open(); Qt.callLater(function() { root.settingsOpen = true }) }
    function record(status: string): void { if (Model.STATUSES.indexOf(status) >= 0) root.record(status) }
    function stopAzan(): void { root.stopAzan() }
  }

  // ---- Look ----------------------------------------------------------------
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Commons.Color.muted
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false

  // ---- Settings --------------------------------------------------------------
  readonly property bool autoLocation: String(setting("location", "auto")) !== "manual"
  readonly property var manualPlace: Model.parsePlace(setting("place", null))
  readonly property string zoneSetting: {
    var v = String(setting("timezone", "auto") || "auto")
    return Model.validZoneId(v) ? v : "auto"
  }
  readonly property var opts: ({
    method: Model.METHODS[setting("method", "Makkah")] ? String(setting("method", "Makkah")) : "Makkah",
    asr: String(setting("asr", "Standard")) === "Hanafi" ? "Hanafi" : "Standard"
  })
  readonly property int hijriOffset: clampInt(setting("hijriOffset", 0), -2, 2, 0)
  readonly property bool hour24: setting("hour24", true) !== false
  readonly property bool notify: setting("notify", true) !== false
  readonly property var azanFor: {
    var v = setting("azanFor", null)
    var list = Array.isArray(v) ? v.filter(function(k) { return Model.PRAYERS.indexOf(k) >= 0 }) : Model.PRAYERS
    var out = {}
    for (var i = 0; i < list.length; i++) out[list[i]] = true
    return out
  }
  readonly property int azanMaxMinutes: clampInt(setting("azanMaxMinutes", 30), 0, 120, 30)
  readonly property var jamaatSettings: {
    var v = setting("jamaat", null)
    return v && typeof v === "object" && !Array.isArray(v) ? v : ({})
  }
  readonly property var rules: Model.jamaatRules(jamaatSettings)
  readonly property bool hasJamaat: Object.keys(rules).length > 0
  readonly property int jamaatLead: clampInt(setting("jamaatLead", 20), 5, 60, 20)
  readonly property bool checkIn: setting("checkIn", true) !== false
  readonly property int checkInLead: clampInt(setting("checkInLead", 15), 5, 60, 15)
  readonly property string barShows: {
    var v = String(setting("barShows", "Counter"))
    return v === "Next" || v === "Both" ? v : "Counter"
  }

  function clampInt(v, lo, hi, fallback) {
    var n = Number(v)
    return typeof v !== "boolean" && isFinite(n) ? Math.max(lo, Math.min(hi, Math.round(n))) : fallback
  }

  // Written straight back to this widget's shell.json entry. undefined removes a key.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) {
      if (values[key] === undefined) delete entry[key]
      else entry[key] = values[key]
    }
    // Settings from before 2.0 (several cities, a "soon" reminder) go.
    delete entry.cities; delete entry.alarmCity; delete entry.notifyBefore
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // ---- Paths -----------------------------------------------------------------
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string scriptPath: pluginDir + "/azan.sh"
  readonly property string historyScript: pluginDir + "/history.sh"
  readonly property string historyPath:
    (Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")) + "/abdulroufsidhu.awqat/history.json"

  // A sound path from settings, "~" expanded; empty or malformed falls back
  // to the bundled recording. It only ever travels as one argv entry.
  function soundPath(key, bundled) {
    var v = String(setting(key, "") || "").trim()
    if (v.indexOf("~/") === 0) v = Quickshell.env("HOME") + v.slice(1)
    if (v === "" || v.length > 4096 || /[\u0000-\u001f]/.test(v) || v.charAt(0) !== "/") return pluginDir + "/sounds/" + bundled
    return v
  }

  // ---- Place and time zone -----------------------------------------------------
  // Automatic: geo.omarchy.org's answer, kept in settings as `detected` so it
  // survives restarts and works offline; until the first answer, the system
  // time zone's reference city. Manual: a city picked in settings.
  readonly property var detectedPlace: Model.parsePlace(setting("detected", null))
  property string systemZoneId: ""
  property var zoneTab: ({ ids: [], coords: {} })
  readonly property var basePlace: {
    if (!autoLocation && manualPlace) return manualPlace
    if (detectedPlace) return detectedPlace
    var z = Model.zonePlace(zoneTab, systemZoneId)
    return z || { name: "Makkah", lat: 21.4225, lon: 39.8262, zone: "Asia/Riyadh", approximate: true }
  }
  readonly property bool approximate: basePlace.approximate === true
  readonly property string zoneId: zoneSetting !== "auto" ? zoneSetting
    : (basePlace.zone || systemZoneId || "UTC")

  // The zone's offsets, from zdump. Until they arrive the system's current
  // offset stands in (right for the system zone, and replaced in moments).
  property var zoneTable: null
  readonly property bool zoneReady: zoneTable !== null && zoneTable.id === zoneId
  readonly property var place: ({
    name: basePlace.name, lat: basePlace.lat, lon: basePlace.lon,
    zone: zoneReady ? zoneTable : Model.fixedZone(-new Date().getTimezoneOffset() / 60, zoneId)
  })

  onZoneIdChanged: loadZone()
  function loadZone() {
    if (!Model.validZoneId(zoneId)) return
    var y = new Date().getFullYear()
    zoneProc.want = zoneId
    zoneProc.command = ["zdump", "-i", "-c", (y - 1) + "," + (y + 3), zoneId]
    zoneProc.running = true
  }
  Process {
    id: zoneProc
    property string want: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var z = Model.parseZoneDump(text, zoneProc.want)
        if (z && z.id === root.zoneId) root.zoneTable = z
      }
    }
  }

  Process {
    id: systemZoneProc
    command: ["readlink", "-f", "/etc/localtime"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var id = String(text || "").trim().replace(/^.*\/zoneinfo\//, "")
        if (Model.validZoneId(id) && id !== root.systemZoneId) {
          var first = root.systemZoneId === ""
          root.systemZoneId = id
          // A new system zone usually means travel: look again.
          if (!first) root.detectLocation(true)
        }
      }
    }
  }

  FileView {
    path: "/usr/share/zoneinfo/zone1970.tab"
    printErrors: false
    onLoaded: root.zoneTab = Model.parseZoneTab(text())
  }

  // geo.omarchy.org: { name, latitude, longitude, timezone } for this network.
  property real lastGeoAt: 0
  property real lastGeoTry: 0
  property bool detecting: false
  function detectLocation(force) {
    if (!autoLocation || geoProc.running) return
    var now = Date.now()
    // After an answer, again in 6 hours; after a failure, in 10 minutes.
    if (!force && lastGeoAt > 0 && now - lastGeoAt < 6 * 3600000) return
    if (!force && now - lastGeoTry < 10 * 60000) return
    lastGeoTry = now
    detecting = true
    geoProc.running = true
  }
  Process {
    id: geoProc
    command: ["curl", "-fsS", "--max-time", "5", "--max-filesize", "8192", "https://geo.omarchy.org/"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.detecting = false
        var p = Model.parsePlaceJson(text)
        if (!p) return
        root.lastGeoAt = Date.now()
        var old = root.detectedPlace
        var moved = Model.distanceKm(old, p)
        if (moved < 1 && old && old.name === p.name && old.zone === p.zone) return
        root.persistSettings({ detected: p })
        if (old && moved > 15 && root.autoLocation)
          Quickshell.execDetached(["sh", root.scriptPath, "notify", "moved-" + Date.now()].concat(
            root.common, ["-u", "low", strings.t("moved.title").arg(p.name), strings.t("moved.body")]))
    }
    }
    onExited: function(code) { if (code !== 0) root.detecting = false }
  }

  // ---- Clock and schedule --------------------------------------------------------
  property real nowMs: Date.now()
  property real lastCheck: Date.now()

  readonly property var today: Model.localDate(nowMs, place.zone)
  readonly property var todayRows: Model.dayRows(today, place, opts)
  readonly property var todayWindows: Model.windows(today, place, opts, checkInLead)
  readonly property var ph: Model.phase(nowMs, place, opts)
  readonly property var nextPrayer: Model.next(nowMs, place, opts)
  // The prayer that can be recorded now: the one whose time this is, or
  // the last that began (Fajr after sunrise).
  readonly property var recordable: Model.current(nowMs, place, opts)

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function prayerName(key, weekday) {
    return strings.t(key === "dhuhr" && weekday === 5 ? "prayer.jumuah" : "prayer." + key)
  }

  function timeText(ms) {
    if (!isFinite(ms)) return strings.t("unavailable")
    var c = Model.clock(ms, place.zone)
    var d = new Date(2000, 0, 1, c.h, c.m)
    return d.toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), root.hour24 ? "HH:mm" : "h:mm AP")
  }

  function n2(v) {
    var f = Commons.I18n.formatNumber
    return v < 10 ? f(0) + f(v) : f(v)
  }

  function counterText(withSeconds) {
    var c = Model.counter(nowMs, ph, withSeconds)
    if (!c) return strings.t("unavailable")
    var f = Commons.I18n.formatNumber
    return withSeconds ? c.sign + f(c.h) + ":" + n2(c.m) + ":" + n2(c.s) : c.sign + f(c.h) + ":" + n2(c.m)
  }

  function dateText(day, format) {
    return new Date(day.y, day.m - 1, day.d).toLocaleDateString(Qt.locale(Commons.I18n.formatLocale), format)
  }

  function hijriText(day) {
    var h = Model.hijriOf(day, hijriOffset)
    var f = Commons.I18n.formatNumber
    return strings.t("hijri").arg(f(h.day)).arg(strings.t("hijri.m" + h.month)).arg(f(h.year))
  }

  // Jamaat of a row, if set and still to come or just begun.
  function jamaatOf(row) { return Model.jamaatAt(row, rules, place.zone) }
  function windowOf(key) {
    for (var i = 0; i < todayWindows.length; i++) if (todayWindows[i].key === key) return todayWindows[i]
    return null
  }

  readonly property string barLabel: {
    var p = ph
    if (!p) return strings.t("unavailable")
    var anchorName = prayerName(p.anchor.key, p.anchor.weekday)
    var n = nextPrayer
    var nextText = n ? strings.t("bar.time").arg(prayerName(n.key, n.weekday)).arg(timeText(n.at)) : ""
    if (barShows === "Next") return nextText || strings.t("unavailable")
    // Between the azan and the jamaat the bar shows the jamaat time.
    var j = p.since ? jamaatOf(p.current) : NaN
    var counter = isFinite(j) && j > nowMs
      ? strings.t("bar.jamaat").arg(anchorName).arg(timeText(j))
      : strings.t("bar.counter").arg(anchorName).arg(counterText(false))
    if (barShows === "Counter" || !n) return counter
    return p.since || n.key !== p.anchor.key
      ? strings.t("bar.both").arg(counter).arg(nextText)
      : strings.t("bar.both").arg(counter).arg(timeText(n.at))
  }

  // ---- History ---------------------------------------------------------------
  property var history: ({ days: {} })
  property var writeQueue: []
  property int graphEnd: 0
  property var hovered: null

  property var themeColors: ({})
  readonly property color colorJamaat: Model.validHex(setting("colorJamaat", "")) || Model.hueColor(themeColors.green, 70, 170, "#5fb760")
  readonly property color colorAlone: Model.validHex(setting("colorAlone", "")) || Model.hueColor(themeColors.yellow, 40, 70, "#e0b43a")
  readonly property color colorLate: Model.validHex(setting("colorLate", "")) || Model.hueColor(themeColors.orange, 12, 40, "#e0803a")
  readonly property color colorMissed: Model.validHex(setting("colorMissed", "")) || Commons.Color.urgent

  function statusColor(status) {
    return status === "jamaat" ? colorJamaat : status === "alone" ? colorAlone : status === "late" ? colorLate
      : status === "missed" ? colorMissed : foreground
  }
  function statusLabel(status) { return strings.t("status." + (status || "none")) }

  // Whether a prayer of a day has begun (only those can be recorded).
  function started(date, key) {
    if (date < today.key) return true
    if (date > today.key) return false
    for (var i = 0; i < todayRows.length; i++) if (todayRows[i].key === key) return todayRows[i].at <= nowMs
    return false
  }

  function setStatus(date, key, status) {
    if (!started(date, key)) return
    history = Model.withStatus(history, date, key, status)
    writeQueue = writeQueue.concat([[date, key, status || "none"]])
    drainWrites()
  }
  function cycle(date, key) { setStatus(date, key, Model.nextStatus(Model.statusOf(history, date, key))) }
  // A status button: pressing the one already set clears it.
  function record(status) {
    var r = recordable
    if (!r) return
    setStatus(r.date, r.key, Model.statusOf(history, r.date, r.key) === status ? "" : status)
  }

  function drainWrites() {
    if (historyWriter.running || writeQueue.length === 0) return
    var w = writeQueue[0]
    writeQueue = writeQueue.slice(1)
    historyWriter.command = ["sh", historyScript, "set", w[0], w[1], w[2]]
    historyWriter.running = true
  }
  Process {
    id: historyWriter
    onExited: {
      if (root.writeQueue.length) root.drainWrites()
      else historyFile.reload()
    }
  }
  FileView {
    id: historyFile
    path: root.historyPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.history = Model.parseHistory(text())
    onLoadFailed: root.history = ({ days: {} })
  }

  FileView {
    id: themeColorsFile
    path: Commons.Color.currentThemePath + "/colors.toml"
    printErrors: false
    onLoaded: root.themeColors = Model.parseThemeColors(text())
  }
  Connections {
    target: Commons.Color
    function onForegroundChanged() { themeColorsFile.reload() }
    function onAccentChanged() { themeColorsFile.reload() }
    function onUrgentChanged() { themeColorsFile.reload() }
  }

  // ---- Notifications and the azan ------------------------------------------------
  // azan.sh claims a marker per event, so with one widget copy per monitor
  // only the first copy acts. Every value is passed as its own argument.
  readonly property var common: ["--app-name", "Awqat", "-g", "\u{f1827}"]
  property bool azanPlaying: false

  function playAzan(marker, key, title, body) {
    var sound = key === "fajr" ? soundPath("azanFajrSound", "azan-fajr.ogg") : soundPath("azanSound", "azan.ogg")
    Quickshell.execDetached(["sh", scriptPath, "fire", marker, sound, String(azanMaxMinutes * 60)]
      .concat(common, [title, body, "--action", strings.t("stopAzan"), "sh", scriptPath, "stop"]))
    azanPlaying = true
  }
  function plain(marker, title, body) {
    Quickshell.execDetached(["sh", scriptPath, "notify", marker].concat(common, ["-u", "normal", title, body]))
  }

  function send(ev, azanThisTick) {
    var name = prayerName(ev.key, ev.weekday)
    var marker = ev.kind + "-" + ev.key + "-" + Math.round(ev.at)
    if (ev.kind === "start") {
      var title = strings.t("notify.start.title").arg(name)
      var body = strings.t("notify.start.body").arg(name).arg(place.name).arg(timeText(ev.at))
      if (ev.azan) playAzan(marker, ev.key, title, body)
      else plain(marker, title, body)
    } else if (ev.kind === "jamaat") {
      var mins = Math.max(0, Math.round((ev.jamaat - Date.now()) / 60000))
      var jt = strings.t("notify.jamaat.title").arg(name).arg(timeText(ev.jamaat))
      var jb = strings.tn("notify.jamaat.body", mins).arg(Commons.I18n.formatNumber(mins))
      // A reminder never interrupts the azan.
      if (azanPlaying || azanThisTick) plain(marker, jt, jb)
      else playAzan(marker, ev.key, jt, jb)
    } else if (ev.kind === "began") {
      plain(marker, strings.t("notify.began.title").arg(name), strings.t("notify.began.body").arg(name).arg(timeText(ev.at)))
    }
  }

  // "Did you pray X?" with Jamaat / Alone / Late / Missed buttons.
  function sendCheckIn(c) {
    var name = prayerName(c.key, c.weekday)
    Quickshell.execDetached(["sh", scriptPath, "ask", "ask-" + c.key + "-" + Math.round(c.at), "\u{f1827}",
      strings.t("checkIn.title").arg(name), strings.t("checkIn.body").arg(name).arg(timeText(c.at)),
      c.date, c.key, statusLabel("jamaat"), statusLabel("alone"), statusLabel("late"), statusLabel("missed")])
  }

  function stopAzan() {
    Quickshell.execDetached(["sh", scriptPath, "stop"])
    azanPlaying = false
  }

  Process {
    id: statusProbe
    command: ["sh", root.scriptPath, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.azanPlaying = String(text || "").indexOf("playing") === 0
    }
  }

  // Polls often only while the azan plays, so the bar flips back when it ends.
  // Also re-reads history (history.sh replaces the file, which a watch can
  // miss) and the system zone, and looks the place up again when it's time.
  Timer {
    interval: root.azanPlaying ? 2000 : 30000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      if (!statusProbe.running) statusProbe.running = true
      if (!historyWriter.running) historyFile.reload()
      if (!systemZoneProc.running) systemZoneProc.running = true
      root.detectLocation(false)
    }
  }

  function tick() {
    var now = Date.now()
    // Back from sleep, maybe on another network: look the place up again.
    if (now - lastCheck > 120000) detectLocation(true)
    if (new Date(now).getFullYear() !== new Date(lastCheck).getFullYear()) loadZone()
    if (zoneReady) {
      if (notify) {
        var events = Model.due(lastCheck, now, place, opts,
          { azan: azanFor, rules: rules, jamaatLead: jamaatLead })
        var azanNow = events.some(function(e) { return e.kind === "start" && e.azan })
        for (var i = 0; i < events.length; i++) send(events[i], azanNow && events[i].kind === "jamaat")
      }
      if (checkIn) {
        var asks = Model.checkIns(lastCheck, now, place, opts, checkInLead)
        for (var j = 0; j < asks.length; j++)
          if (Model.statusOf(history, asks[j].date, asks[j].key) === "") sendCheckIn(asks[j])
      }
      lastCheck = now
    }
    nowMs = now
  }

  Timer {
    interval: root.opened ? 1000 : 10000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.tick()
  }

  Component.onCompleted: loadZone()

  // ---- Panel state -----------------------------------------------------------
  property bool settingsOpen: false
  property int statusCursor: -1
  property int editors: 0          // text fields or popups holding the keyboard

  onOpenedChanged: if (opened) {
    settingsOpen = false
    statusCursor = -1
    graphEnd = 0
    historyFile.reload()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Widest label for the current mode, so the slot doesn't jitter as minutes tick.
  TextMetrics {
    id: labelMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.bar.iconFont
    text: {
      var name = strings.t("prayer.maghrib")
      var t = root.hour24 ? "88:88" : "88:88 PM"
      var c = strings.t("bar.counter").arg(name).arg("−88:88")
      var j = strings.t("bar.jamaat").arg(name).arg(t)
      var widest = j.length > c.length ? j : c
      var next = strings.t("bar.time").arg(name).arg(t)
      if (root.barShows === "Next") return next
      if (root.barShows === "Counter") return widest
      return strings.t("bar.both").arg(widest).arg(next)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.azanPlaying ? "\u{f009e}" : "\u{f1827}"
    labelText: root.vertical ? "" : root.azanPlaying ? strings.t("stopAzan") : root.barLabel
    slotSize: root.vertical ? Style.bar.iconSlot
      : Math.ceil(labelMetrics.advanceWidth + button.canvasSize + Style.spacing.xxl)
    active: root.azanPlaying
    tooltipText: root.azanPlaying ? strings.t("azanPlaying") : root.vertical ? root.barLabel : ""
    // While the azan plays, a click on the widget silences it, like an alarm.
    onPressed: function(b) { if (root.azanPlaying) root.stopAzan(); else root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(root.settingsOpen ? settingsView.implicitHeight : mainView.implicitHeight, Style.space(820))

    PanelKeyCatcher {
      id: keyCatcher
      objectName: "prayerContent"
      anchors.fill: parent
      blocked: root.editors > 0
      onMoveRequested: function(dx, dy) {
        if (root.settingsOpen) { settingsFlick.scrollBy(dy); return }
        var step = LayoutMirroring.enabled ? -dx : dx
        root.statusCursor = root.statusCursor < 0 ? 0 : Math.max(0, Math.min(3, root.statusCursor + step))
      }
      onActivateRequested: if (!root.settingsOpen && root.statusCursor >= 0) root.record(Model.STATUSES[root.statusCursor])
      onCloseRequested: if (root.settingsOpen) root.settingsOpen = false; else root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = t.toLowerCase()
        if (k === "," ) root.settingsOpen = !root.settingsOpen
        else if (k === "n") root.persistSettings({ notify: !root.notify })
        else if (k === "s" && root.azanPlaying) root.stopAzan()
        else if (k === "r") root.detectLocation(true)
      }

      // ================================================================ main
      Column {
        id: mainView
        visible: !root.settingsOpen
        width: parent.width
        spacing: Style.spacing.panelGap

        // Hero: what time it is now, the counter, and recording it.
        Column {
          width: parent.width
          spacing: Style.spacing.rowGap

          PanelHero {
            width: parent.width
            foreground: root.foreground
            fontFamily: root.fontFamily
            title: root.ph ? root.prayerName(root.ph.current.key, root.ph.current.weekday) : strings.t("title")
            meta: strings.t("hero.meta").arg(root.dateText(root.today, "ddd d MMM")).arg(root.hijriText(root.today))
            detail: {
              var r = root.ph && root.ph.since ? root.ph.current : null
              var j = r ? root.jamaatOf(r) : NaN
              return isFinite(j) ? strings.t("jamaatAt").arg(root.timeText(j)) : ""
            }
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "\u{f1827}"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.spacing.xs
                PanelActionButton {
                  iconText: root.notify ? "\u{f009a}" : "\u{f009b}"
                  tooltipText: root.notify ? strings.t("notifyOn") : strings.t("notifyOff")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.persistSettings({ notify: !root.notify })
                }
                PanelActionButton {
                  iconText: "\u{f0493}"
                  tooltipText: strings.t("settings.open")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.settingsOpen = true
                }
              }
            }
          }

          // The counter: + since the current prayer, − to the next time.
          Item {
            width: parent.width
            height: Math.max(counterLabel.implicitHeight, counterSide.implicitHeight)

            PlainLabel {
              id: counterLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.counterText(true)
              color: root.ph && root.ph.since ? root.foreground : root.accent
              font.pixelSize: Style.font.displayLarge
              font.bold: true
              font.features: { "tnum": 1 }
            }
            Column {
              id: counterSide
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xxs
              PlainLabel {
                anchors.right: parent.right
                text: root.ph ? (root.ph.since ? strings.t("counter.since") : strings.t("counter.until"))
                  .arg(root.prayerName(root.ph.anchor.key, root.ph.anchor.weekday)) : ""
                color: root.dim
                font.pixelSize: Style.font.caption
              }
              PlainLabel {
                anchors.right: parent.right
                text: root.nextPrayer ? strings.t("bar.time").arg(root.prayerName(root.nextPrayer.key, root.nextPrayer.weekday))
                  .arg(root.timeText(root.nextPrayer.at)) : ""
                color: root.foreground
                font.pixelSize: Style.font.subtitle
              }
            }
          }

          // Jamaat / Alone / Late / Missed for the prayer that can be recorded now.
          PlainLabel {
            visible: root.recordable !== null && root.ph !== null && root.recordable.key !== root.ph.current.key
            width: parent.width
            text: root.recordable ? strings.t("recordFor").arg(root.prayerName(root.recordable.key, root.recordable.weekday)) : ""
            color: root.dim
            font.pixelSize: Style.font.caption
          }
          Row {
            id: statusRow
            width: parent.width
            spacing: Style.spacing.controlGap
            readonly property string current: root.recordable ? Model.statusOf(root.history, root.recordable.date, root.recordable.key) : ""

            Repeater {
              model: Model.STATUSES
              delegate: Button {
                required property string modelData
                required property int index
                width: (statusRow.width - statusRow.spacing * 3) / 4
                text: root.statusLabel(modelData)
                tooltipText: root.recordable ? strings.t("recordTip").arg(root.prayerName(root.recordable.key, root.recordable.weekday))
                  .arg(root.statusLabel(modelData)) : ""
                bordered: true
                selected: statusRow.current === modelData
                hasCursor: root.statusCursor === index
                enabled: root.recordable !== null
                foreground: selected ? root.statusColor(modelData) : root.foreground
                accent: root.statusColor(modelData)
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.record(modelData)
                onHovered: function(h) { if (h) root.statusCursor = -1 }
              }
            }
          }

          // The azan is playing: one wide button to stop it.
          Button {
            visible: root.azanPlaying
            width: parent.width
            text: strings.t("azanPlayingPanel")
            iconText: "\u{f04db}"
            bordered: true
            active: true
            foreground: root.accent
            fontFamily: root.fontFamily
            onClicked: root.stopAzan()
          }
        }

        PanelSeparator { foreground: root.foreground }

        // Today: Starts / Jamaat / Ends, the current time highlighted.
        Column {
          id: table
          width: parent.width
          readonly property int cols: root.hasJamaat ? 3 : 2
          readonly property real nameW: Math.round(width * 0.34)
          readonly property real colW: (width - nameW) / cols
          readonly property real rowH: Style.spacing.popupRowHeight

          Row {
            height: table.rowH
            Item { width: table.nameW; height: 1 }
            Repeater {
              model: root.hasJamaat ? ["table.starts", "table.jamaat", "table.ends"] : ["table.starts", "table.ends"]
              delegate: PlainLabel {
                required property string modelData
                width: table.colW
                height: table.rowH
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: strings.t(modelData)
                color: root.dim
                font.pixelSize: Style.font.caption
                font.bold: true
                font.capitalization: Font.AllUppercase
              }
            }
          }

          Repeater {
            model: root.todayRows
            delegate: Item {
              id: tRow
              required property var modelData
              readonly property bool prayer: modelData.key !== "sunrise"
              readonly property bool isCurrent: root.ph !== null && root.ph.current.key === modelData.key && root.ph.current.date === modelData.date
              readonly property bool past: isFinite(modelData.at) && modelData.at <= root.nowMs && !isCurrent
              readonly property bool open: prayer && root.started(modelData.date, modelData.key)
              readonly property string status: prayer ? Model.statusOf(root.history, modelData.date, modelData.key) : ""
              readonly property var win: root.windowOf(modelData.key)
              readonly property color textColor: isCurrent ? root.accent : past || !prayer ? root.dim : root.foreground
              width: table.width
              height: table.rowH

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: tRow.isCurrent ? Style.selectedAccentFill : rowMouse.containsMouse && tRow.open ? Style.hoverFill : "transparent"
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: tRow.open
                cursorShape: Qt.PointingHandCursor
                onClicked: root.cycle(tRow.modelData.date, tRow.modelData.key)
                onContainsMouseChanged: root.hovered = containsMouse ? { day: root.today, key: tRow.modelData.key } : null
              }

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.spacing.md

                Item {
                  width: table.nameW - Style.spacing.md
                  height: parent.height
                  // Today's status: click the row to record or change it.
                  Rectangle {
                    visible: tRow.prayer
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.spacing.lg; height: width; radius: width / 2
                    color: tRow.open && tRow.status !== "" ? root.statusColor(tRow.status) : "transparent"
                    border.width: tRow.status === "" ? Style.normalBorderWidth : 0
                    border.color: tRow.open ? root.foreground : root.dim
                    opacity: tRow.open ? 1 : 0.5
                  }
                  PlainLabel {
                    x: Style.spacing.lg + Style.spacing.md
                    width: parent.width - x
                    height: parent.height
                    verticalAlignment: Text.AlignVCenter
                    text: root.prayerName(tRow.modelData.key, tRow.modelData.weekday)
                    color: tRow.textColor
                    font.bold: tRow.isCurrent
                  }
                }
                Repeater {
                  model: root.hasJamaat ? ["start", "jamaat", "end"] : ["start", "end"]
                  delegate: PlainLabel {
                    required property string modelData
                    width: table.colW
                    height: table.rowH
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    font.features: { "tnum": 1 }
                    font.bold: tRow.isCurrent && modelData === "start"
                    color: tRow.textColor
                    text: modelData === "start" ? root.timeText(tRow.modelData.at)
                      : modelData === "jamaat" ? (tRow.prayer ? root.timeText(root.jamaatOf(tRow.modelData)) : strings.t("unavailable"))
                      : (tRow.win ? root.timeText(tRow.win.end) : strings.t("unavailable"))
                  }
                }
              }
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // The last 30 days, like a contribution graph: one row per prayer,
        // one column per day, newest on the right. Click a cell to record.
        Column {
          id: graph
          width: parent.width
          spacing: Style.spacing.md

          readonly property int count: 30
          // Labels as wide as the longest name; rows as tall as a label line.
          readonly property real labelW: Math.ceil(nameMetrics.advanceWidth) + Style.spacing.lg
          readonly property real gap: Math.max(1, Style.spacing.xxs)
          readonly property real cell: Math.max(4, Math.floor((width - labelW - gap * (count - 1)) / count))
          readonly property real rowH: Math.max(cell, Math.ceil(nameMetrics.height))

          TextMetrics {
            id: nameMetrics
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: Model.PRAYERS.map(function(k) { return root.prayerName(k, -1) })
              .reduce(function(a, b) { return b.length > a.length ? b : a }, "")
          }
          readonly property var days: Model.graphDays(root.nowMs, root.place.zone, count, root.graphEnd)
          readonly property var counts: Model.countStatuses(root.history, days)
          readonly property int share: Model.jamaatShare(counts)

          Item {
            width: parent.width
            height: Math.max(graphTitle.implicitHeight, pager.implicitHeight)

            PanelSectionHeader {
              id: graphTitle
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.graphEnd === 0 ? strings.t("history.title")
                : strings.t("history.range").arg(root.dateText(graph.days[0], "d MMM")).arg(root.dateText(graph.days[graph.days.length - 1], "d MMM"))
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              id: pager
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm

              PlainLabel {
                anchors.verticalCenter: parent.verticalCenter
                text: graph.share < 0 ? "" : strings.t("history.share").arg(Commons.I18n.formatNumber(graph.share))
                color: root.colorJamaat
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              PanelActionButton {
                iconText: Commons.I18n.rightToLeft ? "\u{f0142}" : "\u{f0141}"
                tooltipText: strings.t("history.older")
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.graphEnd = Math.min(3650, root.graphEnd + graph.count)
              }
              PanelActionButton {
                iconText: Commons.I18n.rightToLeft ? "\u{f0141}" : "\u{f0142}"
                tooltipText: strings.t("history.newer")
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: root.graphEnd > 0
                onClicked: root.graphEnd = Math.max(0, root.graphEnd - graph.count)
              }
            }
          }

          Column {
            spacing: graph.gap
            Repeater {
              model: Model.PRAYERS
              delegate: Row {
                id: gRow
                required property string modelData
                spacing: graph.gap
                height: graph.rowH

                PlainLabel {
                  width: graph.labelW - graph.gap
                  height: graph.rowH
                  verticalAlignment: Text.AlignVCenter
                  text: root.prayerName(gRow.modelData, -1)
                  color: root.dim
                  font.pixelSize: Style.font.caption
                }

                Repeater {
                  model: graph.days
                  delegate: Rectangle {
                    id: cellBox
                    required property var modelData
                    readonly property bool open: root.started(modelData.key, gRow.modelData)
                    readonly property string status: Model.statusOf(root.history, modelData.key, gRow.modelData)
                    readonly property bool hot: cellMouse.containsMouse
                    anchors.verticalCenter: parent.verticalCenter
                    width: graph.cell
                    height: graph.cell
                    radius: Math.min(Style.cornerRadius, graph.cell / 4)
                    color: !open ? "transparent" : status !== "" ? root.statusColor(status) : Style.normalFill
                    border.width: hot ? Math.max(1, Style.hoverBorderWidth) : open && status !== "" ? 0 : Style.normalBorderWidth
                    border.color: hot ? root.accent : Style.normalBorderColor

                    MouseArea {
                      id: cellMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      enabled: cellBox.open
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.cycle(cellBox.modelData.key, gRow.modelData)
                      onContainsMouseChanged: root.hovered = containsMouse ? { day: cellBox.modelData, key: gRow.modelData } : null
                    }
                  }
                }
              }
            }
          }

          // The hovered cell, or totals for the days shown.
          PlainLabel {
            width: parent.width
            color: root.hovered ? root.foreground : root.dim
            font.pixelSize: Style.font.caption
            text: {
              var h = root.hovered
              if (h) return strings.t("history.cell").arg(root.dateText(h.day, "ddd d MMM"))
                .arg(root.prayerName(h.key, h.day.weekday)).arg(root.statusLabel(Model.statusOf(root.history, h.day.key, h.key)))
              var f = Commons.I18n.formatNumber, c = graph.counts
              return strings.t("history.counts").arg(f(c.jamaat)).arg(f(c.alone)).arg(f(c.late)).arg(f(c.missed))
            }
          }

          Flow {
            width: parent.width
            spacing: Style.spacing.xl
            Repeater {
              model: ["jamaat", "alone", "late", "missed", ""]
              delegate: Row {
                required property string modelData
                spacing: Style.spacing.sm
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: graph.cell; height: graph.cell
                  radius: Math.min(Style.cornerRadius, graph.cell / 4)
                  color: modelData === "" ? Style.normalFill : root.statusColor(modelData)
                  border.width: modelData === "" ? Style.normalBorderWidth : 0
                  border.color: Style.normalBorderColor
                }
                PlainLabel {
                  text: root.statusLabel(modelData)
                  color: root.dim
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // Where and how: place, method, Asr.
        Item {
          width: parent.width
          height: Math.max(footerText.implicitHeight, footerAction.implicitHeight)
          PlainLabel {
            id: footerText
            anchors.left: parent.left
            anchors.right: footerAction.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            wrapMode: Text.Wrap
            elide: Text.ElideNone
            color: root.dim
            font.pixelSize: Style.font.caption
            text: (root.approximate ? strings.t("place.approximate").arg(root.place.name)
                : root.detecting && root.autoLocation ? strings.t("place.detecting").arg(root.place.name)
                : strings.t(root.autoLocation ? "place.auto" : "place.manual").arg(root.place.name))
              + " · " + strings.t("method." + root.opts.method) + " · " + strings.t("asr." + root.opts.asr)
          }
          PanelActionButton {
            id: footerAction
            visible: root.autoLocation
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "\u{f0450}"
            tooltipText: strings.t("place.redetect")
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: !geoProc.running
            onClicked: root.detectLocation(true)
          }
        }
      }

      // ============================================================= settings
      Flickable {
        id: settingsFlick
        visible: root.settingsOpen
        width: parent.width
        height: parent.height
        contentHeight: settingsView.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        function scrollBy(dy) {
          contentY = Math.max(0, Math.min(contentHeight - height, contentY + dy * Style.spacing.popupRowHeight))
        }

        SettingsView { id: settingsView; width: settingsFlick.width }
      }
    }
  }

  // ---- Settings page ------------------------------------------------------------
  component SettingsView: Column {
    spacing: Style.spacing.panelGap

    // Back to today, and the title.
    Item {
      width: parent.width
      height: Math.max(backButton.implicitHeight, settingsTitle.implicitHeight)
      PanelActionButton {
        id: backButton
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        iconText: Commons.I18n.rightToLeft ? "\u{f0054}" : "\u{f004d}"
        tooltipText: strings.t("settings.back")
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.settingsOpen = false
      }
      PlainLabel {
        id: settingsTitle
        anchors.left: backButton.right
        anchors.leftMargin: Style.spacing.lg
        anchors.verticalCenter: parent.verticalCenter
        text: strings.t("settings.title")
        font.pixelSize: Style.font.title
        font.bold: true
      }
    }

    // -- Location
    Section {
      title: strings.t("settings.location")

      PlainLabel {
        width: parent.width
        wrapMode: Text.Wrap
        elide: Text.ElideNone
        text: strings.t(root.autoLocation ? "place.auto" : "place.manual").arg(root.place.name)
          + " · " + root.zoneId
        font.pixelSize: Style.font.body
      }
      ButtonGroup {
        options: [
          { value: "auto", label: strings.t("location.auto"), icon: "\u{f01a4}" },
          { value: "manual", label: strings.t("location.manual"), icon: "\u{f034e}" }
        ]
        value: root.autoLocation ? "auto" : "manual"
        foreground: root.foreground
        fontFamily: root.fontFamily
        focusable: false
        onChanged: function(v) {
          if (v === "auto") { root.persistSettings({ location: "auto" }); root.detectLocation(true) }
          else {
            var p = root.manualPlace || { name: root.place.name, lat: root.place.lat, lon: root.place.lon, zone: root.basePlace.zone || root.zoneId }
            root.persistSettings({ location: "manual", place: p })
          }
        }
      }
      PlainLabel {
        visible: root.autoLocation
        width: parent.width
        wrapMode: Text.Wrap
        elide: Text.ElideNone
        text: strings.t("location.autoNote")
        color: root.dim
        font.pixelSize: Style.font.caption
      }

      // City search (Open-Meteo), or "lat, lon" typed in.
      TextField {
        id: citySearch
        visible: !root.autoLocation
        width: parent.width
        placeholderText: strings.t("location.search")
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        onActiveFocusChanged: root.editorFocus(activeFocus)
        onTextChanged: { root.cityQuery = text; searchDebounce.restart() }
        Keys.onEscapePressed: { text = ""; root.forceFocusPanel() }
        Keys.onReturnPressed: if (root.cityResults.length) { root.pickPlace(root.cityResults[0]); text = "" }
        Keys.onDownPressed: if (cityResults.count) cityResults.itemAt(0).forceActiveFocus()
      }
      Column {
        visible: !root.autoLocation && cityResults.count > 0
        width: parent.width
        spacing: Style.spacing.xxs
        Repeater {
          id: cityResults
          model: root.cityResults
          delegate: Button {
            required property var modelData
            width: parent.width
            leftAlign: true
            focusable: true
            text: modelData.description ? strings.t("location.result").arg(modelData.name).arg(modelData.description) : modelData.name
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: { root.pickPlace(modelData); citySearch.text = "" }
            Keys.onReturnPressed: { root.pickPlace(modelData); citySearch.text = "" }
          }
        }
      }
    }

    // -- Time
    Section {
      title: strings.t("settings.time")

      SearchableDropdown {
        width: parent.width
        label: strings.t("timezone")
        value: root.zoneSetting
        options: [{ value: "auto", label: strings.t("timezone.auto").arg(root.basePlace.zone || root.systemZoneId || "UTC") }]
          .concat(root.zoneTab.ids.map(function(z) { return { value: z, label: z.replace(/_/g, " ") } }))
        foreground: root.foreground
        fontFamily: root.fontFamily
        onPopupOpenChanged: root.editorFocus(popupOpen)
        onChanged: function(v) { root.persistSettings({ timezone: v === "auto" ? undefined : v }) }
      }
      Toggle {
        width: parent.width
        label: strings.t("hour24")
        checked: root.hour24
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.persistSettings({ hour24: !root.hour24 })
      }
    }

    // -- Calculation
    Section {
      title: strings.t("settings.calculation")

      Dropdown {
        width: parent.width
        label: strings.t("method")
        value: root.opts.method
        options: Model.METHOD_NAMES.map(function(m) { return { value: m, label: strings.t("method." + m) } })
        foreground: root.foreground
        fontFamily: root.fontFamily
        onPopupOpenChanged: root.editorFocus(popupOpen)
        onChanged: function(v) { root.persistSettings({ method: v }) }
      }
      FieldRow {
        label: strings.t("asr")
        ButtonGroup {
          options: [{ value: "Standard", label: strings.t("asr.short.Standard") }, { value: "Hanafi", label: strings.t("asr.short.Hanafi") }]
          value: root.opts.asr
          foreground: root.foreground
          fontFamily: root.fontFamily
          focusable: false
          onChanged: function(v) { root.persistSettings({ asr: v }) }
        }
      }
      FieldRow {
        label: strings.t("hijriOffset")
        ButtonGroup {
          options: [-2, -1, 0, 1, 2].map(function(n) {
            return { value: String(n), label: n > 0 ? "+" + Commons.I18n.formatNumber(n) : n < 0 ? "−" + Commons.I18n.formatNumber(-n) : Commons.I18n.formatNumber(0) }
          })
          value: String(root.hijriOffset)
          foreground: root.foreground
          fontFamily: root.fontFamily
          focusable: false
          onChanged: function(v) { root.persistSettings({ hijriOffset: Number(v) }) }
        }
      }
      PlainLabel {
        width: parent.width
        text: root.hijriText(root.today)
        color: root.dim
        font.pixelSize: Style.font.caption
      }
    }

    // -- Azan
    Section {
      title: strings.t("settings.azan")

      Toggle {
        width: parent.width
        label: strings.t("notify")
        description: strings.t("notify.description")
        checked: root.notify
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.persistSettings({ notify: !root.notify })
      }
      FieldRow {
        label: strings.t("azanFor")
        enabled: root.notify
        Row {
          spacing: Style.spacing.xs
          Repeater {
            model: Model.PRAYERS
            delegate: Button {
              required property string modelData
              text: root.prayerName(modelData, -1)
              bordered: true
              selected: root.azanFor[modelData] === true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.spacing.md
              onClicked: {
                var list = Model.PRAYERS.filter(function(k) { return k === modelData ? !root.azanFor[k] : root.azanFor[k] === true })
                root.persistSettings({ azanFor: list })
              }
            }
          }
        }
      }
      FieldRow {
        label: strings.t("azanMax")
        enabled: root.notify
        NumberField {
          value: root.azanMaxMinutes
          from: 0; to: 120; stepSize: 5
          foreground: root.foreground
          fontFamily: root.fontFamily
          onModified: function(v) { root.persistSettings({ azanMaxMinutes: v }) }
        }
      }
    }

    // -- Jamaat
    Section {
      title: strings.t("settings.jamaat")

      PlainLabel {
        width: parent.width
        wrapMode: Text.Wrap
        elide: Text.ElideNone
        text: strings.t("jamaat.help")
        color: root.dim
        font.pixelSize: Style.font.caption
      }
      Grid {
        id: jamaatGrid
        width: parent.width
        columns: 2
        columnSpacing: Style.spacing.xxl
        rowSpacing: Style.spacing.md
        Repeater {
          model: Model.JAMAAT_KEYS
          delegate: Row {
            id: jRow
            required property string modelData
            width: (jamaatGrid.width - jamaatGrid.columnSpacing) / 2
            spacing: Style.spacing.md
            // Saved as 24-hour text; shown in the clock format in use.
            readonly property string saved: String(root.jamaatSettings[modelData] || "")
            readonly property string shown: Model.jamaatText(Model.parseJamaat(saved), !root.hour24)
            PlainLabel {
              width: Math.round(jRow.width * 0.42)
              anchors.verticalCenter: parent.verticalCenter
              text: strings.t(jRow.modelData === "jumuah" ? "prayer.jumuah" : "prayer." + jRow.modelData)
            }
            TextField {
              id: jField
              width: jRow.width - Math.round(jRow.width * 0.42) - jRow.spacing
              text: jRow.shown
              placeholderText: strings.t("jamaat.placeholder")
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              accent: Model.jamaatValid(text) ? root.accent : Commons.Color.urgent
              color: Model.jamaatValid(text) ? root.foreground : Commons.Color.urgent
              onActiveFocusChanged: {
                root.editorFocus(activeFocus)
                if (!activeFocus) commit()
              }
              Keys.onReturnPressed: root.forceFocusPanel()
              Keys.onEscapePressed: { text = jRow.shown; root.forceFocusPanel() }
              function commit() {
                if (!Model.jamaatValid(text)) { text = jRow.shown; return }
                var rule = Model.parseJamaat(text)
                var norm = Model.jamaatText(rule)
                text = Model.jamaatText(rule, !root.hour24)
                if (norm === jRow.saved) return
                var j = {}
                for (var k in root.jamaatSettings) j[k] = root.jamaatSettings[k]
                if (norm === "") delete j[jRow.modelData]; else j[jRow.modelData] = norm
                root.persistSettings({ jamaat: Object.keys(j).length ? j : undefined })
              }
            }
          }
        }
      }
      FieldRow {
        label: strings.t("jamaatLead")
        enabled: root.notify
        NumberField {
          value: root.jamaatLead
          from: 5; to: 60; stepSize: 5
          foreground: root.foreground
          fontFamily: root.fontFamily
          onModified: function(v) { root.persistSettings({ jamaatLead: v }) }
        }
      }
    }

    // -- Prayer record
    Section {
      title: strings.t("settings.record")

      Toggle {
        width: parent.width
        label: strings.t("checkIn")
        description: strings.t("checkIn.description")
        checked: root.checkIn
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.persistSettings({ checkIn: !root.checkIn })
      }
      FieldRow {
        label: strings.t("checkInLead")
        enabled: root.checkIn
        NumberField {
          value: root.checkInLead
          from: 5; to: 60; stepSize: 5
          foreground: root.foreground
          fontFamily: root.fontFamily
          onModified: function(v) { root.persistSettings({ checkInLead: v }) }
        }
      }
    }

    // -- Bar
    Section {
      title: strings.t("settings.bar")
      ButtonGroup {
        options: [
          { value: "Counter", label: strings.t("barShows.Counter") },
          { value: "Next", label: strings.t("barShows.Next") },
          { value: "Both", label: strings.t("barShows.Both") }
        ]
        value: root.barShows
        foreground: root.foreground
        fontFamily: root.fontFamily
        focusable: false
        onChanged: function(v) { root.persistSettings({ barShows: v }) }
      }
    }
  }

  // A titled block of settings.
  component Section: Column {
    property string title: ""
    default property alias content: body.data
    width: parent ? parent.width : 0
    spacing: Style.spacing.rowGap
    PanelSeparator { foreground: root.foreground }
    PanelSectionHeader { text: parent.title; foreground: root.foreground; fontFamily: root.fontFamily }
    Column {
      id: body
      width: parent.width
      spacing: Style.spacing.rowGap
    }
  }

  // A label on the left, one control on the right.
  component FieldRow: Item {
    property string label: ""
    default property alias control: slot.data
    width: parent ? parent.width : 0
    height: Math.max(fieldLabel.implicitHeight, slot.childrenRect.height)
    opacity: enabled ? 1 : 0.5
    PlainLabel {
      id: fieldLabel
      anchors.left: parent.left
      anchors.right: slot.left
      anchors.rightMargin: Style.spacing.controlGap
      anchors.verticalCenter: parent.verticalCenter
      text: parent.label
    }
    Item {
      id: slot
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: childrenRect.width
      height: childrenRect.height
    }
  }

  component PlainLabel: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  // ---- City search ------------------------------------------------------------
  function forceFocusPanel() { keyCatcher.forceActiveFocus() }
  function editorFocus(on) { editors = Math.max(0, editors + (on ? 1 : -1)) }
  onSettingsOpenChanged: { editors = 0; cityResults = [] }

  property string cityQuery: ""
  property var cityResults: []

  function pickPlace(p) {
    if (!p) return
    // Typed coordinates carry no zone: keep the current one.
    var zone = p.zone || root.basePlace.zone || root.zoneId
    root.persistSettings({ location: "manual", place: { name: p.name, lat: p.lat, lon: p.lon, zone: zone } })
    cityResults = []
    forceFocusPanel()
  }

  Timer {
    id: searchDebounce
    interval: 300
    onTriggered: {
      var q = root.cityQuery.trim()
      var coords = Model.parseCoordinates(q)
      if (coords) { root.cityResults = [coords]; return }
      if (q.length < 2) { root.cityResults = []; return }
      geocodeProc.query = q
      if (!geocodeProc.running) root.startGeocode()
    }
  }
  function startGeocode() {
    geocodeProc.active = geocodeProc.query
    geocodeProc.command = ["curl", "-fsS", "--max-time", "5", "--max-filesize", "200000",
      "https://geocoding-api.open-meteo.com/v1/search?count=8&language=en&format=json&name=" + encodeURIComponent(geocodeProc.active)]
    geocodeProc.running = true
  }
  Process {
    id: geocodeProc
    property string query: ""
    property string active: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.autoLocation && root.cityQuery.trim().length >= 2) root.cityResults = Model.parseGeocoding(text)
        if (geocodeProc.query !== geocodeProc.active) Qt.callLater(root.startGeocode)
      }
    }
  }
}
