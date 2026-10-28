// The trigger vocabulary every SDK shares (vocab-contract.md §5 ALLOW), with nested objects
// checked against what this SDK's SDUI decoder reads. Anything outside it is unrenderable.

extension TriggerVocabulary {
    static let v1: TriggerVocabulary = {
        let number = TriggerFieldKind.scalar()
        // Bounded numbers (SDK safety): a look stays near its own frame and can never cover the
        // host app. Each range leaves room over what the shipped looks use.
        let size = TriggerFieldKind.number(0...480)
        let maxSize = TriggerFieldKind.number(0...480, orString: ["infinity"])
        // Widths run to 600, the tablet cap every look's root carries (centred in a wider mount); a
        // width never draws past the mount, which bounds it. Heights keep the 480 bound.
        let width = TriggerFieldKind.number(0...600)
        let maxWidth = TriggerFieldKind.number(0...600, orString: ["infinity"])
        let offsetValue = TriggerFieldKind.number(-64...64)
        let scale = TriggerFieldKind.number(0...2)
        let unit = TriggerFieldKind.number(0...1)
        let duration = TriggerFieldKind.number(0...120)
        let rotation = TriggerFieldKind.number(-360...360)
        let inset = TriggerFieldKind.number(0...64)
        let spacing = TriggerFieldKind.number(-16...64)
        let radius = TriggerFieldKind.number(0...240)
        let lineWidth = TriggerFieldKind.number(0...16)
        let count = TriggerFieldKind.number(0...100)
        let color = TriggerFieldKind.object(TriggerObjectSchema([
            "hex": number,
            "semantic": .scalar(allowed: [
                "label", "secondaryLabel", "tertiaryLabel", "systemBackground", "secondarySystemBackground",
                "systemGroupedBackground", "secondarySystemGroupedBackground", "separator", "tertiarySystemFill",
            ]),
            "appearance": .scalar(allowed: [
                "background", "onBackground", "surface", "onSurface", "accent", "onAccent", "inkOnAccent", "border", "secondary", "track", "backgroundEnd",
            ]),
            "opacity": unit, "lighten": unit, "darken": unit,
        ]))
        let font = TriggerFieldKind.object(TriggerObjectSchema([
            "size": TriggerFieldKind.number(1...64),
            "weight": .scalar(allowed: ["ultraLight", "thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black"]),
            "tracking": TriggerFieldKind.number(-8...8),
            "monospacedDigits": number,
        ]))
        let alignment = TriggerFieldKind.scalar(allowed: [
            "leading", "trailing", "center", "top", "bottom", "topLeading", "topTrailing", "bottomLeading", "bottomTrailing",
        ])
        let offset = TriggerFieldKind.object(TriggerObjectSchema(["x": offsetValue, "y": offsetValue]))
        let pose = TriggerObjectSchema(["scale": scale, "opacity": unit, "rotation": rotation, "offset": offset])
        var keyframe = pose
        keyframe.fields["at"] = unit
        let curve = TriggerFieldKind.scalar(allowed: ["linear", "easeIn", "easeOut", "easeInOut"])

        let style = TriggerFieldKind.object(TriggerObjectSchema([
            "padding": .object(TriggerObjectSchema([
                "top": inset, "leading": inset, "bottom": inset, "trailing": inset,
                "horizontal": inset, "vertical": inset, "all": inset,
            ])),
            "frame": .object(TriggerObjectSchema([
                "width": width, "height": size, "minWidth": width, "maxWidth": maxWidth,
                "minHeight": size, "maxHeight": maxSize, "alignment": alignment,
            ])),
            "cornerRadius": radius,
            "backgroundColor": color,
            "shadow": .object(TriggerObjectSchema([
                "color": color, "radius": TriggerFieldKind.number(0...32),
                "x": TriggerFieldKind.number(-32...32), "y": TriggerFieldKind.number(-32...32), "opacity": unit,
            ])),
            "opacity": unit,
            "clipShape": .object(TriggerObjectSchema([
                "rectangle": .object(TriggerObjectSchema(["cornerRadius": radius])),
                "circle": .object(TriggerObjectSchema([:])),
                "capsule": .object(TriggerObjectSchema([:])),
            ])),
            "clipped": number,
            "borderWidth": lineWidth,
            "borderColor": color,
            "offset": offset,
            "scale": scale,
            "rotation": rotation,
            "overlay": .element,
            "backgroundElement": .element,
            "fixedSize": .object(TriggerObjectSchema(["horizontal": number, "vertical": number])),
            "layoutPriority": TriggerFieldKind.number(-10...10),
            "stateStyles": .map(pose),
            "stateAnimation": .object(TriggerObjectSchema(["curve": curve, "duration": duration])),
            "loop": .object(TriggerObjectSchema([
                "duration": duration, "phaseOffset": unit, "curve": curve,
                "keyframes": .objects(keyframe), "reducedMotion": .object(pose),
            ])),
            "layoutDirection": .scalar(allowed: ["ltr"]),
            "accessibilityHidden": number,
        ]))
        let stack: [String: TriggerFieldKind] = ["alignment": alignment, "spacing": spacing, "children": .elements, "style": style]

        return TriggerVocabulary(
            elements: [
                "text": TriggerObjectSchema([
                    "text": .copy,
                    "countdown": .object(TriggerObjectSchema([
                        "to": .timeKey,
                        "format": .scalar(allowed: ["clock", "hoursMinutes", "hours", "minutes", "seconds", "largestUnit"]),
                        "units": .object(TriggerObjectSchema(["hours": .copy, "minutes": .copy, "seconds": .copy])),
                    ])),
                    "font": font, "color": color, "lineLimit": TriggerFieldKind.number(1...10),
                    "minimumScaleFactor": TriggerFieldKind.number(0.5...1),
                    "scaleGroup": .name,
                    "multilineAlignment": alignment,
                    "segments": .objects(TriggerObjectSchema(["text": .copy, "font": font, "color": color])),
                    "style": style,
                ]),
                "systemImage": TriggerObjectSchema(["systemName": .symbol, "font": font, "color": color, "style": style]),
                "asyncImage": TriggerObjectSchema([
                    "url": number, "contentMode": .scalar(allowed: ["fit", "fill"]),
                    "placeholderColor": color, "fallback": .element, "style": style,
                ]),
                "button": TriggerObjectSchema([
                    "content": .element, "action": .action, "disabled": number,
                    "accessibilityLabel": .copy, "accessibilityHint": .copy,
                    "pressedStyle": .object(TriggerObjectSchema(["scale": scale, "duration": duration])),
                    "style": style,
                ]),
                "vStack": TriggerObjectSchema(stack),
                "hStack": TriggerObjectSchema(stack),
                "zStack": TriggerObjectSchema(["alignment": alignment, "children": .elements, "style": style]),
                "spacer": TriggerObjectSchema(["minLength": size]),
                "shape": TriggerObjectSchema([
                    "type": .scalar(allowed: ["rectangle", "roundedRectangle", "circle", "capsule", "ellipse"]),
                    "cornerRadius": radius, "fillColor": color, "strokeColor": color, "strokeWidth": lineWidth, "style": style,
                ]),
                "gradient": TriggerObjectSchema([
                    "type": .scalar(allowed: ["linear", "radial"]),
                    "direction": .scalar(allowed: ["topToBottom", "bottomToTop", "leadingToTrailing", "trailingToLeading"]),
                    "colors": .objects(TriggerObjectSchema(["color": color, "opacity": unit])),
                    "startRadius": size, "endRadius": size, "style": style,
                ]),
                "forEach": TriggerObjectSchema([
                    "dataSource": .scalar(allowed: ["hostList"]), "list": .listName,
                    "itemTemplate": .element, "limit": count, "offset": count,
                ]),
                "conditional": TriggerObjectSchema(["condition": .condition, "ifTrue": .element, "ifFalse": .element]),
                "group": TriggerObjectSchema(["content": .element, "style": style]),
                "empty": TriggerObjectSchema([:]),
                "progress": TriggerObjectSchema([
                    "value": .object(TriggerObjectSchema([
                        "timeRemaining": .object(TriggerObjectSchema(["from": .timeKey, "to": .timeKey])),
                        "literal": unit,
                    ])),
                    "fillColor": color, "trackColor": color, "style": style,
                ]),
                "marquee": TriggerObjectSchema([
                    "axis": .scalar(allowed: ["horizontal", "vertical"]), "duration": duration, "reverse": number,
                    "spacing": spacing, "animateWhen": .condition, "content": .element, "style": style,
                ]),
            ],
            actions: [
                "trigger": TriggerObjectSchema(["target": .scalar(allowed: ["card", "arrow", "button"])]),
                "dismissTrigger": TriggerObjectSchema([:]),
            ],
            symbols: ["gift", "gift.fill", "chevron.forward", "arrow.forward", "xmark"],
            conditions: [
                "hasValue": number,
                "valueEquals": .object(TriggerObjectSchema(["key": number, "value": number])),
                "stateEquals": .scalar(allowed: ["idle", "busy"]),
                "and": .conditions,
                "or": .conditions,
                "not": .condition,
                "listCountAtLeast": .object(TriggerObjectSchema(["list": .listName, "min": count])),
            ]
        )
    }()
}

