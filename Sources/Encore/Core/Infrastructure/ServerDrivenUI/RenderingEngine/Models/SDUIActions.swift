//
//  SDUIActions.swift
//  Encore
//
//  SDUI action types for button interactions
//

import Foundation

// MARK: - Action Types

/// Action types supported by SDUI buttons
enum SDUIActionType: String, Decodable, CaseIterable {
    case close
    case claimOffer
    case openUrl
    case setState      // Set currentState to a new value
    case setValue      // Set a key-value pair in the values dictionary
    case selectOffer   // Row-aware: write the current forEach offer's id into context.values[targetKey ?? "selectedOfferId"]
    case setOfferIndex // Move the focused offer to an absolute index or by a delta
    case triggerIAP    // Trigger IAP purchase, transition to onSuccessState on success
    case submitLead   // Validate email, check private relay, submit lead, transition to onSuccessState
    case share        // Present the system share sheet for the acting offer
}

/// Action configuration for buttons - supports both simple actions and parameterized actions
struct SDUIAction: Decodable {
    let type: SDUIActionType
    var setState: String?       // For setState action: the new state value
    var setValueKey: String?    // For setValue action: the key to set
    var setValueValue: String?  // For setValue action: the value to set
    var onSuccessState: String? // For triggerIAP action: state to transition to on success
    var onCancelAction: String? // For triggerIAP action: "close" to dismiss, or state name to transition to
    var targetKey: String?      // For selectOffer / setOfferIndex: the context.values key to write the selected offer id into (default "selectedOfferId")
    var offerIndex: Int?        // For setOfferIndex: the absolute display index to move to
    var offerIndexDelta: Int?   // For setOfferIndex: how far to move from the focused index, clamped to the list
    var promoteToIndex: Int?    // For selectOffer: move the chosen offer to this display position, clamped
    /// For setValue: resolve this instead of the literal `setValueValue`, so a
    /// chip can write the category it is iterating. A ref that resolves to
    /// nothing writes nothing, rather than falling back to the literal.
    var setValueRef: SDUIValueRef?
    /// For openUrl: which of the acting offer's own links to open. Constrained
    /// to the offer's fields rather than a free string, so a variant cannot
    /// hand the host an arbitrary scheme.
    var urlAttribute: SDUIOfferAttribute?
    
    // Convenience initializers for simple actions
    static let close = SDUIAction(type: .close)
    static let claimOffer = SDUIAction(type: .claimOffer)
    static let openUrl = SDUIAction(type: .openUrl)
    
    static func setState(_ state: String) -> SDUIAction {
        SDUIAction(type: .setState, setState: state)
    }
    
    static func setValue(key: String, value: String) -> SDUIAction {
        SDUIAction(type: .setValue, setValueKey: key, setValueValue: value)
    }

    static func selectOffer(targetKey: String? = nil, promoteToIndex: Int? = nil) -> SDUIAction {
        SDUIAction(type: .selectOffer, targetKey: targetKey, promoteToIndex: promoteToIndex)
    }
    
    /// Absolute move. An index outside the display list is a no-op.
    static func setOfferIndex(_ index: Int) -> SDUIAction {
        SDUIAction(type: .setOfferIndex, offerIndex: index)
    }

    /// Relative move, clamped to the ends of the display list.
    static func setOfferIndex(delta: Int) -> SDUIAction {
        SDUIAction(type: .setOfferIndex, offerIndexDelta: delta)
    }

    static func triggerIAP(onSuccessState: String) -> SDUIAction {
        SDUIAction(type: .triggerIAP, onSuccessState: onSuccessState)
    }

    static func submitLead(onSuccessState: String) -> SDUIAction {
        SDUIAction(type: .submitLead, onSuccessState: onSuccessState)
    }
    
