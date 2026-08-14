// Sources/Encore/Core/Canonical/RemoteConfig/RemoteConfigDto.swift
//
// Remote configuration domain DTOs - SDUI layout and app config operations.
//

import Foundation
internal import OpenAPIRuntime

extension DTO {
    
    /// Remote Configuration Domain DTOs
    enum RemoteConfig {
        
        // MARK: - Config Route (GET /publisher/sdk/v1/config) - Unified endpoint

        /// Full response from the /config endpoint
        typealias ConfigResponse = Operations.get_sol_publisher_sol_sdk_sol_v1_sol_config.Output.Ok.Body.jsonPayload

        /// UI configuration (template + values)
        typealias UIConfig = ConfigResponse.uiPayload

        /// One entry of the `useCases` prefetch block: a use case's **default**
        /// variant, shipped alongside the requested one so a later presentation
        /// renders without a round trip.
        ///
        /// Hand-declared for one reason: the generator emits a structurally
        /// identical but *distinct* type per use-case key, which cannot be
        /// mapped once and grows a new type with every use case the backend
        /// adds. Every field below is a generated `ui` type — the schemas are
        /// the same objects — so the contract still owns all the shapes.
        struct UseCaseDefault: Decodable, Sendable {
            /// Null when the app is enabled for the surface but no default
            /// variant is eligible for it.
            let variantId: String?
            let variantName: String?
            /// Null means "enabled, but nothing to render" — the SDK must no-op
            /// on this surface and never substitute another use case's template.
            let template: UITemplate?
            /// Always present, even when `template` is null: the copy is
            /// resolved from `app_use_cases` regardless.
            let values: UIValues
        }

        /// Wire envelope for `GET /config`.
        ///
        /// Hand-declared rather than decoded straight into ``ConfigResponse``
        /// because the contract marks `useCases` **required**: the generated
        /// decoder rejects any response without it, and the SDK would lose `ui`
        /// along with it. A backend older than the prefetch rollout — or a
        /// rollback below it — sends exactly that shape, so decoding the block
        /// as optional is what keeps the addition genuinely additive. The three
        /// pre-existing blocks stay required, as they have always been.
        ///
        /// Everything else decodes STRICTLY on purpose (2026-08-11 decision):
        /// a response that fails the contract should be flagged loudly, never
        /// papered over — contracts are synced against the deployed backend as
        /// a release step, and a mismatch is a deploy-ordering bug to surface.
        struct ConfigResponseEnvelope: Decodable, Sendable {
            let ui: UIConfig
            let entitlements: EntitlementsConfig
            let experiments: ExperimentsConfig
            /// Keyed by ``UseCase`` raw value. Absent on a pre-prefetch backend,
            /// empty for an app enabled for one use case only.
            let useCases: [String: UseCaseDefault]?
        }
        
        /// UI template (additionalProperties - parsed to SDUIConfig domain model)
        typealias UITemplate = UIConfig.templatePayload
        
        /// UI values (text + appearance)
        typealias UIValues = UIConfig.valuesPayload
        
        /// Entitlements configuration (IAP or Native mode)
        typealias EntitlementsConfig = ConfigResponse.entitlementsPayload
        
        /// IAP entitlement config
        typealias IAPConfig = EntitlementsConfig.iapPayload
        
        /// Native entitlement config
        typealias NativeConfig = EntitlementsConfig.nativePayload
        
        /// Experiments configuration
        typealias ExperimentsConfig = ConfigResponse.experimentsPayload
        
        /// NCL experiment config
        typealias NCLConfig = ExperimentsConfig.nclPayload
        
        // MARK: - Legacy (GET /publisher/sdk/v1/ui-config) - Deprecated
        
        /// Full response type from the legacy ui-config endpoint
        @available(*, deprecated, message: "Use ConfigResponse from /config endpoint")
        typealias Response = Operations.get_sol_publisher_sol_sdk_sol_v1_sol_ui_hyphen_config.Output.Ok.Body.jsonPayload
        
        /// Success response with SDUI config and remote config (value1)
        @available(*, deprecated, message: "Use UIConfig from /config endpoint")
        typealias SuccessResponse = Response.Value1Payload
        
        /// Response when no active variant exists (value2)
        @available(*, deprecated, message: "Use ConfigResponse from /config endpoint")
        typealias NoVariantResponse = Response.Value2Payload
        
        /// SDUI config wrapper containing variant info and layout JSON
        @available(*, deprecated, message: "Use UIConfig from /config endpoint")
        typealias SDUIConfig = SuccessResponse.sduiConfigPayload
        
        /// SDUI layout config (additionalProperties)
        @available(*, deprecated, message: "Use UITemplate from /config endpoint")
        typealias SDUILayout = SDUIConfig.configPayload
        
        /// Remote config with app text/color variables (flat structure)
        @available(*, deprecated, message: "Use UIValues from /config endpoint")
        typealias LegacyRemoteConfig = SuccessResponse.remoteConfigPayload
        
        /// Appearance mode enum (light/dark/auto)
        @available(*, deprecated, message: "Use UIValues.appearance.mode from /config endpoint")
        typealias AppearanceMode = LegacyRemoteConfig.appearanceModePayload
    }
}
