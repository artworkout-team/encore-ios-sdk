//
//  SDUIScaleGroup.swift
//  Encore
//
//  `text.scaleGroup`: texts in one look tree sharing a key keep their relative base sizes and
//  shrink by ONE factor, the smallest any member needs to fit its frame within its lineLimit,
//  floored at the smallest minimumScaleFactor among them. A member that still does not fit truncates.
//

import SwiftUI
import UIKit

// MARK: - Measurement

/// What one member must fit: its texts (a countdown's widest), base font and line limit.
struct SDUIScaleMeasure: Sendable, Equatable {
    let texts: [String]
    let font: SDUIFont
    let lineLimit: Int?
    /// The member's minimumScaleFactor; nil leaves the group's floor to the others.
    let floor: CGFloat?
    /// The member's own horizontal padding: its frame holds the text and the padding.
    var inset: CGFloat = 0

    /// SwiftUI rounds a text's width UP to the pixel (a 3x pixel covers every screen).
    private static func drawnWidth(_ width: CGFloat) -> CGFloat { (width * 3).rounded(.up) / 3 }

    /// The widest of the texts at the base size (a countdown's room).
    var widest: String {
        let font = Self.uiFont(font, scale: 1)
        return texts.max { ($0 as NSString).size(withAttributes: [.font: font]).width < ($1 as NSString).size(withAttributes: [.font: font]).width } ?? ""
    }

    /// The largest scale (at most 1) at which every text fits `width` within the line limit.
    func neededScale(width frame: CGFloat) -> CGFloat {
        let width = frame - inset
        guard width.isFinite, width > 0, lineLimit != nil else { return 1 }
        // A pixel's grace at full size: a text sized to its own ideal width is whole.
        if fits(scale: 1, width: width + 1.0 / 3) { return 1 }
        var low: CGFloat = 0.05, high: CGFloat = 1
        for _ in 0..<14 {
            let mid = (low + high) / 2
            if fits(scale: mid, width: width) { low = mid } else { high = mid }
        }
        return low
    }

    private func fits(scale: CGFloat, width: CGFloat) -> Bool {
        let font = Self.uiFont(font, scale: scale)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: (self.font.tracking ?? 0) * scale]
        let available = width + 0.01 // float noise only; both sides are whole pixels
        return texts.allSatisfy { text in
            if lineLimit == 1 {
                let line = text.replacingOccurrences(of: "\n", with: " ")
                return Self.drawnWidth(NSAttributedString(string: line, attributes: attributes).size().width) <= available
            }
            // Each written line on one line of its own: measured exactly, as above.
            let written = text.components(separatedBy: "\n")
            if written.count <= (lineLimit ?? .max), written.allSatisfy({
                Self.drawnWidth(NSAttributedString(string: $0, attributes: attributes).size().width) <= available
            }) { return true }
            // Wrapping: laid out at the width, each line held to the same pixel rounding as above.
            guard let lines = Self.lines(NSAttributedString(string: text, attributes: attributes), width: available) else { return false }
            return lines <= (lineLimit ?? .max)
        }
    }

    /// The lines `text` wraps to at `width`; nil when a line would still draw wider once rounded.
    private static func lines(_ text: NSAttributedString, width: CGFloat) -> Int? {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var count = 0
        var tooWide = false
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, used, _, _, _ in
            count += 1
            if drawnWidth(used.width) > width { tooWide = true }
        }
        return tooWide ? nil : count
    }

    /// The UIKit font SwiftUI draws for `font` at `scale`.
    static func uiFont(_ font: SDUIFont, scale: CGFloat) -> UIFont {
        let size = font.size * scale
        return font.monospacedDigits == true
            ? .monospacedDigitSystemFont(ofSize: size, weight: font.weight.uiFontWeight)
            : .systemFont(ofSize: size, weight: font.weight.uiFontWeight)
    }

    /// The widest text a countdown format can show, so ticking digits never move the factor.
    static func widestCountdownTexts(_ format: SDUICountdownFormat, units: (hours: String, minutes: String, seconds: String)) -> [String] {
        switch format {
        case .clock: return ["88:88:88"]
        case .hoursMinutes: return ["88:88"]
        case .hours, .minutes, .seconds: return ["88"]
        case .largestUnit: return [units.hours, units.minutes, units.seconds].map { "88 \($0)" }
        }
    }
}

extension SDUIFont {
    /// This font at `factor` of its size and tracking.
    func scaled(_ factor: CGFloat) -> SDUIFont {
        SDUIFont(size: size * factor, weight: weight, monospacedDigits: monospacedDigits, tracking: tracking.map { $0 * factor })
    }

