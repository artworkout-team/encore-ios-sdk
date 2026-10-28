// A trigger's look: the SDUI element tree the server sends as `ui.template.root`, checked
// strictly before it is drawn, because the sheet decoder ignores fields it does not know.

import Foundation

/// A look that passed ``TriggerLookCheck``: the raw tree and the height it is drawn at.
internal struct TriggerLook: Equatable, Sendable {
    let root: JSONValue
    /// The root's `style.frame.height`, which is the trigger's height.
    let height: CGFloat

    /// The root's own `style.frame.maxWidth` when it is a number: the widest the look draws. Nil
    /// for none or `infinity` (it fills its container).
    var maxWidth: CGFloat? {
        guard case .object(let wrapper) = root, wrapper.count == 1,
              case .object(let element)? = wrapper.first?.value,
              case .object(let style)? = element["style"],
              case .object(let frame)? = style["frame"],
              case .number(let width)? = frame["maxWidth"], width.isFinite else { return nil }
        return CGFloat(width)
    }
}

/// The look keys of a trigger's `ui.template`, read beside the plug-in's own fields.
internal struct TriggerLookSource: Decodable, Sendable, Equatable {
    /// The keys a trigger template may carry (vocab-contract §5 rule 10); any other, a sheet key
    /// included, makes the look unrenderable.
    static let templateKeys: Set<String> = [
        "version", "trigger", "layout", "pin", "useCases", "windowHours", "dismissible", "maxFontScale", "colors", "lightColors",
        "values", "behavior", "strings", "textSlots", "root",
    ]
    /// The keys `colors` and `lightColors` may hold.
    static let paletteKeys: Set<String> = ["background", "accent", "text"]
    static let defaultMaxFontScale = 1.3

    let root: JSONValue?
    /// The most text may grow with the user's text size; the height never does.
    let maxFontScale: Double
    /// Keys outside ``templateKeys``, sorted; any one makes the look unrenderable.
    let unknownKeys: [String]
    /// The first `colors`/`lightColors` entry that is not a background, accent or text hex.
    let paletteProblem: TriggerUnrenderable?
    /// The look's own strings as served, which its tree may name (V-4).
    let strings: [String: String]
    /// The `values` block's defaults, or why the block is refused.
    let defaults: Result<[String: String], TriggerUnrenderable>
    /// The look's `behavior` as served (null included); nil when absent.
    var behavior: JSONValue? = nil
    /// The app text this look takes: each slot over one of its own strings (lenient, see
    /// ``TriggerTextSlots/slots(_:strings:)``).
    var textSlots: [TriggerTextSlot: String] = [:]

    init(
        root: JSONValue?, maxFontScale: Double = Self.defaultMaxFontScale, unknownKeys: [String] = [], paletteProblem: TriggerUnrenderable? = nil,
        strings: [String: String] = [:], defaults: Result<[String: String], TriggerUnrenderable> = .success([:])
    ) {
        self.root = root
        self.maxFontScale = maxFontScale
        self.unknownKeys = unknownKeys
        self.paletteProblem = paletteProblem
        self.strings = strings
        self.defaults = defaults
    }

    private struct Key: CodingKey {
        let stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    /// Lenient like the rest of the template: a malformed field reads as absent.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        root = try? container.decodeIfPresent(JSONValue.self, forKey: Key(stringValue: "root"))
        let scale = try? container.decodeIfPresent(Double.self, forKey: Key(stringValue: "maxFontScale"))
        maxFontScale = scale.flatMap { $0.isFinite && $0 >= 1 ? $0 : nil } ?? Self.defaultMaxFontScale
        unknownKeys = container.allKeys.map(\.stringValue).filter { !Self.templateKeys.contains($0) }.sorted()
        paletteProblem = ["colors", "lightColors"].lazy.compactMap { name in
            (try? container.decodeIfPresent(JSONValue.self, forKey: Key(stringValue: name))).flatMap { $0 }.flatMap { Self.paletteProblem(name, $0) }
        }.first
        strings = (try? container.decodeIfPresent(TriggerStrings.self, forKey: Key(stringValue: "strings")))?.values ?? [:]
        // Present means checked, null included: only an absent block has no defaults.
        let valuesKey = Key(stringValue: "values")
        defaults = container.contains(valuesKey)
            ? TriggerValues.defaults((try? container.decode(JSONValue.self, forKey: valuesKey)) ?? .null)
            : .success([:])
        let behaviorKey = Key(stringValue: "behavior")
        behavior = container.contains(behaviorKey) ? ((try? container.decode(JSONValue.self, forKey: behaviorKey)) ?? .null) : nil
        textSlots = TriggerTextSlots.slots(try? container.decodeIfPresent(JSONValue.self, forKey: Key(stringValue: "textSlots")), strings: strings)
    }

