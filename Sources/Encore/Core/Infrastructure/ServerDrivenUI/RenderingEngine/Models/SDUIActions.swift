//
//  SDUIActions.swift
//  Encore
//
//  SDUI action types for button interactions
//

import Foundation

// MARK: - Action Types

/// Action types supported by SDUI buttons
enum SDUIActionType: String, Decodable {
    case close
    case claimOffer
    case openUrl
    case setState      // Set currentState to a new value
    case setValue      // Set a key-value pair in the values dictionary
    case selectOffer   // Row-aware: write the current forEach offer's id into context.values[targetKey ?? "selectedOfferId"]
    case triggerIAP    // Trigger IAP purchase, transition to onSuccessState on success
    case submitLead   // Validate email, check private relay, submit lead, transition to onSuccessState
}

/// Action configuration for buttons - supports both simple actions and parameterized actions
struct SDUIAction: Decodable {
    let type: SDUIActionType
    var setState: String?       // For setState action: the new state value
    var setValueKey: String?    // For setValue action: the key to set
    var setValueValue: String?  // For setValue action: the value to set
    var onSuccessState: String? // For triggerIAP action: state to transition to on success
    var onCancelAction: String? // For triggerIAP action: "close" to dismiss, or state name to transition to
    var targetKey: String?      // For selectOffer action: the context.values key to write the selected offer id into (default "selectedOfferId")
    
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

    static func selectOffer(targetKey: String? = nil) -> SDUIAction {
        SDUIAction(type: .selectOffer, targetKey: targetKey)
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
    }

    private enum CodingKeys: String, CodingKey {
        case type, setState, setValueKey, setValueValue, onSuccessState, onCancelAction, targetKey
    }

    init(type: SDUIActionType, setState: String? = nil, setValueKey: String? = nil, setValueValue: String? = nil, onSuccessState: String? = nil, onCancelAction: String? = nil, targetKey: String? = nil) {
        self.type = type
        self.setState = setState
        self.setValueKey = setValueKey
        self.setValueValue = setValueValue
        self.onSuccessState = onSuccessState
        self.onCancelAction = onCancelAction
        self.targetKey = targetKey
    }
}