    /// What an unstyled `Text` draws at: body, 17 pt regular.
    static let unstyled = SDUIFont(size: 17, weight: .regular)
}

// MARK: - The groups of one tree

/// Every scale group in one look tree: each member's needed scale, and the factor all draw at.
@MainActor
final class SDUIScaleGroups: ObservableObject {
    @Published private(set) var factors: [String: CGFloat] = [:]
    /// Members that fit at their base size where laid out: they take only the width they draw at,
    /// so a shrunk group leaves no gaps beside them. One leaves the set when its text changes or no
    /// longer fits where it is drawn.
    @Published private(set) var whole: Set<UUID> = []
    private var members: [String: [UUID: (needed: CGFloat, floor: CGFloat?)]] = [:]
    /// What each member last measured, and at what width: the same again measures nothing.
    private var measured: [UUID: (width: CGFloat, measure: SDUIScaleMeasure)] = [:]
    private var publishing = false
    private var pendingWhole: Set<UUID> = []
    private var leavingWhole: Set<UUID> = []
    /// Where each member's text was last drawn, read when it would become whole (the drawing may
    /// come first).
    private var drawnWidths: [UUID: (width: CGFloat, measure: SDUIScaleMeasure)] = [:]

    /// A rise this small is not drawn: it only follows a sibling's rounding, and taking it could
    /// swing the factor back and forth by a pixel.
    static let minimumRise: CGFloat = 0.005

    /// The smallest needed scale, floored at the smallest declared minimum (no minimum: 1).
    nonisolated static func factor(_ members: [(needed: CGFloat, floor: CGFloat?)]) -> CGFloat {
        guard let floor = members.compactMap(\.floor).min() else { return 1 }
        let needed = members.map(\.needed).min() ?? 1
        return min(1, max(floor, needed))
    }

    /// A member was offered `width` for `measure`: what it needs there joins its group.
    func offer(group: String, member: UUID, width: CGFloat, measure: SDUIScaleMeasure) {
        if let last = measured[member], last.width == width, last.measure == measure, members[group]?[member] != nil { return }
        let changed = measured[member].map { $0.measure != measure } ?? false
        measured[member] = (width, measure)
        if changed, whole.contains(member) { leavingWhole.insert(member) }
        let needed = measure.neededScale(width: width)
        if let current = members[group]?[member], current.needed == needed, current.floor == measure.floor, !changed { return }
        if members[group]?[member] == nil, needed >= 1 { pendingWhole.insert(member) }
        members[group, default: [:]][member] = (needed, measure.floor)
        schedulePublish()
    }

    /// The text changed where it stands (new copy, another text size): measured again at the last
    /// width, and a whole member keeps its room again until it has.
    func remeasure(group: String, member: UUID, measure: SDUIScaleMeasure) {
        guard let last = measured[member] else { return }
        offer(group: group, member: member, width: last.width, measure: measure)
    }

    /// A whole member drew `width` wide: if its text no longer fits there at the group's factor (a
    /// narrower mount), it keeps its room again so the group can shrink.
    func drawn(group: String, member: UUID, width: CGFloat, measure: SDUIScaleMeasure) {
        guard width > 0 else { return }
        drawnWidths[member] = (width, measure)
        guard whole.contains(member) || pendingWhole.contains(member) else { return }
        guard !Self.fits(drawnWidths[member], at: factors[group] ?? 1) else { return }
        leavingWhole.insert(member)
        schedulePublish()
    }

    /// Whether the text drawn `drawn` wide still fits at `factor`; unknown counts as fitting.
    private static func fits(_ drawn: (width: CGFloat, measure: SDUIScaleMeasure)?, at factor: CGFloat) -> Bool {
        guard let drawn else { return true }
        return drawn.measure.neededScale(width: drawn.width) >= factor - minimumRise
    }

    func leave(group: String, member: UUID) {
        measured[member] = nil
        drawnWidths[member] = nil
        pendingWhole.remove(member)
        leavingWhole.remove(member)
        if whole.contains(member) { whole.remove(member) }
        guard members[group]?.removeValue(forKey: member) != nil else { return }
        if members[group]?.isEmpty == true { members[group] = nil }
        schedulePublish()
    }

