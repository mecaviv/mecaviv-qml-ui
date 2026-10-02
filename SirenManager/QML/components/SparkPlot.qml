import QtQuick

// A rolling 0-100 % plot, as Activity Monitor draws it: time runs right to
// left (newest at the right edge), a smooth line with a faint glow and a
// gradient fill. Hue follows the level (green, amber, red) and the fill fades
// out toward the bottom.
Canvas {
    id: plot

    property var samples: []        // percent, oldest first
    property int history: 60        // samples across the full width
    property int staleCount: 0      // leading samples from a previous session (dimmed)
    property string staleLabel: "" // written at the divider after them

    onSamplesChanged: requestPaint()
    onStaleCountChanged: requestPaint()
    onStaleLabelChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
        var ctx = getContext("2d")
        var w = width, h = height
        ctx.reset()
        ctx.fillStyle = "#111"
        ctx.fillRect(0, 0, w, h)
        ctx.strokeStyle = "#333"
        ctx.lineWidth = 1
        ctx.beginPath()
        for (var g = 1; g < 4; g++) {          // 25, 50, 75 %
            var gy = Math.round(h * g / 4) + 0.5
            ctx.moveTo(0, gy); ctx.lineTo(w, gy)
        }
        ctx.stroke()
        var data = plot.samples
        if (data.length < 2) return
        var step = w / (plot.history - 1)
        var x0 = w - (data.length - 1) * step
        function y(v) { return h - (v / 100) * (h - 2) - 1 }
        function px(i) { return x0 + i * step }
        // Smooth curve through the samples (quadratic through midpoints).
        function trace(joined) {            // joined: continue the current path
            if (!joined) ctx.moveTo(px(0), y(data[0]))
            for (var i = 1; i < data.length - 1; i++)
                ctx.quadraticCurveTo(px(i), y(data[i]), (px(i) + px(i + 1)) / 2, (y(data[i]) + y(data[i + 1])) / 2)
            ctx.lineTo(px(data.length - 1), y(data[data.length - 1]))
        }
        // Green when idle, amber then red as the load climbs: the same
        // ramp colors the line (by absolute level) and tints the fill.
        function ramp(a) {
            var g = ctx.createLinearGradient(0, 0, 0, h)
            g.addColorStop(0.00, "rgba(224, 85, 85, " + a + ")")
            g.addColorStop(0.35, "rgba(224, 160, 48, " + a + ")")
            g.addColorStop(0.70, "rgba(90, 200, 120, " + a + ")")
            return g
        }
        var top = h
        for (var k = 0; k < data.length; k++) top = Math.min(top, y(data[k]))
        // Fill: hue by height, opacity fading from the curve's peak down to
        // nothing at the bottom, as one vertical gradient of small steps.
        function hue(t) {                          // t: 0 top (100 %) .. 1 bottom
            return t < 0.35 ? [224, 85, 85] : t < 0.7 ? [224, 160, 48] : [90, 200, 120]
        }
        var fill = ctx.createLinearGradient(0, 0, 0, h)
        for (var s = 0; s <= 24; s++) {
            var t = s / 24, yy = t * h
            var fade = yy <= top ? 1 : Math.max(0, 1 - (yy - top) / Math.max(1, h - top))
            var c = hue(t)
            fill.addColorStop(t, "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + (0.55 * fade).toFixed(3) + ")")
        }
        ctx.beginPath()
        ctx.moveTo(px(0), h)
        ctx.lineTo(px(0), y(data[0]))
        trace(true)
        ctx.lineTo(px(data.length - 1), h)
        ctx.closePath()
        ctx.fillStyle = fill
        ctx.fill()
        // Line: soft glow, then the crisp stroke.
        ctx.lineJoin = "round"
        ctx.beginPath(); trace()
        ctx.strokeStyle = ramp(0.25); ctx.lineWidth = 5; ctx.stroke()
        ctx.beginPath(); trace()
        ctx.strokeStyle = ramp(1.0); ctx.lineWidth = 1.6; ctx.stroke()
        // Latest reading.
        var lx = px(data.length - 1), ly = y(data[data.length - 1])
        ctx.beginPath(); ctx.arc(lx - 2, ly, 2.5, 0, 2 * Math.PI)
        ctx.fillStyle = "#fff"; ctx.fill()

        // The past: dimmed, closed by a dashed divider that carries the time of
        // its last sample. The divider moves left as samples come, then goes.
        if (plot.staleCount > 0) {
            var n = Math.min(plot.staleCount, data.length)
            var bx = n >= data.length ? px(data.length - 1) : (px(n - 1) + px(n)) / 2
            if (bx > 0) {
                ctx.fillStyle = "rgba(17, 17, 17, 0.55)"
                ctx.fillRect(x0, 0, bx - x0, h)
                ctx.strokeStyle = "rgba(200, 208, 216, 0.6)"
                ctx.lineWidth = 1
                ctx.beginPath()
                for (var dy = 0; dy < h; dy += 6) { ctx.moveTo(Math.round(bx) + 0.5, dy); ctx.lineTo(Math.round(bx) + 0.5, Math.min(h, dy + 3)) }
                ctx.stroke()
                if (plot.staleLabel !== "") {
                    ctx.font = "10px Menlo"
                    ctx.fillStyle = "rgba(200, 208, 216, 0.8)"
                    var tw = ctx.measureText(plot.staleLabel).width
                    var onLeft = bx - tw - 6 >= 0
                    ctx.fillText(plot.staleLabel, onLeft ? bx - tw - 4 : bx + 4, h - 5)
                }
            }
        }
    }
}
