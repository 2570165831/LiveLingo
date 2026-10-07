import Foundation

/// Uses the production whitelist with a replacement entry point. No AppModel,
/// model, service, real session or runtime configuration is started.
@main struct CLITranslationFailureTests {
    struct Failure: Error { let check: String }
    static func expect(_ value: Bool, _ check: String) throws {
        if !value { throw Failure(check: check) }
    }

    static func main() throws {
        typealias Reason = TranscriptSegment.TranslationFailureReason
        for reason in Reason.allCases {
            let fields: [String: Any] = ["translationFailureReason": reason.rawValue, "translationFailureCount": 3,
                "message": "PRIVATE_ERROR_TEXT", "text": "PRIVATE_SOURCE_TEXT", "path": "/PRIVATE_PATH",
                "segments": 8, "sessionID": UUID().uuidString, "summaryRunning": true]
            let event = LiveLingoCLI.safeEvent("translation_failure", fields: fields, elapsed: 0.5)
            try expect(Set(event.keys) == ["event", "translationFailureReason", "translationFailureCount"], "failure_keys")
            try expect(event["event"] as? String == "translation_failure", "event_enum")
            try expect(event["translationFailureReason"] as? String == reason.rawValue, "reason_enum")
            try expect(type(of: event["translationFailureCount"]!) == Int.self, "integer_count")
            let bytes = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            try expect(!String(decoding: bytes, as: UTF8.self).contains("PRIVATE"), "no_private_text")
        }
        for count in [true, false, -1, 0, 1.0, "1", NSNumber(value: 1), [1]] as [Any] {
            let event = LiveLingoCLI.safeEvent("translation_failure", fields:
                ["translationFailureReason": "processExited", "translationFailureCount": count], elapsed: 0)
            try expect(event.count == 1, "reject_non_integer_or_non_positive_count")
        }
        for reason in ["PRIVATE_ERROR_TEXT", "futureReason", 1, true, ["processExited"]] as [Any] {
            let event = LiveLingoCLI.safeEvent("translation_failure", fields:
                ["translationFailureReason": reason, "translationFailureCount": 1], elapsed: 0)
            try expect(event.count == 1, "reject_non_enum_reason")
        }
        let normal = LiveLingoCLI.safeEvent("state", fields: ["segments": 1, "translated": 1, "summarized": 0,
            "otherLanguageTranscription": 0, "translationFailureReason": "processExited", "translationFailureCount": 2], elapsed: 1.25)
        let normalBytes = try JSONSerialization.data(withJSONObject: normal, options: [.sortedKeys])
        try expect(String(decoding: normalBytes, as: UTF8.self) ==
            #"{"elapsedSeconds":1.25,"event":"state","otherLanguageTranscription":0,"segments":1,"summarized":0,"translated":1}"#,
            "normal_english_event_bytes")
        LiveLingoCLI.writeEvent(["event": "translation_failure_cli_tests_passed", "groups": 4])
    }
}