    /// Published after the layout pass that measured, never inside it.
    private func schedulePublish() {
        guard !publishing else { return }
        publishing = true
        // The main queue, not a Task: it also runs inside a nested run loop (a host drawing a
        // snapshot), where a main-actor Task would wait for the caller to yield.
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.publish() } }
    }

    private func publish() {
        publishing = false
        var next = members.mapValues { Self.factor(Array($0.values)) }
        for (group, factor) in next {
            if let current = factors[group], factor > current, factor - current < Self.minimumRise { next[group] = current }
        }
        if next != factors { factors = next }
        if !leavingWhole.isEmpty {
            whole.subtract(leavingWhole)
            pendingWhole.subtract(leavingWhole)
            // Measured again from its room, so its next offer counts.
            for member in leavingWhole { measured[member] = nil }
            leavingWhole = []
        }
        if !pendingWhole.isEmpty {
            // A member whose text no longer fits where it was drawn keeps its room.
            let fitting = pendingWhole.filter { member in
                Self.fits(drawnWidths[member], at: members.values.first { $0[member] != nil }.map { Self.factor(Array($0.values)) } ?? 1)
            }
            whole.formUnion(fitting)
            for member in pendingWhole.subtracting(fitting) { measured[member] = nil }
            pendingWhole = []
        }
    }

    #if DEBUG
    /// The key a countdown member's drawn size is recorded under.
    static let countdownKey = "countdown"
    /// The last point size each member was drawn at, by its text (tests).
    static var debugDrawnSizes: [String: CGFloat] = [:]
    /// Every draw in order: the member's key, the text drawn and its size (tests).
    static var debugDrawnHistory: [(key: String, text: String, size: CGFloat)] = []

    /// Off unless a test turns it on, so the history never grows in a long run.
    static var debugRecording = false

    static func recordDrawn(key: String, text: String, size: CGFloat) {
        guard debugRecording else { return }
        debugDrawnSizes[key] = size
        debugDrawnHistory.append((key, text, size))
    }
    #endif
}

private struct SDUIScaleGroupsKey: EnvironmentKey {
    static let defaultValue: SDUIScaleGroups? = nil
}

extension EnvironmentValues {
    /// The look tree's scale groups; nil outside a trigger tree, where `scaleGroup` is ignored.
    var sduiScaleGroups: SDUIScaleGroups? {
        get { self[SDUIScaleGroupsKey.self] }
        set { self[SDUIScaleGroupsKey.self] = newValue }
    }
}

// MARK: - A member

/// One member. Until it has measured, and for good once it needs to shrink, it keeps the room
/// its text takes on its own (drawn hidden at its base size, a countdown at its widest), so the
/// width it measures never depends on the group's factor. A member that fits whole takes only
/// the width it draws at.
@available(iOS 17.0, *)
struct SDUIScaleGroupMember<Content: View>: View {
    let group: String
    let measure: SDUIScaleMeasure
    let alignment: SDUIAlignment?
    @ObservedObject var groups: SDUIScaleGroups
    /// The text at a factor; nil is the text on its own, the room the member keeps.
    @ViewBuilder let content: (CGFloat?) -> Content
    @State private var id = UUID()

    var body: some View {
        SDUIScaleMemberLayout(alignment: alignment ?? .leading, whole: groups.whole.contains(id)) {
            content(nil)
                .hidden()
                .accessibilityHidden(true)
                // The committed frame only: sizing probes never reach a geometry reader.
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { offer(geometry.size.width) }
                        .onChange(of: geometry.size.width) { _, width in offer(width) }
                })
            content(groups.factors[group] ?? 1)
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { groups.drawn(group: group, member: id, width: geometry.size.width, measure: measure) }
                        .onChange(of: geometry.size.width) { _, width in
                            groups.drawn(group: group, member: id, width: width, measure: measure)
                        }
                })
        }
        .onChange(of: measure) { _, next in groups.remeasure(group: group, member: id, measure: next) }
        .onDisappear { groups.leave(group: group, member: id) }
    }

    private func offer(_ width: CGFloat) {
        groups.offer(group: group, member: id, width: width, measure: measure)
    }
}

/// The room (first child) sizes the member, or for a whole member the drawn text (second) does
/// and the room sits at its ideal size, out of the way.
@available(iOS 17.0, *)
private struct SDUIScaleMemberLayout: Layout {
    let alignment: SDUIAlignment
    let whole: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return subviews.first?.sizeThatFits(proposal) ?? .zero }
        return whole ? subviews[1].sizeThatFits(proposal) : subviews[0].sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let (room, text) = (subviews[0], subviews[1])
        room.place(at: bounds.origin, proposal: whole ? .unspecified : ProposedViewSize(bounds.size))
        // Its own height: the room's lines may be shorter than the drawn ones.
        let size = text.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let x: CGFloat
        switch alignment.horizontalAlignment {
        case .center: x = bounds.midX - size.width / 2
        case .trailing: x = bounds.maxX - size.width
        default: x = bounds.minX
        }
        text.place(at: CGPoint(x: x, y: bounds.midY - size.height / 2), proposal: ProposedViewSize(size))
    }
}
