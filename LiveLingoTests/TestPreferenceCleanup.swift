import Darwin
import Foundation

/// CFFIXED_USER_HOME does not redirect cfprefsd. Remove only a fresh UUID suite
/// registered by this test, after flushing its empty persistent domain.
struct TestPreferenceCleanup: Sendable {
    private let suite: String
    private let plist: URL

    init(suite: String) throws {
        let prefixes = ["FloatingSubtitleDisplay-", "ClassroomPresentation-", "LiveLingoMeterTest-"]
        guard let prefix = prefixes.first(where: suite.hasPrefix),
              UUID(uuidString: String(suite.dropFirst(prefix.count))) != nil,
              let directory = getpwuid(getuid())?.pointee.pw_dir else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        self.suite = suite
        plist = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent(suite + ".plist")
        guard !FileManager.default.fileExists(atPath: plist.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        print("TEST_PREFERENCE_CREATED suite=\(suite)")
    }

    func remove(_ defaults: UserDefaults) throws {
        let hadValues = defaults.persistentDomain(forName: suite)?.isEmpty == false
        let removedAt = Date()
        defaults.removePersistentDomain(forName: suite)
        guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
        // On current macOS, even synchronize/CFPreferencesSynchronize returns
        // before cfprefsd's periodic disk write. Deleting earlier recreates an
        // empty plist later. Wait for this suite's cleared domain to reach disk.
        if hadValues {
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
        if FileManager.default.fileExists(atPath: plist.path) {
            let values = try plist.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try FileManager.default.removeItem(at: plist)
        }
        guard !FileManager.default.fileExists(atPath: plist.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        print("TEST_PREFERENCE_CLEANED suite=\(suite)")
    }

    func remove() throws {
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.fileWriteUnknown) }
        try remove(defaults)
    }
}
