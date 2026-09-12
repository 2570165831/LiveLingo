import Foundation
import AppKit
import AVFoundation
import CryptoKit
@main struct LiveLingoCLI {
 @MainActor static func main() async {
  let args = Array(CommandLine.arguments.dropFirst())
  if args.isEmpty || args.contains("--help") {
   print("Usage: livelingo-cli (--replay AUDIO | --system-audio SECONDS) --output NEW_DIRECTORY [--high-quality]\n       livelingo-cli --verify-saved DIRECTORY\nReplay injects PCM without playing sound. Uses the selected local ASR service and MLX runtime; does not modify the installed App.");return
  }
  do {
   if args.first == "--verify-saved" {
    guard args.count == 2 else { throw CLIError.invalidArguments }
    try verifySaved(URL(fileURLWithPath: args[1], isDirectory: true))
    return
   }
   var index = 0
   while index < args.count {
    switch args[index] {
     case "--high-quality": index += 1
     case "--replay", "--system-audio", "--output":
      guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else { throw CLIError.invalidArguments }
      index += 2
     default: throw CLIError.invalidArguments
    }
   }
   for key in ["--replay", "--system-audio", "--output", "--high-quality"] {
    guard args.filter({ $0 == key }).count <= 1 else { throw CLIError.invalidArguments }
   }
   func value(_ key:String) throws -> String {guard let i=args.firstIndex(of:key),i+1<args.count else {throw CLIError.invalidArguments};return args[i+1]}
   let replay=args.contains("--replay"),capture=args.contains("--system-audio")
   guard replay != capture else {throw CLIError.invalidArguments}
   let directory=URL(fileURLWithPath:try value("--output"),isDirectory:true).standardizedFileURL
   guard !FileManager.default.fileExists(atPath:directory.path) else {throw CLIError.outputExists}
   let file = replay ? URL(fileURLWithPath:try value("--replay")).standardizedFileURL : nil
   if let file {guard FileManager.default.isReadableFile(atPath:file.path) else {throw CLIError.invalidArguments}}
   let seconds=capture ? Double(try value("--system-audio")) ?? 0 : 0
   if capture {guard seconds.isFinite && seconds>0 && seconds<=3600 else {throw CLIError.invalidArguments}}
   try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
   let model=AppModel(reviewQueue: LearningReviewQueue(journalURL: directory.appendingPathComponent("review-queue.json"), observeSleep: false))
   let start=ProcessInfo.processInfo.systemUptime
   try await model.cliRun(file:file,seconds:seconds,directory:directory,highQuality:args.contains("--high-quality")) {event,fields in
    var payload=fields;payload["event"]=event;payload["elapsedSeconds"]=ProcessInfo.processInfo.systemUptime-start
    if let data=try? JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys]),let line=String(data:data,encoding:.utf8) {print(line);fflush(stdout)}
   }
   try verifySaved(directory)
  } catch {fputs("CLI failed: \(error)\n",stderr);exit(1)}
 }
 static func verifySaved(_ directory: URL) throws {
  let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
  let manifest=try decoder.decode(SessionExporter.Manifest.self,from:Data(contentsOf:directory.appendingPathComponent("manifest.json")))
  guard manifest.recordingFile == "recording.wav" else { throw CLIError.inconsistentExport }
  let jsonl=try String(contentsOf:directory.appendingPathComponent("bilingual.jsonl"),encoding:.utf8)
  let segments=try jsonl.split(separator:"\n").map { try decoder.decode(TranscriptSegment.self,from:Data($0.utf8)) }
  guard segments.count == manifest.segmentCount, !segments.isEmpty else { throw CLIError.inconsistentExport }
  let english=try String(contentsOf:directory.appendingPathComponent("transcript-en.txt"),encoding:.utf8)
  let chinese=try String(contentsOf:directory.appendingPathComponent("transcript-zh-Hans.txt"),encoding:.utf8)
  guard english == segments.map(\.english).joined(separator:"\n")+"\n",
        chinese == segments.map(\.chinese).joined(separator:"\n")+"\n" else { throw CLIError.inconsistentExport }
  let audio=try AVAudioFile(forReading:directory.appendingPathComponent(manifest.recordingFile))
  guard audio.length>0, audio.processingFormat.sampleRate>0 else { throw CLIError.inconsistentExport }
  var names=["manifest.json","bilingual.jsonl","bilingual.srt","transcript-en.txt","transcript-zh-Hans.txt","recording.wav"]
  if FileManager.default.fileExists(atPath:directory.appendingPathComponent("summary-zh-Hans.md").path) { names.append("summary-zh-Hans.md") }
  let files=try names.map { name -> [String:Any] in
   let data=try Data(contentsOf:directory.appendingPathComponent(name))
   guard !data.isEmpty else { throw CLIError.inconsistentExport }
   return ["name":name,"bytes":data.count,"sha256":SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()]
  }
  let receipt:[String:Any]=["event":"saved_verified","segments":segments.count,"audioSeconds":Double(audio.length)/audio.processingFormat.sampleRate,"files":files]
  print(String(decoding:try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys]),as:UTF8.self))
 }
 enum CLIError: Error {case invalidArguments,outputExists,inconsistentExport}
}
