// Sources/Encore/Core/Infrastructure/Storage/TemplateStore.swift
//
// File-based storage for resolved templates, one file per use case. The
// variant identity and its template travel as an atomic pair on purpose: a
// persisted config that claims variant X but cannot render X is the
// half-state this store exists to prevent.

import Foundation

// MARK: - Stored Template

/// One use case's last-known-good resolved template. The variant identity and
/// template are an atomic pair by design: they are only ever written and read
/// together, so a stored claim can always render.
///
/// Schema mirrored on Android: `{useCase, variantId, variantName, uiValues,
/// template, savedAtMs, userId, language}`. `template` is the RAW wire JSON,
/// not the parsed tree: robust across internal model changes, byte-stable, and
/// symmetric with Android. `uiValues` is the use case's own values snapshot;
/// only churn's config blob persists, so borrowing the blob's values for a
/// rung-2 render would lose every other use case's dashboard copy. `userId`
/// and `language` stamp the identity it was resolved for, so a read for a
/// different identity treats it as absent rather than rendering another
/// user's arm.
internal struct StoredTemplate: Codable, Sendable, Equatable {
    let useCase: String
    let variantId: String?
    let variantName: String?
    /// The use case's values snapshot at resolution time.
    let uiValues: UIValues
    /// Raw wire-shape template JSON, re-parsed by the never-throws parser on read.
    let template: Data
    let savedAtMs: Int64
    let userId: String
    let language: String?

    init(
        useCase: UseCase,
        variantId: String?,
        variantName: String?,
        uiValues: UIValues,
        template: Data,
        savedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        userId: String,
        language: String?
    ) {
        self.useCase = useCase.rawValue
        self.variantId = variantId
        self.variantName = variantName
        self.uiValues = uiValues
        self.template = template
        self.savedAtMs = savedAtMs
        self.userId = userId
        self.language = language
    }

    /// Whether this template was resolved for `userId`/`language`. A mismatch
    /// means it is absent, never that it may be adapted.
    func matches(userId: String, language: String?) -> Bool {
        self.userId == userId && self.language == language
    }
}

// MARK: - Stored Template Store

/// File-per-use-case storage under an env-scoped directory.
/// - Serial queue for reads and writes (mirrors `OutboxStorage`)
/// - Temp file + atomic rename, so a killed process leaves no torn file
/// - Injectable directory so tests never touch Application Support
internal final class TemplateStore: @unchecked Sendable {

    // MARK: - Properties

    private let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let queue: DispatchQueue
    /// Same `(environment, api key)` scoping as the config blob key: a
    /// template from one environment must never serve another.
    private let scope: String

    // MARK: - Init

    init(
        environment: EnvironmentConfiguration? = nil,
        apiKey: String? = nil,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.queue = DispatchQueue(label: "com.encore.config.templatestore", qos: .utility)
        self.scope = environment.map { "\($0).\(apiKey.map { String($0.suffix(8)) } ?? "")" } ?? ""

        if let directory {
            self.directory = directory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            self.directory = (appSupport ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                .appendingPathComponent("com.encore.sdk/config", isDirectory: true)
        }

        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        Logger.debug("TemplateStore: Initialized at: \(self.directory.path)")
    }

    // MARK: - Public API

    /// Writes `template`, replacing any previous one for that use case.
    /// Temp file + rename, so a reader never observes a half-written file.
    @discardableResult
    func save(_ template: StoredTemplate) -> Bool {
        queue.sync {
            let destination = fileURL(forUseCaseRawValue: template.useCase)
            let temp = destination.appendingPathExtension("tmp")
            do {
                // Idempotent, and self-heals a directory removed under us
                // (storage cleanup, or the OS purging Application Support).
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try encoder.encode(template)
                try data.write(to: temp, options: .atomic)
                _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
                Logger.debug("TemplateStore: Saved template for \(template.useCase) (variantId=\(template.variantId ?? "nil"))")
                return true
            } catch {
                try? fileManager.removeItem(at: temp)
                Logger.error(.transport(.persistence(error)), context: .configuration)
                return false
            }
        }
    }

    /// Reads the template for `useCase`, or nil when absent, unreadable, or
    /// stamped with a different identity.
    func load(useCase: UseCase, userId: String, language: String?) -> StoredTemplate? {
        queue.sync {
            let url = fileURL(forUseCaseRawValue: useCase.rawValue)
            guard let data = try? Data(contentsOf: url),
                  let stored = try? decoder.decode(StoredTemplate.self, from: data) else { return nil }
            guard stored.matches(userId: userId, language: language) else {
                Logger.debug("TemplateStore: Ignoring \(useCase.rawValue) template stamped for another identity")
                return nil
            }
            return stored
        }
    }

    /// Deletes the template for `useCase`. Called on a server fresh-null, so
    /// it never outlives a publisher's decision to disable the surface.
    func delete(useCase: UseCase) {
        queue.sync {
            try? fileManager.removeItem(at: fileURL(forUseCaseRawValue: useCase.rawValue))
        }
    }

    /// Deletes every stored template in this scope. Called on logout/reset
    /// and identity change.
    func deleteAll() {
        queue.sync {
            let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in contents where name.hasSuffix(".json") && name.hasPrefix(filePrefix) {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    // MARK: - Private

    private var filePrefix: String { scope.isEmpty ? "template." : "template.\(scope)." }

    /// Filenames are env-scoped so two environments' templates coexist without
    /// either seeding the other, matching the config blob's key scoping.
    private func fileURL(forUseCaseRawValue rawValue: String) -> URL {
        let safe = rawValue.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(filePrefix)\(safe).json")
    }
}
