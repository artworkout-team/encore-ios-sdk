// Sources/Encore/Core/Infrastructure/ServerDrivenUI/SDUIConfigurationManager.swift
//
// SDUI configuration management - parsing and fallback handling.
// Lazily derives layout from RemoteConfigurationManager when accessed,
// independently per use case.
//

import Foundation

// MARK: - SDUI Configuration Manager

/// Manages SDUI layout parsing and fallback handling.
/// Lazily derives layout from `remoteConfigManager?.ui(for:)` when accessed.
///
/// Layouts are derived **per read, per use case**. There is deliberately no
/// layout memo. Templates are parsed eagerly at decode, so derivation is
/// dictionary reads; a memo keyed on config state is what let a disk-restored
/// template-less config poison the real variant id. Only the static embedded
/// fallback parse is memoised. The unparameterised accessors (`layout`,
/// `variantId`, `requiresIAP`) are churn-intervention shorthands.
class SDUIConfigurationManager {

    private let decoder = JSONDecoder()

    /// Resolves the remote UI configuration for a use case.
    /// Injected so tests can drive layout resolution without a network fetch.
    private let uiProvider: (UseCase) -> UIConfiguration?

    /// Use cases latched onto the embedded fallback after variant validation
    /// failed (e.g. an invalid IAP product). A latch, not a cache: it holds
    /// across reads and clears only via `clearForcedFallback()`.
    private var forcedFallback: Set<UseCase> = []

    /// Memoised parses of the static embedded floor JSON, per use case. Safe
    /// to memoise: the JSON is compiled into the binary, so no config state
    /// can drift under it.
    private var floorMemo: [UseCase: SDUIConfig] = [:]

    #if DEBUG
    private var hasLoggedDevStatus = false
    #endif

    // MARK: - Init

    init(uiProvider: @escaping (UseCase) -> UIConfiguration? = { remoteConfigManager?.ui(for: $0) }) {
        self.uiProvider = uiProvider
    }

    // MARK: - Public Properties

    /// SDUI layout config for the churn-intervention use case.
    var layout: SDUIConfig? { layout(for: .reduceChurn) }

    /// Variant ID for the churn-intervention use case.
    var variantId: String? { variantId(for: .reduceChurn) }

    /// Whether the churn-intervention layout requires IAP functionality.
    var requiresIAP: Bool { requiresIAP(for: .reduceChurn) }

    // MARK: - Public Methods

    /// Where `layout(for:)` currently resolves from. Recomputed per read, so
    /// it can never disagree with the layout it describes.
    enum LayoutSource {
        /// The remote template (fresh or a rung-2 pair).
        case remote
        /// The use case's own embedded floor.
        case floor
        /// A resolved server "no": render nothing, the presentation declines.
        case declined
    }

    /// SDUI layout config for `useCase`. Derived from remote config on every
    /// read, with dev/fallback handling.
    ///
    /// Returns `nil` only when the server explicitly resolved no template for
    /// a use case whose null is a decline (`resolvedNullDeclines`); the caller
    /// must then no-op. See `layoutSource(for:)`.
    func layout(for useCase: UseCase) -> SDUIConfig? {
        #if DEBUG
        if !hasLoggedDevStatus {
            SDUIDevConfig.logStatus()
            hasLoggedDevStatus = true
        }
        // The dev override is a churn-intervention authoring tool. Letting
        // it hijack another use case would mask the null-template safety
        // property in exactly the builds where it's easiest to miss.
        if SDUIDevConfig.useDevConfig, useCase == .reduceChurn {
            return loadDevConfig()
        }
        #endif

        switch layoutSource(for: useCase) {
        case .remote:
            let ui = uiProvider(useCase)
            Logger.info("✅ [SDUIConfig] Using remote template: variantId=\(ui?.variantId ?? "nil")")
            return ui?.template
        case .floor:
            Logger.info("📦 [SDUIConfig] Rendering the \(useCase.rawValue) embedded floor")
            return floor(for: useCase)
        case .declined:
            Logger.info("ℹ️ [SDUIConfig] Server resolved no \(useCase.rawValue) template, declining")
            return nil
        }
    }

