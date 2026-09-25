import QtQuick

// A glowing trackpad. The surface lights where the fingers are, a tap leaves
// a ripple, a lifted finger leaves a fading trail, and a slow scan line
// crosses the pad while nothing is touching it so the chip reads as live.
// The aura and glow match the other Pulse chips so it sits beside them.
Item {
    id: root
    // Fingers from live.json: [{x: 0..1, y: 0..1, p: 0..1|null, palm, speed}].
    property var fingers: []
    property color tint: '#43f2a1'
    property color palmTint: '#ff6b6b'
    property color surface: '#0b141b'
    property color glint: '#ffffff'
    property color mutedTint: '#8c9499'
    property bool padEnabled: true
    property bool animate: true
    property bool compact: false
    // Physical aspect ratio of the pad, width over height.
    property real aspect: 1.6
    // 0..1 activity that drives the aura: finger speed over 200 mm/s.
    property real level: 0
    property real phase: 0
    implicitWidth: compact ? 30 : 200
    implicitHeight: compact ? 22 : 130

    // Trails and ripples are kept here, not derived from bindings, because
    // they are history: a point the finger has already left.
    property var trails: ({})
    property var ripples: []
    property var downSince: ({})
    property var lastSeen: ({})
    readonly property bool busy: (fingers && fingers.length > 0) || ripples.length > 0 || Object.keys(trails).length > 0
    readonly property real phaseStep: tick.interval / 6400 * (root.busy ? 1 : 1)

    // Every paint is coalesced onto one timer. Painting straight from each
    // fingers change meant a 20 Hz live file drove every chip on the panel at
    // 20 paints a second on the GUI thread, which is what froze the bar.
    // The tick also ages trails and ripples, so it keeps running while there
    // is something to fade even with the icon animation off; otherwise the
    // last frame of a swipe stayed painted on the chip until the next touch.
    // Off still means an idle chip never repaints: the aura and sweep only
    // move when animate is on.
    Timer {
        id: tick
        interval: root.busy ? 50 : 125
        repeat: true
        running: root.visible && (root.animate || root.busy)
        onTriggered: {
            if (root.animate) root.phase = (root.phase + root.phaseStep) % 1
            root.age(Date.now())
            canvas.requestPaint()
        }
    }
    Timer {
        id: coalesce
        interval: 50
        repeat: false
        onTriggered: if (root.visible) canvas.requestPaint()
    }
    function repaint() { if (root.visible && !coalesce.running) coalesce.start() }
    onTintChanged: repaint()
    onSurfaceChanged: repaint()
    onPadEnabledChanged: repaint()
    onVisibleChanged: repaint()
    onFingersChanged: { note(Date.now()); if (!tick.running) repaint() }

    // Remember where each slot was so a lift can draw a trail, and how long
    // it was down so a short touch can ripple.
    function note(now) {
        var seen = {}, list = root.fingers || []
        for (var i = 0; i < list.length; i++) {
            var f = list[i], key = String(f.slot)
            seen[key] = f
            if (!(key in root.downSince)) root.downSince[key] = now
            var trail = root.trails[key] || []
            trail.push({x: f.x, y: f.y, t: now})
            if (trail.length > 14) trail.shift()
            root.trails[key] = trail
        }
        for (var key2 in root.lastSeen) {
            if (!(key2 in seen)) {
                var was = root.lastSeen[key2]
                if (now - (root.downSince[key2] || now) < 260) root.ripples.push({x: was.x, y: was.y, t: now, palm: !!was.palm})
                delete root.downSince[key2]
            }
        }
        root.lastSeen = seen
    }
    function age(now) {
        var next = []
        for (var i = 0; i < root.ripples.length; i++) if (now - root.ripples[i].t < 520) next.push(root.ripples[i])
        root.ripples = next
        var trails = root.trails, keep = {}
        for (var key in trails) {
            var pts = []
            for (var j = 0; j < trails[key].length; j++) if (now - trails[key][j].t < 700) pts.push(trails[key][j])
            if (pts.length) keep[key] = pts
        }
        root.trails = keep
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        onWidthChanged: root.repaint()
        onHeightChanged: root.repaint()
        onPaint: {
            var c = getContext('2d'), w = width, h = height, now = Date.now()
            c.reset(); c.clearRect(0, 0, w, h)
            var pad = root.compact ? 2 : 10
            var bw = w - pad * 2, bh = bw / root.aspect
            if (bh > h - pad * 2) { bh = h - pad * 2; bw = bh * root.aspect }
            var x = (w - bw) / 2, y = (h - bh) / 2, r = root.compact ? 3 : 10
            var tint = root.padEnabled ? root.tint : root.mutedTint
            // Aura.
            if (!root.compact) {
                var aura = c.createRadialGradient(w / 2, h / 2, bw * 0.15, w / 2, h / 2, bw * 0.75)
                aura.addColorStop(0, Qt.alpha(tint, 0.22 + 0.3 * root.level))
                aura.addColorStop(0.7, Qt.alpha(tint, 0.06 + 0.05 * Math.sin(root.phase * Math.PI * 2)))
                aura.addColorStop(1, 'transparent')
                c.fillStyle = aura; c.fillRect(0, 0, w, h)
            }
            // Body.
            function rounded(px, py, pw, ph, rad) {
                c.beginPath()
                c.moveTo(px + rad, py); c.lineTo(px + pw - rad, py); c.quadraticCurveTo(px + pw, py, px + pw, py + rad)
                c.lineTo(px + pw, py + ph - rad); c.quadraticCurveTo(px + pw, py + ph, px + pw - rad, py + ph)
                c.lineTo(px + rad, py + ph); c.quadraticCurveTo(px, py + ph, px, py + ph - rad)
                c.lineTo(px, py + rad); c.quadraticCurveTo(px, py, px + rad, py); c.closePath()
            }
            rounded(x, y, bw, bh, r)
            c.fillStyle = root.surface; c.fill()
            // Glow as a few widening, fading strokes, never shadowBlur: the blur
            // is rasterised on the GUI thread and costs tens of milliseconds per
            // paint at hero size. These strokes cost about a millisecond.
            c.save(); c.strokeStyle = tint
            for (var halo = (root.compact ? 2 : 4); halo > 0; halo--) {
                c.globalAlpha = 0.09 + 0.06 * root.level
                c.lineWidth = (root.compact ? 1.2 : 2) + halo * (root.compact ? 1.2 : 2.4)
                rounded(x, y, bw, bh, r); c.stroke()
            }
            c.restore()
            c.strokeStyle = Qt.alpha(tint, root.padEnabled ? 0.95 : 0.5); c.lineWidth = root.compact ? 1.2 : 2
            rounded(x, y, bw, bh, r); c.stroke()
            c.save(); rounded(x + 1, y + 1, bw - 2, bh - 2, Math.max(1, r - 1)); c.clip()
            // Sensor grid.
            var cols = root.compact ? 6 : 16, rows = root.compact ? 4 : 10
            c.strokeStyle = Qt.alpha(tint, root.compact ? 0.16 : 0.22); c.lineWidth = 0.7
            for (var i = 1; i < cols; i++) { c.beginPath(); c.moveTo(x + bw * i / cols, y); c.lineTo(x + bw * i / cols, y + bh); c.stroke() }
            for (var j = 1; j < rows; j++) { c.beginPath(); c.moveTo(x, y + bh * j / rows); c.lineTo(x + bw, y + bh * j / rows); c.stroke() }
            // Idle scan line, or a faster one while a finger is down.
            if (root.animate && root.padEnabled) {
                var sweep = x + ((root.phase * (1 + root.level * 3)) % 1) * bw
                var beam = c.createLinearGradient(sweep - 10, 0, sweep + 10, 0)
                beam.addColorStop(0, 'transparent'); beam.addColorStop(0.5, Qt.alpha(root.glint, root.compact ? 0.22 : 0.16)); beam.addColorStop(1, 'transparent')
                c.fillStyle = beam; c.fillRect(sweep - 10, y, 20, bh)
            }
            // Trails.
            for (var key in root.trails) {
                var pts = root.trails[key]
                if (pts.length < 2) continue
                for (var k = 1; k < pts.length; k++) {
                    var a = 1 - (now - pts[k].t) / 700
                    c.strokeStyle = Qt.alpha(tint, Math.max(0, a) * 0.55)
                    c.lineWidth = (root.compact ? 1.5 : 4) * Math.max(0.2, a)
                    c.beginPath(); c.moveTo(x + pts[k - 1].x * bw, y + pts[k - 1].y * bh); c.lineTo(x + pts[k].x * bw, y + pts[k].y * bh); c.stroke()
                }
            }
            // Ripples.
            for (var m = 0; m < root.ripples.length; m++) {
                var rp = root.ripples[m], age = (now - rp.t) / 520
                var rr = (root.compact ? 3 : 8) + age * (root.compact ? 8 : 34)
                c.strokeStyle = Qt.alpha(rp.palm ? root.palmTint : root.glint, (1 - age) * 0.8); c.lineWidth = root.compact ? 1 : 2
                c.beginPath(); c.arc(x + rp.x * bw, y + rp.y * bh, rr, 0, Math.PI * 2); c.stroke()
            }
            // Fingers.
            var list = root.fingers || []
            for (var n = 0; n < list.length; n++) {
                var f = list[n], fx = x + f.x * bw, fy = y + f.y * bh
                var colour = f.palm ? root.palmTint : tint
                var size = (root.compact ? 2.6 : 7) * (f.p !== null && f.p !== undefined ? 0.7 + f.p * 0.9 : 1) * (f.palm ? 1.8 : 1)
                var glow = c.createRadialGradient(fx, fy, size * 0.3, fx, fy, size * (root.compact ? 2.4 : 3.2))
                glow.addColorStop(0, Qt.alpha(colour, 0.85)); glow.addColorStop(1, 'transparent')
                c.fillStyle = glow; c.beginPath(); c.arc(fx, fy, size * 3.2, 0, Math.PI * 2); c.fill()
                c.fillStyle = root.glint; c.beginPath(); c.arc(fx, fy, size * 0.55, 0, Math.PI * 2); c.fill()
            }
            c.restore()
            // Disabled: a slash across the pad.
            if (!root.padEnabled) {
                c.strokeStyle = Qt.alpha(tint, 0.9); c.lineWidth = root.compact ? 1.5 : 3
                c.beginPath(); c.moveTo(x + bw * 0.2, y + bh * 0.85); c.lineTo(x + bw * 0.8, y + bh * 0.15); c.stroke()
            }
            // Pins, like the other chips.
            if (!root.compact) {
                c.strokeStyle = Qt.alpha(tint, 0.7); c.lineWidth = 2
                for (var p = 0; p < 4; p++) {
                    var px = x + bw * (p + 1) / 5, len = 7
                    c.beginPath(); c.moveTo(px, y - len); c.lineTo(px, y); c.moveTo(px, y + bh); c.lineTo(px, y + bh + len); c.stroke()
                }
                for (var q = 0; q < 2; q++) {
                    var py = y + bh * (q + 1) / 3
                    c.beginPath(); c.moveTo(x - 7, py); c.lineTo(x, py); c.moveTo(x + bw, py); c.lineTo(x + bw + 7, py); c.stroke()
                }
            }
        }
    }
}
