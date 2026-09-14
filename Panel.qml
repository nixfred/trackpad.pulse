pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model
import "Curve.js" as Curve
import "Pulse.js" as Pulse

// Trackpad Pulse: a trackpad that shows you what your fingers are doing, on
// top of Trackpad Plus's per-device controls and pointer-feel editor.
//
// Two halves, kept deliberately separate:
//   * settings — David Fano's trackpads.py and the action queue below it,
//     unchanged in behaviour: every write is scoped to one device, debounced,
//     journalled and rolled back on failure;
//   * telemetry — the Trackpad Pulse recorder (collectors/trackpad_pulse.py),
//     a user service that reads the pad's own event node and writes
//     snapshot / live / history files this panel only ever reads.
Panel {
  id: root
  moduleName: "nixfred.trackpad-pulse"
  ipcTarget: "nixfred.trackpad-pulse"
  manageIpc: false

  property string releaseVersion: ""
  FileView {
    path: Qt.resolvedUrl("manifest.json")
    onLoaded: {
      try { root.releaseVersion = JSON.parse(text()).version || "" }
      catch (error) { root.releaseVersion = "" }
    }
  }

  // ---- settings state (Trackpad Plus) --------------------------------------
  // Each panel instance can select a device; the helper serializes writes across bars.
  property var devices: []
  property string selectedDevice: "apple"
  property string selectedLabel: "Apple"
  property bool deviceConnected: false
  property bool hasSavedSettings: false
  property string deviceName: ""
  property bool touchpadEnabled: true
  property bool naturalScroll: false
  property bool tapToClick: true
  property bool disableWhileTyping: true
  property bool clickfingerBehavior: true
  property bool pointerAcceleration: true
  property var pointerFeel: ({ profile: "adaptive", curve: Curve.defaults() })
  property var previousFeels: ({})
  property bool editingCurve: false
  property bool deviceSettingsOpen: false
  property real scrollScale: 1
  property real scrollFactor: 0.2
  property real pointerSpeed: 0.0
  property real pendingPointerSpeed: 0.0
  property string settingsError: ""
  property var pendingActions: []
  property int editGeneration: 0
  property int stateGeneration: 0
  property bool refreshPending: false
  readonly property string backend: decodeURIComponent(String(Qt.resolvedUrl("trackpads.py")).replace(/^file:\/\//, ""))

  function updateState(raw) {
    var data
    try { data = JSON.parse(raw) } catch (e) { settingsError = "Could not read trackpad settings"; return }
    if (data.error) { settingsError = data.error; return }
    devices = data.devices || []
    loadSelection()
  }

  function loadSelection() {
    var row = null
    for (var i = 0; i < devices.length; i++) {
      if (devices[i].id === selectedDevice) row = devices[i]
    }
    if (!row && devices.length) { row = devices[0]; selectedDevice = row.id }
    if (!row) { deviceName = ""; deviceConnected = false; return }
    selectedLabel = row.label
    deviceConnected = row.connected
    hasSavedSettings = row.configured !== false
    deviceName = row.names[0] || ""
    var v = row.settings
    touchpadEnabled = v.enabled
    naturalScroll = v.natural_scroll
    tapToClick = v.tap_to_click
    disableWhileTyping = v.disable_while_typing
    clickfingerBehavior = v.clickfinger_behavior
    pointerAcceleration = v.accel_profile !== "flat"
    pointerFeel = Curve.fromSettings(v)
    var previous = Curve.copy(previousFeels)
    if (row.previous_pointer_feel) previous[selectedDevice] = row.previous_pointer_feel
    else delete previous[selectedDevice]
    previousFeels = previous
    scrollScale = v.scroll_scale || Math.max(1, v.scroll_factor)
    scrollFactor = v.scroll_factor / scrollScale
    pendingScrollFactor = scrollFactor
    pointerSpeed = v.sensitivity
    pendingPointerSpeed = pointerSpeed
  }

  function selectDevice(key) {
    // Flush pending slider edits against the OLD device before changing selection.
    if (scrollDebounce.running) { scrollDebounce.stop(); commitScrollFactor() }
    if (pointerDebounce.running) { pointerDebounce.stop(); commitPointerSpeed() }
    selectedDevice = key
    settingsError = ""
    loadSelection()
  }

  function enqueue(option, value) {
    var queue = pendingActions.slice()
    // Replace only consecutive writes of the same scalar; preserve profile/undo ordering.
    var last = queue.length ? queue[queue.length - 1] : null
    if (last && last.device === selectedDevice && last.option === option && option !== "pointer_feel") {
      queue.pop()
    }
    if (queue.length >= 128) {
      settingsError = "Too many pending changes; wait for them to finish"
      loadSelection()
      return
    }
    editGeneration++
    settingsError = ""
    queue.push({ device: selectedDevice, option: option, value: value })
    pendingActions = queue
    // Keep the local snapshot consistent while queued writes finish.
    for (var i = 0; i < devices.length; i++) {
      if (devices[i].id === selectedDevice) {
        var settings = devices[i].settings
        if (option === "pointer_feel") {
          devices[i].previous_pointer_feel = Curve.fromSettings(settings)
          settings.accel_profile = value.profile === "mac" || value.profile === "custom" ? "custom" : value.profile
          settings.curve = Curve.copy(value.curve)
          settings.curve_preset = value.profile === "mac" ? "mac" : "custom"
        } else if (option === "scroll_scale") {
          var oldScale = settings.scroll_scale || Math.max(1, settings.scroll_factor)
          settings.scroll_factor = Math.round(settings.scroll_factor * value / oldScale * 1000000) / 1000000
          settings.scroll_scale = value
        } else settings[option] = value
      }
    }
    runNextAction()
  }

  function runNextAction() {
    if (actionProc.running || pendingActions.length === 0) return
    var queue = pendingActions.slice()
    var next = queue.shift()
    pendingActions = queue
    actionProc.command = bounded(10, ["python3", backend, "set", next.device, next.option, JSON.stringify(next.value)])
    actionProc.running = true
  }

  // Pending scroll factor while dragging the slider.
  property real pendingScrollFactor: 0.4
  property bool scrollSetQueued: false

  // ---- Cursor navigation (controls page) ----
  property string focusSection: "header"
  property int selectedIndex: 0
  property bool cursorActive: false

  readonly property var allSections: ["device", "header", "scroll"].concat(
    pointerFeel.profile === "mac" || pointerFeel.profile === "custom" ? [] : ["pointer"]
  ).concat(["scale", "acceleration", "natural", "tap", "typing", "clickfinger"])

  readonly property string icon: {
    if (!deviceName) return ""
    return touchpadEnabled ? "󰟸" : "󰤳"
  }

  readonly property string heroStatusText: deviceConnected
    ? (touchpadEnabled ? (hasSavedSettings ? "Settings saved separately" : "Ready to customize") : "Trackpad disabled")
    : "Disconnected · settings remembered"

  readonly property color hoverFill: bar
    ? Style.hoverFillFor(bar.foreground, Color.accent)
    : "transparent"
  readonly property color selectedFill: bar
    ? Style.selectedFillFor(bar.foreground, Color.accent)
    : "transparent"

  function moveCursor(delta) {
    var sections = allSections
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) { focusSection = sections[0]; return }

    if (delta > 0) {
      if (sIdx < sections.length - 1) focusSection = sections[sIdx + 1]
    } else {
      if (sIdx > 0) focusSection = sections[sIdx - 1]
    }
  }

  function moveCursorH(delta) {
    if (focusSection === "device") {
      var index = devices.findIndex(function(d) { return d.id === selectedDevice })
      var next = Math.max(0, Math.min(devices.length - 1, index + delta))
      if (devices[next]) selectDevice(devices[next].id)
    } else if (focusSection === "scroll") {
      adjustScrollFactor(delta > 0 ? 0.01 : -0.01)
    } else if (focusSection === "pointer") {
      adjustPointerSpeed(delta > 0 ? 0.1 : -0.1)
    } else if (focusSection === "scale") {
      setScrollScale(scrollScale + (delta > 0 ? 0.1 : -0.1))
    }
  }

  function activateCursor() {
    if (focusSection === "acceleration") { openCurveEditor(); return }
    if (focusSection === "header") { toggleTouchpad(); return }
    if (focusSection === "natural") { toggleNaturalScroll(); return }
    if (focusSection === "tap") { toggleTapToClick(); return }
    if (focusSection === "typing") { toggleDisableWhileTyping(); return }
    if (focusSection === "clickfinger") { toggleClickfingerBehavior(); return }
  }

  // ---- Process discipline ----
  //
  // Nothing this widget launches may outlive its usefulness. Every spawn goes
  // through here, so a wedged hyprctl, a stuck omarchy-* tool or a helper
  // blocked on something unforeseen is reaped rather than accumulating one
  // orphan per click.
  function bounded(seconds, argv) {
    return ["timeout", "-k", "2", String(seconds)].concat(argv)
  }

  // ---- Actions: every change is scoped to the selected trackpad. ----
  function toggleTouchpad() {
    if (!deviceName) return
    touchpadEnabled = !touchpadEnabled
    enqueue("enabled", touchpadEnabled)
  }

  function setTouchpadEnabled(on) {
    if (!deviceName || touchpadEnabled === on) return
    touchpadEnabled = on
    enqueue("enabled", on)
  }

  function toggleNaturalScroll() {
    var next = !naturalScroll
    naturalScroll = next
    setHyprOption("natural_scroll", next)
  }

  function toggleTapToClick() {
    var next = !tapToClick
    tapToClick = next
    setHyprOption("tap_to_click", next)
  }

  function toggleDisableWhileTyping() {
    var next = !disableWhileTyping
    disableWhileTyping = next
    setHyprOption("disable_while_typing", next)
  }

  function toggleClickfingerBehavior() {
    var next = !clickfingerBehavior
    clickfingerBehavior = next
    setHyprOption("clickfinger_behavior", next)
  }

  function setHyprOption(option, value) { enqueue(option, value) }

  function togglePointerAcceleration() {
    if (!touchpadEnabled) return
    pointerAcceleration = !pointerAcceleration
    enqueue("accel_profile", pointerAcceleration ? "adaptive" : "flat")
  }

  function openCurveEditor() {
    if (!touchpadEnabled) return
    selectDevice(selectedDevice) // Flush any pending speed edits first.
    editingCurve = true
    active = "feel"
    curveEditor.begin()
  }

  function applyPointerFeel(value) {
    var previous = Curve.copy(previousFeels)
    previous[selectedDevice] = Curve.copy(pointerFeel)
    previousFeels = previous
    enqueue("pointer_feel", value)
    loadSelection()
  }

  function restorePointerFeel() {
    if (!previousFeels[selectedDevice]) return
    var value = Curve.copy(previousFeels[selectedDevice])
    applyPointerFeel(value)
    curveEditor.draft = Curve.copy(value)
  }

  function toggleDeviceSettings(key) {
    var sameDevice = key === selectedDevice
    selectDevice(key)
    deviceSettingsOpen = sameDevice ? !deviceSettingsOpen : true
  }

  function setScrollScale(value) {
    var next = Math.max(0.1, Math.min(10, Math.round(value * 100) / 100))
    if (Math.abs(next - scrollScale) < 0.000001) return
    // A pending speed edit belongs to the old scale; keep that ordering.
    if (scrollDebounce.running) { scrollDebounce.stop(); commitScrollFactor() }
    enqueue("scroll_scale", next)
    scrollScale = next
  }

  function adjustScrollFactor(delta) {
    var next = Model.clampScrollFactor(scrollFactor + delta)
    scrollFactor = next
    pendingScrollFactor = next
    scrollDebounce.restart()
  }

  function setScrollFactor(value) {
    var clamped = Model.clampScrollFactor(value)
    scrollFactor = clamped
    pendingScrollFactor = clamped
    scrollDebounce.restart()
  }

  function commitScrollFactor() {
    setHyprOption("scroll_factor", Math.round(pendingScrollFactor * scrollScale * 1000000) / 1000000)
  }

  function adjustPointerSpeed(delta) {
    if (pointerFeel.profile === "mac" || pointerFeel.profile === "custom") return
    var next = Model.clampSensitivity(pointerSpeed + delta)
    pointerSpeed = next
    pendingPointerSpeed = next
    pointerDebounce.restart()
  }

  function setPointerSpeed(value) {
    if (pointerFeel.profile === "mac" || pointerFeel.profile === "custom") return
    var clamped = Model.clampSensitivity(value)
    pointerSpeed = clamped
    pendingPointerSpeed = clamped
    pointerDebounce.restart()
  }

  function commitPointerSpeed() {
    enqueue("sensitivity", Model.clampSensitivity(pendingPointerSpeed))
  }

  function refresh() {
    refreshPending = true
    if (!stateProc.running && !actionProc.running && pendingActions.length === 0
        && !scrollDebounce.running && !pointerDebounce.running) {
      refreshPending = false
      stateGeneration = editGeneration
      stateProc.running = true
    }
  }

  function receiveState(raw) {
    // A read remains stale even after the newer write has finished.
    if (stateGeneration !== editGeneration || actionProc.running || pendingActions.length
        || scrollDebounce.running || pointerDebounce.running) {
      refreshPending = true
      return
    }
    updateState(raw)
  }

  function finishStateRead(code) {
    if (code !== 0 && !settingsError) settingsError = "Could not read trackpad settings"
    if (refreshPending) refresh()
  }

  function finishAction(code) {
    if (code !== 0 && !settingsError) settingsError = "Could not save trackpad settings"
    if (pendingActions.length) runNextAction()
    else refresh()
  }

  // ---- telemetry (Trackpad Pulse) ---------------------------------------
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/trackpad-pulse"
  readonly property string runtimeDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/trackpad-pulse"
  readonly property string collector: decodeURIComponent(String(Qt.resolvedUrl("collectors/trackpad_pulse.py")).replace(/^file:\/\//, ""))
  property var snap: ({})
  property var live: ({})
  property var histories: ({})
  property real now: Date.now() / 1000
  property string active: "overview"
  property bool chooseMode: false
  property int range: 3600
  property string actionStatus: ""
  onActionStatusChanged: if (actionStatus !== "") statusExpiry.restart()
  Timer { id: statusExpiry; interval: 9000; onTriggered: root.actionStatus = "" }
  readonly property var pages: [
    { key: "overview", label: "Overview" },
    { key: "controls", label: "Controls" },
    { key: "feel", label: "Pointer feel" },
    { key: "gestures", label: "Gestures" },
    { key: "lab", label: "Touch lab" },
    { key: "report", label: "Report" },
    { key: "about", label: "About" }
  ]
  readonly property int pageIndex: {
    for (var i = 0; i < root.pages.length; i++) if (root.pages[i].key === root.active) return i
    return 0
  }
  readonly property bool stale: !snap.warm || now - Pulse.num(snap.ts) > 20
  readonly property bool cursorOnly: !stale && snap.access === "cursor"
  readonly property bool noAccess: !stale && (snap.access === "none" || snap.access === "cursor")
  readonly property var today: snap.today || ({})
  readonly property var todayCounts: today.counts || ({})
  readonly property var week: snap.week || ({})
  readonly property real binWidth: Pulse.num(snap.binMmS) || 5
  readonly property real mmPerUnitMs: Pulse.num(snap.mmPerUnitMs) || 25.4
  readonly property var todayHist: root.cursorOnly ? ((today.cursor || {}).hist || []) : (today.hist || [])
  // The curve editor wants a distribution with some weight in it; a fresh day
  // borrows the week until it has half a minute of movement of its own.
  readonly property var feelHist: Pulse.padHist(snap, root.selectedDevice, Pulse.total(todayHist) >= 30 || !week.hist ? todayHist : week.hist)
  readonly property var chart: histories[String(range)] || ({ points: [], seconds: range, now: now, bucket: 60, count: 0, peak: 0, busiest: 0, touches: 0, distance: 0 })
  readonly property var spans: snap.windows || ({})
  readonly property var pads: snap.pads || []
  readonly property real presetScale: Pulse.presetScale(snap, root.selectedDevice)
  readonly property var readablePads: pads.filter(function(p) { return p.readable })
  readonly property var livePads: live.pads || []
  readonly property var liveFingers: {
    var out = []
    for (var i = 0; i < root.livePads.length; i++) out = out.concat(root.livePads[i].fingers || [])
    return out
  }
  readonly property int fingersNow: liveFingers.length
  readonly property bool palmNow: liveFingers.some(function(f) { return f.palm })
  readonly property real speedNow: {
    var s = 0
    for (var i = 0; i < root.livePads.length; i++) s = Math.max(s, Pulse.num(root.livePads[i].speed))
    if (root.cursorOnly && root.live.cursor) s = Pulse.num(root.live.cursor.speed) / 10
    return s
  }
  readonly property real hzNow: {
    var h = 0
    for (var i = 0; i < root.livePads.length; i++) h = Math.max(h, Pulse.num(root.livePads[i].hz))
    for (var j = 0; !h && j < root.pads.length; j++) h = Math.max(h, Pulse.num(root.pads[j].hz))
    return h
  }
  readonly property real padAspect: readablePads.length && readablePads[0].height > 0 ? readablePads[0].width / readablePads[0].height : 1.6
  readonly property real level: Pulse.clamp(speedNow / 200, 0, 1)
  readonly property bool animated: root.setting("animated", true) !== false

  readonly property color ink: Color.popups.text
  readonly property color inkDim: Util.alpha(ink, 0.66)
  readonly property color card: Util.alpha(ink, 0.05)
  readonly property color cardEdge: Util.alpha(ink, 0.15)
  readonly property color rule: Util.alpha(ink, 0.14)
  readonly property color heat: Color.urgent
  readonly property color tint: !deviceConnected || !touchpadEnabled || stale ? Color.muted
    : palmNow ? Color.urgent : fingersNow > 0 ? Color.accent : Qt.darker(Color.accent, 1.15)
  readonly property string verdict: Pulse.verdict(snap, live, touchpadEnabled, deviceConnected, now)

  function setSetting(key, value) {
    var next = {}
    for (var k in root.settings) next[k] = root.settings[k]
    next[key] = value
    root.settings = next
    var saved = root.bar && root.bar.shell
      ? root.bar.shell.updateEntryInline(root.moduleName, root.settings) !== false
      : false
    if (!saved) root.actionStatus = "Changed for now, but it could not be saved to shell.json."
    return saved
  }
  function showPage(key) {
    for (var i = 0; i < root.pages.length; i++) if (root.pages[i].key === key) { root.chooseMode = false; root.active = key; return true }
    root.actionStatus = "No such page: " + key
    return false
  }
  function stepPage(delta) {
    root.active = root.pages[Math.max(0, Math.min(root.pages.length - 1, root.pageIndex + delta))].key
  }
  function status() {
    return JSON.stringify({ opened: root.opened, active: root.active, chooseMode: root.chooseMode, version: root.releaseVersion,
      device: root.selectedDevice, deviceName: root.deviceName, connected: root.deviceConnected, enabled: root.touchpadEnabled,
      scrollFactor: root.scrollFactor, scrollScale: root.scrollScale, pointerSpeed: root.pointerSpeed, profile: root.pointerFeel.profile,
      access: root.snap.access || "offline", stale: root.stale, verdict: root.verdict, animated: root.animated,
      fingers: root.fingersNow, speed: root.speedNow, hz: root.hzNow, today: root.todayCounts, peak: root.today.peak || 0,
      samples: root.chart.count || 0, pads: root.pads.length, panelWidth: panel.contentWidth, panelHeight: panel.contentHeight,
      travel: root.spans, gestures: root.gestures, hint: root.hintActive ? root.hint.summary : "", catalogue: root.catalogue.length,
      contentNeeded: shell.implicitHeight, availableHeight: panel.availableCardHeight, availableWidth: panel.availableCardWidth,
      action: root.actionStatus, error: root.settingsError })
  }
  // The recorder's actions return one JSON line each. Links never go through
  // here: they are constants handed to xdg-open detached, after the panel
  // closes, the way the other Pulse plugins learned to do it.
  function runPulse(action, extra, mode) {
    if (pulseProc.running) return
    pulseProc.mode = mode || "status"
    if (!mode) root.actionStatus = action === "grant-access" ? "Asking polkit for permission to install the udev rule…"
      : action === "revoke-access" ? "Asking polkit to remove the udev rule…"
      : action === "install-service" ? "Starting the recorder…" : "Working…"
    pulseProc.command = root.bounded(130, ["python3", root.collector, action].concat(extra || []))
    pulseProc.running = true
  }
  // ---- the standing check ------------------------------------------------
  // The recorder re-runs the optimizer every ten minutes against the settings
  // in use and leaves hint.json. A hint with changes and some confidence that
  // you have not seen yet lights the Optimize button and the Pointer feel tab.
  property var hint: ({})
  readonly property bool hintActive: !!(root.hint && root.hint.changes && root.hint.changes.length > 0 && root.hint.confidence !== "low"
    && String(root.setting("hintSeen", "")) !== String(root.hint.signature) && !root.stale && !root.noAccess)
  function hintSeen() { root.setSetting("hintSeen", root.hint && root.hint.signature ? String(root.hint.signature) : "") }
  property real pulseOpacity: 1
  SequentialAnimation on pulseOpacity {
    running: root.hintActive && root.opened
    loops: Animation.Infinite
    NumberAnimation { to: 0.35; duration: 650 }
    NumberAnimation { to: 1; duration: 650 }
    onRunningChanged: if (!running) root.pulseOpacity = 1
  }
  FileView {
    id: hintFile; path: root.stateDir + "/hint.json"; watchChanges: true; printErrors: false
    onFileChanged: reload()
    onLoaded: { try { root.hint = JSON.parse(text()) } catch (e) {} }
  }

  // ---- gestures ----------------------------------------------------------
  // The catalogue comes from the recorder, so the panel never holds a command
  // line; it sends slot and action ids and the recorder writes the Lua.
  property var catalogue: []
  property var catalogueMeta: ({})
  readonly property var gestureDefaults: root.catalogueMeta.defaults || ({})
  // The recorder keeps the applied map beside the Lua it wrote, so the page
  // knows what is live even when the widget entry could not save it.
  readonly property var gestures: root.setting("gestures", null) || root.catalogueMeta.current || null
  readonly property bool gesturesApplied: !!root.gestures
  readonly property var gestureOptions: {
    var out = []
    for (var i = 0; i < root.catalogue.length; i++) {
      var a = root.catalogue[i]
      if (!a.available) continue
      out.push({ value: a.id, label: a.group === "Nothing" ? "Nothing" : a.group + "  ·  " + a.label, description: a.hint })
    }
    return out
  }
  function gestureValue(slot) {
    var g = root.gestures || root.gestureDefaults
    return g && g[slot] ? String(g[slot]) : "none"
  }
  function actionById(id) {
    for (var i = 0; i < root.catalogue.length; i++) if (root.catalogue[i].id === id) return root.catalogue[i]
    return null
  }
  function loadCatalogue() {
    if (root.catalogue.length || pulseProc.running) return
    root.runPulse("gestures-catalogue", [], "catalogue")
  }
  function setGesture(slot, id) {
    var base = root.gestures || root.gestureDefaults, next = {}
    for (var k in base) next[k] = base[k]
    next[slot] = id
    var parts = slot.split("-"), partners = { left: "right", right: "left", up: "down", down: "up" }
    var partner = partners[parts[1]] ? parts[0] + "-" + partners[parts[1]] : null
    var spec = root.actionById(id), was = partner ? root.actionById(next[partner]) : null
    if (partner && spec && spec.pair) next[partner] = id
    else if (partner && was && was.pair && !(spec && spec.pair)) next[partner] = "none"
    root.applyGestures(next)
  }
  function applyGestures(map) {
    root.actionStatus = "Writing the gesture file and reloading Hyprland…"
    root.runPulse("gestures-apply", [JSON.stringify(map)], "gestures")
  }

  // ---- the report and auto-off --------------------------------------------
  property var reportData: ({})
  property var autoOffLocal: null
  readonly property bool autoOffOn: root.autoOffLocal === null ? !!((root.snap.autoOff || {}).enabled) : !!root.autoOffLocal
  onSnapChanged: {
    if (root.autoOffLocal !== null && !!((root.snap.autoOff || {}).enabled) === !!root.autoOffLocal) root.autoOffLocal = null
    if (root.strayLocal !== null && !!((root.snap.strayGuard || {}).enabled) === !!root.strayLocal) root.strayLocal = null
  }
  function loadReport() { if (!pulseProc.running) root.runPulse("report", [], "report") }
  function setAutoOff(on) {
    root.autoOffLocal = on
    root.runPulse(on ? "auto-off-on" : "auto-off-off")
  }
  // The stray guard: opt-in, the recorder puts the cursor back after an
  // accidental-looking touch. Same local-echo pattern as auto-off.
  property var strayLocal: null
  readonly property var strayGuard: root.snap.strayGuard || ({})
  readonly property bool strayGuardOn: root.strayLocal === null ? !!root.strayGuard.enabled : !!root.strayLocal
  function setStrayGuard(on) {
    root.strayLocal = on
    root.runPulse(on ? "stray-guard-on" : "stray-guard-off")
  }
  Timer { interval: 60000; repeat: true; running: root.opened && root.active === "report"; onTriggered: root.loadReport() }

  // ---- the optimizer ----------------------------------------------------
  // A proposal from the recorder: what to change and why, from the shape of
  // the finger-speed distribution and the overshoot / re-stroke rates since
  // the last applied pass. Nothing moves until Apply.
  property var proposal: null
  readonly property var optimizeCurrent: ({
    profile: root.pointerFeel.profile, curve: root.pointerFeel.curve, scrollFactor: root.scrollFactor, scrollScale: root.scrollScale,
    gainMaximum: root.scrollScale, practiceMedianMs: curveEditor.practiceMedianMs, device: root.selectedDevice, presetScale: root.presetScale })
  function requestOptimize() {
    if (pulseProc.running) return
    root.proposal = null
    root.chooseMode = false
    root.active = "feel"
    root.actionStatus = "Reading a week of touches…"
    pulseProc.mode = "optimize"
    pulseProc.command = root.bounded(60, ["python3", root.collector, "optimize", JSON.stringify(root.optimizeCurrent)])
    pulseProc.running = true
  }
  function applyProposal() {
    var p = root.proposal
    if (!p || !p.proposal) return
    var feel = { profile: p.proposal.profile || "custom", curve: Curve.copy(p.proposal.curve) }
    var curveChanged = p.changes.some(function(c) { return c.key !== "scroll" })
    var scrollChanged = p.changes.some(function(c) { return c.key === "scroll" })
    if (curveChanged) {
      curveEditor.draft = Curve.copy(feel)
      root.applyPointerFeel(feel)
    }
    if (scrollChanged) {
      root.setScrollFactor(p.proposal.scrollFactor)
      scrollDebounce.stop()
      root.commitScrollFactor()
    }
    var entry = { changes: p.changes, evidence: p.evidence, verdict: p.verdict, practiceMedianMs: curveEditor.practiceMedianMs, device: p.device || root.selectedDevice }
    root.proposal = null
    root.hintSeen()
    if (pulseProc.running) { root.actionStatus = "Applied; the log entry will be written on the next pass."; return }
    pulseProc.mode = "applied"
    pulseProc.command = root.bounded(30, ["python3", root.collector, "optimize-applied", JSON.stringify(entry)])
    pulseProc.running = true
  }
  // You disagree with an undo: the recorder marks the change kept and the
  // next pass moves on to the next one.
  function keepAnyway() {
    if (pulseProc.running) return
    root.proposal = null
    root.hintSeen()
    root.actionStatus = "Keeping it…"
    pulseProc.mode = "keep"
    pulseProc.command = root.bounded(30, ["python3", root.collector, "optimize-keep", JSON.stringify({ device: root.selectedDevice })])
    pulseProc.running = true
  }
  function fmtValue(key, v) {
    if (v === null || v === undefined) return "—"
    if (key === "start" || key === "end") return Pulse.speed(Pulse.curveToMm(v, root.mmPerUnitMs)) + " (" + (Pulse.num(v) / 4 * 100).toFixed(0) + "%)"
    if (key === "scroll") return Pulse.num(v).toFixed(2) + "×"
    if (key === "profile") return String(v)
    return Pulse.num(v).toFixed(4) + "×"
  }
  readonly property var links: ({ site: "https://nixfred.com", repo: "https://github.com/nixfred/trackpad.pulse", plugins: "https://omarchy.nixfred.com",
    upstream: "https://github.com/davefano/omarchy-trackpad-plus", origin: "https://github.com/awkent01/omarchy-touchpad-widget" })
  function openLink(name) {
    var url = root.links[name]
    if (!url) return
    root.close()
    Quickshell.execDetached(["xdg-open", url])
  }

  FileView {
    id: snapshotFile; path: root.stateDir + "/snapshot.json"; watchChanges: true; printErrors: false
    onFileChanged: reload()
    onLoaded: { try { var m = JSON.parse(text()); if (m.warm) root.snap = m } catch (e) {} }
  }
  FileView {
    id: liveFile; path: root.runtimeDir + "/live.json"; watchChanges: true; printErrors: false
    onFileChanged: reload()
    onLoaded: { try { root.live = JSON.parse(text()) } catch (e) {} }
  }
  FileView {
    id: historyFile; path: root.stateDir + "/history.json"; watchChanges: true; printErrors: false
    onFileChanged: reload()
    onLoaded: { try { root.histories = JSON.parse(text()) } catch (e) {} }
  }
  Timer {
    interval: 3000; running: true; repeat: true
    onTriggered: { root.now = Date.now() / 1000; if (root.stale) { snapshotFile.reload(); historyFile.reload(); liveFile.reload() } }
  }
  Timer { id: reoptimize; interval: 200; onTriggered: root.requestOptimize() }
  // `omarchy plugin add` runs no installer, so a fresh machine had no
  // recorder until someone found Start the recorder. Once per load, a snapshot
  // still stale after a few seconds asks the recorder to start itself; it
  // leaves one you stopped alone.
  Timer {
    id: ensureRecorder; interval: 5000
    onTriggered: { if (!root.stale) return; if (pulseProc.running) { restart(); return } root.runPulse("ensure-service", [], "ensure") }
  }
  Process {
    id: pulseProc
    property string mode: "status"
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var r = JSON.parse(String(text))
          if (pulseProc.mode === "optimize" && !r.error) { root.proposal = r; root.actionStatus = "" }
          else if (pulseProc.mode === "catalogue" && !r.error) { root.catalogue = r.actions || []; root.catalogueMeta = r; root.actionStatus = "" }
          else if (pulseProc.mode === "report" && !r.error) { root.reportData = r; root.actionStatus = "" }
          else if (pulseProc.mode === "keep" && !r.error) { root.actionStatus = r.message || "Kept."; reoptimize.start() }
          else if (pulseProc.mode === "gestures" && !r.error) { if (r.gestures) root.setSetting("gestures", r.gestures); root.actionStatus = r.message || "Gestures applied." }
          else if (pulseProc.mode === "ensure") { if (r.error) root.actionStatus = r.error }
          else root.actionStatus = r.error || r.message || "Done"
        } catch (e) { root.actionStatus = "The recorder helper did not answer." }
        pulseProc.mode = "status"
        snapshotFile.reload()
      }
    }
    onExited: function(code, status) { if (code !== 0 && root.actionStatus.indexOf("…") >= 0) root.actionStatus = "That did not complete." }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.chooseMode = false; root.open() }
    function close(): void { root.close() }
    function show(): void { root.chooseMode = false; root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.chooseMode = false; root.toggle() }
    function status(): string { return root.status() }
    function page(name: string): void { if (root.showPage(String(name))) root.open() }
    function chooser(): void { root.chooseMode = true; root.open() }
    function enable(on: bool): void { root.setTouchpadEnabled(on) }
    function optimize(): void { root.requestOptimize(); root.open() }
    function gestures(): void { root.showPage("gestures"); root.open() }
    function report(): void { root.showPage("report"); root.open() }
  }

  // ---- Lifecycle ----
  visible: deviceName !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: { refresh(); ensureRecorder.start() }

  onOpenedChanged: {
    if (opened) {
      editingCurve = false
      refresh()
      snapshotFile.reload()
      historyFile.reload()
      focusSection = "device"
      cursorActive = false
      if (!chooseMode && active === "feel") { editingCurve = true; curveEditor.begin() }
    }
  }
  onActiveChanged: {
    if (active === "feel" && opened) { editingCurve = true; curveEditor.begin() }
    else editingCurve = false
    if (active === "gestures") root.loadCatalogue()
    if (active === "report") root.loadReport()
  }

  // Poll while open so external changes are reflected.
  Timer {
    interval: 3000
    running: root.opened || root.devices.length === 0
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: scrollDebounce
    interval: 200
    repeat: false
    onTriggered: root.commitScrollFactor()
  }

  Timer {
    id: pointerDebounce
    interval: 200
    repeat: false
    onTriggered: root.commitPointerSpeed()
  }

  Process {
    id: stateProc
    command: root.bounded(15, ["python3", root.backend, "state"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.receiveState(String(text))
      }
    }
    onExited: function(code, status) {
      Qt.callLater(function() { root.finishStateRead(code) })
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text))
          if (data.error) root.settingsError = data.error
        } catch (e) { root.settingsError = "Could not save trackpad settings" }
      }
    }
    onExited: function(code, status) {
      Qt.callLater(function() { root.finishAction(code) })
    }
  }

  // ---- Bar entry ----
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: vertical ? -1 : barRow.implicitWidth + 12
    fixedHeight: vertical ? barRow.implicitHeight + 12 : -1
    tooltipText: {
      var lines = ["Trackpad Pulse" + (root.releaseVersion !== "" ? " v" + root.releaseVersion : "") + " · " + root.selectedLabel]
      lines.push(root.verdict)
      if (!root.stale) {
        lines.push("Today: " + Pulse.readout(root.snap, root.live, 0) + " touches · " + Pulse.readout(root.snap, root.live, 2) + " taps · " + Pulse.int(root.todayCounts.clicks) + " clicks · " + Pulse.readout(root.snap, root.live, 1))
        lines.push("Peak " + Pulse.readout(root.snap, root.live, 3) + " · active " + Pulse.readout(root.snap, root.live, 6) + " · " + Pulse.readout(root.snap, root.live, 7) + " palms rejected · " + Pulse.int(root.todayCounts.strays) + " stray touches")
        if (root.spans.all) lines.push("Travelled " + Pulse.distance((root.spans.week || {}).distance) + " this week · " + Pulse.distance(root.spans.all.distance) + " all time")
      }
      if (root.hintActive) lines.push("Optimize has a new proposal: " + root.hint.summary)
      lines.push("Left-click: dashboard · Right-click: on/off")
      return lines.join("\n")
    }
    onPressed: function(b) {
      if (b === Qt.RightButton) { root.chooseMode = true; root.open() }
      else { root.chooseMode = false; root.toggle() }
    }
    // The chip alone. It already says everything the bar needs: whether the
    // pad is on, whether a finger is down and where, and how fast it moves.
    Row {
      id: barRow
      anchors.centerIn: parent
      TrackpadChip {
        anchors.verticalCenter: parent.verticalCenter
        compact: true
        width: 34; height: 24
        fingers: root.liveFingers
        tint: root.tint
        surface: Color.background
        mutedTint: Color.muted
        glint: root.bar ? root.bar.foreground : root.ink
        padEnabled: root.touchpadEnabled && root.deviceConnected
        animate: !root.stale && root.animated
        level: root.level
        aspect: root.padAspect
      }
    }
  }

  // ---- Shared components ----
  component Label: Text {
    color: root.inkDim
    font.pixelSize: 12
    textFormat: Text.PlainText
  }
  component Heading: Text {
    color: root.ink
    font.pixelSize: 15
    font.bold: true
    textFormat: Text.PlainText
  }
  component Action: Rectangle {
    id: act
    property string text: ""
    property bool selected: false
    property color accent: root.ink
    signal clicked()
    implicitWidth: caption.implicitWidth + 26
    implicitHeight: 34
    radius: 9
    opacity: act.enabled ? 1 : 0.45
    color: act.selected ? Qt.alpha(accent, Style.selectedFillAlpha) : area.containsMouse ? Style.hoverFill : Style.normalFill
    border.color: act.selected ? accent : area.containsMouse ? Style.hoverBorderColor : Style.normalBorderColor
    Behavior on color { ColorAnimation { duration: 120 } }
    Text {
      id: caption
      anchors.centerIn: parent
      text: act.text
      color: act.selected ? root.ink : root.inkDim
      font.pixelSize: 12
      font.bold: act.selected
      textFormat: Text.PlainText
    }
    MouseArea {
      id: area
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (act.enabled) act.clicked()
    }
  }
  component Stat: Rectangle {
    id: stat
    property string label: ""
    property string value: ""
    property string hint: ""
    property color valueColor: root.ink
    radius: 12
    color: root.card
    border.color: root.cardEdge
    Column {
      anchors.fill: parent
      anchors.margins: 12
      spacing: 5
      Label { text: stat.label; font.pixelSize: 10; font.letterSpacing: 1 }
      Heading { text: stat.value; font.pixelSize: 20; color: stat.valueColor; width: parent.width; elide: Text.ElideRight }
      Label { text: stat.hint; font.pixelSize: 10; width: parent.width; elide: Text.ElideRight }
    }
  }
  component Card: Rectangle {
    radius: 14
    color: root.card
    border.color: root.cardEdge
  }
  component SettingRow: CursorSurface {
    id: settingRow
    required property string sectionName
    foreground: root.bar ? root.bar.foreground : root.ink
    fill: root.hoverFill
    radius: 0
    hasCursor: root.cursorActive && root.focusSection === sectionName
    z: hasCursor ? 1 : 0
    Rectangle {
      anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
      height: 1; color: Qt.alpha(settingRow.foreground, 0.12); visible: !settingRow.hasCursor
    }
    Rectangle {
      anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
      height: 1; color: Qt.alpha(settingRow.foreground, 0.12); visible: !settingRow.hasCursor
    }
    HoverHandler {
      onHoveredChanged: if (hovered) {
        root.cursorActive = true
        root.focusSection = settingRow.sectionName
      }
    }
  }
  component ToggleRow: SettingRow {
    id: toggleRow
    required property string label
    required property string description
    required property bool checked
    signal toggled()
    hasCursor: root.cursorActive && root.focusSection === sectionName
    foreground: root.bar ? root.bar.foreground : root.ink
    fill: root.hoverFill
    implicitHeight: Math.max(Style.space(58), rowContent.implicitHeight + Style.space(24))
    opacity: root.touchpadEnabled ? 1.0 : 0.4
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) { root.cursorActive = true; root.focusSection = toggleRow.sectionName }
      onClicked: if (toggleRow.enabled) toggleRow.toggled()
    }
    Item {
      id: rowContent
      anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10); anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(rowLabels.implicitHeight, rowSwitch.implicitHeight)
      Column {
        id: rowLabels
        anchors.left: parent.left; anchors.right: rowSwitch.left; anchors.rightMargin: Style.space(12); anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)
        Text { text: toggleRow.label; color: toggleRow.foreground; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body; elide: Text.ElideRight; width: parent.width }
        Text { visible: toggleRow.description !== ""; text: toggleRow.description; color: Qt.darker(toggleRow.foreground, 1.5); font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideRight; width: parent.width; wrapMode: Text.WordWrap }
      }
      ToggleSwitch {
        id: rowSwitch
        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
        checked: toggleRow.checked
        foreground: toggleRow.foreground
        onToggled: if (toggleRow.enabled) toggleRow.toggled()
      }
    }
  }
  // A slider row with − / + ends, shared by scroll speed and pointer speed.
  component SliderRow: SettingRow {
    id: sliderRow
    required property string label
    required property string valueText
    required property real minimum
    required property real maximum
    required property real step
    required property real value
    property bool dimmed: false
    signal moved(real v)
    signal released(real v)
    signal nudged(real delta)
    readonly property alias dragging: slider.dragging
    readonly property alias liveValue: slider.liveValue
    implicitHeight: content.implicitHeight + Style.space(26)
    Column {
      id: content
      anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10); anchors.rightMargin: Style.space(10)
      spacing: Style.space(6)
      opacity: sliderRow.dimmed ? 0.4 : 1
      Item {
        width: parent.width
        implicitHeight: sliderLabel.implicitHeight
        Text { id: sliderLabel; anchors.left: parent.left; text: sliderRow.label; color: sliderRow.foreground; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body }
        Text { anchors.right: parent.right; text: sliderRow.valueText; color: Qt.darker(sliderRow.foreground, 1.4); font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption }
      }
      Item {
        width: parent.width
        implicitHeight: Style.space(32)
        CursorSurface {
          id: minusSurface
          anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
          width: Style.space(32); height: Style.space(32)
          hasCursor: false; foreground: sliderRow.foreground; fill: root.hoverFill
          Text { anchors.centerIn: parent; text: "−"; color: sliderRow.foreground; font.pixelSize: Style.font.heading; opacity: sliderRow.value <= sliderRow.minimum ? 0.3 : 1 }
          MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sliderRow.nudged(-sliderRow.step); onContainsMouseChanged: if (containsMouse) { root.cursorActive = true; root.focusSection = sliderRow.sectionName } }
        }
        CursorSurface {
          anchors.left: minusSurface.right; anchors.right: plusSurface.left; anchors.leftMargin: Style.space(4); anchors.rightMargin: Style.space(4); anchors.verticalCenter: parent.verticalCenter
          height: slider.implicitHeight + Style.spacing.controlGap
          hasCursor: false; foreground: sliderRow.foreground; outline: true
          PanelSlider {
            id: slider
            bar: root.bar
            anchors.fill: parent; anchors.leftMargin: Style.space(6); anchors.rightMargin: Style.space(6)
            minimum: sliderRow.minimum; maximum: sliderRow.maximum; step: sliderRow.step
            value: sliderRow.value
            onMoved: function(v) { sliderRow.moved(v) }
            onReleased: function(v) { sliderRow.released(v) }
          }
          HoverHandler { onHoveredChanged: if (hovered) { root.cursorActive = true; root.focusSection = sliderRow.sectionName } }
        }
        CursorSurface {
          id: plusSurface
          anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
          width: Style.space(32); height: Style.space(32)
          hasCursor: false; foreground: sliderRow.foreground; fill: root.hoverFill
          Text { anchors.centerIn: parent; text: "+"; color: sliderRow.foreground; font.pixelSize: Style.font.heading; opacity: sliderRow.value >= sliderRow.maximum ? 0.3 : 1 }
          MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sliderRow.nudged(sliderRow.step); onContainsMouseChanged: if (containsMouse) { root.cursorActive = true; root.focusSection = sliderRow.sectionName } }
        }
      }
    }
  }

  // ---- Popup panel ----
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Both dimensions are the content's real size; KeyboardPanel fits them to
    // the screen itself. Nothing here scrolls: the pages are laid out wide so
    // every control and every number is on screen at once.
    contentWidth: panel.fittedContentWidth(root.chooseMode ? 620 : 1180)
    contentHeight: panel.fittedContentHeight(shell.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingCurve && root.active === "feel" && !root.chooseMode
      onMoveRequested: function(dx, dy) {
        if (root.chooseMode) return
        if (root.active !== "controls") { if (dx !== 0) root.stepPage(dx); return }
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive && root.active === "controls") root.activateCursor()
      onCloseRequested: { if (root.chooseMode) root.chooseMode = false; else root.close() }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // The popup card can be translucent under some themes; the dashboard
      // paints its own ground, as the other Pulse panels do, so a terminal
      // behind it never shows through a graph.
      Rectangle { anchors.fill: parent; anchors.margins: -10; radius: 14; color: Color.popups.background; z: -1 }

      Column {
        id: shell
        width: parent.width
        spacing: 14

        // Header: name, blurb, and the verdict pill.
        Row {
          width: parent.width
          spacing: 10
          // The live pad rides in the header on every page. Overview has the
          // hero-sized one and About has its own, so those two skip it.
          readonly property bool headerChip: !root.chooseMode && root.active !== "overview" && root.active !== "about"
          Column {
            width: parent.width - 300 - (parent.headerChip ? 110 : 0)
            spacing: 3
            Heading { text: "TRACKPAD PULSE"; font.pixelSize: 19; font.letterSpacing: 3 }
            Label {
              width: parent.width; elide: Text.ElideRight
              text: (root.chooseMode ? "Switch the pad off, or open a page." : "Your trackpad, in motion.  ·  " + root.selectedLabel + (root.deviceName && root.deviceName !== root.selectedLabel ? "  ·  " + root.deviceName : ""))
                + (root.releaseVersion !== "" ? "   ·   v" + root.releaseVersion : "")
              font.pixelSize: 11
            }
          }
          TrackpadChip {
            visible: parent.headerChip
            width: visible ? 100 : 0; height: 50
            anchors.verticalCenter: parent.verticalCenter
            fingers: root.liveFingers; tint: root.tint; surface: Color.background; mutedTint: Color.muted; glint: root.ink
            padEnabled: root.touchpadEnabled && root.deviceConnected
            animate: root.opened && visible && !root.stale && root.animated
            level: root.level; aspect: root.padAspect
          }
          Rectangle {
            width: 290; height: 32; radius: 16
            anchors.verticalCenter: parent.verticalCenter
            color: Qt.alpha(root.tint, 0.14)
            border.color: Qt.alpha(root.tint, 0.5)
            Row {
              anchors.centerIn: parent
              spacing: 7
              Rectangle {
                width: 6; height: 6; radius: 3; color: root.tint
                anchors.verticalCenter: parent.verticalCenter
                SequentialAnimation on opacity {
                  running: root.opened && !root.stale && root.animated
                  loops: Animation.Infinite
                  NumberAnimation { to: 0.3; duration: 900 }
                  NumberAnimation { to: 1; duration: 900 }
                }
              }
              Label { text: root.verdict; color: root.ink; font.pixelSize: 9; font.bold: true; elide: Text.ElideRight; width: Math.min(implicitWidth, 250) }
            }
          }
        }

        // Page switcher.
        Row {
          visible: !root.chooseMode
          height: visible ? implicitHeight : 0
          spacing: 8
          Repeater {
            model: root.pages
            Action {
              required property int index
              required property var modelData
              text: modelData.label + (modelData.key === "feel" && root.hintActive ? "  •" : "")
              selected: root.active === modelData.key
              accent: root.tint
              opacity: modelData.key === "feel" && root.hintActive && root.active !== "feel" ? root.pulseOpacity : 1
              onClicked: root.active = modelData.key
            }
          }
          Item { width: 16; height: 1 }
          Label {
            visible: root.settingsError !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: root.settingsError; color: Color.urgent; font.pixelSize: 11
            width: Math.min(implicitWidth, 420); elide: Text.ElideRight
          }
        }

        // ================= OVERVIEW =================
        Column {
          width: parent.width
          spacing: 14
          visible: !root.chooseMode && root.active === "overview"
          height: visible ? implicitHeight : 0

          // Something is in the way of telemetry: say what, and offer the fix.
          Rectangle {
            width: parent.width
            visible: root.stale || root.noAccess
            height: visible ? 64 : 0
            radius: 12
            color: Util.alpha(Color.accent, 0.09)
            border.color: Util.alpha(Color.accent, 0.38)
            Row {
              anchors.fill: parent; anchors.margins: 12; spacing: 14
              Column {
                width: parent.width - 260; anchors.verticalCenter: parent.verticalCenter; spacing: 3
                Heading {
                  font.pixelSize: 12
                  text: root.stale ? "THE RECORDER IS NOT RUNNING" : root.cursorOnly ? "CURSOR ONLY: THE TOUCHPAD ITSELF IS CLOSED TO YOUR USER" : "NO ACCESS TO THE TOUCHPAD"
                }
                Label {
                  width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 10
                  text: root.stale ? "Settings work without it. Start the user service to record touches, taps, gestures, speed and a week of history."
                    : "Omarchy keeps users out of the input group so nothing can keylog. A udev rule can grant just the touchpad node to the logged-in seat, never the keyboard. One polkit prompt."
                }
              }
              Action {
                anchors.verticalCenter: parent.verticalCenter
                accent: Color.accent; selected: true
                text: root.stale ? "Start the recorder" : "Grant touchpad access"
                enabled: !pulseProc.running
                onClicked: root.runPulse(root.stale ? "install-service" : "grant-access")
              }
            }
          }

          // The standing check found a better curve than the one in use.
          Rectangle {
            width: parent.width
            visible: root.hintActive
            height: visible ? 64 : 0
            radius: 12
            color: Util.alpha(root.tint, 0.10)
            border.color: Qt.alpha(root.tint, 0.4 + 0.5 * root.pulseOpacity)
            Row {
              anchors.fill: parent; anchors.margins: 12; spacing: 14
              Column {
                width: parent.width - 230; anchors.verticalCenter: parent.verticalCenter; spacing: 3
                Heading { font.pixelSize: 12; text: "OPTIMIZE HAS A NEW PROPOSAL  ·  " + String(root.hint.confidence || "").toUpperCase() + " CONFIDENCE" }
                Label { width: parent.width; elide: Text.ElideRight; font.pixelSize: 10; text: String(root.hint.summary || "") + "  ·  checked " + Pulse.ago(root.hint.ts, root.now) }
              }
              Action { anchors.verticalCenter: parent.verticalCenter; text: "Review"; accent: root.tint; selected: true; onClicked: root.requestOptimize() }
              Action { anchors.verticalCenter: parent.verticalCenter; text: "Later"; onClicked: root.hintSeen() }
            }
          }

          // Hero: the pad itself, live, beside today's headline number.
          Rectangle {
            width: parent.width; height: 176; radius: 16
            border.color: Qt.alpha(root.tint, 0.45)
            gradient: Gradient { GradientStop { position: 0; color: Qt.alpha(root.tint, 0.13) } GradientStop { position: 1; color: root.card } }
            TrackpadChip {
              x: 14; y: 8; width: 236; height: 160
              fingers: root.liveFingers; tint: root.tint; surface: Color.background; mutedTint: Color.muted; glint: root.ink
              padEnabled: root.touchpadEnabled && root.deviceConnected
              animate: root.opened && root.active === "overview" && !root.stale && root.animated
              level: root.level; aspect: root.padAspect
            }
            Column {
              x: 268; y: 22; spacing: 6
              Label { text: root.cursorOnly ? "CURSOR TRAVEL TODAY" : "TOUCHES TODAY"; font.pixelSize: 11; font.letterSpacing: 2 }
              Row {
                spacing: 10
                Text {
                  text: root.stale ? "—" : root.cursorOnly ? Pulse.int((root.today.cursor || {}).distance) : Pulse.int(root.todayCounts.touches)
                  color: root.ink; font.pixelSize: 52; font.weight: Font.Light; textFormat: Text.PlainText
                }
                Label { visible: root.cursorOnly; text: "px"; font.pixelSize: 18; anchors.bottom: parent.bottom; anchors.bottomMargin: 10 }
              }
              Label {
                text: root.stale ? "Start the recorder to count them." : root.cursorOnly ? "No fingers, taps or gestures without pad access."
                  : Pulse.int(root.todayCounts.moves) + " pointer moves  ·  " + Pulse.int(root.todayCounts.scrolls) + " scrolls  ·  " + Pulse.int(Pulse.num(root.todayCounts.taps) + Pulse.num(root.todayCounts.taps2) + Pulse.num(root.todayCounts.taps3)) + " taps  ·  " + Pulse.int(root.todayCounts.clicks) + " clicks"
                color: root.inkDim
              }
              Label {
                width: 560; elide: Text.ElideRight; font.pixelSize: 10
                text: root.readablePads.length ? (root.readablePads[0].kernelName || root.readablePads[0].name) + "  ·  " + root.readablePads[0].width + " × " + root.readablePads[0].height + " mm  ·  " + root.readablePads[0].resX + " units/mm  ·  " + root.readablePads[0].slots + " fingers  ·  " + root.readablePads[0].bus
                  : root.pads.length ? root.pads[0].name + "  ·  not readable" : root.deviceName
              }
            }
            // Where you touch, today, in the span between the count and the speed.
            HeatMap {
              x: 852; y: 10; width: 178; height: 138
              visible: !root.cursorOnly
              heat: root.today.heat || []; cols: Pulse.num(root.snap.heatW) || 32; rows: Pulse.num(root.snap.heatH) || 20
              aspect: root.padAspect; tint: root.tint; hot: root.heat; ink: root.ink; surface: Color.background
            }
            Label { x: 852; y: 150; width: 178; horizontalAlignment: Text.AlignHCenter; visible: !root.cursorOnly; font.pixelSize: 9; font.letterSpacing: 1; text: "WHERE YOU TOUCH · TODAY" }
            Column {
              anchors.right: parent.right; anchors.rightMargin: 20; anchors.top: parent.top; anchors.topMargin: 20
              spacing: 2
              Text { anchors.right: parent.right; text: root.stale ? "—" : root.cursorOnly ? Pulse.pxSpeed(root.speedNow * 10) : Pulse.speed(root.speedNow); color: Qt.alpha(root.ink, 0.85); font.pixelSize: 22; font.weight: Font.Light; textFormat: Text.PlainText }
              Label { anchors.right: parent.right; text: root.fingersNow > 0 ? root.fingersNow + (root.fingersNow === 1 ? " finger down" : " fingers down") : "now"; font.pixelSize: 10 }
              Label { anchors.right: parent.right; text: root.hzNow > 0 ? Pulse.hz(root.hzNow) + " report rate" : ""; font.pixelSize: 10 }
            }
          }

          Row {
            width: parent.width; spacing: 10
            Stat { width: (parent.width - 30) / 4; height: 96; label: root.cursorOnly ? "CURSOR TRAVEL" : "DISTANCE TODAY"
              value: root.stale ? "—" : root.cursorOnly ? Pulse.int((root.today.cursor || {}).distance) + " px" : Pulse.distance(root.todayCounts.distance)
              hint: root.cursorOnly ? "in logical pixels" : Pulse.distance(root.todayCounts.scroll) + " under two fingers  ·  " + Pulse.distance(root.week.distance) + " this week" }
            Stat { width: (parent.width - 30) / 4; height: 96; label: "TAPS · CLICKS"
              value: root.stale || root.cursorOnly ? "—" : Pulse.int(Pulse.num(root.todayCounts.taps) + Pulse.num(root.todayCounts.taps2) + Pulse.num(root.todayCounts.taps3)) + " · " + Pulse.int(Pulse.num(root.todayCounts.clicks) + Pulse.num(root.todayCounts.rightClicks))
              hint: Pulse.int(root.todayCounts.taps2) + " two-finger taps  ·  " + Pulse.int(root.todayCounts.rightClicks) + " right clicks" }
            Stat { width: (parent.width - 30) / 4; height: 96; label: "PEAK SPEED"
              value: root.stale ? "—" : root.cursorOnly ? Pulse.pxSpeed((root.today.cursor || {}).peak) : Pulse.speed(root.today.peak)
              hint: (root.today.peakAt ? "at " + Pulse.clock(root.today.peakAt) : "no movement yet") + "  ·  median " + (root.cursorOnly ? Pulse.pxSpeed(Pulse.percentile(root.todayHist, root.binWidth * 10, 0.5)) : Pulse.speed(Pulse.percentile(root.todayHist, root.binWidth, 0.5))) }
            Stat { width: (parent.width - 30) / 4; height: 96; label: "ACTIVE TIME"
              value: root.stale ? "—" : Pulse.duration(root.cursorOnly ? (root.today.cursor || {}).active : root.todayCounts.active)
              hint: root.cursorOnly ? "cursor in motion" : Pulse.duration(root.todayCounts.moving) + " moving  ·  " + Pulse.duration(root.week.active) + " this week" }
          }

          Row {
            width: parent.width; spacing: 10
            Card {
              width: parent.width * 0.6 - 5; height: 236
              Column {
                anchors.fill: parent; anchors.margins: 14; spacing: 8
                Row {
                  width: parent.width; spacing: 7
                  Heading { text: "CONTINUOUS HISTORY"; font.pixelSize: 12; width: parent.width - 222; anchors.verticalCenter: parent.verticalCenter }
                  Repeater {
                    model: [{ t: "1 hour", s: 3600 }, { t: "24 hours", s: 86400 }, { t: "7 days", s: 604800 }]
                    Action { required property var modelData; text: modelData.t; selected: root.range === modelData.s; accent: root.tint; implicitWidth: 68; implicitHeight: 28; onClicked: root.range = modelData.s }
                  }
                }
                TouchHistoryGraph { width: parent.width; height: 146; historyData: root.chart; tint: root.tint; heat: root.heat; ink: root.ink; surface: Color.popups.background }
                Row {
                  spacing: 14
                  Label { text: "▮ touches"; color: root.tint; font.pixelSize: 10 }
                  Label { text: "━ peak mm/s"; color: root.heat; font.pixelSize: 10 }
                  Label { text: Pulse.int(root.chart.touches) + " touches  ·  " + Pulse.distance(root.chart.distance) + "  ·  " + (root.chart.count || 0) + " minutes recorded"; font.pixelSize: 10 }
                }
                Label { font.pixelSize: 10; text: (root.chart.count || 0) < 2 ? "History is starting. One row per minute, seven-day retention." : "Recording while closed  ·  7-day retention  ·  hover to inspect" }
              }
            }
            Card {
              width: parent.width * 0.4 - 5; height: 236
              Column {
                anchors.fill: parent; anchors.margins: 14; spacing: 8
                Row {
                  width: parent.width
                  Heading { text: root.cursorOnly ? "CURSOR SPEED" : "WHERE YOUR FINGERS LIVE"; font.pixelSize: 12; width: parent.width - 60 }
                  Label { text: "today"; font.pixelSize: 10; width: 60; horizontalAlignment: Text.AlignRight }
                }
                SpeedHistogram {
                  width: parent.width; height: 146
                  hist: root.todayHist; binWidth: root.binWidth; mmPerUnitMs: root.mmPerUnitMs; cursorUnits: root.cursorOnly
                  curveStart: !root.cursorOnly && (root.pointerFeel.profile === "custom" || root.pointerFeel.profile === "mac") ? root.pointerFeel.curve.start : -1
                  curveEnd: !root.cursorOnly && (root.pointerFeel.profile === "custom" || root.pointerFeel.profile === "mac") ? root.pointerFeel.curve.end : -1
                  tint: root.tint; heat: root.heat; ink: root.ink; surface: Color.popups.background
                }
                Label {
                  width: parent.width; font.pixelSize: 10; wrapMode: Text.WordWrap
                  text: Pulse.total(root.todayHist) <= 0 ? "Move a finger and the distribution appears."
                    : "Median " + (root.cursorOnly ? Pulse.pxSpeed(Pulse.percentile(root.todayHist, root.binWidth * 10, 0.5)) : Pulse.speed(Pulse.percentile(root.todayHist, root.binWidth, 0.5)))
                      + "  ·  90% under " + (root.cursorOnly ? Pulse.pxSpeed(Pulse.percentile(root.todayHist, root.binWidth * 10, 0.9)) : Pulse.speed(Pulse.percentile(root.todayHist, root.binWidth, 0.9)))
                      + (root.pointerFeel.profile === "custom" || root.pointerFeel.profile === "mac" ? "  ·  shaded: where your curve accelerates" : "")
                }
              }
            }
          }

          // Distance, touches and clicks on every clock that matters.
          Row {
            width: parent.width; spacing: 8
            Repeater {
              model: [
                { l: "LAST MINUTE", k: "minute" }, { l: "LAST HOUR", k: "hour" }, { l: "TODAY", k: "today" }, { l: "THIS WEEK", k: "week" },
                { l: "THIS MONTH", k: "month" }, { l: "THIS YEAR", k: "year" }, { l: "ALL TIME", k: "all" }
              ]
              Rectangle {
                id: travelCard
                required property var modelData
                readonly property var span: root.spans[travelCard.modelData.k] || ({})
                width: (shell.width - 48) / 7; height: 70; radius: 12; color: root.card; border.color: root.cardEdge
                Column {
                  anchors.fill: parent; anchors.margins: 10; spacing: 2
                  Label { text: travelCard.modelData.l; font.pixelSize: 9; font.letterSpacing: 1 }
                  Heading { text: root.stale || root.cursorOnly ? "—" : Pulse.distance(travelCard.span.distance); font.pixelSize: 17; width: parent.width; elide: Text.ElideRight }
                  Label {
                    font.pixelSize: 9; width: parent.width; elide: Text.ElideRight
                    text: root.stale || root.cursorOnly ? "" : Pulse.int(travelCard.span.touches) + " touches · " + Pulse.int(travelCard.span.clicks) + " clicks"
                      + (travelCard.modelData.k === "all" && root.spans.firstDay ? " · " + (travelCard.span.days || 0) + " d" : "")
                  }
                }
              }
            }
          }

          Row {
            width: parent.width; spacing: 10
            Repeater {
              model: [
                { l: "POINTER MOVES", k: "moves" }, { l: "2-FINGER SCROLLS", k: "scrolls" }, { l: "PINCHES", k: "pinches" },
                { l: "3-FINGER SWIPES", k: "swipes3" }, { l: "4-FINGER SWIPES", k: "swipes4" }, { l: "PALMS REJECTED", k: "palms" }, { l: "STRAY TOUCHES", k: "strays" }
              ]
              Rectangle {
                id: gestureCard
                required property var modelData
                width: (shell.width - 60) / 7; height: 62; radius: 12; color: root.card; border.color: root.cardEdge
                Column {
                  anchors.fill: parent; anchors.margins: 10; spacing: 3
                  Label { text: gestureCard.modelData.l; font.pixelSize: 9; font.letterSpacing: 1 }
                  Heading { text: root.stale || root.cursorOnly ? "—" : Pulse.int(root.todayCounts[gestureCard.modelData.k]); font.pixelSize: 18 }
                }
              }
            }
          }
        }

        // ================= CONTROLS =================
        Column {
          width: parent.width
          spacing: 12
          visible: !root.chooseMode && root.active === "controls"
          height: visible ? implicitHeight : 0

          Row {
            width: parent.width
            spacing: Style.space(8)
            Repeater {
              model: root.devices
              CursorSurface {
                id: deviceButton
                required property var modelData
                width: Math.min(380, (shell.width - Style.space(8) * (root.devices.length - 1)) / Math.max(1, root.devices.length))
                height: Style.space(38)
                foreground: root.bar ? root.bar.foreground : root.ink
                fill: root.selectedDevice === modelData.id ? root.selectedFill : root.hoverFill
                current: root.selectedDevice === modelData.id
                hasCursor: root.cursorActive && root.focusSection === "device" && root.selectedDevice === modelData.id
                Text {
                  anchors.centerIn: parent
                  width: parent.width - Style.space(20)
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                  text: deviceButton.modelData.label + (deviceButton.modelData.connected ? "" : "  ·  away")
                  color: deviceButton.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: root.selectedDevice === deviceButton.modelData.id
                  textFormat: Text.PlainText
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: { root.selectDevice(deviceButton.modelData.id); root.focusSection = "device" }
                }
              }
            }
            Label { anchors.verticalCenter: parent.verticalCenter; text: root.devices.length > 1 ? "Each trackpad keeps its own settings." : ""; font.pixelSize: 10 }
          }

          Row {
            width: parent.width
            spacing: 24
            // Left: the pad, the speeds and the scale.
            Column {
              id: settingsLeft
              width: (parent.width - 24) / 2
              spacing: -1
              SettingRow {
                sectionName: "header"
                width: parent.width
                implicitHeight: heroContent.implicitHeight + Style.space(24)
                Item {
                  id: heroContent
                  anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10); anchors.rightMargin: Style.space(10)
                  implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)
                  Text { id: heroIcon; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: root.icon; color: root.bar ? root.bar.foreground : root.ink; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.display; opacity: root.touchpadEnabled ? 1 : 0.5 }
                  ToggleSwitch {
                    id: powerSwitch
                    visible: root.deviceName !== ""
                    checked: root.touchpadEnabled
                    hasCursor: false
                    foreground: root.bar ? root.bar.foreground : root.ink
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    onHovered: function(on) { if (on) { root.cursorActive = true; root.focusSection = "header" } }
                    onToggled: root.toggleTouchpad()
                    PanelToolTip { visible: powerSwitch.containsMouse; text: root.touchpadEnabled ? "Disable touchpad" : "Enable touchpad"; fontFamily: root.bar ? root.bar.fontFamily : Style.font.family }
                  }
                  Column {
                    id: heroLabels
                    anchors.left: heroIcon.right; anchors.leftMargin: Style.space(14); anchors.right: parent.right; anchors.rightMargin: powerSwitch.visible ? powerSwitch.width + Style.space(12) : 0
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)
                    Text { text: /touchpad|trackpad/i.test(root.selectedLabel) ? root.selectedLabel : root.selectedLabel + " trackpad"; color: root.bar ? root.bar.foreground : root.ink; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.title; font.bold: true; elide: Text.ElideRight; width: parent.width; textFormat: Text.PlainText }
                    Text { text: root.heroStatusText.toUpperCase(); color: Qt.darker(root.bar ? root.bar.foreground : root.ink, 1.4); font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1.2; elide: Text.ElideRight; width: parent.width }
                  }
                }
              }
              SliderRow {
                id: scrollRow
                sectionName: "scroll"
                width: parent.width
                label: "Scroll Speed"
                valueText: {
                  var v = scrollRow.dragging ? scrollRow.liveValue : root.scrollFactor
                  return Model.scrollSpeedLabel(v) + "  " + v.toFixed(2) + (root.scrollScale === 1 ? "×" : " × " + root.scrollScale.toFixed(2))
                }
                minimum: 0.01; maximum: 1.0; step: 0.01
                value: root.scrollFactor
                dimmed: !root.touchpadEnabled
                onMoved: function(v) { root.setScrollFactor(v) }
                onReleased: function(v) { root.setScrollFactor(v); scrollDebounce.stop(); root.commitScrollFactor() }
                onNudged: function(d) { root.adjustScrollFactor(d) }
              }
              SliderRow {
                id: pointerRow
                sectionName: "pointer"
                width: parent.width
                visible: root.pointerFeel.profile !== "mac" && root.pointerFeel.profile !== "custom"
                height: visible ? implicitHeight : 0
                label: "Pointer Speed"
                valueText: {
                  var v = pointerRow.dragging ? pointerRow.liveValue : root.pointerSpeed
                  return Model.pointerSpeedLabel(v) + "  " + v.toFixed(1)
                }
                minimum: -1.0; maximum: 1.0; step: 0.1
                value: root.pointerSpeed
                dimmed: !root.touchpadEnabled
                onMoved: function(v) { root.setPointerSpeed(v) }
                onReleased: function(v) { root.setPointerSpeed(v); pointerDebounce.stop(); root.commitPointerSpeed() }
                onNudged: function(d) { root.adjustPointerSpeed(d) }
              }
              SettingRow {
                sectionName: "scale"
                width: parent.width
                implicitHeight: scaleContent.implicitHeight + Style.space(24)
                Item {
                  id: scaleContent
                  anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10); anchors.rightMargin: Style.space(10)
                  implicitHeight: Math.max(scaleLabels.implicitHeight, scaleSpinner.implicitHeight)
                  Column {
                    id: scaleLabels
                    anchors.left: parent.left; anchors.right: scaleSpinner.left; anchors.rightMargin: Style.space(12); anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)
                    Text { text: "Device scale"; color: root.bar ? root.bar.foreground : root.ink; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body }
                    Text { text: "Scroll range and curve ceiling · 1× for this pad, 3× for a wider range"; color: Qt.darker(root.bar ? root.bar.foreground : root.ink, 1.5); font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; width: parent.width; elide: Text.ElideRight }
                  }
                  SpinBox {
                    id: scaleSpinner
                    objectName: "scrollScaleSpinner"
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(110)
                    from: 10; to: 1000; stepSize: 10
                    value: Math.round(root.scrollScale * 100)
                    editable: true; live: false; wheelEnabled: false
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                    textFromValue: function(value, locale) { return (value / 100).toLocaleString(locale, 'f', 2) }
                    valueFromText: function(text, locale) { return Math.round(Number.fromLocaleString(locale, text) * 100) }
                    validator: DoubleValidator { bottom: 0.1; top: 10; decimals: 2; notation: DoubleValidator.StandardNotation; locale: scaleSpinner.locale.name }
                    onValueModified: root.setScrollScale(value / 100)
                    Accessible.name: "Device scale for " + root.selectedLabel
                    implicitHeight: Style.space(34)
                    leftPadding: Style.space(8); rightPadding: Style.space(24)
                    function handleLargeStep(event) {
                      if (!(event.modifiers & Qt.ShiftModifier) || (event.key !== Qt.Key_Up && event.key !== Qt.Key_Down)) return
                      var current = scaleInput.acceptableInput ? valueFromText(scaleInput.text, locale) : value
                      root.setScrollScale(Math.max(from, Math.min(to, current + (event.key === Qt.Key_Up ? 1 : -1) * stepSize * 10)) / 100)
                      event.accepted = true
                    }
                    Keys.onPressed: function(event) { handleLargeStep(event) }
                    contentItem: TextInput {
                      id: scaleInput
                      objectName: "scrollScaleInput"
                      text: scaleSpinner.textFromValue(scaleSpinner.value, scaleSpinner.locale)
                      font: scaleSpinner.font
                      color: root.bar ? root.bar.foreground : root.ink
                      selectionColor: Color.accent
                      selectedTextColor: Color.background
                      verticalAlignment: TextInput.AlignVCenter
                      selectByMouse: true; clip: true
                      validator: scaleSpinner.validator
                      inputMethodHints: Qt.ImhFormattedNumbersOnly
                      Keys.onPressed: function(event) { scaleSpinner.handleLargeStep(event) }
                    }
                    background: Rectangle {
                      color: Qt.alpha(root.bar ? root.bar.foreground : root.ink, 0.04)
                      border.width: 1
                      border.color: scaleSpinner.activeFocus ? Color.accent : Qt.alpha(root.bar ? root.bar.foreground : root.ink, 0.2)
                    }
                    up.indicator: Text { x: scaleSpinner.width - width; y: 0; width: Style.space(22); height: scaleSpinner.height / 2; text: "▴"; color: root.bar ? root.bar.foreground : root.ink; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; opacity: scaleSpinner.up.pressed ? 1 : 0.65 }
                    down.indicator: Text { x: scaleSpinner.width - width; y: scaleSpinner.height / 2; width: Style.space(22); height: scaleSpinner.height / 2; text: "▾"; color: root.bar ? root.bar.foreground : root.ink; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; opacity: scaleSpinner.down.pressed ? 1 : 0.65 }
                  }
                }
              }
            }
            // Right: the toggles and the way into the curve editor.
            Column {
              width: (parent.width - 24) / 2
              spacing: -1
              SettingRow {
                sectionName: "acceleration"
                width: parent.width
                height: Style.space(58)
                foreground: root.bar ? root.bar.foreground : root.ink
                fill: root.hoverFill
                opacity: root.touchpadEnabled ? 1 : 0.4
                enabled: root.touchpadEnabled
                Column {
                  anchors.left: parent.left; anchors.leftMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(3)
                  Text { text: "Pointer feel  ›"; color: root.bar ? root.bar.foreground : root.ink; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.body }
                  Text { text: ({ adaptive: "System", flat: "Flat", mac: "Mac-inspired", custom: "Custom" })[root.pointerFeel.profile] + " · Presets and acceleration curve, with your finger-speed map under it"; color: Qt.darker(root.bar ? root.bar.foreground : root.ink, 1.4); font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption }
                }
                MouseArea {
                  anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                  onContainsMouseChanged: if (containsMouse) { root.cursorActive = true; root.focusSection = "acceleration" }
                  onClicked: root.openCurveEditor()
                }
              }
              ToggleRow { width: parent.width; label: "Natural Scrolling"; description: "Scroll content in the direction of finger movement"; checked: root.naturalScroll; sectionName: "natural"; enabled: root.touchpadEnabled; onToggled: root.toggleNaturalScroll() }
              ToggleRow { width: parent.width; label: "Tap to Click"; description: "Tap the touchpad to click"; checked: root.tapToClick; sectionName: "tap"; enabled: root.touchpadEnabled; onToggled: root.toggleTapToClick() }
              ToggleRow { width: parent.width; label: "Disable While Typing"; description: "Ignore touchpad input while typing"; checked: root.disableWhileTyping; sectionName: "typing"; enabled: root.touchpadEnabled; onToggled: root.toggleDisableWhileTyping() }
              ToggleRow { width: parent.width; label: "Two-Finger Right Click"; description: "Press with two fingers to right-click"; checked: root.clickfingerBehavior; sectionName: "clickfinger"; enabled: root.touchpadEnabled; onToggled: root.toggleClickfingerBehavior() }
            }
          }
          Label {
            width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 10
            text: "Sliders and switches save as you use them, per device, through Trackpad Plus's journalled backend. The first edit of a new device applies every value shown. ↑↓ moves between rows, ←→ adjusts, Enter toggles."
          }
        }

        // ================= POINTER FEEL =================
        Row {
          width: parent.width
          spacing: 20
          visible: !root.chooseMode && root.active === "feel"
          height: visible ? implicitHeight : 0
          Column {
            width: 600
            spacing: Style.space(10)
            CurveEditor {
              id: curveEditor
              width: parent.width
              foreground: root.bar ? root.bar.foreground : root.ink
              accent: Color.accent
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              uiScale: Style.space(100) / 100
              saved: root.pointerFeel
              gainMaximum: root.scrollScale
              hardwareScale: root.presetScale
              deviceLabel: /touchpad|trackpad/i.test(root.selectedLabel) ? root.selectedLabel : root.selectedLabel + " Trackpad"
              busy: actionProc.running || root.pendingActions.length > 0
              settingsError: root.settingsError
              canRestore: !!root.previousFeels[root.selectedDevice]
              speedHistogram: root.cursorOnly ? [] : root.feelHist
              histogramBinUnits: root.binWidth / root.mmPerUnitMs
              histogramColor: root.tint
              onApplyRequested: function(value) { root.applyPointerFeel(value) }
              onRestoreRequested: root.restorePointerFeel()
              onBackRequested: { root.active = "controls"; keyCatcher.forceActiveFocus() }
            }
          }
          Column {
            width: parent.width - 620
            spacing: 12
            Card {
              width: parent.width; height: 250
              Column {
                anchors.fill: parent; anchors.margins: 14; spacing: 8
                Row {
                  width: parent.width
                  Heading { text: "WHERE YOUR FINGERS LIVE"; font.pixelSize: 12; width: parent.width - 90 }
                  Label { text: root.feelHist === root.todayHist ? "today" : "this week"; font.pixelSize: 10; width: 90; horizontalAlignment: Text.AlignRight }
                }
                SpeedHistogram {
                  width: parent.width; height: 160
                  hist: root.cursorOnly ? [] : root.feelHist; binWidth: root.binWidth; mmPerUnitMs: root.mmPerUnitMs
                  curveStart: curveEditor.custom ? curveEditor.draft.curve.start : -1
                  curveEnd: curveEditor.custom ? curveEditor.draft.curve.end : -1
                  tint: root.tint; heat: root.heat; ink: root.ink; surface: Color.popups.background
                }
                Label { width: parent.width; font.pixelSize: 10; wrapMode: Text.WordWrap; text: "Bars: seconds of finger movement per 5 mm/s. Solid line: median. Dotted: 90th percentile. Shaded: the draft curve's acceleration band. Dashed: the right edge of the graph on the left." }
              }
            }
            Card {
              width: parent.width; height: optimizeColumn.implicitHeight + 28
              border.color: root.proposal ? Qt.alpha(root.tint, 0.55) : root.cardEdge
              Column {
                id: optimizeColumn
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 14
                spacing: 8
                Row {
                  width: parent.width
                  Heading { text: "OPTIMIZE FOR MY HAND"; font.pixelSize: 12; width: parent.width - 150 }
                  Label {
                    width: 150; horizontalAlignment: Text.AlignRight; font.pixelSize: 10
                    text: root.proposal ? root.proposal.verdict + " · " + root.proposal.confidence + " confidence" : ""
                    color: root.proposal && root.proposal.confidence === "high" ? root.tint : root.inkDim
                  }
                }
                Label {
                  visible: !root.proposal
                  width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 11
                  text: "One change a pass: Start and End to where your fingers live, then the gains and the scroll speed by at most 10% from your overshoots and re-strokes. The next pass keeps the change or proposes undoing it, with the reason logged. Nothing changes until you Apply."
                }
                Column {
                  visible: !!root.proposal
                  width: parent.width; spacing: 6
                  Repeater {
                    model: root.proposal ? root.proposal.changes : []
                    Column {
                      id: changeRow
                      required property var modelData
                      width: parent.width; spacing: 1
                      Row {
                        spacing: 8
                        Heading { text: changeRow.modelData.label; font.pixelSize: 12; width: 110 }
                        Label { text: root.fmtValue(changeRow.modelData.key, changeRow.modelData.from) + "  →  "; font.pixelSize: 12 }
                        Heading { text: root.fmtValue(changeRow.modelData.key, changeRow.modelData.to); font.pixelSize: 12; color: root.tint }
                      }
                      Label { text: changeRow.modelData.reason; width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 10 }
                    }
                  }
                  Label {
                    visible: !!root.proposal && root.proposal.verdict === "watching"
                    width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 11; color: root.ink
                    text: root.proposal && root.proposal.previous ? "Still judging " + String(root.proposal.previous.summary || "the last pass") + ", applied " + Pulse.ago(root.proposal.previous.ts, root.now) + ": " + String(root.proposal.previous.reason || "") + " Nothing else changes until it is kept or undone." : ""
                  }
                  Label {
                    visible: !!root.proposal && root.proposal.changes.length === 0 && root.proposal.verdict !== "watching"
                    width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 11; color: root.ink
                    text: "Nothing to change: the shape already fits and neither overshoots nor re-strokes are running high."
                  }
                  Label {
                    visible: !!root.proposal && (root.proposal.queued || []).length > 0
                    width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 10
                    text: "Seen, waiting its turn: " + (root.proposal ? (root.proposal.queued || []).map(function(q) { return q.label + " " + root.fmtValue(q.key, q.from) + " → " + root.fmtValue(q.key, q.to) }).join("  ·  ") : "")
                  }
                  Repeater {
                    model: root.proposal ? root.proposal.notes : []
                    Label { required property string modelData; text: "· " + modelData; width: optimizeColumn.width; wrapMode: Text.WordWrap; font.pixelSize: 10; color: root.ink }
                  }
                  Label {
                    width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 10
                    text: {
                      var p = root.proposal
                      if (!p) return ""
                      var e = p.evidence || {}
                      return p.message + "  Overshoot corrections " + Math.round(Pulse.num(e.correctionRate) * 100) + "% of long moves (" + Math.round(Pulse.num(e.fastCorrectionRate) * 100) + "% after fast ones)  ·  re-strokes " + Math.round(Pulse.num(e.restrokeRate) * 100) + "%  ·  scroll reversals " + Math.round(Pulse.num(e.scrollReversalRate) * 100) + "% of " + Pulse.int(e.scrolls) + " scrolls."
                    }
                  }
                  Label {
                    visible: !!(root.proposal && root.proposal.previous) && root.proposal.verdict !== "watching"
                    width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 10; color: root.ink
                    text: {
                      var q = root.proposal ? root.proposal.previous : null
                      if (!q) return ""
                      var when = Qt.formatDateTime(new Date(Pulse.num(q.ts) * 1000), "ddd d MMM h:mm AP")
                      var s = "Last pass, " + when + ", " + (q.undo ? "undid " : "") + String(q.summary || "") + ": " + (q.judgement === "undo" ? "undo proposed. " : String(q.judgement || "") + ". ") + String(q.reason || "")
                      if (q.practiceBefore && q.practiceAfter) s += " Target practice " + (Pulse.num(q.practiceBefore) / 1000).toFixed(2) + " s → " + (Pulse.num(q.practiceAfter) / 1000).toFixed(2) + " s."
                      return s
                    }
                  }
                }
                Row {
                  spacing: 8
                  Action { visible: !root.proposal; text: pulseProc.running && pulseProc.mode === "optimize" ? "Reading…" : root.hintActive ? "Optimize for my hand  ·  new proposal" : "Optimize for my hand"; accent: root.tint; selected: true; opacity: root.hintActive ? root.pulseOpacity : 1; enabled: !pulseProc.running && !root.cursorOnly && !root.stale; onClicked: root.requestOptimize() }
                  Action { visible: !!root.proposal && root.proposal.changes.length > 0; text: root.proposal && root.proposal.verdict === "undo" ? "Undo it" : "Apply this"; accent: root.tint; selected: true; enabled: !(actionProc.running || root.pendingActions.length > 0); onClicked: root.applyProposal() }
                  Action { visible: !!root.proposal && root.proposal.verdict === "undo"; text: "Keep it anyway"; enabled: !pulseProc.running; onClicked: root.keepAnyway() }
                  Action { visible: !!root.proposal; text: root.proposal && root.proposal.changes.length > 0 ? "Dismiss" : "Close"; onClicked: { root.proposal = null; root.hintSeen() } }
                  Label { visible: root.cursorOnly || root.stale; anchors.verticalCenter: parent.verticalCenter; font.pixelSize: 10; text: root.stale ? "needs the recorder" : "needs pad access, not cursor-only" }
                }
              }
            }
            Card {
              width: parent.width; height: readingColumn.implicitHeight + 28
              Column {
                id: readingColumn
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 14
                spacing: 8
                Heading { text: "WHAT THE DATA SAYS"; font.pixelSize: 12 }
                Label {
                  width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 11; color: root.ink
                  text: {
                    if (root.cursorOnly) return "Without access to the pad there is no finger speed to compare the curve against. Grant it from the Touch lab."
                    var h = root.feelHist
                    if (Pulse.total(h) < 5) return "Fewer than five seconds of movement recorded. Use the pad for a while and come back; the curve will have something to be judged against."
                    var med = Pulse.percentile(h, root.binWidth, 0.5), p90 = Pulse.percentile(h, root.binWidth, 0.9)
                    var lines = ["Half of your movement is slower than " + Pulse.speed(med) + ", which is " + Math.round(Pulse.mmToCurve(med, root.mmPerUnitMs) / 4 * 100) + "% of the way across the graph. Nine tenths is under " + Pulse.speed(p90) + "."]
                    if (curveEditor.custom) {
                      var s = Pulse.curveToMm(curveEditor.draft.curve.start, root.mmPerUnitMs), e = Pulse.curveToMm(curveEditor.draft.curve.end, root.mmPerUnitMs)
                      var below = Pulse.shareBelow(h, root.binWidth, s), inside = Pulse.shareBelow(h, root.binWidth, e) - below
                      lines.push("This draft holds precision gain up to " + Pulse.speed(s) + " and reaches full gain at " + Pulse.speed(e) + ": " + Math.round(below * 100) + "% of your movement stays in the precision zone, " + Math.round(inside * 100) + "% rides the transition, " + Math.round((1 - below - inside) * 100) + "% is already at full gain.")
                      if (below > 0.85) lines.push("Nearly everything you do is below Start. Either that is the point, or Start could come left.")
                      if (below + inside < 0.3) lines.push("Most of your movement is past End: the curve is mostly acting as a flat multiplier. Push End right to spread the transition over speeds you actually use.")
                    } else {
                      lines.push("Choose Custom or Mac-inspired to place the acceleration band against this distribution.")
                    }
                    var beyond = 1 - Pulse.shareBelow(h, root.binWidth, Pulse.curveToMm(4, root.mmPerUnitMs))
                    if (beyond > 0.15) lines.push(Math.round(beyond * 100) + "% of your movement is faster than the graph's right edge; libinput holds the fast-swipe gain out there.")
                    return lines.join("  ")
                  }
                }
              }
            }
          }
        }

        // ================= GESTURES =================
        Column {
          width: parent.width
          spacing: 12
          visible: !root.chooseMode && root.active === "gestures"
          height: visible ? implicitHeight : 0
          Rectangle {
            width: parent.width; height: 58; radius: 12
            color: Util.alpha(root.gesturesApplied ? root.tint : Color.accent, 0.09)
            border.color: Util.alpha(root.gesturesApplied ? root.tint : Color.accent, 0.38)
            Row {
              anchors.fill: parent; anchors.margins: 12; spacing: 14
              Column {
                width: parent.width - 330; anchors.verticalCenter: parent.verticalCenter; spacing: 3
                Heading { font.pixelSize: 12; text: root.gesturesApplied ? "LIVE IN HYPRLAND" : "SUGGESTED, NOT APPLIED YET" }
                Label { width: parent.width; elide: Text.ElideRight; font.pixelSize: 10
                  text: root.gesturesApplied ? "Pick an action for any gesture; it applies at once. The file is " + (root.catalogueMeta.file || "") + "."
                    : "These are suggestions. Press Apply suggested to switch them on, or change any of them first." }
              }
              Action { anchors.verticalCenter: parent.verticalCenter; text: root.gesturesApplied ? "Reset to suggested" : "Apply suggested"; accent: root.tint; selected: !root.gesturesApplied; enabled: !pulseProc.running && root.catalogue.length > 0; onClicked: root.applyGestures(root.gestureDefaults) }
              Action { anchors.verticalCenter: parent.verticalCenter; text: "Clear all"; enabled: !pulseProc.running && root.catalogue.length > 0; onClicked: { var none = {}; for (var k in root.gestureDefaults) none[k] = "none"; root.applyGestures(none) } }
            }
          }
          Row {
            width: parent.width; spacing: 10
            Repeater {
              model: [3, 4]
              Card {
                id: fingerCard
                required property int modelData
                width: (shell.width - 10) / 2; height: gestureColumn.implicitHeight + 28
                Column {
                  id: gestureColumn
                  anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 14
                  spacing: 8
                  Row {
                    width: parent.width
                    Heading { text: fingerCard.modelData + " FINGERS"; font.pixelSize: 12; width: parent.width / 2 }
                    Label { text: "swipe and pinch"; font.pixelSize: 10; width: parent.width / 2; horizontalAlignment: Text.AlignRight }
                  }
                  Repeater {
                    model: [
                      { d: "left", l: "←  Swipe left" }, { d: "right", l: "→  Swipe right" }, { d: "up", l: "↑  Swipe up" }, { d: "down", l: "↓  Swipe down" },
                      { d: "pinchin", l: "⤡  Pinch in" }, { d: "pinchout", l: "⤢  Pinch out" }
                    ]
                    Row {
                      id: gestureRow
                      required property var modelData
                      readonly property string slot: fingerCard.modelData + "-" + modelData.d
                      readonly property var current: root.actionById(root.gestureValue(slot))
                      width: gestureColumn.width; spacing: 10
                      Label { text: gestureRow.modelData.l; width: 128; color: root.ink; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
                      SearchableDropdown {
                        width: gestureColumn.width - 138
                        showLabel: false
                        options: root.gestureOptions
                        value: root.gestureValue(gestureRow.slot)
                        placeholderText: "Search actions…"
                        emptyText: "No action matches"
                        onChanged: function(v) { if (v !== root.gestureValue(gestureRow.slot)) root.setGesture(gestureRow.slot, v) }
                      }
                    }
                  }
                  Label { width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 10
                    text: fingerCard.modelData === 3 ? "Slide, move, resize and scroll-the-tape follow your fingers and take both directions of their axis." : "Themes and backgrounds live here by default: left and right step through themes, up changes the background." }
                }
              }
            }
          }
          Label { visible: root.catalogue.length === 0; text: pulseProc.running ? "Loading the action catalogue…" : "The action catalogue did not load. " + root.actionStatus; font.pixelSize: 11; color: root.ink }
          Label {
            width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 10
            text: "Gestures are Hyprland's own: the panel writes one Lua file of hl.gesture lines into Omarchy's toggles and asks Hyprland to reload, nothing runs in the background. Native actions (slide, fullscreen, close, float, scratchpad, zoom) animate 1:1; the rest run an Omarchy command. If you also define gestures in input.lua they add up, so keep one place in charge."
          }
        }

        // ================= REPORT =================
        Column {
          width: parent.width
          spacing: 12
          visible: !root.chooseMode && root.active === "report"
          height: visible ? implicitHeight : 0
          readonly property var rp: root.reportData || ({})
          readonly property var wk: rp.week || ({})
          readonly property var lw: rp.lastWeek || ({})
          function delta(a, b) { a = Pulse.num(a); b = Pulse.num(b); if (b <= 0) return "no last week yet"; var d = (a - b) / b * 100; return (d >= 0 ? "+" : "") + d.toFixed(0) + "% vs last week" }
          id: reportPage
          Row {
            width: parent.width; spacing: 10
            Stat { width: (parent.width - 30) / 4; height: 96; label: "THIS WEEK · DISTANCE"; value: Pulse.distance(reportPage.wk.distance); hint: reportPage.delta(reportPage.wk.distance, reportPage.lw.distance) + " · " + (reportPage.wk.days || 0) + " days recorded" }
            Stat { width: (parent.width - 30) / 4; height: 96; label: "TOUCHES"; value: Pulse.int(reportPage.wk.touches); hint: reportPage.delta(reportPage.wk.touches, reportPage.lw.touches) + " · " + Pulse.int(reportPage.wk.taps) + " taps" }
            Stat { width: (parent.width - 30) / 4; height: 96; label: "CLICKS"; value: Pulse.int(reportPage.wk.clicks); hint: reportPage.delta(reportPage.wk.clicks, reportPage.lw.clicks) + " · " + Pulse.int(reportPage.wk.gestures) + " gestures" }
            Stat { width: (parent.width - 30) / 4; height: 96; label: "ACTIVE ON THE PAD"; value: Pulse.duration(reportPage.wk.active); hint: "peak " + Pulse.speed(reportPage.wk.peak) + " · busiest day " + (reportPage.rp.busiestDay || "—") + (reportPage.rp.busiestHour !== null && reportPage.rp.busiestHour !== undefined ? " · busiest hour " + reportPage.rp.busiestHour + ":00" : "") }
          }
          Row {
            width: parent.width; spacing: 10
            Card {
              width: parent.width * 0.6 - 5; height: 200
              Column {
                anchors.fill: parent; anchors.margins: 14; spacing: 6
                Row {
                  width: parent.width
                  Heading { text: "SEVEN DAYS"; font.pixelSize: 12; width: parent.width / 2 }
                  Label { text: "distance per day · touches below"; font.pixelSize: 10; width: parent.width / 2; horizontalAlignment: Text.AlignRight }
                }
                Item {
                  id: weekBars
                  width: parent.width; height: 140
                  readonly property var days: reportPage.rp.days || []
                  readonly property real peak: { var m = 1; for (var i = 0; i < weekBars.days.length; i++) m = Math.max(m, Pulse.num(weekBars.days[i].distance)); return m }
                  Row {
                    anchors.fill: parent; spacing: 8
                    Repeater {
                      model: weekBars.days
                      Item {
                        id: dayBar
                        required property var modelData
                        width: (weekBars.width - 8 * Math.max(0, weekBars.days.length - 1)) / Math.max(1, weekBars.days.length); height: weekBars.height
                        Label { anchors.top: parent.top; anchors.horizontalCenter: parent.horizontalCenter; font.pixelSize: 9; text: Pulse.distance(dayBar.modelData.distance) }
                        Rectangle {
                          anchors.bottom: parent.bottom; anchors.bottomMargin: 26; anchors.horizontalCenter: parent.horizontalCenter
                          width: parent.width * 0.7; radius: 3
                          height: Math.max(2, (weekBars.height - 44) * Pulse.num(dayBar.modelData.distance) / weekBars.peak)
                          color: dayBar.modelData.day === (root.today.day || "") ? root.tint : Util.alpha(root.tint, 0.45)
                        }
                        Label { anchors.bottom: parent.bottom; anchors.bottomMargin: 13; anchors.horizontalCenter: parent.horizontalCenter; font.pixelSize: 9; text: Pulse.int(dayBar.modelData.touches) }
                        Label { anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter; font.pixelSize: 9; color: root.ink; text: String(dayBar.modelData.day || "").slice(5) }
                      }
                    }
                  }
                  Label { visible: weekBars.days.length === 0; anchors.centerIn: parent; text: "No days recorded yet." }
                }
              }
            }
            Card {
              width: parent.width * 0.4 - 5; height: 200
              Column {
                anchors.fill: parent; anchors.margins: 14; spacing: 6
                Heading { text: "YOUR HAND"; font.pixelSize: 12 }
                Heading {
                  readonly property var hand: root.snap.hand || reportPage.rp.hand || ({})
                  text: hand.hand === "right" ? "Right hand" : hand.hand === "left" ? "Left hand" : "Not sure yet"; font.pixelSize: 26; color: root.tint
                }
                Label { readonly property var hand: root.snap.hand || reportPage.rp.hand || ({}); text: hand.confidence ? "confidence " + Pulse.pct(hand.confidence) : ""; font.pixelSize: 10 }
                Label { readonly property var hand: root.snap.hand || reportPage.rp.hand || ({}); width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 11; text: String(hand.reason || "") }
                Label { width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 10; text: "Read from today's heatmap and where rejected palms land: a right hand parks its thumb bottom-left and drops its heel bottom-right." }
              }
            }
          }
          Row {
            width: parent.width; spacing: 10
            Card {
              width: parent.width * 0.5 - 5; height: 186
              Column {
                anchors.fill: parent; anchors.margins: 14; spacing: 7
                Row {
                  width: parent.width
                  Heading { text: "MOUSE VS TRACKPAD"; font.pixelSize: 12; width: parent.width / 2 }
                  Label { text: "this week, by active time"; font.pixelSize: 10; width: parent.width / 2; horizontalAlignment: Text.AlignRight }
                }
                Item {
                  width: parent.width; height: 14
                  readonly property real pad: Pulse.num(reportPage.wk.active)
                  readonly property real mouse: Pulse.num(reportPage.wk.mouse)
                  readonly property real share: pad + mouse > 0 ? pad / (pad + mouse) : 0.5
                  Rectangle { anchors.fill: parent; radius: 7; color: Util.alpha(root.ink, 0.13) }
                  Rectangle { width: parent.width * parent.share; height: parent.height; radius: 7; color: root.tint }
                }
                Label {
                  readonly property real pad: Pulse.num(reportPage.wk.active)
                  readonly property real mouse: Pulse.num(reportPage.wk.mouse)
                  width: parent.width; font.pixelSize: 11; color: root.ink
                  text: pad + mouse > 0 ? "Trackpad " + Pulse.pct(pad / (pad + mouse)) + " · mouse " + Pulse.pct(mouse / (pad + mouse)) + "  ·  " + Pulse.duration(pad) + " on the pad, " + Pulse.duration(mouse) + " on a mouse" : "Nothing measured yet."
                }
                Row {
                  spacing: 8
                  Label { text: "Auto-off"; anchors.verticalCenter: parent.verticalCenter; color: root.ink }
                  Action { text: "On"; implicitWidth: 52; implicitHeight: 26; selected: root.autoOffOn; accent: root.tint; enabled: !pulseProc.running; onClicked: root.setAutoOff(true) }
                  Action { text: "Off"; implicitWidth: 52; implicitHeight: 26; selected: !root.autoOffOn; accent: root.tint; enabled: !pulseProc.running; onClicked: root.setAutoOff(false) }
                  Label { anchors.verticalCenter: parent.verticalCenter; font.pixelSize: 10; text: (root.snap.autoOff || {}).offNow ? "pad is off right now · a tap or a real move brings it back" : "switched off " + Pulse.int((root.snap.autoOff || {}).today) + "× today" }
                }
                Label { width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 10; text: "Cursor motion with no finger on the pad counts as a mouse. With auto-off on, 15 s of mouse use switches the pad off and a tap or a 10 mm move switches it back on." }
              }
            }
            Card {
              width: parent.width * 0.5 - 5; height: 186
              Column {
                anchors.fill: parent; anchors.margins: 14; spacing: 5
                Row {
                  width: parent.width
                  Heading { text: "WHERE YOU USE IT"; font.pixelSize: 12; width: parent.width / 2 }
                  Label { text: "touches by focused window, this week"; font.pixelSize: 10; width: parent.width / 2; horizontalAlignment: Text.AlignRight }
                }
                Repeater {
                  model: (reportPage.rp.apps || []).slice(0, 6)
                  Row {
                    id: appRow
                    required property var modelData
                    readonly property real peak: Pulse.num(((reportPage.rp.apps || [])[0] || {}).touches) || 1
                    width: parent.width; spacing: 8; height: 18
                    Label { text: appRow.modelData.app || "—"; width: 150; elide: Text.ElideRight; color: root.ink; font.pixelSize: 11; anchors.verticalCenter: parent.verticalCenter }
                    Item {
                      width: parent.width - 150 - 8 - 150 - 8; height: parent.height
                      Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 6; radius: 3; color: Util.alpha(root.ink, 0.13)
                        Rectangle { width: parent.width * Pulse.clamp(Pulse.num(appRow.modelData.touches) / appRow.peak, 0, 1); height: parent.height; radius: 3; color: root.tint } }
                    }
                    Label { text: Pulse.int(appRow.modelData.touches) + " · " + Pulse.distance(appRow.modelData.distance); width: 150; horizontalAlignment: Text.AlignRight; font.pixelSize: 10; anchors.verticalCenter: parent.verticalCenter }
                  }
                }
                Label { visible: (reportPage.rp.apps || []).length === 0; text: "Touches are stamped with the focused window from now on; the list fills as you work."; font.pixelSize: 10; width: parent.width; wrapMode: Text.WordWrap }
              }
            }
          }
          Card {
            width: parent.width; height: optColumn2.implicitHeight + 28
            Column {
              id: optColumn2
              anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 14
              spacing: 5
              Row {
                width: parent.width
                Heading { text: "OPTIMIZE HISTORY"; font.pixelSize: 12; width: parent.width / 2 }
                Label { text: Pulse.int(reportPage.wk.palms) + " palms rejected this week" + ((reportPage.rp.palms || {}).x !== null && (reportPage.rp.palms || {}).x !== undefined ? ", landing " + ((reportPage.rp.palms || {}).x >= 0.5 ? "right" : "left") + " of centre" : "") + "  ·  " + Pulse.int((reportPage.rp.strays || {}).week) + " stray touches, " + Pulse.int((reportPage.rp.strays || {}).reverts) + " put back"; font.pixelSize: 10; width: parent.width / 2; horizontalAlignment: Text.AlignRight; elide: Text.ElideLeft }
              }
              Repeater {
                model: reportPage.rp.optimize || []
                Label {
                  required property var modelData
                  width: optColumn2.width; font.pixelSize: 11; color: root.ink
                  elide: Text.ElideRight
                  text: Qt.formatDateTime(new Date(Pulse.num(modelData.ts) * 1000), "ddd d MMM h:mm AP") + "  ·  " + (modelData.undo ? "undid " : "changed ") + ((modelData.changes || []).join(", ") || "nothing") + "  ·  " + (modelData.judgement === "watching" ? "being judged" : modelData.judgement === "undo" ? "undo proposed" : String(modelData.judgement || "")) + (modelData.reason ? "  ·  " + String(modelData.reason) : "")
                }
              }
              Label { visible: (reportPage.rp.optimize || []).length === 0; width: parent.width; font.pixelSize: 11; text: "No Optimize pass applied yet. Pointer feel has the button." }
            }
          }
          Label { width: parent.width; font.pixelSize: 10; text: reportPage.rp.ts ? "Report built " + Pulse.ago(reportPage.rp.ts, root.now) + " · refreshes every minute while open" : (pulseProc.running ? "Building the report…" : "The report did not load. " + root.actionStatus) }
        }

        // ================= TOUCH LAB =================
        Column {
          width: parent.width
          spacing: 12
          visible: !root.chooseMode && root.active === "lab"
          height: visible ? implicitHeight : 0
          Row {
            width: parent.width; spacing: 10
            Card {
              width: parent.width * 0.5 - 5; height: 214
              Column {
                anchors.fill: parent; anchors.margins: 14; spacing: 6
                Row {
                  width: parent.width
                  Heading { text: "EVERY FINGER"; font.pixelSize: 12; width: parent.width / 2 }
                  Label { text: root.fingersNow > 0 ? root.fingersNow + " on the pad" : root.stale ? "recorder offline" : root.cursorOnly ? "no pad access" : "nothing touching"; width: parent.width / 2; horizontalAlignment: Text.AlignRight; color: Color.accent }
                }
                Row {
                  width: parent.width
                  Label { text: "SLOT"; font.pixelSize: 9; width: parent.width * 0.12 }
                  Label { text: "X mm"; font.pixelSize: 9; width: parent.width * 0.18 }
                  Label { text: "Y mm"; font.pixelSize: 9; width: parent.width * 0.18 }
                  Label { text: "SPEED"; font.pixelSize: 9; width: parent.width * 0.22 }
                  Label { text: "PRESSURE"; font.pixelSize: 9; width: parent.width * 0.16 }
                  Label { text: "TOOL"; font.pixelSize: 9; width: parent.width * 0.14 }
                }
                Repeater {
                  model: 5
                  Row {
                    id: fingerRow
                    required property int index
                    readonly property var f: root.active === "lab" && index < root.liveFingers.length ? root.liveFingers[index] : null
                    readonly property var pad: root.readablePads.length ? root.readablePads[0] : null
                    width: parent.width; height: 24
                    opacity: f ? 1 : 0.3
                    Label { text: fingerRow.f ? String(fingerRow.f.slot) : String(fingerRow.index); width: parent.width * 0.12; color: root.ink; anchors.verticalCenter: parent.verticalCenter }
                    Label { text: fingerRow.f && fingerRow.pad ? (fingerRow.f.x * fingerRow.pad.width).toFixed(1) : "—"; width: parent.width * 0.18; anchors.verticalCenter: parent.verticalCenter }
                    Label { text: fingerRow.f && fingerRow.pad ? (fingerRow.f.y * fingerRow.pad.height).toFixed(1) : "—"; width: parent.width * 0.18; anchors.verticalCenter: parent.verticalCenter }
                    Item {
                      width: parent.width * 0.22; height: parent.height
                      Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 8; height: 5; radius: 3; color: Util.alpha(root.ink, 0.13)
                        Rectangle { width: parent.width * Pulse.clamp((fingerRow.f ? fingerRow.f.speed : 0) / 300, 0, 1); height: parent.height; radius: 3; color: root.tint } }
                    }
                    Label { text: fingerRow.f ? (fingerRow.f.p === null || fingerRow.f.p === undefined ? "n/a" : Pulse.pct(fingerRow.f.p)) : "—"; width: parent.width * 0.16; anchors.verticalCenter: parent.verticalCenter }
                    Label { text: fingerRow.f ? (fingerRow.f.palm ? "palm" : "finger") : "—"; width: parent.width * 0.14; color: fingerRow.f && fingerRow.f.palm ? root.heat : root.inkDim; anchors.verticalCenter: parent.verticalCenter }
                  }
                }
              }
            }
            Card {
              width: parent.width * 0.5 - 5; height: 214
              Column {
                anchors.fill: parent; anchors.margins: 14; spacing: 8
                Heading { text: "THE PAD"; font.pixelSize: 12 }
                Grid {
                  width: parent.width; columns: 3; columnSpacing: 10; rowSpacing: 8
                  Repeater {
                    model: {
                      var p = root.readablePads.length ? root.readablePads[0] : (root.pads.length ? root.pads[0] : null)
                      if (!p) return [{ l: "DEVICE", v: root.deviceName || "—", h: "as Hyprland names it" }]
                      return [
                        { l: "SIZE", v: p.width ? p.width + " × " + p.height + " mm" : "—", h: p.unitsX ? p.unitsX + " × " + p.unitsY + " units" : "" },
                        { l: "RESOLUTION", v: p.resX ? p.resX + " units/mm" : "—", h: p.resX ? (25.4 * p.resX).toFixed(0) + " dpi" : "" },
                        { l: "FINGERS", v: p.slots ? p.slots + " slots" : "—", h: p.multitouch ? "multitouch" : "single touch" },
                        { l: "REPORT RATE", v: Pulse.hz(p.hz), h: "frames per second while touched" },
                        { l: "PRESSURE", v: p.pressure ? "yes" : "no", h: p.major ? "touch size reported" : "no touch size" },
                        { l: "BUS", v: (p.bus || "—") + (p.vendor ? "  " + p.vendor + ":" + p.product : ""), h: p.node || "" }
                      ]
                    }
                    Column {
                      id: padFact
                      required property var modelData
                      width: (shell.width * 0.5 - 5 - 28 - 20) / 3
                      spacing: 2
                      Label { text: padFact.modelData.l; font.pixelSize: 9; font.letterSpacing: 1 }
                      Heading { text: padFact.modelData.v; font.pixelSize: 14; width: parent.width; elide: Text.ElideRight }
                      Label { text: padFact.modelData.h; font.pixelSize: 9; width: parent.width; elide: Text.ElideRight }
                    }
                  }
                }
                Label { width: parent.width; font.pixelSize: 10; elide: Text.ElideRight; text: root.readablePads.length ? (root.readablePads[0].kernelName || root.readablePads[0].name) + "  ·  " + root.readablePads[0].phys : "" }
              }
            }
          }
          Row {
            width: parent.width; spacing: 10
            Rectangle {
              width: parent.width * 0.5 - 5; height: 196; radius: 12
              color: Util.alpha(Color.accent, 0.09); border.color: Util.alpha(Color.accent, 0.38)
              Column {
                anchors.fill: parent; anchors.margins: 14; spacing: 8
                Heading { text: "ACCESS"; font.pixelSize: 12 }
                Label {
                  width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 11; color: root.inkDim
                  text: {
                    if (root.stale) return "The recorder is not running, so nothing is being read. Start it and it will report which of these it has."
                    var parts = ["Recorder: " + Pulse.accessLabel(root.snap) + "."]
                    parts.push("input group: " + (root.snap.inputGroup ? "yes (Omarchy normally removes it)" : "no") + ".")
                    parts.push("udev rule: " + (root.snap.udevRule ? "installed" : "not installed") + ".")
                    if (root.snap.access === "evdev") parts.push("Fingers, taps and gestures are being read from the pad's own event node.")
                    else parts.push("A udev rule can grant the logged-in seat read access to touchpad nodes only. It takes one polkit prompt and is removable here.")
                    return parts.join("  ")
                  }
                }
                Row {
                  spacing: 8
                  Action { text: root.stale ? "Start the recorder" : "Restart the recorder"; accent: Color.accent; enabled: !pulseProc.running; onClicked: root.runPulse("install-service") }
                  Action { visible: !root.stale; text: root.snap.udevRule ? "Remove the udev rule" : "Grant touchpad access"; accent: Color.accent; selected: !root.snap.udevRule && root.noAccess; enabled: !pulseProc.running; onClicked: root.runPulse(root.snap.udevRule ? "revoke-access" : "grant-access") }
                  Action { visible: !root.stale; text: "Stop the recorder"; enabled: !pulseProc.running; onClicked: root.runPulse("uninstall-service") }
                }
              }
            }
            Card {
              width: parent.width * 0.5 - 5; height: 196
              Column {
                anchors.fill: parent; anchors.margins: 14; spacing: 3
                Row {
                  width: parent.width
                  Heading { text: "EVERY CLOCK"; font.pixelSize: 12; width: parent.width / 2 }
                  Label { text: root.spans.firstDay ? "recording since " + root.spans.firstDay : ""; font.pixelSize: 10; width: parent.width / 2; horizontalAlignment: Text.AlignRight }
                }
                Row {
                  width: parent.width
                  Label { text: ""; width: parent.width * 0.16; font.pixelSize: 9 }
                  Repeater {
                    model: ["DISTANCE", "TOUCHES", "TAPS", "CLICKS", "ACTIVE", "PER HOUR"]
                    Label { required property string modelData; text: modelData; font.pixelSize: 9; font.letterSpacing: 1; width: (parent.width * 0.84) / 6; horizontalAlignment: Text.AlignRight }
                  }
                }
                Repeater {
                  model: [
                    { l: "Last minute", k: "minute", s: 60 }, { l: "Last hour", k: "hour", s: 3600 }, { l: "Today", k: "today", s: 0 }, { l: "Week", k: "week", s: 0 },
                    { l: "Month", k: "month", s: 0 }, { l: "Year", k: "year", s: 0 }, { l: "All time", k: "all", s: 0 }
                  ]
                  Row {
                    id: clockRow
                    required property var modelData
                    readonly property var span: root.spans[clockRow.modelData.k] || ({})
                    // Touches per hour of active use, so a day of typing does not dilute it.
                    readonly property real perHour: Pulse.num(clockRow.span.active) > 30 ? Pulse.num(clockRow.span.touches) / (Pulse.num(clockRow.span.active) / 3600) : 0
                    width: parent.width
                    Label { text: clockRow.modelData.l; width: parent.width * 0.16; font.pixelSize: 10; color: root.ink }
                    Label { text: root.stale ? "—" : Pulse.distance(clockRow.span.distance); width: (parent.width * 0.84) / 6; horizontalAlignment: Text.AlignRight; font.pixelSize: 10; color: root.ink }
                    Label { text: root.stale ? "—" : Pulse.int(clockRow.span.touches); width: (parent.width * 0.84) / 6; horizontalAlignment: Text.AlignRight; font.pixelSize: 10 }
                    Label { text: root.stale ? "—" : Pulse.int(clockRow.span.taps); width: (parent.width * 0.84) / 6; horizontalAlignment: Text.AlignRight; font.pixelSize: 10 }
                    Label { text: root.stale ? "—" : Pulse.int(clockRow.span.clicks); width: (parent.width * 0.84) / 6; horizontalAlignment: Text.AlignRight; font.pixelSize: 10 }
                    Label { text: root.stale ? "—" : Pulse.duration(clockRow.span.active); width: (parent.width * 0.84) / 6; horizontalAlignment: Text.AlignRight; font.pixelSize: 10 }
                    Label { text: root.stale || clockRow.perHour <= 0 ? "—" : Pulse.int(clockRow.perHour) + " touches"; width: (parent.width * 0.84) / 6; horizontalAlignment: Text.AlignRight; font.pixelSize: 10 }
                  }
                }
              }
            }
          }
          Row {
            width: parent.width; spacing: 10
            Card {
              width: parent.width * 0.5 - 5; height: 206
              Column {
                anchors.fill: parent; anchors.margins: 14; spacing: 6
                Row {
                  width: parent.width
                  Heading { text: "STRAY TOUCHES"; font.pixelSize: 12; width: parent.width / 2 }
                  Label { text: "where they start · today"; font.pixelSize: 10; width: parent.width / 2; horizontalAlignment: Text.AlignRight }
                }
                Row {
                  width: parent.width; spacing: 12
                  HeatMap { width: parent.width * 0.42; height: 112; emptyText: "No stray touches yet"; heat: root.today.strayHeat || []; cols: Pulse.num(root.snap.heatW) || 32; rows: Pulse.num(root.snap.heatH) || 20; aspect: root.padAspect; tint: root.tint; hot: root.heat; ink: root.ink; surface: Color.background }
                  Column {
                    width: parent.width * 0.58 - 12; spacing: 5
                    Label { width: parent.width; font.pixelSize: 11; color: root.ink; text: root.stale || root.cursorOnly ? "Needs the recorder on the pad's own node." : Pulse.int(root.strayGuard.today) + " today · " + Pulse.int(root.strayGuard.week) + " this week" }
                    Label { width: parent.width; font.pixelSize: 10; wrapMode: Text.WordWrap; text: "A brief brush on an idle pad, or a slow drift from the thumb strip or a side edge, that moved the cursor." }
                    Row {
                      spacing: 8
                      Label { text: "Put back"; anchors.verticalCenter: parent.verticalCenter; color: root.ink }
                      Action { text: "On"; implicitWidth: 52; implicitHeight: 26; selected: root.strayGuardOn; accent: root.tint; enabled: !pulseProc.running && !root.stale; onClicked: root.setStrayGuard(true) }
                      Action { text: "Off"; implicitWidth: 52; implicitHeight: 26; selected: !root.strayGuardOn; accent: root.tint; enabled: !pulseProc.running && !root.stale; onClicked: root.setStrayGuard(false) }
                      Label { anchors.verticalCenter: parent.verticalCenter; font.pixelSize: 10; text: Pulse.int(root.strayGuard.reverts) + " put back · " + Pulse.int(root.strayGuard.regrets) + " regretted" + (Pulse.num(root.strayGuard.reverts) >= 10 && Pulse.num(root.strayGuard.regrets) / Pulse.num(root.strayGuard.reverts) > 0.2 ? " · fighting you, consider Off" : "") }
                    }
                    Label { width: parent.width; font.pixelSize: 10; wrapMode: Text.WordWrap; text: "Put back warps the cursor to where it was, 0.3 s after the finger lifts, unless a finger is back or a mouse moved it. Disable while typing is " + (root.disableWhileTyping ? "on" : "OFF, see Controls") + "." }
                  }
                }
              }
            }
            Card {
              width: parent.width * 0.5 - 5; height: 206
              Column {
                anchors.fill: parent; anchors.margins: 14; spacing: 6
                Row {
                  width: parent.width
                  Heading { text: "YOUR DAY"; font.pixelSize: 12; width: parent.width / 2 }
                  Label { text: "touches per hour of the day"; font.pixelSize: 10; width: parent.width / 2; horizontalAlignment: Text.AlignRight }
                }
                Item {
                  id: rhythm
                  width: parent.width; height: 130
                  readonly property var hours: root.today.hours || []
                  readonly property real peak: { var m = 1; for (var i = 0; i < rhythm.hours.length; i++) m = Math.max(m, Pulse.num(rhythm.hours[i])); return m }
                  Row {
                    anchors.fill: parent; spacing: 3
                    Repeater {
                      model: 24
                      Item {
                        id: hourBar
                        required property int index
                        width: (rhythm.width - 3 * 23) / 24; height: rhythm.height
                        Rectangle {
                          anchors.bottom: parent.bottom; anchors.bottomMargin: 14; width: parent.width; radius: 2
                          height: Math.max(2, (rhythm.height - 16) * Pulse.num(rhythm.hours[hourBar.index]) / rhythm.peak)
                          color: hourBar.index === new Date(root.now * 1000).getHours() ? root.tint : Util.alpha(root.tint, 0.45)
                        }
                        Label { anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter; font.pixelSize: 8; text: hourBar.index % 3 === 0 ? String(hourBar.index) : "" }
                      }
                    }
                  }
                }
                Label { width: parent.width; font.pixelSize: 10; elide: Text.ElideRight
                  text: { var h = rhythm.hours, best = 0; for (var i = 0; i < h.length; i++) if (Pulse.num(h[i]) > Pulse.num(h[best])) best = i
                    return Pulse.num(h[best]) > 0 ? "Busiest hour so far: " + best + ":00 with " + Pulse.int(h[best]) + " touches" : "No touches recorded today yet" } }
              }
            }
          }
          Label {
            width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 10
            text: "Settings: " + (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/local-touchpads/settings.json and the generated toggles/hypr/zz-local-touchpads.lua, both Trackpad Plus's.  Live fingers: " + root.runtimeDir + "/live.json on tmpfs, written only while something touches the pad."
          }
        }

        // ================= ABOUT =================
        Column {
          width: parent.width
          spacing: 12
          visible: !root.chooseMode && root.active === "about"
          height: visible ? implicitHeight : 0
          Rectangle {
            width: parent.width; height: 132; radius: 16; border.color: Qt.alpha(root.tint, 0.45)
            gradient: Gradient { GradientStop { position: 0; color: Qt.alpha(root.tint, 0.13) } GradientStop { position: 1; color: root.card } }
            TrackpadChip { x: 14; y: 6; width: 180; height: 120; fingers: root.liveFingers; tint: root.tint; surface: Color.background; glint: root.ink; padEnabled: true; animate: root.opened && root.active === "about" && root.animated; level: root.level; aspect: root.padAspect }
            Column {
              x: 210; y: 22; spacing: 6
              Heading { text: "TRACKPAD PULSE"; font.pixelSize: 22; font.letterSpacing: 3 }
              Label { text: "Your trackpad, in motion."; font.pixelSize: 11 }
              Row {
                spacing: 8
                Rectangle {
                  height: 24; width: versionText.implicitWidth + 18; radius: 12
                  color: Qt.alpha(root.tint, 0.16); border.color: Qt.alpha(root.tint, 0.5)
                  Text { id: versionText; anchors.centerIn: parent; text: root.releaseVersion ? "v" + root.releaseVersion : "version unavailable"; color: root.ink; font.pixelSize: 11; font.bold: true; textFormat: Text.PlainText }
                }
                Label { text: "MIT · Fred Nix, on David Fano's Trackpad Plus, on Andrew Kent's touchpad widget"; font.pixelSize: 11; anchors.verticalCenter: parent.verticalCenter }
              }
            }
          }
          Row {
            width: parent.width; spacing: 12
            Rectangle {
              width: siteText.implicitWidth + 40; height: 44; radius: 10
              color: siteArea.containsMouse ? Qt.alpha(Color.accent, 0.26) : Qt.alpha(Color.accent, 0.14)
              border.color: Qt.alpha(Color.accent, siteArea.containsMouse ? 0.9 : 0.55); border.width: 2
              Behavior on color { ColorAnimation { duration: 120 } }
              Text { id: siteText; anchors.centerIn: parent; text: "nixfred.com"; color: root.ink; font.pixelSize: 19; font.bold: true; textFormat: Text.PlainText }
              MouseArea { id: siteArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.openLink("site") }
            }
            Action { anchors.verticalCenter: parent.verticalCenter; text: "github.com/nixfred/trackpad.pulse"; implicitHeight: 44; onClicked: root.openLink("repo") }
            Action { anchors.verticalCenter: parent.verticalCenter; text: "More Omarchy plugins →"; implicitHeight: 44; onClicked: root.openLink("plugins") }
            Label { anchors.verticalCenter: parent.verticalCenter; text: "MIT"; font.pixelSize: 13 }
          }
          Row {
            width: parent.width; spacing: 10
            Stat { width: (parent.width - 30) / 4; height: 91; label: "VERSION"; value: root.releaseVersion !== "" ? "v" + root.releaseVersion : "—"; hint: "manifest.json, the single source" }
            Stat { width: (parent.width - 30) / 4; height: 91; label: "RECORDER"; value: root.stale ? "offline" : Pulse.accessLabel(root.snap); hint: "trackpad-pulse.service, user scope"; valueColor: root.stale ? Color.urgent : root.ink }
            Stat { width: (parent.width - 30) / 4; height: 91; label: "RETENTION"; value: "7 days"; hint: "one row per minute, this machine only" }
            Stat { width: (parent.width - 30) / 4; height: 91; label: "LEAVES THE BOX"; value: "nothing"; hint: "no network calls, no telemetry upstream" }
          }
          Column {
            width: parent.width; spacing: 6
            Label { text: "LINEAGE"; font.pixelSize: 10; font.letterSpacing: 1.5 }
            Label {
              width: parent.width; wrapMode: Text.WordWrap
              text: "The Controls and Pointer feel pages are Trackpad Plus by David Fano, whole: per-device settings, the libinput-validated acceleration curve, the journalled state files and their rollback, all unchanged. Trackpad Plus began as Andrew Kent's omarchy-touchpad-widget. Trackpad Pulse adds the recorder, the live chip, the Overview, the Touch lab, the finger-speed map under the curve, and this page."
            }
            Row {
              spacing: 8
              Action { text: "davefano/omarchy-trackpad-plus →"; implicitHeight: 28; onClicked: root.openLink("upstream") }
              Action { text: "awkent01/omarchy-touchpad-widget →"; implicitHeight: 28; onClicked: root.openLink("origin") }
            }
          }
          Label {
            width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 10
            text: "History stays on this machine in a private state directory. The recorder reads the touchpad's event node only, never a keyboard, and only when your user may open it; it never sends input, never touches settings, and never needs to run as root. The one optional root action, the udev rule, is a two-line constant you can read in the Touch lab."
          }
        }

        // ================= CHOOSER (right-click) =================
        Column {
          width: parent.width
          spacing: 10
          visible: root.chooseMode
          height: visible ? implicitHeight : 0
          Rectangle {
            width: parent.width; height: 64; radius: 12
            color: Qt.alpha(root.touchpadEnabled ? Color.accent : Color.urgent, 0.10)
            border.color: Qt.alpha(root.touchpadEnabled ? Color.accent : Color.urgent, 0.45)
            Row {
              anchors.fill: parent; anchors.margins: 12; spacing: 14
              Column {
                width: parent.width - 80; anchors.verticalCenter: parent.verticalCenter; spacing: 3
                Heading { text: root.touchpadEnabled ? "TRACKPAD IS ON" : "TRACKPAD IS OFF"; font.pixelSize: 13 }
                Label { text: root.touchpadEnabled ? "Switch it off while you type on the keyboard; the setting is per device and survives reloads." : "Nothing on the pad reaches the cursor. Switch it back on here or from a keyboard shortcut over IPC."; font.pixelSize: 10; width: parent.width; wrapMode: Text.WordWrap }
              }
              ToggleSwitch { anchors.verticalCenter: parent.verticalCenter; checked: root.touchpadEnabled; foreground: root.ink; onToggled: root.toggleTouchpad() }
            }
          }
          Row {
            spacing: 8
            Action { text: "Open the dashboard →"; accent: root.tint; selected: true; onClicked: { root.chooseMode = false; root.active = "overview" } }
            Action { text: "Controls"; onClicked: { root.chooseMode = false; root.active = "controls" } }
            Action { text: "Pointer feel"; onClicked: { root.chooseMode = false; root.active = "feel" } }
            Action { text: "Gestures"; onClicked: { root.chooseMode = false; root.active = "gestures" } }
            Action { text: "Report"; onClicked: { root.chooseMode = false; root.active = "report" } }
            Action { text: root.animated ? "Icon animation: on" : "Icon animation: off"; selected: root.animated; accent: root.tint; onClicked: root.setSetting("animated", !root.animated) }
          }
          Label { text: "The icon is the pad itself: it lights where your fingers are and dims when the pad is off.  ·  Esc closes"; font.pixelSize: 10; width: parent.width; wrapMode: Text.WordWrap }
        }

        Rectangle { width: parent.width; height: 1; color: root.rule }
        Label {
          width: parent.width; wrapMode: Text.WordWrap; font.pixelSize: 10
          color: root.actionStatus !== "" ? root.ink : root.stale ? Color.urgent : root.inkDim
          text: root.actionStatus || (root.stale ? "Recorder offline · settings still work · start it from Overview or the Touch lab · Esc closes"
            : "LIVE · updated " + Qt.formatTime(new Date(Pulse.num(root.snap.ts) * 1000), "h:mm:ss AP") + "  ·  History stays on this machine  ·  ←→ switches pages  ·  Esc closes")
        }
      }
    }
  }
}