    /// Why a palette object is not a set of background, accent and text hex colours, or nil.
    static func paletteProblem(_ name: String, _ value: JSONValue) -> TriggerUnrenderable? {
        guard case .object(let entries) = value else { return TriggerUnrenderable(path: name, detail: "expected an object") }
        for key in entries.keys.sorted() {
            guard paletteKeys.contains(key) else { return TriggerUnrenderable(path: "\(name).\(key)", detail: "unknown palette key \(key)") }
            guard case .string(let hex)? = entries[key], AppearanceHex.parse(hex) != nil else {
                return TriggerUnrenderable(path: "\(name).\(key)", detail: "not a hex colour")
            }
        }
        return nil
    }
}

/// What one JSON field may hold, for the strict pre-check.
internal indirect enum TriggerFieldKind: Sendable {
    /// A string, number or bool (`allowed` limits strings to a closed set, e.g. an enum).
    case scalar(allowed: Set<String>? = nil)
    /// A number inside `range`: sizes, offsets, scales and durations stay bounded, so a look can
    /// never grow over the host app's own views or take their taps. `orString` names the words
    /// allowed instead (`infinity` for a max size, which fills the parent and no more).
    case number(ClosedRange<Double>, orString: Set<String> = [])
    /// A visible string: only `${...}` tokens, punctuation, digits and spaces (no literal letters).
    case copy
    /// One of the trigger's time keys (`deadline`, `start`).
    case timeKey
    /// One of the trigger's host lists.
    case listName
    /// One element.
    case element
    /// An array of elements.
    case elements
    /// An object whose keys must all appear in the schema.
    case object(TriggerObjectSchema)
    /// An array of objects of one schema.
    case objects(TriggerObjectSchema)
    /// A map from free keys (state names) to objects of one schema.
    case map(TriggerObjectSchema)
    /// An action object: its `type` must be a known action, then its fields are checked.
    case action
    /// A condition: an object with exactly one known condition key.
    case condition
    /// An array of conditions (`and`, `or`).
    case conditions
    /// A system symbol name that every SDK draws.
    case symbol
    /// A short camel-case name (`^[a-z][A-Za-z0-9]{0,31}$`), e.g. a scale group's key.
    case name
}

/// The keys one JSON object may have, and what each may hold.
internal struct TriggerObjectSchema: Sendable {
    var fields: [String: TriggerFieldKind]

    init(_ fields: [String: TriggerFieldKind]) {
        self.fields = fields
    }
}

/// Everything a trigger tree may use on this SDK. Anything else makes the look unrenderable.
internal struct TriggerVocabulary: Sendable {
    /// Element name to the keys inside it.
    var elements: [String: TriggerObjectSchema]
    /// Action `type` to the other keys the action may carry.
    var actions: [String: TriggerObjectSchema]
    /// System symbol names every SDK can draw.
    var symbols: Set<String>
    /// Condition name to what its payload may be.
    var conditions: [String: TriggerFieldKind] = [:]
}

/// What one trigger's host provides: the `${keys}`, time keys and lists a tree may name.
internal struct TriggerLookRules: Sendable {
    var values: Set<String>
    var times: Set<String>
    /// List name to its item fields.
    var lists: [String: Set<String>]
    /// `dismissTrigger` is valid only when the template says the trigger is dismissible.
    var dismissible: Bool
    /// The steps its look's `behavior` may name.
    var behavior: [String: TriggerBehaviorStep] = [:]
}

/// Why a look cannot be drawn. `path` names the first offending node, for the log.
internal struct TriggerUnrenderable: Error, Equatable, Sendable {
    let path: String
    let detail: String
}

