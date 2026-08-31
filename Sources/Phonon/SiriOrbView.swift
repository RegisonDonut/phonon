import SwiftUI

/// A sci-fi "orbital" orb: a glowing core wrapped in several great-circle rings
/// (like an armillary sphere / gyroscope) that are tilted at different angles and
/// spin in different directions. Each ring carries a travelling ripple wave whose
/// amplitude grows with the voice, so it reads as energy rippling around a planet.
/// Lifecycle:
///   • recording – rings ripple/expand with the voice level
///   • thinking  – rings spin fast while the model works
///   • closing   – spins faster while shrinking to nothing
struct SiriOrbView: View {
    enum Phase: Equatable { case recording, thinking, closing }

    var level: Float
    var phase: Phase
    var closeStart: Date? = nil      // set by the coordinator when closing begins
    var tint: OrbTint = .plasma

    enum OrbTint { case plasma, ember }

    private let ringCount = 6
    private let segments = 96            // points per ring (smoothness of the ripple)
    private let closeDuration: Double = 0.6

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                self.draw(ctx, size, timeline.date)
            }
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ now: Date) {
        let t: Double = now.timeIntervalSinceReferenceDate
        let prog: Double = closingProgress(now)
        let spin: Double = spinRate(prog)
        let scale: Double = (phase == .closing) ? pow(1.0 - prog, 1.6) : 1.0
        let fade: Double = (phase == .closing) ? (1.0 - prog) : 1.0

        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        // Extra gamma lift so even soft speech produces clearly visible motion.
        let lvl: Double = min(1.0, pow(Double(max(0, level)), 0.7) * 1.25)
        let energy: Double = (phase == .recording) ? lvl : 0.12
        let minSide: Double = Double(min(size.width, size.height))
        // base orbit radius; breathes gently and expands with the voice
        let R: Double = minSide * 0.13 * scale
            * (1.0 + sin(t * 1.6) * 0.03 + energy * 0.18)
        if R < 0.5 { return }

        drawGlow(ctx, c: c, R: R, energy: energy, fade: fade)
        drawCore(ctx, c: c, R: R, energy: energy, fade: fade)
        drawRings(ctx, c: c, R: R, t: t, energy: energy, spin: spin, fade: fade)
    }

    private func closingProgress(_ now: Date) -> Double {
        guard phase == .closing, let s = closeStart else { return 0 }
        return min(1.0, max(0.0, now.timeIntervalSince(s) / closeDuration))
    }

    private func spinRate(_ prog: Double) -> Double {
        switch phase {
        case .recording: return 1.0
        case .thinking:  return 6.0                  // fast whirl — clearly "working"
        case .closing:   return 6.0 + prog * 6.0
        }
    }

    // MARK: drawing

    private func drawGlow(_ ctx: GraphicsContext, c: CGPoint, R: Double, energy: Double, fade: Double) {
        let g = R * 2.3
        let rect = CGRect(x: c.x - g, y: c.y - g, width: g * 2, height: g * 2)
        ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: coronaColors(energy, fade)),
            center: c, startRadius: R * 0.1, endRadius: g))
    }

    private func drawCore(_ ctx: GraphicsContext, c: CGPoint, R: Double, energy: Double, fade: Double) {
        let cr = R * (0.42 + energy * 0.08)
        let rect = CGRect(x: c.x - cr, y: c.y - cr, width: cr * 2, height: cr * 2)
        ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: coreColors(fade)),
            center: c, startRadius: 0, endRadius: cr))
    }

    /// The orbital rings. Each ring is a circle in its own tilted plane, rotated
    /// in 3D over time (different axis + direction per ring), projected
    /// orthographically. A travelling sine ripple deforms the radius; depth (z)
    /// controls brightness/width so the front of each ring reads brighter than the
    /// part passing behind the core — giving the "wrapped around a planet" feel.
    /// Drawn additively so crossings bloom into light.
    private func drawRings(_ ctx: GraphicsContext, c: CGPoint, R: Double, t: Double, energy: Double, spin: Double, fade: Double) {
        let rippleAmp: Double = 0.035 + energy * 0.20         // voice-driven ripple depth
        ctx.drawLayer { layer in
            layer.blendMode = .plusLighter
            for i in 0..<ringCount {
                let ki: Double = 0.95 + Double(i) * 0.17       // concentric shells
                // each ring tumbles about its own axis, random rate & direction
                let dir: Double = rnd(i, 9) > 0.5 ? 1.0 : -1.0
                let rateX: Double = (0.10 + rnd(i, 1) * 0.35) * spin * dir
                let rateY: Double = (0.10 + rnd(i, 2) * 0.35) * spin * (rnd(i, 8) > 0.5 ? 1 : -1)
                let ax: Double = rnd(i, 3) * 6.2832 + t * rateX
                let ay: Double = rnd(i, 4) * 6.2832 + t * rateY
                let az: Double = rnd(i, 5) * 6.2832            // static roll, varies per ring
                let waves: Double = 3 + floor(rnd(i, 6) * 3)   // 3–5 ripples around the ring
                let phase0: Double = rnd(i, 7) * 6.2832 + t * (1.2 + rnd(i, 1) * 1.6)

                let cosx = cos(ax), sinx = sin(ax)
                let cosy = cos(ay), siny = sin(ay)
                let cosz = cos(az), sinz = sin(az)

                var prev: (x: Double, y: Double, z: Double)? = nil
                for s in 0...segments {
                    let th: Double = Double(s) / Double(segments) * 6.2832
                    let rr: Double = R * ki * (1.0 + rippleAmp * sin(waves * th + phase0))
                    // point on the ring's local plane
                    var x = cos(th) * rr
                    var y = sin(th) * rr
                    var z = 0.0
                    // Rz
                    let x1 = x * cosz - y * sinz
                    let y1 = x * sinz + y * cosz
                    x = x1; y = y1
                    // Ry
                    let x2 = x * cosy + z * siny
                    let z2 = -x * siny + z * cosy
                    x = x2; z = z2
                    // Rx
                    let y3 = y * cosx - z * sinx
                    let z3 = y * sinx + z * cosx
                    y = y3; z = z3

                    if let p = prev {
                        // depth at the midpoint → brightness & width (front brighter)
                        let zmid = (p.z + z) * 0.5
                        let depth = zmid / (R * ki)            // -1 (back) … +1 (front)
                        let dn = depth * 0.5 + 0.5             // 0…1
                        let a: Double = (0.10 + dn * 0.55) * (0.55 + energy * 0.6) * fade
                        if a > 0.012 {
                            let w: Double = (0.7 + dn * 1.8) * (0.85 + energy * 0.5)
                            var seg = Path()
                            seg.move(to: CGPoint(x: c.x + p.x, y: c.y + p.y))
                            seg.addLine(to: CGPoint(x: c.x + x, y: c.y + y))
                            layer.stroke(seg, with: .color(ringColor(front: dn, alpha: min(0.9, a))),
                                         style: StrokeStyle(lineWidth: w, lineCap: .round))
                        }
                    }
                    prev = (x, y, z)
                }

                // a bright energy node racing along the front of each ring
                drawNode(layer, c: c, R: R, ki: ki, t: t,
                         cosx: cosx, sinx: sinx, cosy: cosy, siny: siny, cosz: cosz, sinz: sinz,
                         seed: i, energy: energy, spin: spin, fade: fade)
            }
        }
    }

    private func drawNode(_ layer: GraphicsContext, c: CGPoint, R: Double, ki: Double, t: Double,
                          cosx: Double, sinx: Double, cosy: Double, siny: Double, cosz: Double, sinz: Double,
                          seed: Int, energy: Double, spin: Double, fade: Double) {
        let th: Double = t * (0.6 + rnd(seed, 11) * 1.4) * spin + rnd(seed, 12) * 6.2832
        let rr = R * ki
        var x = cos(th) * rr, y = sin(th) * rr, z = 0.0
        let x1 = x * cosz - y * sinz, y1 = x * sinz + y * cosz; x = x1; y = y1
        let x2 = x * cosy + z * siny, z2 = -x * siny + z * cosy; x = x2; z = z2
        let y3 = y * cosx - z * sinx, z3 = y * sinx + z * cosx; y = y3; z = z3
        let dn = (z / rr) * 0.5 + 0.5
        guard dn > 0.35 else { return }                       // only when on the near side
        let gr = (1.8 + dn * 2.6) * (0.9 + energy * 0.8)
        let a = min(0.95, (0.35 + energy * 0.5) * dn) * fade
        let p = CGPoint(x: c.x + x, y: c.y + y)
        layer.fill(Path(ellipseIn: CGRect(x: p.x - gr, y: p.y - gr, width: gr * 2, height: gr * 2)),
                   with: .radialGradient(Gradient(colors: [nodeColor(a), nodeColor(0)]),
                                         center: p, startRadius: 0, endRadius: gr))
    }

    // MARK: helpers

    private func rnd(_ i: Int, _ s: Double) -> Double {
        let x: Double = sin(Double(i) * 12.9898 + s * 78.233) * 43758.5453
        return x - floor(x)
    }

    private func coronaColors(_ e: Double, _ f: Double) -> [Color] {
        switch tint {
        case .plasma:
            return [Color(red: 0.55, green: 0.40, blue: 0.95).opacity((0.22 + e * 0.22) * f),
                    Color(red: 0.40, green: 0.22, blue: 0.78).opacity(0.12 * f),
                    Color.clear]
        case .ember:
            return [Color(red: 1.0, green: 0.6, blue: 0.2).opacity((0.24 + e * 0.22) * f),
                    Color(red: 1.0, green: 0.3, blue: 0.15).opacity(0.12 * f),
                    Color.clear]
        }
    }
    private func coreColors(_ f: Double) -> [Color] {
        switch tint {
        case .plasma:
            return [Color.white.opacity(0.85 * f),
                    Color(red: 0.62, green: 0.48, blue: 1.0).opacity(0.75 * f),
                    Color(red: 0.42, green: 0.24, blue: 0.82).opacity(0.0)]
        case .ember:
            return [Color.white.opacity(0.85 * f),
                    Color(red: 1.0, green: 0.78, blue: 0.4).opacity(0.75 * f),
                    Color(red: 1.0, green: 0.35, blue: 0.1).opacity(0.0)]
        }
    }
    /// Ring stroke colour — front arcs trend brighter/cooler, back arcs deep purple.
    private func ringColor(front dn: Double, alpha: Double) -> Color {
        switch tint {
        case .plasma:
            let r = 0.45 + dn * 0.30
            let g = 0.30 + dn * 0.45
            let b = 0.85 + dn * 0.15
            return Color(red: r, green: g, blue: b).opacity(alpha)
        case .ember:
            let r = 0.95
            let g = 0.40 + dn * 0.40
            let b = 0.15 + dn * 0.25
            return Color(red: r, green: g, blue: b).opacity(alpha)
        }
    }
    private func nodeColor(_ a: Double) -> Color {
        tint == .plasma ? Color(red: 0.80, green: 0.72, blue: 1.0).opacity(a)
                        : Color(red: 1.0, green: 0.88, blue: 0.6).opacity(a)
    }
}
