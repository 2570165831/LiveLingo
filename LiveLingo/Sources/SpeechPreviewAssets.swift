import Foundation
import Speech

enum SpeechPreviewAssets {
    @available(macOS 27, *)
    static func prepare(locale: Locale, modules: [any SpeechModule]) async throws -> Bool {
        let reserved = await AssetInventory.reservedLocales
        let wasReserved = reserved.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        return try await prepare(
            wasReserved: wasReserved,
            reserve: { try await AssetInventory.reserve(locale: locale) },
            isInstalled: { await AssetInventory.status(forModules: modules) == .installed },
            release: { _ = await AssetInventory.release(reservedLocale: locale) }
        )
    }

    /// A new app can see shared, installed assets as merely `supported` until
    /// it reserves the locale. Reserving does not request a model download.
    /// Keep an existing reservation intact if the model is temporarily absent.
    static func prepare(
        wasReserved: Bool,
        reserve: @Sendable () async throws -> Bool,
        isInstalled: @Sendable () async -> Bool,
        release: @Sendable () async -> Void
    ) async throws -> Bool {
        try Task.checkCancellation()
        let added = try await reserve()
        let installed = await isInstalled()
        if !installed || Task.isCancelled {
            if added && !wasReserved { await release() }
            try Task.checkCancellation()
            return false
        }
        return true
    }
}
