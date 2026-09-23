import Foundation
import AppKit
import AVFoundation
import CryptoKit
import Darwin
#if !LIVELINGO_CLI_LIFECYCLE_TESTS
@main
#endif
struct LiveLingoCLI {
 @MainActor static func main() async {
  signal(SIGPIPE, SIG_IGN)
  let operation = Task { @MainActor in try await run() }
  let receivedSignal = SignalState()
  let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
   signal(number, SIG_IGN)
   let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
   source.setEventHandler { receivedSignal.record(number); operation.cancel() }
   source.resume()
   return source
  }
  var exitCode: Int32 = 0
  do {
   try await operation.value
  } catch {
   exitCode = receivedSignal.value.map { 128 + $0 } ?? 1
   writeEvent(safeFailure(error), to: .standardError)
  }
  // Cleanup is outside the cancelled operation. Only exact owned children are
  // touched; an unconfirmed release is a failed run, never a success receipt.
  if !(await cleanupOwnedRuntimes()) {
   writeEvent(safeFailure(CLIError.cleanupIncomplete), to: .standardError)
   if exitCode == 0 { exitCode = 1 }
  }
  if exitCode == 0, let number = receivedSignal.value { exitCode = 128 + number }
  for source in signals { source.cancel() }
  Darwin.exit(exitCode)
 }

 // MARK: - Command line

 static let usage = "Usage: livelingo-cli (--replay AUDIO | --system-audio SECONDS) --output NEW_DIRECTORY [--high-quality] [--import] [--export-notes] [--run-review]\n       livelingo-cli --translate-text TEXT [--high-quality] [--output NEW_DIRECTORY]\n       livelingo-cli --verify-saved DIRECTORY\n       livelingo-cli --open-saved DIRECTORY\n       livelingo-cli --resume-saved DIRECTORY [--high-quality] [--export-notes] [--run-review]\nReplay injects PCM without playing sound. --import uses the app's file-import path. Audio requires ASRRuntime/ and Models/ beside this executable or inside its isolated bundle. External ASR endpoints are rejected. MLX paths use LIVELINGO_MLX_PYTHON/WORKER/MODELS. Each generating run creates independent preferences, data and checkpoints; failures retain state. Only --translate-text prints translated content. --verify-saved is a read-only export-integrity check (it does NOT prove a complete run, and it accepts valid audio with zero captions). --open-saved reopens a course this CLI itself isolated and bound; it never records, never resumes generation and reports identity, revision, batches, source and pause state. --resume-saved performs the same bound reopen and then explicitly continues the saved translation/notes work; it refuses courses whose bound session, revision, captions or batches do not match the recorded identity."

 struct GenerateCommand: Equatable, Sendable {
  enum Source: Equatable, Sendable { case replay(String), systemAudio(Double) }
  var source: Source
  var output: String
  var highQuality: Bool
  var fileImport: Bool
  var exportNotes: Bool
  var runReview: Bool
 }

 enum Command: Equatable, Sendable {
  case help
  case verifySaved(String)
  case translateText(text: String, highQuality: Bool, output: String?)
  case generate(GenerateCommand)
  case openSaved(String)
  case resumeSaved(path: String, highQuality: Bool, exportNotes: Bool, runReview: Bool)
 }

 /// Pure syntax parse. It never touches the filesystem, so ambiguity rules can
 /// be tested without creating anything. Runtime path checks happen in run().
 static func parse(_ arguments: [String]) throws -> Command {
  if arguments.isEmpty || arguments.contains("--help") { return .help }
  let valueOptions: Set<String> = ["--replay", "--system-audio", "--output", "--translate-text",
                                   "--verify-saved", "--open-saved", "--resume-saved"]
  let switches: Set<String> = ["--high-quality", "--import", "--export-notes", "--run-review"]
  var values: [String: String] = [:]
  var index = 0
  while index < arguments.count {
   let token = arguments[index]
   if valueOptions.contains(token) {
    guard values[token] == nil, index + 1 < arguments.count,
          !arguments[index + 1].isEmpty, !arguments[index + 1].hasPrefix("--") else {
     throw CLIError.invalidArguments
    }
    values[token] = arguments[index + 1]
    index += 2
   } else if switches.contains(token) {
    guard values[token] == nil else { throw CLIError.invalidArguments }
    values[token] = "true"
    index += 1
   } else {
    throw CLIError.invalidArguments
   }
  }
  func flag(_ name: String) -> Bool { values[name] != nil }
  let modes = ["--replay", "--system-audio", "--translate-text", "--verify-saved",
               "--open-saved", "--resume-saved"].filter { values[$0] != nil }
  guard modes.count == 1, let mode = modes.first else { throw CLIError.invalidArguments }
  if mode == "--verify-saved" || mode == "--open-saved" {
   // Read-only and reopen-only modes take no other option: mixing them with
   // generation flags is ambiguous and must be rejected before any path is
   // touched. Explicit processing requires --resume-saved.
   guard values.count == 1 else { throw CLIError.invalidArguments }
   return mode == "--verify-saved" ? .verifySaved(values[mode]!) : .openSaved(values[mode]!)
  }
  if mode == "--resume-saved" {
   guard !flag("--output"), !flag("--import") else { throw CLIError.invalidArguments }
   return .resumeSaved(path: values[mode]!, highQuality: flag("--high-quality"),
                       exportNotes: flag("--export-notes"), runReview: flag("--run-review"))
  }
  if mode == "--translate-text" {
   guard !flag("--import"), !flag("--export-notes"), !flag("--run-review") else { throw CLIError.invalidArguments }
   return .translateText(text: values[mode]!, highQuality: flag("--high-quality"), output: values["--output"])
  }
  guard let output = values["--output"] else { throw CLIError.invalidArguments }
  guard !flag("--import") || mode == "--replay" else { throw CLIError.invalidArguments }
  let source: GenerateCommand.Source
  if mode == "--replay" {
   source = .replay(values[mode]!)
  } else {
   guard let seconds = Double(values[mode]!), seconds.isFinite, seconds > 0, seconds <= 3_600 else {
    throw CLIError.invalidArguments
   }
   source = .systemAudio(seconds)
  }
  return .generate(GenerateCommand(source: source, output: output, highQuality: flag("--high-quality"),
                                   fileImport: flag("--import"), exportNotes: flag("--export-notes"),
                                   runReview: flag("--run-review")))
 }

 @MainActor static func run() async throws {
  switch try parse(Array(CommandLine.arguments.dropFirst())) {
  case .help:
   print(usage)
  case .verifySaved(let path):
   try verifySaved(URL(fileURLWithPath: path, isDirectory: true))
  case .translateText(let text, let highQuality, let output):
   try await runTranslateText(text: text, highQuality: highQuality, output: output)
  case .generate(let command):
   try await runGenerate(command)
  case .openSaved(let path):
   try await runReopen(directory: URL(fileURLWithPath: path, isDirectory: true), resume: false,
                       highQuality: false, exportNotes: false, runReview: false)
  case .resumeSaved(let path, let highQuality, let exportNotes, let runReview):
   try await runReopen(directory: URL(fileURLWithPath: path, isDirectory: true), resume: true,
                       highQuality: highQuality, exportNotes: exportNotes, runReview: runReview)
  }
 }

 @MainActor static func runTranslateText(text: String, highQuality: Bool, output: String?) async throws {
  let directory = output.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
  _ = try configureIsolation(output: directory)
  let model = highQuality ? QwenModelProfile.highQuality.translationModel
                          : QwenModelProfile.energySaver.translationModel
  print("model=\(model)")
  for (index, sentence) in text.components(separatedBy: "||").enumerated() {
   let translated = try await QwenTranslationClient.translate(sentence, modelName: model)
   print("OUTPUT[\(index)]=\(translated)")
  }
 }

 @MainActor static func runGenerate(_ command: GenerateCommand) async throws {
  let directory = URL(fileURLWithPath: command.output, isDirectory: true).standardizedFileURL
  guard !FileManager.default.fileExists(atPath: directory.path) else { throw CLIError.outputExists }
  var source: CLIRunSource
  var file: URL?
  var seconds = 0.0
  switch command.source {
  case .replay(let path):
   let url = URL(fileURLWithPath: path).standardizedFileURL
   guard FileManager.default.isReadableFile(atPath: url.path) else { throw CLIError.invalidArguments }
   file = url
   source = CLIRunSource(kind: command.fileImport ? "file-import" : "silent-pcm-replay",
                         file: url.path, sha256: nil, bytes: nil, frames: nil, sampleRate: nil, seconds: nil)
   if let digest = try? hashFile(url) { source.sha256 = digest.sha256; source.bytes = Int(digest.bytes) }
   if let audio = try? AVAudioFile(forReading: url) {
    source.frames = Int(audio.length)
    source.sampleRate = try? audio.processingFormat.sampleRate
    if let rate = source.sampleRate, rate > 0 { source.seconds = Double(audio.length) / rate }
   }
  case .systemAudio(let value):
   seconds = value
   source = CLIRunSource(kind: "system-audio", file: nil, sha256: nil, bytes: nil, frames: nil,
                         sampleRate: nil, seconds: value)
  }
  _ = try configureIsolation(output: directory, source: source)
  try Task.checkCancellation()
  let endpoint = try await ASRRuntime.shared.endpoint()
  guard let runtimeID = endpoint.runtimeID, let pid = endpoint.processIdentifier, pid > 0,
        endpoint.baseURL.host == "127.0.0.1", let port = endpoint.baseURL.port,
        port > 0, port != 18765, !endpoint.token.isEmpty else { throw CLIError.unownedASR }
  writeEvent(["event": "asr_owned", "runtimeID": runtimeID.uuidString, "pid": Int(pid)])
  let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("review-queue.json"), observeSleep: false)
  let model = AppModel(reviewQueue: queue)
  let start = ProcessInfo.processInfo.systemUptime
  do {
   try await model.cliRun(file: file, seconds: seconds, directory: directory,
                          highQuality: command.highQuality, paced: !command.fileImport,
                          exportNotes: command.exportNotes, runReview: command.runReview) { event, fields in
    writeEvent(safeEvent(event, fields: fields, elapsed: ProcessInfo.processInfo.systemUptime - start))
   }
  } catch {
   await queue.pauseAndWait()
   // Interrupted generation must still be recoverable: bind the durable state
   // that actually reached the disk before this run stopped.
   if let bound = try? bindSession(directory: directory, source: source) {
    writeEvent(["event": "session_bound", "sessionID": bound.sessionID, "recovered": true,
                "revision": bound.inputRevision, "segments": bound.segmentIDs.count])
   } else {
    writeEvent(["event": "session_binding", "bound": false, "reason": "no_durable_snapshot"])
   }
   throw error
  }
  await queue.pauseAndWait()
  let segmentCount = try verifySaved(directory)
  let snapshot = try SessionStore(directory: directory).load()
  try verifyProcessing(state: model.transcriptionProcessing, snapshot: snapshot, segmentCount: segmentCount)
  let bound = try bindSession(directory: directory, source: source)
  guard bound.segmentIDs.count == segmentCount, bound.sessionID == snapshot?.sessionID.uuidString else {
   throw CLIError.inconsistentExport
  }
  writeEvent(["event": "session_bound", "sessionID": bound.sessionID, "revision": bound.inputRevision,
              "segments": bound.segmentIDs.count, "batches": bound.batchIDs.count])
  writeEvent(["event": "run_verified", "segments": segmentCount,
              "pendingTranscription": 0, "unresolvedTranscription": 0])
 }

 /// Reopen a course this CLI created and bound. `resume` additionally continues
 /// the saved translation/notes work. Neither mode ever starts capture.
 @MainActor static func runReopen(directory: URL, resume: Bool, highQuality: Bool, exportNotes: Bool,
                                  runReview: Bool) async throws {
  let root = directory.standardizedFileURL
  try validateReopenTarget(root)
  let marker = try readMarker(root)
  guard let bound = marker.session else { throw CLIError.sessionUnbound }
  try applyMarkerIsolation(marker, directory: root)
  let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("review-queue.json"), observeSleep: false)
  let model = AppModel(reviewQueue: queue)
  let start = ProcessInfo.processInfo.systemUptime
  let observed: CLIObservedSession
  do {
   observed = try await model.cliOpenSaved(directory: root, resume: resume, highQuality: highQuality,
                                           exportNotes: exportNotes, runReview: runReview) { event, fields in
    writeEvent(safeEvent(event, fields: fields, elapsed: ProcessInfo.processInfo.systemUptime - start))
   }
  } catch {
   await queue.pauseAndWait()
   throw error
  }
  await queue.pauseAndWait()
  var verified = observed
  verified.exports = try fingerprintExports(observed.exportPaths)
  // Internal, opt-in diagnostics: counts and digests only, never classroom text.
  if ProcessInfo.processInfo.environment["LIVELINGO_CLI_DEBUG_VERIFY"] == "1" {
   let observedIDs = Set(verified.snapshot.segments.map { $0.id.uuidString })
   writeEvent(["event": "verify_debug",
               "observedSession": verified.sessionID.uuidString, "boundSession": bound.sessionID,
               "snapshotSession": verified.snapshot.sessionID.uuidString,
               "sessionMatch": verified.sessionID.uuidString == bound.sessionID,
               "snapshotMatch": verified.snapshot.sessionID == verified.sessionID,
               "revision": verified.snapshot.inputRevision, "boundRevision": bound.inputRevision,
               "boundSegments": bound.segmentIDs.count, "observedSegments": verified.snapshot.segments.count,
               "subset": Set(bound.segmentIDs).isSubset(of: observedIDs),
               "captionMatch": fingerprint(from: verified.snapshot.segments, batches: []).captions == bound.captionDigest,
               "boundCaptions": bound.captionDigest, "observedCaptions": fingerprint(from: verified.snapshot.segments, batches: []).captions,
               "boundIDs": bound.segmentIDs.sorted().joined(separator: ","), "observedIDs": observedIDs.sorted().joined(separator: ",")])
  }
  // Read-only export integrity is its own receipt. A completed resume must have
  // produced it; a paused course that never exported is allowed to lack it.
  let readback = try exportReadback(root)
  if resume { try verifyResumed(marker: marker, observed: verified, bound: bound) }
  else { try verifyReopened(marker: marker, observed: verified, bound: bound) }
  if resume, readback == nil { throw CLIError.exportIncomplete }
  if runReview {
   guard let report = try ReviewExportSource.markdown(for: root, queue: queue), !report.isEmpty else {
    throw CLIError.reviewIncomplete
   }
   writeEvent(["event": "review_verified", "bytes": report.utf8.count])
  }
  let rebound = try bindSession(directory: root, source: marker.source)
  writeEvent(["event": "reopen_verified", "mode": resume ? "resume-saved" : "open-saved",
              "sessionID": verified.sessionID.uuidString, "revision": verified.snapshot.inputRevision,
              "segments": verified.snapshot.segments.count, "batches": verified.snapshot.batches.count,
              "translated": verified.translatedCount, "summarized": verified.summarizedCount,
              "capture": verified.captureActive, "paused": verified.processingPaused,
              "exports": verified.exports.map(\.name).sorted(), "reboundRevision": rebound.inputRevision])
 }

 /// Export integrity only; it never proves a whole run. Zero valid captions pass
 /// this check, so a caller must not treat exit 0 here as end-to-end success.
 @discardableResult static func verifySaved(_ directory: URL, emit: Bool = true) throws -> Int {
  let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
  let manifest=try decoder.decode(SessionExporter.Manifest.self,from:Data(contentsOf:directory.appendingPathComponent("manifest.json")))
  guard manifest.recordingFile == "recording.wav" else { throw CLIError.inconsistentExport }
  let jsonl=try String(contentsOf:directory.appendingPathComponent("bilingual.jsonl"),encoding:.utf8)
  let segments=try jsonl.split(separator:"\n").map { try decoder.decode(TranscriptSegment.self,from:Data($0.utf8)) }
  guard segments.count == manifest.segmentCount, Set(segments.map(\.id)).count == segments.count else { throw CLIError.inconsistentExport }
  let english=try String(contentsOf:directory.appendingPathComponent("transcript-en.txt"),encoding:.utf8)
  let chinese=try String(contentsOf:directory.appendingPathComponent("transcript-zh-Hans.txt"),encoding:.utf8)
  guard english == segments.map(\.english).joined(separator:"\n")+"\n",
        // Keep this aligned with the production exporter, including legacy
        // missing-translation placeholders. It does not prove translation quality.
        chinese == segments.map({ SessionExporter.humanReadableChinese($0.chinese) }).joined(separator:"\n")+"\n" else { throw CLIError.inconsistentExport }
  let expectedSRT = segments.enumerated().map { index, segment in
   "\(index + 1)\n\(SessionExporter.srtTimestamp(segment.startTime)) --> \(SessionExporter.srtTimestamp(segment.endTime))\n\(segment.english)\n\(SessionExporter.humanReadableChinese(segment.chinese))"
  }.joined(separator: "\n\n") + "\n"
  guard try String(contentsOf: directory.appendingPathComponent("bilingual.srt"), encoding: .utf8) == expectedSRT else { throw CLIError.inconsistentExport }
  let audio=try AVAudioFile(forReading:directory.appendingPathComponent(manifest.recordingFile))
  guard audio.length>0, audio.processingFormat.sampleRate>0 else { throw CLIError.inconsistentExport }
  var names=["manifest.json","bilingual.jsonl","bilingual.srt","transcript-en.txt","transcript-zh-Hans.txt","recording.wav"]
  if FileManager.default.fileExists(atPath:directory.appendingPathComponent("summary-zh-Hans.md").path) { names.append("summary-zh-Hans.md") }
  let files=try names.map { name -> [String:Any] in
   let digest = try hashFile(directory.appendingPathComponent(name))
   guard digest.bytes > 0 else { throw CLIError.inconsistentExport }
   return ["name":name,"bytes":digest.bytes,"sha256":digest.sha256]
  }
  let receipt:[String:Any]=["event":"saved_verified", "scope": "export_integrity",
    "wholeRunVerified": false,
    "segments":segments.count,
    "captionState": segments.isEmpty ? "no_captions" : "present",
    "missingTranslations": segments.filter { !$0.hasUsableTranslation }.count,
    "audioSeconds":Double(audio.length)/audio.processingFormat.sampleRate,"files":files]
  if emit { writeEvent(receipt) }
  return segments.count
 }

 static func verifyProcessing(state: TranscriptionProcessingState?, snapshot: SessionSnapshot?, segmentCount: Int) throws {
  guard let state, let snapshot, state.sessionID == snapshot.sessionID,
        !state.isCapturing, state.activeCount == 0, state.pendingCount == 0, state.unresolvedCount == 0,
        snapshot.segments.count == segmentCount,
        snapshot.processing.pendingSegmentIDs.isEmpty,
        snapshot.processing.pendingBatchIDs.isEmpty,
        snapshot.processing.lastError == nil, snapshot.processing.captureError == nil else {
   throw CLIError.processingIncomplete
  }
  guard segmentCount > 0 else { throw CLIError.noCaptions }
 }

 // MARK: - Isolation marker (.cli-runtime/run.json)

 struct CLIRunSource: Codable, Equatable, Sendable {
  var kind: String
  var file: String?
  var sha256: String?
  var bytes: Int?
  var frames: Int?
  var sampleRate: Double?
  var seconds: Double?
  static let pending = CLIRunSource(kind: "pending", file: nil, sha256: nil, bytes: nil,
                                    frames: nil, sampleRate: nil, seconds: nil)
 }

 /// Durable identity of the exact saved state this isolated directory held when
 /// the CLI last wrote it. A later reopen must find every listed item retained;
 /// missing or rewritten content is an identity failure, never a fresh start.
 struct CLIRunSession: Codable, Equatable, Sendable {
  var sessionID: String
  var inputRevision: Int
  var segmentIDs: [String]
  var captionDigest: String
  var completedIDs: [String]
  var completedDigest: String
  var batchIDs: [String]
  var batchDigest: String
  var latestEvidenceIDs: [String]
  var audioFrames: Int
  var audioSampleRate: Double
  var journalIncompleteTailBytes: Int
  var boundAt: String
 }

 struct CLIRunMarker: Codable, Equatable, Sendable {
  static let currentVersion = 2
  static let maximumBoundSegments = 20_000
  var version: Int
  var runID: String
  var directory: String
  var preferencesSuite: String
  var data: String
  var checkpoints: String
  var createdAt: String
  var source: CLIRunSource
  var session: CLIRunSession?
  var checksum: String

  func checksummed() throws -> CLIRunMarker {
   var copy = self; copy.checksum = ""
   let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
   return CLIRunMarker(version: copy.version, runID: copy.runID, directory: copy.directory,
                       preferencesSuite: copy.preferencesSuite, data: copy.data,
                       checkpoints: copy.checkpoints, createdAt: copy.createdAt, source: copy.source,
                       session: copy.session, checksum: try LiveLingoCLI.digestData(encoder.encode(copy)))
  }
 }

 static func digestData(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
 }

 static func digestLines(_ lines: [String]) -> String {
  var hash = SHA256()
  for line in lines { hash.update(data: Data((line + "\n").utf8)) }
  return hash.finalize().map { String(format: "%02x", $0) }.joined()
 }

 static func markerURL(_ directory: URL) -> URL {
  directory.appendingPathComponent(".cli-runtime/run.json")
 }

 static func newMarker(directory: URL, runID: UUID, source: CLIRunSource) throws -> CLIRunMarker {
  let marker = CLIRunMarker(version: CLIRunMarker.currentVersion, runID: runID.uuidString,
                            directory: directory.standardizedFileURL.resolvingSymlinksInPath().path,
                            preferencesSuite: "com.jianhongli.LiveLingo.CLI." + runID.uuidString,
                            data: ".cli-runtime/data", checkpoints: ".cli-runtime/checkpoints",
                            createdAt: ISO8601DateFormatter().string(from: Date()), source: source,
                            session: nil, checksum: "")
  return try marker.checksummed()
 }

 static func writeMarker(_ marker: CLIRunMarker, directory: URL) throws {
  let url = markerURL(directory)
  let confirmed = try marker.checksummed()
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
  try encoder.encode(confirmed).write(to: url, options: .atomic)
 }

 /// Decode and authenticate the marker. The checksum covers every field except
 /// itself, so a hand-copied directory or edited identity is rejected.
 static func readMarker(_ directory: URL) throws -> CLIRunMarker {
  let root = directory.standardizedFileURL.resolvingSymlinksInPath()
  let url = markerURL(root)
  guard FileManager.default.fileExists(atPath: url.path) else { throw CLIError.markerMissing }
  guard let data = try? Data(contentsOf: url),
        let marker = try? JSONDecoder().decode(CLIRunMarker.self, from: data) else {
   // Distinguish the pre-binding receipt shape written by earlier builds.
   if let text = try? String(contentsOf: url, encoding: .utf8), text.contains("\"runID\"") {
    throw CLIError.legacyMarkerUnsupported
   }
   throw CLIError.markerInvalid
  }
  guard marker.version == CLIRunMarker.currentVersion else { throw CLIError.legacyMarkerUnsupported }
  guard (try? marker.checksummed().checksum) == marker.checksum, !marker.checksum.isEmpty else {
   throw CLIError.markerInvalid
  }
  guard marker.directory == root.path else { throw CLIError.markerInvalid }
  guard marker.preferencesSuite == "com.jianhongli.LiveLingo.CLI." + marker.runID,
        marker.data == ".cli-runtime/data", marker.checkpoints == ".cli-runtime/checkpoints",
        UUID(uuidString: marker.runID) != nil else { throw CLIError.markerInvalid }
  return marker
 }

 /// Reuse the original isolated preferences/data/checkpoints. A missing folder is
 /// a refusal: recreating it silently would start a new task from scratch.
 static func applyMarkerIsolation(_ marker: CLIRunMarker, directory: URL) throws {
  let root = directory.standardizedFileURL.resolvingSymlinksInPath()
  guard marker.directory == root.path else { throw CLIError.markerInvalid }
  let suite = "com.jianhongli.LiveLingo.CLI." + marker.runID
  guard marker.preferencesSuite == suite else { throw CLIError.markerInvalid }
  let data = root.appendingPathComponent(marker.data, isDirectory: true)
  let checkpoints = root.appendingPathComponent(marker.checkpoints, isDirectory: true)
  for folder in [data, checkpoints] {
   var isDirectory: ObjCBool = false
   guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
         isDirectory.boolValue else { throw CLIError.isolationMissing }
  }
  for (key, value) in [("LIVELINGO_PREFERENCES_SUITE", suite),
                       ("LIVELINGO_DATA_DIRECTORY", data.path),
                       ("LIVELINGO_MLX_STATE", checkpoints.path)] {
   guard setenv(key, value, 1) == 0 else { throw CLIError.isolationFailed }
  }
  writeEvent(["event": "isolation_restored", "runID": marker.runID])
 }

 /// Only this CLI's own isolated directories may be reopened. Real user data,
 /// installed apps, system locations and bundle contents are refused outright.
 static func validateReopenTarget(_ directory: URL) throws {
  let root = directory.standardizedFileURL.resolvingSymlinksInPath()
  let path = root.path
  guard root.isFileURL, path != "/" else { throw CLIError.reopenTargetForbidden }
  if (try? FileManager.default.destinationOfSymbolicLink(atPath: directory.standardizedFileURL.path)) != nil {
   throw CLIError.reopenTargetForbidden
  }
  let forbidden = ["/Applications", "/System", "/Library", "/usr", "/bin", "/sbin", "/opt", "/cores",
                   "/dev", "/Volumes", "/private/var/db"]
  for base in forbidden where path == base || path.hasPrefix(base + "/") {
   throw CLIError.reopenTargetForbidden
  }
  let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
  for userRoot in ["Library/Application Support/LiveLingo", "Library/Containers", "Library/Preferences"] {
   let base = home.appendingPathComponent(userRoot).path
   if path == base || path.hasPrefix(base + "/") { throw CLIError.reopenTargetForbidden }
  }
  if path == home.path { throw CLIError.reopenTargetForbidden }
  if root.pathComponents.contains(where: { $0.hasSuffix(".app") }) { throw CLIError.installedAppForbidden }
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
   throw CLIError.markerMissing
  }
 }

 static func fingerprint(from segments: [TranscriptSegment], batches: [LearningNoteBatch]) -> (ids: [String], captions: String, completed: [String], completedDigest: String, batchIDs: [String], batchDigest: String) {
  let ordered = segments.sorted { $0.id.uuidString < $1.id.uuidString }
  let captionLines = ordered.map { segment in
   "\(segment.id.uuidString)|\(segment.english)|\(segment.inputRevision)|\(time(segment.startTime))|\(time(segment.endTime))"
  }
  let completed = ordered.filter { $0.hasUsableTranslation }
  let completedLines = completed.map { "\($0.id.uuidString)|\($0.chinese)" }
  let batchLines = batches.map { batch in
   "\(batch.id.uuidString)|\(batch.evidence.map(\.id.uuidString).sorted().joined(separator: ","))|\(batch.note.markdown)"
  }
  return (ordered.map { $0.id.uuidString }, digestLines(captionLines),
          completed.map { $0.id.uuidString }, digestLines(completedLines),
          batches.map { $0.id.uuidString }.sorted(), digestLines(batchLines))
 }

 static func time(_ value: TimeInterval) -> String { String(format: "%.6f", value) }

 /// Bind the durable session plus the exact CLI source that produced it.
 @discardableResult
 static func bindSession(directory: URL, source: CLIRunSource) throws -> CLIRunSession {
  let root = directory.standardizedFileURL.resolvingSymlinksInPath()
  let marker = try readMarker(root)
  let loaded = try SessionStore(directory: root).loadDetailed()
  guard let snapshot = loaded.snapshot else { throw CLIError.sessionUnbound }
  guard loaded.incompleteTailBytes >= 0 else { throw CLIError.sessionUnbound }
  let recording = root.appendingPathComponent(SessionWorkspace.recordingFileName)
  var frames = 0
  var rate = 0.0
  if FileManager.default.fileExists(atPath: recording.path) {
   let audio = try AVAudioFile(forReading: recording)
   frames = Int(audio.length)
   rate = audio.processingFormat.sampleRate
  }
  let facts = fingerprint(from: snapshot.segments, batches: snapshot.batches)
  guard facts.ids.count <= CLIRunMarker.maximumBoundSegments else { throw CLIError.sessionUnbound }
  let bound = CLIRunSession(sessionID: snapshot.sessionID.uuidString, inputRevision: snapshot.inputRevision,
                            segmentIDs: facts.ids, captionDigest: facts.captions,
                            completedIDs: facts.completed, completedDigest: facts.completedDigest,
                            batchIDs: facts.batchIDs, batchDigest: facts.batchDigest,
                            latestEvidenceIDs: snapshot.latestEvidenceIDs.map(\.uuidString).sorted(),
                            audioFrames: frames, audioSampleRate: rate,
                            journalIncompleteTailBytes: loaded.incompleteTailBytes,
                            boundAt: ISO8601DateFormatter().string(from: Date()))
  var updated = marker
  updated.source = source
  updated.session = bound
  try writeMarker(updated, directory: root)
  return bound
 }

 // MARK: - Observed state and verification

 struct CLIExportFingerprint: Equatable, Sendable {
  var name: String
  var bytes: Int
  var sha256: String
  var fileExtension: String
  var signature: String
 }

 /// Facts gathered by the production model after an explicit reopen/resume. The
 /// CLI verifies them; the model never decides its own PASS.
 struct CLIObservedSession {
  var sessionID: UUID
  var snapshot: SessionSnapshot
  var notes: String
  var processingPaused: Bool
  var captureActive: Bool
  var transcription: TranscriptionProcessingState?
  var candidates: Int
  var reviewHasWork: Bool
  var reviewRunning: Bool
  var reviewFailure: String?
  var summarizedCount: Int
  var translatedCount: Int
  var pendingWorkers: Int
  var archiveErrorPresent: Bool
  var journalIncompleteTailBytes: Int
  var exportPaths: [String]
  var exports: [CLIExportFingerprint] = []
  var audioFrames: Int
  var audioSampleRate: Double
 }

 static func retained(_ recorded: [String], in observed: Set<String>) -> [String] {
  recorded.filter { observed.contains($0) }
 }

 /// Identity, revision, source and content retention. Growth is allowed (an
 /// explicit resume may finish more work); loss or rewriting is never allowed.
 static func verifyRetention(bound: CLIRunSession, observed: CLIObservedSession) throws {
  guard observed.sessionID.uuidString == bound.sessionID,
        observed.snapshot.sessionID == observed.sessionID else { throw CLIError.sessionIdentityMismatch }
  guard observed.snapshot.inputRevision >= bound.inputRevision else { throw CLIError.sessionIdentityMismatch }
  let segmentIDs = Set(observed.snapshot.segments.map { $0.id.uuidString })
  guard Set(bound.segmentIDs).isSubset(of: segmentIDs), !bound.segmentIDs.isEmpty else {
   throw CLIError.sessionIdentityMismatch
  }
  let retainedIDs = Set(retained(bound.segmentIDs, in: segmentIDs))
  let facts = fingerprint(from: observed.snapshot.segments.filter { retainedIDs.contains($0.id.uuidString) },
                          batches: [])
  guard facts.captions == bound.captionDigest, facts.ids.count == bound.segmentIDs.count else {
   throw CLIError.captionRetentionFailed
  }
  let observedCompleted = Set(observed.snapshot.segments.filter { $0.hasUsableTranslation }.map { $0.id.uuidString })
  let retainedCompleted = retained(bound.completedIDs, in: observedCompleted)
  guard retainedCompleted == bound.completedIDs else { throw CLIError.completedRetentionFailed }
  let completedLines = observed.snapshot.segments
   .filter { retainedCompleted.contains($0.id.uuidString) }
   .sorted { $0.id.uuidString < $1.id.uuidString }
   .map { "\($0.id.uuidString)|\($0.chinese)" }
  guard digestLines(completedLines) == bound.completedDigest else { throw CLIError.completedRetentionFailed }
  let observedBatches = Set(observed.snapshot.batches.map { $0.id.uuidString })
  guard Set(bound.batchIDs).isSubset(of: observedBatches) else { throw CLIError.batchRetentionFailed }
  let retainedBatchIDs = Set(retained(bound.batchIDs, in: observedBatches))
  let retainedBatchDigest = digestLines(observed.snapshot.batches
   .filter { retainedBatchIDs.contains($0.id.uuidString) }
   .map { "\($0.id.uuidString)|\($0.evidence.map(\.id.uuidString).sorted().joined(separator: ","))|\($0.note.markdown)" })
  guard retainedBatchDigest == bound.batchDigest,
        retainedBatchIDs.count == bound.batchIDs.count else { throw CLIError.batchRetentionFailed }
  guard observed.audioFrames == bound.audioFrames,
        observed.audioSampleRate == bound.audioSampleRate else { throw CLIError.captureChangedSavedAudio }
  guard observed.snapshot.segments.count > 0 else { throw CLIError.noCaptions }
 }

 static func verifyReopened(marker: CLIRunMarker, observed: CLIObservedSession, bound: CLIRunSession) throws {
  try verifyRetention(bound: bound, observed: observed)
  // Reopening must not edit the input revision: any body change is an explicit
  // user edit and must not be attributed to opening a course.
  guard observed.snapshot.inputRevision == bound.inputRevision else { throw CLIError.revisionChangedOnReopen }
  // Reopening must not record or process. Unfinished work stays parked;
  // finished work retains its completed state without a needless pause.
  guard !observed.captureActive, observed.transcription?.isCapturing != true else { throw CLIError.captureActiveOnReopen }
  let parked = observed.processingPaused && observed.snapshot.processing.paused
  let completed = !observed.processingPaused && !observed.snapshot.processing.paused
   && observed.snapshot.processing.phase == .completed
  guard parked || completed else { throw CLIError.reopenNotPaused }
  // A course without a durable transcription journal has no restored queue in
  // this process. That is not a failure; a present queue must match and be idle.
  if let transcription = observed.transcription {
   guard transcription.sessionID == observed.sessionID else { throw CLIError.sessionIdentityMismatch }
   guard !transcription.isCapturing, transcription.activeCount == 0,
         transcription.pendingCount == 0, transcription.unresolvedCount == 0 else {
    throw CLIError.processingIncomplete
   }
  }
  guard observed.candidates == 0 else { throw CLIError.candidateBacklog }
  guard observed.pendingWorkers == 0 else { throw CLIError.processingIncomplete }
  guard !observed.archiveErrorPresent else { throw CLIError.savedArchiveUnreadable }
  guard !observed.reviewRunning, !observed.reviewHasWork, observed.reviewFailure == nil else {
   throw CLIError.reviewBacklog
  }
  guard observed.exports.isEmpty || Set(observed.exports.map(\.fileExtension)) == ["md", "txt", "docx", "pdf"] else {
   throw CLIError.exportIncomplete
  }
 }

 static func verifyResumed(marker: CLIRunMarker, observed: CLIObservedSession, bound: CLIRunSession) throws {
  try verifyRetention(bound: bound, observed: observed)
  guard !observed.captureActive, observed.transcription?.isCapturing != true else { throw CLIError.captureActiveOnReopen }
  guard !observed.processingPaused, !observed.snapshot.processing.paused else { throw CLIError.resumeIncomplete }
  if let state = observed.transcription {
   guard state.sessionID == observed.sessionID else { throw CLIError.sessionIdentityMismatch }
   guard state.activeCount == 0, state.pendingCount == 0, state.unresolvedCount == 0 else {
    throw CLIError.processingIncomplete
   }
  }
  guard observed.pendingWorkers == 0,
        observed.snapshot.processing.pendingSegmentIDs.isEmpty,
        observed.snapshot.processing.pendingBatchIDs.isEmpty,
        observed.snapshot.processing.lastError == nil,
        observed.snapshot.processing.captureError == nil,
        observed.snapshot.processing.phase == .completed else { throw CLIError.processingIncomplete }
  guard observed.candidates == 0 else { throw CLIError.candidateBacklog }
  guard !observed.archiveErrorPresent else { throw CLIError.savedArchiveUnreadable }
  guard observed.snapshot.segments.count > 0 else { throw CLIError.noCaptions }
  guard observed.snapshot.segments.allSatisfy({ $0.hasUsableTranslation }) else { throw CLIError.processingIncomplete }
  // Translation notes must be finished for every completed translation.
  guard observed.translatedCount > 0, observed.summarizedCount >= observed.translatedCount,
        !observed.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !observed.snapshot.batches.isEmpty else { throw CLIError.notesIncomplete }
  guard !observed.reviewRunning, !observed.reviewHasWork, observed.reviewFailure == nil else {
   throw CLIError.reviewBacklog
  }
 }

 static func fingerprintExports(_ paths: [String]) throws -> [CLIExportFingerprint] {
  var result: [CLIExportFingerprint] = []
  for path in paths {
   let url = URL(fileURLWithPath: path).standardizedFileURL
   guard !result.contains(where: { $0.fileExtension == url.pathExtension.lowercased() }) else { continue }
   let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
   let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
   guard bytes > 0 else { throw CLIError.exportIncomplete }
   let digest = try hashFile(url)
   let handle = try FileHandle(forReadingFrom: url)
   let head = (try? handle.read(upToCount: 5)) ?? Data()
   try? handle.close()
   let fileExtension = url.pathExtension.lowercased()
   let signature: String
   switch fileExtension {
   case "pdf":
    guard head.starts(with: Data("%PDF".utf8)) else { throw CLIError.exportIncomplete }
    signature = "pdf"
   case "docx":
    guard head.starts(with: Data([0x50, 0x4b, 0x03, 0x04])) else { throw CLIError.exportIncomplete }
    signature = "ooxml"
   case "md", "txt":
    let text = try String(contentsOf: url, encoding: .utf8)
    guard text.contains(NotesExportDocument.notesHeading) else { throw CLIError.exportIncomplete }
    signature = "text"
   default:
    throw CLIError.exportIncomplete
   }
   result.append(CLIExportFingerprint(name: url.lastPathComponent, bytes: bytes, sha256: digest.sha256,
                                      fileExtension: fileExtension, signature: signature))
  }
  return result.sorted { $0.fileExtension < $1.fileExtension }
 }

 /// Export integrity of the saved course, or nil when this paused course has
 /// never exported. A partially written export set is always a failure.
 static func exportReadback(_ directory: URL) throws -> Int? {
  let manifest = directory.appendingPathComponent("manifest.json")
  let jsonl = directory.appendingPathComponent("bilingual.jsonl")
  guard FileManager.default.fileExists(atPath: manifest.path) else {
   guard !FileManager.default.fileExists(atPath: jsonl.path) else { throw CLIError.inconsistentExport }
   return nil
  }
  return try verifySaved(directory)
 }

 // Explicit allowlists prevent a new diagnostic or status field from silently
 // leaking classroom text. Identifiers are parsed, never copied arbitrarily.
 static func safeEvent(_ event: String, fields: [String: Any], elapsed: TimeInterval) -> [String: Any] {
  let events: Set<String> = ["prepare", "state", "capture", "capture_ready", "review_start", "review_done",
                             "review_skipped", "exported", "finished", "save_failed", "opened", "resumed"]
  var result: [String: Any] = ["event": events.contains(event) ? (event == "finished" ? "processing_finished" : event) : "progress"]
  if elapsed.isFinite && elapsed >= 0 { result["elapsedSeconds"] = elapsed }
  for key in ["segments", "translated", "summarized", "pendingTranscription", "unresolvedTranscription", "jobs", "bytes", "revision", "batches"] {
   if let value = fields[key] as? Int, value >= 0 { result[key] = value }
  }
  for key in ["summaryRunning", "concurrency", "paused", "capture"] { if let value = fields[key] as? Bool { result[key] = value } }
  for key in ["seconds", "stopSeconds"] { if let value = fields[key] as? Double, value.isFinite && value >= 0 { result[key] = value } }
  if let raw = fields["sessionID"] as? String, let id = UUID(uuidString: raw) { result["sessionID"] = id.uuidString }
  if let kind = fields["kind"] as? String, ["silent-pcm-replay", "file-import", "system-audio"].contains(kind) { result["kind"] = kind }
  if let format = fields["format"] as? String, NotesExportFormat.allCases.contains(where: { $0.rawValue == format }) { result["format"] = format }
  if let mode = fields["mode"] as? String, ["open-saved", "resume-saved"].contains(mode) { result["mode"] = mode }
  return result
 }

 static func writeEvent(_ event: [String: Any], to handle: FileHandle = .standardOutput) {
  guard var data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
  data.append(10)
  try? handle.write(contentsOf: data)
 }

 static func safeFailure(_ error: Error) -> [String: Any] {
  // Arbitrary error descriptions can include model input, output and stderr.
  if let failure = error as? CLIError { return ["event": "cli_failed", "reason": failure.rawValue] }
  if error is CancellationError { return ["event": "cli_failed", "reason": "cancelled"] }
  let category: String
  switch error {
   case is QwenRuntimeError: category = "model_runtime"
   case is DecodingError: category = "invalid_saved_data"
   case is SessionStoreError: category = "session_archive"
   default: category = "operation_failed"
  }
  return ["event": "cli_failed", "reason": category, "code": (error as NSError).code]
 }

 static func hashFile(_ url: URL) throws -> (bytes: UInt64, sha256: String) {
  try SessionArchiveCoding.requireRegularFileIfPresent(url)
  let file = try FileHandle(forReadingFrom: url)
  defer { try? file.close() }
  var hash = SHA256(), count: UInt64 = 0
  while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk); count += UInt64(chunk.count) }
  return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
 }

 @discardableResult static func configureIsolation(output: URL?, source: CLIRunSource = .pending) throws -> URL {
  let environment = ProcessInfo.processInfo.environment
  guard environment["LIVELINGO_ASR_ENDPOINT"] == nil, environment["LIVELINGO_ASR_TOKEN"] == nil else { throw CLIError.unownedASR }
  if let output, (try? FileManager.default.destinationOfSymbolicLink(atPath: output.path)) != nil {
   throw CLIError.outputExists
  }
  let runID = UUID()
  let directory = (output ?? FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingoCLI-" + runID.uuidString, isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath()
  guard !FileManager.default.fileExists(atPath: directory.path) else { throw CLIError.outputExists }
  let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
  let inputs = [directory, Bundle.main.bundleURL, resources.appendingPathComponent("ASRRuntime/python/bin/python3"),
                resources.appendingPathComponent("ASRRuntime/qwen_asr_service.py"), resources.appendingPathComponent("Models"),
                resources.appendingPathComponent("LanguageRuntime/python/bin/python3"), resources.appendingPathComponent("LanguageRuntime/worker.py")] +
   ["LIVELINGO_MLX_PYTHON", "LIVELINGO_MLX_WORKER", "LIVELINGO_MLX_MODELS"].compactMap { key in environment[key].map { URL(fileURLWithPath: $0) } }
  guard !inputs.contains(where: { url in
   let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
   return resolved == "/Applications" || resolved.hasPrefix("/Applications/")
  }) else { throw CLIError.installedAppForbidden }
  try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
  // Claim the final directory exclusively, even if another CLI chose the same
  // path between the initial existence check and this operation.
  guard mkdir(directory.path, 0o700) == 0 else {
   throw errno == EEXIST ? CLIError.outputExists : CLIError.isolationFailed
  }
  let runtime = directory.appendingPathComponent(".cli-runtime", isDirectory: true)
  let data = runtime.appendingPathComponent("data", isDirectory: true)
  let checkpoints = runtime.appendingPathComponent("checkpoints", isDirectory: true)
  for folder in [data, checkpoints] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
  let marker = try newMarker(directory: directory, runID: runID, source: source)
  for (key, value) in ["LIVELINGO_PREFERENCES_SUITE": marker.preferencesSuite,
                       "LIVELINGO_DATA_DIRECTORY": data.path, "LIVELINGO_MLX_STATE": checkpoints.path] {
   guard setenv(key, value, 1) == 0 else { throw CLIError.isolationFailed }
  }
  try writeMarker(marker, directory: directory)
  writeEvent(["event": "cli_isolated", "runID": runID.uuidString])
  return directory
 }

 static func cleanupOwnedRuntimes() async -> Bool {
  let before = await MLXRuntime.shared.resourceStates()
  for name in before.keys.sorted() {
   guard let state = before[name] else { continue }
   writeEvent(["event": "runtime_cleanup_start", "workerID": state.workerID.uuidString,
               "pid": Int(state.processIdentifier), "requests": state.outstandingRequests,
               "controls": state.pendingControls, "retiring": state.retiring])
  }
  await ASRRuntime.shared.stop()
  let deadline = ProcessInfo.processInfo.systemUptime + 15
  var remaining = await MLXRuntime.shared.resourceStates()
  while !remaining.isEmpty {
   for name in remaining.keys.sorted() { await MLXRuntime.shared.unload(name) }
   remaining = await MLXRuntime.shared.resourceStates()
   if remaining.isEmpty || ProcessInfo.processInfo.systemUptime >= deadline { break }
   await withCheckedContinuation { continuation in
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { continuation.resume() }
   }
  }
  let asrRunning = await ASRRuntime.shared.isRunning
  let clean = remaining.isEmpty && !asrRunning
  writeEvent(["event": "runtime_cleanup", "confirmed": clean, "remainingMLX": remaining.count,
              "asrRunning": asrRunning])
  return clean
 }

 final class SignalState: @unchecked Sendable {
  private let lock = NSLock()
  private var number: Int32?
  func record(_ value: Int32) { lock.withLock { if number == nil { number = value } } }
  var value: Int32? { lock.withLock { number } }
 }

 enum CLIError: String, Error {
  case invalidArguments, outputExists, inconsistentExport, unownedASR, installedAppForbidden
  case isolationFailed, processingIncomplete, noCaptions, cleanupIncomplete
  case reopenTargetForbidden, markerMissing, markerInvalid, legacyMarkerUnsupported, sessionUnbound
  case isolationMissing, sessionIdentityMismatch, captureChangedSavedAudio
  case captionRetentionFailed, completedRetentionFailed, batchRetentionFailed, revisionChangedOnReopen
  case captureActiveOnReopen, reopenNotPaused, resumeIncomplete, candidateBacklog
  case savedArchiveUnreadable, reviewBacklog, reviewIncomplete, notesIncomplete, exportIncomplete
 }
}