/// The strict pre-check (S-5): an allow-list walk over the raw tree, before any decode.
internal enum TriggerLookCheck {
    /// `rules` nil checks structure only (unit tests of the walker).
    /// `look` is what the template adds: its strings and value defaults.
    static func check(
        _ root: JSONValue?, vocabulary: TriggerVocabulary, rules: TriggerLookRules? = nil, look: TriggerLookTokens = TriggerLookTokens()
    ) -> Result<TriggerLook, TriggerUnrenderable> {
        guard let root else { return .failure(TriggerUnrenderable(path: "root", detail: "missing")) }
        do {
            let walker = Walker(vocabulary: vocabulary, rules: rules, look: look)
            try walker.element(root, path: "root", itemFields: nil)
            guard let height = rootHeight(root), height > 0 else {
                throw TriggerUnrenderable(path: "root", detail: "no numeric style.frame.height")
            }
            guard height <= maxHeight else {
                throw TriggerUnrenderable(path: "root", detail: "height \(height) over \(maxHeight)")
            }
            // Nothing inside may be much taller than the look itself: a frame that is would cover
            // the host app's views above or below it (and, in SwiftUI, take their taps).
            if let (path, tall) = tallestFrame(root, path: "root"), tall > height + maxOverflow {
                throw TriggerUnrenderable(path: path, detail: "\(tall) taller than the look's \(height) + \(maxOverflow)")
            }
            // The allow-list knows names, not shapes: a tree the engine cannot decode (a required
            // field missing, a string for a number) would draw a blank slot that still counts views.
            guard decodeElement(root) != nil else {
                throw TriggerUnrenderable(path: "root", detail: "does not decode")
            }
            return .success(TriggerLook(root: root, height: CGFloat(height)))
        } catch let failure as TriggerUnrenderable {
            return .failure(failure)
        } catch {
            return .failure(TriggerUnrenderable(path: "root", detail: "\(error)"))
        }
    }

    /// A whole trigger template: only its own keys, and a look every layout must have.
    static func check(
        _ source: TriggerLookSource, vocabulary: TriggerVocabulary, rules: TriggerLookRules
    ) -> Result<TriggerLook, TriggerUnrenderable> {
        if let key = source.unknownKeys.first {
            return .failure(TriggerUnrenderable(path: key, detail: "unknown template key"))
        }
        if let problem = source.paletteProblem { return .failure(problem) }
        // `behavior` is the server's to apply: an unknown step or value is skipped, never refused.
        let defaults: [String: String]
        switch source.defaults {
        case .success(let checked): defaults = checked
        case .failure(let problem): return .failure(problem)
        }
        // Every value a string names needs a default (a translation adding one is refused too).
        for key in source.strings.keys.sorted() {
            if let missing = TriggerValues.keys(in: source.strings[key] ?? "").first(where: { defaults[$0] == nil }) {
                return .failure(TriggerUnrenderable(path: "strings.\(key)", detail: "${values.\(missing)} has no default"))
            }
        }
        return check(source.root, vocabulary: vocabulary, rules: rules, look: TriggerLookTokens(strings: source.strings, defaults: defaults))
    }

    /// The tallest look a trigger may have.
    static let maxHeight: Double = 240
    /// How far an inner frame may stand out of the look (the pulse ring is 120 in a 112 look).
    static let maxOverflow: Double = 24