    // Custom decoding to support both string format (legacy) and object format (new)
    init(from decoder: Decoder) throws {
        // Try to decode as a simple string first (backward compatibility)
        if let container = try? decoder.singleValueContainer(),
           let typeString = try? container.decode(String.self),
           let actionType = SDUIActionType(rawValue: typeString) {
            self.type = actionType
            self.setState = nil
            self.setValueKey = nil
            self.setValueValue = nil
            self.onSuccessState = nil
            self.onCancelAction = nil
            self.targetKey = nil
            self.offerIndex = nil
            self.offerIndexDelta = nil
            self.promoteToIndex = nil
            self.setValueRef = nil
            self.urlAttribute = nil
            return
        }
        
        // Otherwise decode as an object
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(SDUIActionType.self, forKey: .type)
        self.setState = try container.decodeIfPresent(String.self, forKey: .setState)
        self.setValueKey = try container.decodeIfPresent(String.self, forKey: .setValueKey)
        self.setValueValue = try container.decodeIfPresent(String.self, forKey: .setValueValue)
        self.onSuccessState = try container.decodeIfPresent(String.self, forKey: .onSuccessState)
        self.onCancelAction = try container.decodeIfPresent(String.self, forKey: .onCancelAction)
        self.targetKey = try container.decodeIfPresent(String.self, forKey: .targetKey)
        self.offerIndex = try container.decodeIfPresent(Int.self, forKey: .offerIndex)
        self.offerIndexDelta = try container.decodeIfPresent(Int.self, forKey: .offerIndexDelta)
        self.promoteToIndex = try container.decodeIfPresent(Int.self, forKey: .promoteToIndex)
        self.setValueRef = try container.decodeIfPresent(SDUIValueRef.self, forKey: .setValueRef)
        self.urlAttribute = try container.decodeIfPresent(SDUIOfferAttribute.self, forKey: .urlAttribute)
    }

    private enum CodingKeys: String, CodingKey {
        case type, setState, setValueKey, setValueValue, onSuccessState, onCancelAction, targetKey
        case offerIndex, offerIndexDelta, promoteToIndex, setValueRef, urlAttribute
    }

    init(type: SDUIActionType, setState: String? = nil, setValueKey: String? = nil, setValueValue: String? = nil, onSuccessState: String? = nil, onCancelAction: String? = nil, targetKey: String? = nil, offerIndex: Int? = nil, offerIndexDelta: Int? = nil, promoteToIndex: Int? = nil, setValueRef: SDUIValueRef? = nil, urlAttribute: SDUIOfferAttribute? = nil) {
        self.type = type
        self.setState = setState
        self.setValueKey = setValueKey
        self.setValueValue = setValueValue
        self.onSuccessState = onSuccessState
        self.onCancelAction = onCancelAction
        self.targetKey = targetKey
        self.offerIndex = offerIndex
        self.offerIndexDelta = offerIndexDelta
        self.promoteToIndex = promoteToIndex
        self.setValueRef = setValueRef
        self.urlAttribute = urlAttribute
    }

    /// The display index this action moves to, or nil for a no-op.
    ///
    /// `offerIndex` wins over `offerIndexDelta` when a variant carries both, so
    /// an absolute move never depends on where the user happened to be. An
    /// absolute index outside the list does nothing, matching
    /// `selectCenteredOffer`, which also refuses an index it cannot render. A
    /// delta CLAMPS instead: "Next gift" on the last card should stop, and a
    /// template hides that button with `isLastOffer`.
    func resolvedOfferIndex(focused: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        if let absolute = offerIndex {
            return (0..<count).contains(absolute) ? absolute : nil
        }
        guard let delta = offerIndexDelta else { return nil }
        // The delta is clamped BEFORE it is added, not after. Adding first
        // traps on overflow, and `offerIndexDelta` is an unbounded Int off the
        // wire: `9223372036854775807` from any focused index above zero killed
        // the host app. A delta larger than the list can never mean more than
        // "go to the end", so nothing is lost by bounding it here.
        let bounded = min(max(delta, -count), count)
        return min(max((focused ?? 0) + bounded, 0), count - 1)
    }
}
