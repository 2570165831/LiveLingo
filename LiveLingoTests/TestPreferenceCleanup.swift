import Darwin
import Foundation

/// CFFIXED_USER_HOME does not redirect cfprefsd. Remove only a fresh UUID suite
/// registered by this test, after flushing its empty persistent domain.
struct TestPreferenceCleanup: Sendable {
    private let suite: String
    private let plist: URL

    init(suite: String) throws {
        let prefixes = [
            "SpanishFrenchTarget-",
            "FullScreenClassMode-",
            "FloatingSubtitleDisplay-",
            "EnglishTargetPanel-",
            "ClassroomPresentation-",
            "LiveLingoMeterTest-",
            "LiveLingo-CaptionIdentity-",
            "LiveLingo-StabilityDraft-",
            "LiveLingo-StabilityLifecycle-",
            "LiveLingo-Publication-",
            "LiveLingo-CaptionScheduling-",
            "DefaultTargetGolden-",
            "LiveLingo-LatinDefaultPipeline-",
            "LiveLingo-MultilingualAppModel-",
            "LiveLingo-MultilingualCaptionGate-",
            "MultilingualPreview-",
            "LiveLingo-V2bRecovery-",
            "OutputLanguageBaseline-",
            "LiveLingo-Race-",
            "LiveLingo-Test-",
            "LiveLingo-Item7-",
        ]
        guard let prefix = prefixes.first(where: suite.hasPrefix),
              UUID(uuidString: String(suite.dropFirst(prefix.count))) != nil,
              let directory = getpwuid(getuid())?.pointee.pw_dir else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        self.suite = suite
        plist = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent(suite + ".plist")
        guard try Self.fileStatus(at: plist) == nil else {
            throw CocoaError(.fileWriteFileExists)
        }
        print("TEST_PREFERENCE_CREATED suite=\(suite)")
    }

    func remove(_ defaults: UserDefaults) throws {
        let domain = defaults.persistentDomain(forName: suite)
        // Clearing a read-only/nonexistent domain itself queues an empty plist.
        // Leave it untouched; there is nothing for cfprefsd to flush or erase.
        let hadValues = domain?.isEmpty == false
        // On current macOS, even synchronize/CFPreferencesSynchronize returns
        // before cfprefsd's periodic disk write. Deleting earlier recreates an
        // empty plist later. Wait for this suite's cleared domain to reach disk.
        if hadValues {
            let removedAt = Date()
            defaults.removePersistentDomain(forName: suite)
            guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
            let deadline = Date().addingTimeInterval(15)
            var clearedOnDisk = false
            repeat {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: plist.path),
                   let modified = attributes[.modificationDate] as? Date, modified >= removedAt,
                   let data = try? Data(contentsOf: plist),
                   let domain = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   domain.isEmpty {
                    clearedOnDisk = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            } while Date() < deadline
            guard clearedOnDisk else { throw CocoaError(.fileWriteUnknown) }
        }
        if let status = try Self.fileStatus(at: plist) {
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try FileManager.default.removeItem(at: plist)
        }
        guard try Self.fileStatus(at: plist) == nil else {
            throw CocoaError(.fileWriteUnknown)
        }
        print("TEST_PREFERENCE_CLEANED suite=\(suite)")
    }

    func remove() throws {
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.fileWriteUnknown) }
        try remove(defaults)
    }

    private static func fileStatus(at url: URL) throws -> stat? {
        var status = stat()
        if lstat(url.path, &status) == 0 { return status }
        guard errno == ENOENT else { throw CocoaError(.fileReadUnknown) }
        return nil
    }
}
