//
//  ConfettiView.swift
//  Encore
//
//  Native confetti for the SDUI `confetti` element. SDUI JSON can't express
//  particle systems, so this wraps a CAEmitterLayer in a UIViewRepresentable.
//
//  Two independent layers, either or both:
//  - BURST (`intensity`/`duration`): a one-shot emitter that rains and clears.
//    Motion on entry, but gone seconds later — and invisible in any screenshot.
//  - SCATTER (`scatter`): settled pieces drawn straight into the view, so they
//    stay put while the user reads and DO appear in a static render.
//
//  Never intercepts touches beneath it.
//

import SwiftUI

#if canImport(UIKit)
import UIKit

/// SwiftUI bridge to the native confetti view. Non-interactive by
/// construction — the hosting UIView disables user interaction and the SwiftUI
/// wrapper disables hit testing, so it can be layered as a celebratory overlay
/// above tappable buttons without stealing their taps.
@available(iOS 17.0, *)
struct ConfettiView: UIViewRepresentable {
    /// Colors for the confetti pieces. Empty falls back to a festive palette.
    let colors: [UIColor]
    /// Total pieces-per-second, spread across the colors.
    let intensity: Int
    /// Seconds the emitter emits before it stops and settles.
    let duration: Double
    /// Fraction (0...1) of the container height for the emission line. 0 = top.
    let originY: Double
    /// Fraction (0...1) of the container width for a POINT burst, or nil for the
    /// default full-width LINE.
    let originX: Double?
    /// Count of settled decorative pieces. 0 = burst only (legacy behavior).
    let scatter: Int
    /// Fraction (0...1) of the container height the settled scatter spans.
    let scatterHeight: Double

    func makeUIView(context: Context) -> ConfettiEmitterUIView {
        let view = ConfettiEmitterUIView()
        view.configure(
            colors: colors,
            intensity: intensity,
            duration: duration,
            originY: originY,
            originX: originX,
            scatter: scatter,
            scatterHeight: scatterHeight
        )
        return view
    }

    func updateUIView(_ uiView: ConfettiEmitterUIView, context: Context) {}
}