    /// The tallest `style.frame` height, minHeight or maxHeight that can show outside the look,
    /// with its path. A frame held in by a clipping ancestor (`clipped`, a `clipShape`, a marquee)
    /// cannot, so it is skipped; the clipping element's own frame still counts.
    static func tallestFrame(_ value: JSONValue, path: String, clipped: Bool = false, clipsChildren: Bool = false) -> (String, Double)? {
        var best: (String, Double)?
        func consider(_ candidate: (String, Double)?) {
            if let candidate, candidate.1 > (best?.1 ?? -.infinity) { best = candidate }
        }
        switch value {
        case .object(let fields):
            var clipsInside = clipsChildren
            if case .object(let style)? = fields["style"] {
                clipsInside = clipsInside || style["clipShape"] != nil || isTrue(style["clipped"])
            }
            for key in fields.keys.sorted() {
                guard let next = fields[key] else { continue }
                let child = "\(path).\(key)"
                if key == "style", case .object(let style) = next {
                    // The element's own frame is the clip; what its style draws (overlay,
                    // background element) is inside it.
                    for styleKey in style.keys.sorted() {
                        guard let inner = style[styleKey] else { continue }
                        let innerPath = "\(child).\(styleKey)"
                        if styleKey == "frame", case .object(let frame) = inner {
                            guard !clipped else { continue }
                            // A maximum only caps; it never draws taller than the look proposes.
                            for size in ["height", "minHeight"] {
                                if case .number(let number)? = frame[size] { consider(("\(innerPath).\(size)", number)) }
                            }
                        } else {
                            consider(tallestFrame(inner, path: innerPath, clipped: clipped || clipsInside))
                        }
                    }
                } else {
                    // A marquee is a window onto its content: its body clips what it holds.
                    consider(tallestFrame(next, path: child, clipped: clipped || clipsInside, clipsChildren: key == "marquee"))
                }
            }
        case .array(let items):
            for (index, item) in items.enumerated() { consider(tallestFrame(item, path: "\(path)[\(index)]", clipped: clipped)) }
        default:
            break
        }
        return best
    }