extension TriggerLookRules {
    /// GiftsButton: copy, its icon, the held offers (count, first perk, whether any is new) and their
    /// logos; no times; never dismissible.
    static let giftsButton = TriggerLookRules(
        values: ["title", "subtitle", "cta", "layout", "icon", "appIconUrl", "offersTitle", "offerCount", "perk", "isNew"],
        times: [],
        lists: [
            "offerLogos": ["logoUrl", "advertiserName", "advertiserInitial", "perk"],
            "offerLogosA": ["logoUrl", "advertiserName", "advertiserInitial", "perk"],
            "offerLogosB": ["logoUrl", "advertiserName", "advertiserInitial", "perk"],
        ],
        dismissible: false,
        behavior: TriggerBehavior.steps["giftsButton"] ?? [:]
    )

    /// ClaimReminder: copy, the advertiser, the claim's window and its logos.
    static func claimReminder(dismissible: Bool) -> TriggerLookRules {
        TriggerLookRules(
            values: [
                "title", "subtitle", "cta", "layout", "dismiss", "hours", "minutes", "seconds",
                "advertiserName", "advertiserInitial", "advertiserLogoUrl", "accessibilityTitle", "icon", "appIconUrl",
                "offerTitle", "titleMany", "claimCount", "perk", "accessibilityHint", "left",
            ],
            times: ["start", "deadline"],
            lists: [
                "claims": ["transactionId", "advertiserName", "advertiserInitial", "advertiserLogoUrl"],
                "marqueeLogos": ["logoUrl"], "marqueeLogosA": ["logoUrl"], "marqueeLogosB": ["logoUrl"],
            ],
            dismissible: dismissible,
            behavior: TriggerBehavior.steps["claimReminder"] ?? [:]
        )
    }
}