    /// Rung 3 of the availability ladder. A resolved template wins; a server
    /// fresh-null declines only where null is a resolved answer (churn has no
    /// remote kill switch on the wire, so its fresh null is a knowledge gap);
    /// anything else (offline, nothing cached, a stale template-less blob, the
    /// forced-fallback latch) renders this use case's OWN floor, never
    /// another's.
    ///
    /// The claim-only invariant lives HERE, in the derivation: a remote
    /// template for a non-IAP use case that references an IAP trigger
    /// anywhere derives as that use case's floor, so every reader gets the
    /// safe answer with no ordering dependence, and a mis-authored variant
    /// heals the moment the server ships a fix. The latch remains only for
    /// product validation failures, which need StoreKit IO to detect.
    func layoutSource(for useCase: UseCase) -> LayoutSource {
        if forcedFallback.contains(useCase) { return .floor }

        guard let ui = uiProvider(useCase) else { return .floor }
        if let template = ui.template {
            if !useCase.allowsIAP, Self.templateReferencesIAP(template) {
                Logger.warn("⚠️ [SDUIConfig] \(useCase.rawValue) template references an IAP trigger on a claim-only surface, rendering its floor instead")
                return .floor
            }
            return .remote
        }
        if ui.fromNetwork, useCase.resolvedNullDeclines { return .declined }
        return .floor
    }

    /// Variant ID from remote config for `useCase`.
    func variantId(for useCase: UseCase) -> String? {
        uiProvider(useCase)?.variantId
    }

    /// Whether `useCase`'s layout requires IAP functionality.
    /// Wide by design: the invalid-product guard is only as good as this scan.
    func requiresIAP(for useCase: UseCase) -> Bool {
        guard let config = layout(for: useCase) else { return false }
        return Self.templateReferencesIAP(config)
    }

    /// Wide IAP scan: the element tree, `stateActions` entry actions, and
    /// `triggerIAPFirst` alike.
    static func templateReferencesIAP(_ config: SDUIConfig) -> Bool {
        if config.triggerIAPFirst == true { return true }
        if let actions = config.stateActions,
           actions.values.contains(where: { $0.onEnter?.type == .triggerIAP }) {
            return true
        }
        return elementContainsTriggerIAP(config.root)
    }

    /// Latches `useCase` onto its OWN embedded floor. Call when variant
    /// validation fails (e.g. an invalid IAP product). The latch holds across
    /// reads, so a re-derivation cannot un-force a rejected remote template.
    func useFallbackConfig(for useCase: UseCase = .reduceChurn, reason: String) {
        guard useCase.allowsFallbackLayout else {
            Logger.warn("⚠️ [SDUIConfig] Refusing fallback for useCase=\(useCase.rawValue): \(reason)")
            return
        }
        Logger.warn("⚠️ [SDUIConfig] Switching to the \(useCase.rawValue) floor: \(reason)")
        forcedFallback.insert(useCase)
    }

    /// Clears the forced-fallback latch. Call alongside
    /// `RemoteConfigurationManager.clearCache()`, because a new identity's variant
    /// deserves a fresh validation, not the previous user's verdict.
    func clearForcedFallback() {
        forcedFallback.removeAll()
    }

    /// The embedded floor layout for `useCase`. Memoised per use case: the
    /// JSON is compiled into the binary, so no config state can drift under it.
    func floor(for useCase: UseCase) -> SDUIConfig? {
        if let memoised = floorMemo[useCase] { return memoised }
        guard let data = SDUIFallbackConfig.json(for: useCase).data(using: .utf8) else {
            Logger.warn("❌ [SDUIConfig] Floor JSON invalid for \(useCase.rawValue)")
            return nil
        }

        do {
            let parsed = try decoder.decode(SDUIConfig.self, from: data)
            floorMemo[useCase] = parsed
            return parsed
        } catch {
            Logger.warn("❌ [SDUIConfig] Failed to parse the \(useCase.rawValue) floor: \(error)")
            return nil
        }
    }

    // MARK: - Private Methods

    #if DEBUG
    private func loadDevConfig() -> SDUIConfig? {
        guard let data = SDUIDevConfig.devJSON.data(using: .utf8) else {
            Logger.warn("❌ [SDUIConfig] Dev JSON invalid, using fallback")
            return floor(for: .reduceChurn)
        }

        do {
            return try decoder.decode(SDUIConfig.self, from: data)
        } catch {
            Logger.warn("❌ [SDUIConfig] Failed to parse dev config: \(error), using fallback")
            return floor(for: .reduceChurn)
        }
    }
    #endif

    private static func elementContainsTriggerIAP(_ element: SDUIElement) -> Bool {
        switch element {
        case .button(let button):
            return button.action.type == .triggerIAP
        case .vStack(let stack):
            return stack.children.contains { elementContainsTriggerIAP($0) }
        case .hStack(let stack):
            return stack.children.contains { elementContainsTriggerIAP($0) }
        case .zStack(let stack):
            return stack.children.contains { elementContainsTriggerIAP($0) }
        case .scrollView(let scroll):
            return elementContainsTriggerIAP(scroll.content)
        case .conditional(let cond):
            return elementContainsTriggerIAP(cond.ifTrue) || (cond.ifFalse.map { elementContainsTriggerIAP($0) } ?? false)
        case .forEach(let forEach):
            return elementContainsTriggerIAP(forEach.itemTemplate)
        default:
            return false
        }
    }
}