    /// A JSON true, or a non-zero number (the engine reads `clipped` either way).
    private static func isTrue(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(let flag)?: return flag
        case .number(let number)?: return number != 0
        default: return false
        }
    }

    /// The tree, decoded by the engine's own decoder in a trigger mount; nil when it does not decode.
    static func decodeElement(_ root: JSONValue) -> SDUIElement? {
        guard let data = try? JSONEncoder().encode(root) else { return nil }
        let decoder = JSONDecoder()
        // Tokens that exist only in trigger mounts (`inkOnAccent`) decode only here.
        decoder.userInfo[.sduiTriggerMount] = true
        return try? decoder.decode(SDUIElement.self, from: data)
    }

    /// `root.<element>.style.frame.height`.
    static func rootHeight(_ root: JSONValue) -> Double? {
        guard case .object(let wrapper) = root, wrapper.count == 1,
              case .object(let element)? = wrapper.first?.value,
              case .object(let style)? = element["style"],
              case .object(let frame)? = style["frame"],
              case .number(let height)? = frame["height"] else { return nil }
        return height
    }

    /// The `${...}` tokens in `text`, in order.
    static func tokens(in text: String) -> [String] {
        var result: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "${") {
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else { break }
            result.append(String(rest[open.upperBound..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    /// Whether `text` has a letter outside its `${...}` tokens (punctuation and digits are fine).
    static func hasLiteralLetters(_ text: String) -> Bool {
        var stripped = text
        for token in tokens(in: text) {
            stripped = stripped.replacingOccurrences(of: "${\(token)}", with: "")
        }
        return stripped.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private struct Walker {
        static func isName(_ name: String) -> Bool {
            name.range(of: "^[a-z][A-Za-z0-9]{0,31}$", options: .regularExpression) != nil
        }

        let vocabulary: TriggerVocabulary
        let rules: TriggerLookRules?
        let look: TriggerLookTokens

        func element(_ value: JSONValue, path: String, itemFields: Set<String>?) throws {
            // An element is an object with exactly one key, its name.
            guard case .object(let wrapper) = value, wrapper.count == 1, let (name, body) = wrapper.first else {
                throw TriggerUnrenderable(path: path, detail: "not an element")
            }
            guard let schema = vocabulary.elements[name] else {
                throw TriggerUnrenderable(path: path, detail: "unknown element \(name)")
            }
            if case .null = body, schema.fields.isEmpty { return }
            var scoped = itemFields
            if name == "forEach", case .object(let fields) = body {
                scoped = try hostListItemFields(fields, path: "\(path).\(name)")
            }
            try object(body, schema: schema, path: "\(path).\(name)", itemFields: scoped, outerItemFields: itemFields, isForEach: name == "forEach")
        }

        /// A `forEach` must loop over a host list; its item template may read that list's fields.
        private func hostListItemFields(_ fields: [String: JSONValue], path: String) throws -> Set<String>? {
            guard case .string("hostList")? = fields["dataSource"] else {
                throw TriggerUnrenderable(path: "\(path).dataSource", detail: "only hostList")
            }
            guard case .string(let list)? = fields["list"] else {
                throw TriggerUnrenderable(path: "\(path).list", detail: "missing")
            }
            guard let rules else { return [] }
            guard let itemFields = rules.lists[list] else {
                throw TriggerUnrenderable(path: "\(path).list", detail: "unknown list \(list)")
            }
            return itemFields
        }

        private func object(
            _ value: JSONValue, schema: TriggerObjectSchema, path: String,
            itemFields: Set<String>?, outerItemFields: Set<String>? = nil, isForEach: Bool = false
        ) throws {
            guard case .object(let fields) = value else {
                throw TriggerUnrenderable(path: path, detail: "expected an object")
            }
            for key in fields.keys.sorted() {
                guard let kind = schema.fields[key] else {
                    throw TriggerUnrenderable(path: "\(path).\(key)", detail: "unknown field")
                }
                // Only a forEach's item template sees the item; its own fields do not.
                let scope = isForEach && key != "itemTemplate" ? outerItemFields : itemFields
                try field(fields[key] ?? .null, kind: kind, path: "\(path).\(key)", itemFields: scope)
            }
        }

        private func field(_ value: JSONValue, kind: TriggerFieldKind, path: String, itemFields: Set<String>?) throws {
            if case .string(let string) = value { try tokens(string, path: path, itemFields: itemFields) }
            switch kind {
            case .scalar(let allowed):
                switch value {
                case .string(let string):
                    if let allowed, !allowed.contains(string) {
                        throw TriggerUnrenderable(path: path, detail: "unknown value \(string)")
                    }
                case .number, .bool:
                    if allowed != nil { throw TriggerUnrenderable(path: path, detail: "expected one of a closed set") }
                default:
                    throw TriggerUnrenderable(path: path, detail: "expected a scalar")
                }
            case .number(let range, let words):
                if case .string(let word) = value, words.contains(word) { break }
                guard case .number(let number) = value else { throw TriggerUnrenderable(path: path, detail: "expected a number") }
                guard range.contains(number) else {
                    throw TriggerUnrenderable(path: path, detail: "\(number) outside \(range.lowerBound)...\(range.upperBound)")
                }
            case .copy:
                guard case .string(let string) = value else { throw TriggerUnrenderable(path: path, detail: "expected text") }
                if rules != nil, TriggerLookCheck.hasLiteralLetters(string) {
                    throw TriggerUnrenderable(path: path, detail: "literal text")
                }
            case .timeKey:
                guard case .string(let key) = value else { throw TriggerUnrenderable(path: path, detail: "expected a time key") }
                if let rules, !rules.times.contains(key) {
                    throw TriggerUnrenderable(path: path, detail: "unknown time \(key)")
                }
            case .listName:
                guard case .string(let list) = value else { throw TriggerUnrenderable(path: path, detail: "expected a list") }
                if let rules, rules.lists[list] == nil {
                    throw TriggerUnrenderable(path: path, detail: "unknown list \(list)")
                }
            case .element:
                try element(value, path: path, itemFields: itemFields)
            case .elements:
                guard case .array(let items) = value else { throw TriggerUnrenderable(path: path, detail: "expected an array") }
                for (index, item) in items.enumerated() {
                    try element(item, path: "\(path)[\(index)]", itemFields: itemFields)
                }
            case .object(let schema):
                try object(value, schema: schema, path: path, itemFields: itemFields)
            case .objects(let schema):
                guard case .array(let items) = value else { throw TriggerUnrenderable(path: path, detail: "expected an array") }
                for (index, item) in items.enumerated() {
                    try object(item, schema: schema, path: "\(path)[\(index)]", itemFields: itemFields)
                }
            case .map(let schema):
                guard case .object(let entries) = value else { throw TriggerUnrenderable(path: path, detail: "expected an object") }
                for key in entries.keys.sorted() {
                    try object(entries[key] ?? .null, schema: schema, path: "\(path).\(key)", itemFields: itemFields)
                }
            case .action:
                guard case .object(let fields) = value, case .string(let type)? = fields["type"] else {
                    throw TriggerUnrenderable(path: path, detail: "an action needs a type")
                }
                guard let schema = vocabulary.actions[type] else {
                    throw TriggerUnrenderable(path: path, detail: "unknown action \(type)")
                }
                if type == "dismissTrigger", let rules, !rules.dismissible {
                    throw TriggerUnrenderable(path: path, detail: "dismissTrigger on a trigger that is not dismissible")
                }
                var rest = fields
                rest["type"] = nil
                try object(.object(rest), schema: schema, path: path, itemFields: itemFields)
            case .condition:
                guard case .object(let fields) = value, fields.count == 1, let (name, payload) = fields.first else {
                    throw TriggerUnrenderable(path: path, detail: "a condition has exactly one key")
                }
                guard let payloadKind = vocabulary.conditions[name] else {
                    throw TriggerUnrenderable(path: path, detail: "unknown condition \(name)")
                }
                // Every value has a default, so it would always hold.
                if rules != nil, name == "hasValue", case .string(let key) = payload, key.hasPrefix(TriggerValues.tokenPrefix) {
                    throw TriggerUnrenderable(path: "\(path).\(name)", detail: "hasValue on a value is always true")
                }
                try field(payload, kind: payloadKind, path: "\(path).\(name)", itemFields: itemFields)
            case .conditions:
                guard case .array(let items) = value else { throw TriggerUnrenderable(path: path, detail: "expected an array") }
                for (index, item) in items.enumerated() {
                    try field(item, kind: .condition, path: "\(path)[\(index)]", itemFields: itemFields)
                }
            case .name:
                guard case .string(let name) = value, Self.isName(name) else {
                    throw TriggerUnrenderable(path: path, detail: "expected a short camel-case name")
                }
            case .symbol:
                guard case .string(let name) = value else { throw TriggerUnrenderable(path: path, detail: "expected a symbol name") }
                guard vocabulary.symbols.contains(name) else {
                    throw TriggerUnrenderable(path: path, detail: "unknown symbol \(name)")
                }
            }
        }

        /// Fields a publisher value may fill: visible text and the spoken label and hint.
        private static let valueFields: Set<String> = ["text", "accessibilityLabel", "accessibilityHint"]

        /// The field name `path` ends in (`url` for `root.asyncImage.url`).
        private static func fieldName(_ path: String) -> Substring {
            path.split(separator: ".").last ?? Substring(path)
        }

        /// Where a value may never reach, even through one of the look's strings: an image URL or a
        /// countdown unit. Nil elsewhere.
        private static func closedToValues(_ path: String) -> String? {
            if path.hasSuffix(".asyncImage.url") { return "an image URL" }
            if path.contains(".countdown.units.") { return "a countdown unit" }
            return nil
        }

        /// Every `${key}` must be one this trigger's host provides, one of the look's own strings (V-4),
        /// a value with a default where values may go, or a field of the loop's item.
        private func tokens(_ string: String, path: String, itemFields: Set<String>?) throws {
            guard let rules else { return }
            let closed = Self.closedToValues(path)
            for token in TriggerLookCheck.tokens(in: string) {
                if let closed, token.hasPrefix(TriggerValues.tokenPrefix) || look.strings[token].map({ !TriggerValues.keys(in: $0).isEmpty }) == true {
                    throw TriggerUnrenderable(path: path, detail: "a publisher value may not reach \(closed)")
                }
                if token.hasPrefix(TriggerValues.tokenPrefix) {
                    let key = String(token.dropFirst(TriggerValues.tokenPrefix.count))
                    guard Self.valueFields.contains(String(Self.fieldName(path))) else {
                        throw TriggerUnrenderable(path: path, detail: "a publisher value may not reach this field")
                    }
                    guard look.defaults[key] != nil else {
                        throw TriggerUnrenderable(path: path, detail: "${\(token)} has no default in values")
                    }
                } else if token.hasPrefix("item.") {
                    guard let itemFields, itemFields.contains(String(token.dropFirst(5))) else {
                        throw TriggerUnrenderable(path: path, detail: "unknown item field \(token)")
                    }
                } else if !rules.values.contains(token), look.strings[token] == nil {
                    throw TriggerUnrenderable(path: path, detail: "unknown value \(token)")
                }
            }
        }
    }
}