/// UIView host that owns the `CAEmitterLayer`, sizes the emission line to its
/// width on layout, kicks off the burst once, then zeroes the birth rate after
/// `duration` for a natural one-shot settle.
@available(iOS 17.0, *)
final class ConfettiEmitterUIView: UIView {
    private let emitter = CAEmitterLayer()
    private var colors: [UIColor] = []
    private var intensity: Int = 20
    private var duration: Double = 2.5
    private var originY: Double = 0
    private var originX: Double? = nil
    private var scatter: Int = 0
    private var scatterHeight: Double = 0.45
    private var didStart = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        // `contentMode` .redraw so a rotation/resize re-lays the settled scatter
        // against the new bounds instead of stretching the cached bitmap.
        contentMode = .redraw
        layer.addSublayer(emitter)
    }

    func configure(
        colors: [UIColor],
        intensity: Int,
        duration: Double,
        originY: Double,
        originX: Double?,
        scatter: Int,
        scatterHeight: Double
    ) {
        self.colors = colors.isEmpty ? Self.defaultPalette : colors
        self.intensity = max(1, intensity)
        self.duration = max(0.1, duration)
        self.originY = min(1, max(0, originY))
        self.originX = originX.map { min(1, max(0, $0)) }
        self.scatter = max(0, scatter)
        self.scatterHeight = min(1, max(0.05, scatterHeight))
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Vertical origin: at the default originY 0 the emitter sits just above
        // the top edge so pieces enter already falling.
        emitter.frame = bounds
        let y = originY <= 0 ? -8 : bounds.height * CGFloat(originY)

        if let originX {
            // POINT burst: spray from a single centered point and fan outward
            // (the widened emissionRange is applied per-cell in makeCells).
            emitter.emitterShape = .point
            emitter.emitterPosition = CGPoint(x: bounds.width * CGFloat(originX), y: y)
            emitter.emitterSize = .zero
        } else {
            // Default: rain across the full width from a line.
            emitter.emitterShape = .line
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: y)
            emitter.emitterSize = CGSize(width: bounds.width, height: 1)
        }
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard !didStart, bounds.width > 0 else { return }
        didStart = true

        emitter.beginTime = CACurrentMediaTime()
        emitter.birthRate = 1
        emitter.emitterCells = makeCells()

        // One-shot: stop emitting after `duration` so existing pieces fall out
        // and the layer goes idle (no perpetual CPU/GPU work). Weak self so a
        // dismissed sheet doesn't keep the view alive.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.emitter.birthRate = 0
        }
    }

    private func makeCells() -> [CAEmitterCell] {
        // Split the requested birth rate evenly across colors, minimum 1 each.
        let perColorRate = max(1, Float(intensity) / Float(max(1, colors.count)))

        // A point burst fans out wide (~±75°) so pieces spray outward before
        // gravity pulls them down; a line rains straight down with a gentle
        // ±45° scatter.
        let emissionRange: CGFloat = originX != nil ? (.pi / 180 * 75) : (.pi / 4)

        return colors.enumerated().map { index, color in
            let cell = CAEmitterCell()
            cell.birthRate = perColorRate
            cell.lifetime = 6.0
            cell.lifetimeRange = 1.5

            // Emit downward (UIKit layer y-axis points down) with a spread for
            // horizontal scatter; gravity keeps pulling everything down.
            cell.velocity = 210
            cell.velocityRange = 80
            cell.emissionLongitude = .pi / 2
            cell.emissionRange = emissionRange
            cell.yAcceleration = 320
            cell.xAcceleration = 0

            // Tumble as they fall.
            cell.spin = 3.5
            cell.spinRange = 4.0

            cell.scale = 0.55
            cell.scaleRange = 0.25

            // Alternate rectangles and circles for classic confetti variety.
            let shape: PieceShape = index.isMultiple(of: 2) ? .rectangle : .circle
            cell.contents = Self.pieceImage(color: color, shape: shape)?.cgImage
            return cell
        }
    }

    // MARK: - Settled scatter

    /// Draws the settled decorative pieces beneath the emitter.
    ///
    /// Deliberately Core Graphics rather than a second `CAEmitterLayer`: an
    /// emitter is rendered by the render server and does NOT appear in
    /// `layer.render(in:)`, so a particle-based "settled" layer would still be
    /// missing from every screenshot and snapshot test. Drawn pieces are real
    /// view content and show up everywhere the view does.
    override func draw(_ rect: CGRect) {
        guard scatter > 0, bounds.width > 0, bounds.height > 0,
              let ctx = UIGraphicsGetCurrentContext() else { return }

        // Seeded so the scatter is IDENTICAL on every draw and every launch.
        // A fresh random layout each redraw would make the screen flicker on
        // rotation and make snapshot tests unrepeatable.
        var rng = SeededGenerator(seed: 0x5EED_C0FE)
        let band = bounds.height * CGFloat(scatterHeight)

        for index in 0..<scatter {
            // Bleed slightly past both edges so pieces are clipped by the frame
            // rather than all sitting neatly inside it.
            let x = bounds.minX - 10 + rng.next(upTo: bounds.width + 20)
            // Even through the band. A top-heavy bias was tried and read as a
            // stripe along the very top edge; the design fills its band and
            // then simply stops, so `scatterHeight` does the shaping.
            let y = band * rng.unit()
            // Mostly small pieces with the occasional larger one — an even size
            // spread reads as uniform dots rather than scattered confetti.
            let size = 5 + 9 * pow(rng.unit(), 1.6)
            let angle = rng.unit() * .pi * 2
            let color = colors[index % colors.count]
            let shape = Self.scatterShapes[index % Self.scatterShapes.count]

            ctx.saveGState()
            ctx.translateBy(x: x, y: y)
            ctx.rotate(by: angle)
            color.setFill()
            color.setStroke()
            Self.drawScatterPiece(shape, size: size, in: ctx)
            ctx.restoreGState()
        }
    }

    /// Cycled per piece. Weighted toward circles and ribbons, which is what the
    /// design leans on, with diamonds and squiggles for variety.
    private static let scatterShapes: [ScatterShape] = [
        .circle, .ribbon, .diamond, .circle, .squiggle, .ribbon,
        .circle, .diamond, .ribbon, .squiggle
    ]

    enum ScatterShape {
        case circle
        case ribbon
        case diamond
        case squiggle
    }

    private static func drawScatterPiece(_ shape: ScatterShape, size: CGFloat, in ctx: CGContext) {
        switch shape {
        case .circle:
            ctx.fillEllipse(in: CGRect(x: -size / 2, y: -size / 2, width: size, height: size))

        case .ribbon:
            let w = size * 0.75, h = size * 1.25
            let path = UIBezierPath(
                roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h),
                cornerRadius: size * 0.18
            )
            ctx.addPath(path.cgPath)
            ctx.fillPath()

        case .diamond:
            let r = size * 0.62
            ctx.move(to: CGPoint(x: 0, y: -r))
            ctx.addLine(to: CGPoint(x: r, y: 0))
            ctx.addLine(to: CGPoint(x: 0, y: r))
            ctx.addLine(to: CGPoint(x: -r, y: 0))
            ctx.closePath()
            ctx.fillPath()

        case .squiggle:
            // An open, stroked "S" — two cubic segments curving opposite ways.
            // Arcs were tried first and read as fish hooks: a circular sweep
            // closes too far around, where the design's ribbons are shallow
            // waves. Cubics keep the curve open and the ends far apart.
            let h = size * 1.5, w = size * 0.85
            ctx.setLineWidth(max(1.6, size * 0.2))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: -w / 2, y: -h / 2))
            ctx.addCurve(
                to: CGPoint(x: 0, y: 0),
                control1: CGPoint(x: w / 2, y: -h / 2.6),
                control2: CGPoint(x: w / 2, y: -h / 8)
            )
            ctx.addCurve(
                to: CGPoint(x: w / 2, y: h / 2),
                control1: CGPoint(x: -w / 2, y: h / 8),
                control2: CGPoint(x: -w / 2, y: h / 2.6)
            )
            ctx.strokePath()
        }
    }

    /// Tiny deterministic PRNG (SplitMix64). Self-contained on purpose:
    /// `SystemRandomNumberGenerator` is unseedable, so it cannot give a stable
    /// layout, and stability is the whole point here.
    struct SeededGenerator {
        private var state: UInt64

        init(seed: UInt64) { self.state = seed }

        mutating func nextBits() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Uniform in 0..<1.
        mutating func unit() -> CGFloat {
            CGFloat(nextBits() >> 11) / CGFloat(UInt64(1) << 53)
        }

        /// Uniform in 0..<limit.
        mutating func next(upTo limit: CGFloat) -> CGFloat {
            unit() * limit
        }
    }

    // MARK: - Piece rendering

    private enum PieceShape {
        case rectangle
        case circle
    }

    /// Draws a small colored piece into a UIImage so no bundled assets are
    /// required. Rectangles are slightly taller than wide for a "ribbon" look.
    private static func pieceImage(color: UIColor, shape: PieceShape) -> UIImage? {
        let size: CGSize
        switch shape {
        case .rectangle: size = CGSize(width: 8, height: 12)
        case .circle: size = CGSize(width: 9, height: 9)
        }

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            let rect = CGRect(origin: .zero, size: size)
            switch shape {
            case .rectangle:
                ctx.fill(rect)
            case .circle:
                ctx.cgContext.fillEllipse(in: rect)
            }
        }
    }

    /// Festive default palette used when the author supplies no colors.
    static let defaultPalette: [UIColor] = [
        UIColor(red: 1.00, green: 0.23, blue: 0.19, alpha: 1), // red
        UIColor(red: 1.00, green: 0.18, blue: 0.33, alpha: 1), // pink
        UIColor(red: 1.00, green: 0.58, blue: 0.00, alpha: 1), // orange
        UIColor(red: 1.00, green: 0.80, blue: 0.00, alpha: 1), // yellow
        UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1), // green
        UIColor(red: 0.00, green: 0.48, blue: 1.00, alpha: 1), // blue
        UIColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1)  // purple
    ]
}
#endif
