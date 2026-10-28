//
//  SDUITriggerVocabulary.swift
//  Encore
//
//  Vocabulary the trigger components (GiftsButton, ClaimReminder) draw with: time-driven text and bars,
//  repeating motion, a marquee, host lists. New decode branches only; a sheet that never uses
//  these keys decodes and renders exactly as before.
//

import SwiftUI

// MARK: - Decoder flag

extension CodingUserInfoKey {
    /// Set on the decoder for a trigger mount. Tokens that exist only inside triggers decode only with it.
    static let sduiTriggerMount = CodingUserInfoKey(rawValue: "encore.sduiTriggerMount")!
}

extension Decoder {
    /// Host-fed vocabulary (host times, host lists) reads values only a trigger host supplies. In a
    /// sheet it would draw empty, so it fails to decode there, like any unknown key: the variant
    /// is invalid, never a blank element.
    func requireTriggerMount(_ what: String) throws {
        guard (userInfo[.sduiTriggerMount] as? Bool) == true else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "\(what) exists only in trigger mounts"))
        }
    }
}

// MARK: - G1 countdown text

/// Ticking time text: the time left until a host time key.
struct SDUICountdown: Decodable, Equatable {
    /// A host time key, e.g. `deadline`.
    let to: String
    let format: SDUICountdownFormat
    /// Unit words for `largestUnit`, usually `${hours}` / `${minutes}` / `${seconds}`.
    var units: SDUICountdownUnits?

    private enum CodingKeys: String, CodingKey { case to, format, units }

    init(to: String, format: SDUICountdownFormat, units: SDUICountdownUnits? = nil) {
        self.to = to
        self.format = format
        self.units = units
    }

    init(from decoder: Decoder) throws {
        try decoder.requireTriggerMount("countdown")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        to = try container.decode(String.self, forKey: .to)
        format = try container.decode(SDUICountdownFormat.self, forKey: .format)
        units = try container.decodeIfPresent(SDUICountdownUnits.self, forKey: .units)
    }
}

enum SDUICountdownFormat: String, Decodable, Equatable {
    /// `HH:MM:SS` / `HH:MM` (the same, without seconds; minutes floored), each `%02d`.
    case clock, hoursMinutes, hours, minutes, seconds, largestUnit
}

struct SDUICountdownUnits: Decodable, Equatable {
    var hours: String?
    var minutes: String?
    var seconds: String?
}

// MARK: - G2 progress

/// A capsule bar filled to a value; a time-remaining value drains once a second.
struct SDUIProgress: Decodable {
    let value: SDUIProgressValue
    var fillColor: SDUIColor?
    var trackColor: SDUIColor?
    var style: SDUIStyle?
}

enum SDUIProgressValue: Decodable, Equatable {
    case timeRemaining(from: String, to: String)
    case literal(Double)

    private enum CodingKeys: String, CodingKey { case timeRemaining, literal }
    private struct Span: Decodable { let from: String; let to: String }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let span = try container.decodeIfPresent(Span.self, forKey: .timeRemaining) {
            try decoder.requireTriggerMount("progress timeRemaining")
            self = .timeRemaining(from: span.from, to: span.to)
        } else if let literal = try container.decodeIfPresent(Double.self, forKey: .literal) {
            self = .literal(literal)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "progress value needs timeRemaining or literal"))
        }
    }
}

// MARK: - G3 loop

/// A repeating keyframe animation of the element's scale, opacity, rotation and offset.
struct SDUILoop: Decodable {
    let duration: Double
    /// Starts the loop this far (0...1) into its cycle.
    var phaseOffset: Double?
    var curve: SDUIAnimationCurve?
    let keyframes: [SDUILoopKeyframe]
    /// The pose shown under reduce motion; absent falls back per the contract.
    var reducedMotion: SDUILoopPose?
}

struct SDUILoopKeyframe: Decodable {
    let at: Double
    var scale: CGFloat?
    var opacity: Double?
    var rotation: Double?
    var offset: SDUIOffset?
}

struct SDUILoopPose: Decodable {
    var scale: CGFloat?
    var opacity: Double?
    var rotation: Double?
    var offset: SDUIOffset?
}

// MARK: - G4 marquee

enum SDUIMarqueeAxis: String, Decodable {
    case horizontal, vertical
}

/// Content laid along an axis that scrolls on a loop when `animateWhen` holds.
struct SDUIMarquee: Decodable {
    let axis: SDUIMarqueeAxis
    let duration: Double
    var reverse: Bool?
    var spacing: CGFloat?
    var animateWhen: SDUICondition?
    let content: SDUIElement
    var style: SDUIStyle?
}

// MARK: - G8 small additions

/// Press feedback for a button.
struct SDUIPressedStyle: Decodable {
    var scale: CGFloat?
    var duration: Double?
}

enum SDUILayoutDirection: String, Decodable {
    case ltr
}

enum SDUIGradientType: String, Decodable {
    case linear, radial
}
