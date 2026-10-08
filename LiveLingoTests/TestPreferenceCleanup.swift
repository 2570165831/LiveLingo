import Foundation

/// A synthetic calendar clock that advances only with monotonic elapsed time.
/// Timer integration still runs, but changing the host's date cannot move it.
@MainActor
final class TestWallClock {
    private let origin = ContinuousClock.now
    private let epoch: Date

    init(epoch: Date = Date(timeIntervalSince1970: 0)) { self.epoch = epoch }

    func now() -> Date {
        let elapsed = origin.duration(to: .now).components
        return epoch.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
}

private final class TestBundleLocation: NSObject {}

/// XCTest may choose its own system temporary directory despite TMPDIR. Keep
/// synthetic fixture evidence beside this invocation's build products instead.
enum TestFixtureDirectory {
    static let root: URL = {
        var directory = Bundle(for: TestBundleLocation.self).bundleURL
        while directory.path != "/" {
            let parent = directory.deletingLastPathComponent()
            if directory.lastPathComponent == "Products", parent.lastPathComponent == "Build" {
                let root = parent.deletingLastPathComponent().appendingPathComponent("tmp", isDirectory: true)
                do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
                catch { preconditionFailure("Cannot create the test fixture directory") }
                return root
            }
            directory = parent
        }
        return FileManager.default.temporaryDirectory
    }()
}

/// Preferences stay in memory, including reopening a suite and inspecting its
/// persistent domain. Neither reads nor teardown touch the user's preferences.
class TestUserDefaults: UserDefaults, @unchecked Sendable {
    private final class Domain: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var values: [String: Any] = [:]
        var volatile: [String: [String: Any]] = [:]
        var registered: [String: Any] = [:]
    }
    private final class Suites: @unchecked Sendable {
        let lock = NSLock()
        var domains: [String: Domain] = [:]
    }
    private static let suites = Suites()
    private let suite: String
    private let domain: Domain

    override init?(suiteName: String?) {
        guard let suiteName else { return nil }
        suite = suiteName
        domain = Self.suites.lock.withLock {
            if let existing = Self.suites.domains[suiteName] { return existing }
            let created = Domain()
            Self.suites.domains[suiteName] = created
            return created
        }
        super.init(suiteName: suiteName)
    }

    override func object(forKey key: String) -> Any? {
        domain.lock.withLock {
            domain.volatile[UserDefaults.argumentDomain]?[key]
                ?? domain.volatile[suite]?[key]
                ?? domain.values[key]
                ?? domain.registered[key]
        }
    }
    override func string(forKey key: String) -> String? {
        let value = object(forKey: key)
        return value as? String ?? (value as? NSNumber)?.stringValue
    }
    override func bool(forKey key: String) -> Bool {
        let value = object(forKey: key)
        return (value as? NSNumber)?.boolValue ?? (value as? NSString)?.boolValue ?? false
    }
    override func integer(forKey key: String) -> Int {
        let value = object(forKey: key)
        return (value as? NSNumber)?.intValue ?? (value as? NSString)?.integerValue ?? 0
    }
    override func double(forKey key: String) -> Double {
        let value = object(forKey: key)
        return (value as? NSNumber)?.doubleValue ?? (value as? NSString)?.doubleValue ?? 0
    }
    override func float(forKey key: String) -> Float { Float(double(forKey: key)) }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func url(forKey key: String) -> URL? {
        let value = object(forKey: key)
        return value as? URL ?? (value as? String).flatMap(URL.init(string:))
    }

    override func set(_ value: Any?, forKey key: String) {
        willChangeValue(forKey: key)
        domain.lock.withLock { domain.values[key] = value }
        didChangeValue(forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }
    override func set(_ value: Bool, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Int, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Float, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: URL?, forKey key: String) { set(value as Any?, forKey: key) }
    override func removeObject(forKey key: String) { set(nil as Any?, forKey: key) }
    override func register(defaults: [String: Any]) {
        domain.lock.withLock { domain.registered.merge(defaults) { _, new in new } }
    }
    override func persistentDomain(forName name: String) -> [String: Any]? {
        guard name == suite else { return nil }
        return domain.lock.withLock { domain.values.isEmpty ? nil : domain.values }
    }
    override func setPersistentDomain(_ values: [String: Any], forName name: String) {
        precondition(name == suite)
        domain.lock.withLock { domain.values = values }
    }
    override func removePersistentDomain(forName name: String) {
        precondition(name == suite)
        domain.lock.withLock { domain.values = [:] }
    }
    override func volatileDomain(forName name: String) -> [String: Any] {
        domain.lock.withLock { domain.volatile[name] ?? [:] }
    }
    override func setVolatileDomain(_ values: [String: Any], forName name: String) {
        domain.lock.withLock { domain.volatile[name] = values }
    }
    override func removeVolatileDomain(forName name: String) {
        domain.lock.withLock { domain.volatile[name] = nil }
    }
    override func synchronize() -> Bool { true }
    override func dictionaryRepresentation() -> [String: Any] {
        domain.lock.withLock {
            var values = domain.registered
            values.merge(domain.values) { _, new in new }
            values.merge(domain.volatile[suite] ?? [:]) { _, new in new }
            values.merge(domain.volatile[UserDefaults.argumentDomain] ?? [:]) { _, new in new }
            return values
        }
    }
    fileprivate static func release(suite: String) {
        suites.lock.withLock { _ = suites.domains.removeValue(forKey: suite) }
    }
}

/// Existing fixture registrations now release only their synthetic suite.
struct TestPreferenceCleanup: Sendable {
    private let suite: String

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
              UUID(uuidString: String(suite.dropFirst(prefix.count))) != nil else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        self.suite = suite
        print("TEST_PREFERENCE_CREATED suite=\(suite) storage=memory")
    }

    func remove(_ defaults: UserDefaults) throws {
        guard defaults is TestUserDefaults else { throw CocoaError(.fileWriteInvalidFileName) }
        defaults.removePersistentDomain(forName: suite)
        try remove()
    }

    func remove() throws {
        TestUserDefaults.release(suite: suite)
        print("TEST_PREFERENCE_CLEANED suite=\(suite) storage=memory")
    }
}
