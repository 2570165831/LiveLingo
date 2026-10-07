import AVFoundation
import Darwin
import Foundation
#if !PRIVACY_AUDIO_PROBE
import Testing
@testable import LiveLingo
#endif

/// Hardware-free WAV cases. Every path and byte belongs to a fresh synthetic
/// fixture; fixtures are retained under superseded for the parent to inspect.
struct PrivacyAudioTests {
    private struct AssertionFailure: Error { let message: String }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw AssertionFailure(message: message) }
    }

    private struct Fixture {
        let root: URL

        init() throws {
            #if PRIVACY_AUDIO_PROBE
            let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            #else
            let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("work/privacy-followup/audio", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            #endif
            root = base.appendingPathComponent("synthetic-audio-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        func directory(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            guard chmod(url.path, 0o755) == 0 else { throw POSIXError(.EACCES) }
            return url
        }

        func retain() {
            let destination = root.deletingLastPathComponent().appendingPathComponent("superseded", isDirectory: true)
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: root, to: destination.appendingPathComponent(root.lastPathComponent))
        }
    }

    private func format(_ rate: Double = 16_000, channels: AVAudioChannelCount = 1,
                        common: AVAudioCommonFormat = .pcmFormatFloat32,
                        interleaved: Bool = false) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(commonFormat: common, sampleRate: rate,
                                       channels: channels, interleaved: interleaved) else {
            throw AssertionFailure(message: "Synthetic PCM format is unavailable")
        }
        return format
    }

    private func buffer(_ format: AVAudioFormat, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw AssertionFailure(message: "Synthetic PCM buffer is unavailable")
        }
        buffer.frameLength = frames
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audio in list {
            guard let data = audio.mData else { throw AssertionFailure(message: "Missing PCM storage") }
            let samples = Int(frames) * Int(audio.mNumberChannels)
            switch format.commonFormat {
            case .pcmFormatFloat32:
                data.assumingMemoryBound(to: Float.self).initialize(repeating: 0.25, count: samples)
            case .pcmFormatFloat64:
                data.assumingMemoryBound(to: Double.self).initialize(repeating: 0.25, count: samples)
            case .pcmFormatInt16:
                data.assumingMemoryBound(to: Int16.self).initialize(repeating: 8_192, count: samples)
            case .pcmFormatInt32:
                data.assumingMemoryBound(to: Int32.self).initialize(repeating: 536_870_912, count: samples)
            default: throw AssertionFailure(message: "Unsupported synthetic PCM representation")
            }
        }
        return buffer
    }

    private func sentinel(_ url: URL) throws -> Data {
        let bytes = Data(repeating: 0xA5, count: 257)
        try bytes.write(to: url)
        return bytes
    }

    private func link(_ url: URL, to target: URL) throws {
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }

    private func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return info.st_mode & 0o777
    }

    private func aclText(_ url: URL) throws -> String {
        _ = try mode(url)
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return "" }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { throw POSIXError(.EINVAL) }
        defer { _ = acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }

    private func allowACLCount(_ url: URL) throws -> Int {
        _ = try mode(url)
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return 0 }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var cursor = Int32(ACL_FIRST_ENTRY.rawValue), count = 0
        while true {
            var entry: acl_entry_t?
            guard acl_get_entry(acl, cursor, &entry) == 0, let entry else { return count }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else { throw POSIXError(.EINVAL) }
            if tag == ACL_EXTENDED_ALLOW { count += 1 }
            cursor = Int32(ACL_NEXT_ENTRY.rawValue)
        }
    }

    private func checkReadback(_ url: URL, format: AVAudioFormat, frames: AVAudioFramePosition) throws {
        let reader = try AVAudioFile(forReading: url)
        try require(reader.length == frames, "Finalized WAV frame count changed")
        try require(reader.fileFormat.sampleRate == format.sampleRate, "WAV sample rate changed")
        try require(reader.fileFormat.channelCount == format.channelCount, "WAV channel count changed")
        try require(reader.fileFormat.streamDescription.pointee.mBitsPerChannel ==
                    format.streamDescription.pointee.mBitsPerChannel, "WAV bit depth changed")
        try require(reader.fileFormat.commonFormat == format.commonFormat, "WAV sample representation changed")
        guard let pcm = AVAudioPCMBuffer(pcmFormat: reader.processingFormat,
                                       frameCapacity: AVAudioFrameCount(frames)) else {
            throw AssertionFailure(message: "Readback buffer is unavailable")
        }
        try reader.read(into: pcm)
        try require(AVAudioFramePosition(pcm.frameLength) == frames, "PCM readback lost frames")
        guard let channels = pcm.floatChannelData else { throw AssertionFailure(message: "Float readback missing") }
        for channel in 0..<Int(pcm.format.channelCount) {
            for frame in 0..<Int(pcm.frameLength) {
                try require(abs(channels[channel][frame] - 0.25) < 0.000_01, "PCM sample changed")
            }
        }
        let layout = try WAVContextClip.readLayout(at: url)
        try require(layout.frameCount == Int(frames), "RIFF context reader lost frames")
        try require(layout.channelCount == Int(format.channelCount), "RIFF channel count changed")
        try require(layout.sampleRate == format.sampleRate, "RIFF sample rate changed")
    }

    private func normalPCM(in directory: URL, format: AVAudioFormat) throws {
        let url = directory.appendingPathComponent("normal-" + UUID().uuidString + ".wav")
        let writer = try SecureAudioWriter(forWriting: url, format: format)
        try writer.write(from: buffer(format, frames: 257))
        try writer.write(from: buffer(format, frames: 129))
        try require(writer.length == 386, "Writer frame count changed")
        let active = try WAVContextClip.readLayout(at: url)
        try require(active.frameCount == 386, "Growing RIFF context reader lost frames")
        try writer.close()
        try require(try mode(url) == 0o600, "New WAV is not private")
        try require(try allowACLCount(url) == 0, "New WAV retained an allow ACL")
        try checkReadback(url, format: format, frames: 386)
    }

    #if !PRIVACY_AUDIO_PROBE
    @Test
    #endif
    func leafSymlinkIsRejectedBeforeTruncationAndMonoPCMStillReads() throws {
        let fixture = try Fixture(); defer { fixture.retain() }
        let outside = try fixture.directory("outside")
        let target = outside.appendingPathComponent("synthetic-target.wav")
        let original = try sentinel(target)
        let alias = fixture.root.appendingPathComponent("recording.wav")
        try link(alias, to: target)
        var rejected = false
        do { try SecureAudioWriter(forWriting: alias, format: format()).close() }
        catch { rejected = true }
        try require(try Data(contentsOf: target) == original, "Leaf symlink truncated the outside sentinel")
        try require(rejected, "Leaf symlink was accepted")
        try normalPCM(in: fixture.root, format: format())
    }

    #if !PRIVACY_AUDIO_PROBE
    @Test
    #endif
    func parentSymlinkIsRejectedBeforeTruncationAndStereoPCMStillReads() throws {
        let fixture = try Fixture(); defer { fixture.retain() }
        let outside = try fixture.directory("outside")
        let target = outside.appendingPathComponent("recording.wav")
        let original = try sentinel(target)
        let alias = fixture.root.appendingPathComponent("linked-parent")
        try link(alias, to: outside)
        var rejected = false
        do { try SecureAudioWriter(forWriting: alias.appendingPathComponent("recording.wav"),
                                   format: format(48_000, channels: 2)).close() }
        catch { rejected = true }
        try require(try Data(contentsOf: target) == original, "Parent symlink truncated the outside sentinel")
        try require(rejected, "Linked ancestor was accepted")
        try normalPCM(in: fixture.root, format: format(48_000, channels: 2))
    }

    #if !PRIVACY_AUDIO_PROBE
    @Test
    #endif
    func openedDirectoryAndWriterStayBoundAcrossParentAndLeafReplacement() throws {
        let fixture = try Fixture(); defer { fixture.retain() }
        let working = try fixture.directory("working")
        let acl = Process()
        acl.executableURL = URL(fileURLWithPath: "/bin/chmod")
        acl.arguments = ["+a", "everyone allow read,readattr,readextattr,readsecurity,file_inherit", working.path]
        try acl.run(); acl.waitUntilExit()
        try require(acl.terminationStatus == 0, "Synthetic inherited ACL setup failed")
        let priorMode = try mode(working), priorACL = try aclText(working)
        let directory = try SecureAudioWriter.Directory.open(at: working)
        let outside = try fixture.directory("outside")
        let target = outside.appendingPathComponent("chunk.wav")
        let original = try sentinel(target)
        let retained = fixture.root.appendingPathComponent("retained-directory")
        try FileManager.default.moveItem(at: working, to: retained)
        try link(working, to: outside)
        // The descriptor was acquired before the adversarial rename. Creation,
        // audio data and final header must all use that same original object.
        let f = try format(48_000, channels: 2)
        let writer = try directory.makeWriter(named: "chunk.wav", format: f)
        let originalFile = retained.appendingPathComponent("chunk.wav")
        try require(try mode(retained) == priorMode, "Existing parent permissions changed")
        try require(try aclText(retained) == priorACL, "Existing parent ACL changed")
        try require(try mode(originalFile) == 0o600, "New descriptor file is not private")
        try require(try allowACLCount(originalFile) == 0, "Inherited allow ACL survived creation")
        try writer.write(from: buffer(f, frames: 257))
        let active = try WAVContextClip.readLayout(at: originalFile)
        try require(active.frameCount == 257, "Growing RIFF is incompatible")
        let retainedFile = retained.appendingPathComponent("retained-audio.wav")
        try FileManager.default.moveItem(at: originalFile, to: retainedFile)
        try link(originalFile, to: target)
        try writer.write(from: buffer(f, frames: 129))
        try writer.close()
        try require(try Data(contentsOf: target) == original, "Descriptor replacement modified the outside sentinel")
        try checkReadback(retainedFile, format: f, frames: 386)
    }

    #if !PRIVACY_AUDIO_PROBE
    @Test
    #endif
    func exclusiveCreationPreservesExistingAndHardLinkedFilesAndIntegerPCM() throws {
        let fixture = try Fixture(); defer { fixture.retain() }
        let existing = fixture.root.appendingPathComponent("existing.wav")
        let original = try sentinel(existing)
        var rejected = false
        do { try SecureAudioWriter(forWriting: existing, format: format()).close() }
        catch { rejected = true }
        try require(try Data(contentsOf: existing) == original, "Existing file was truncated")
        try require(rejected, "Exclusive creation replaced an existing file")
        let hardLink = fixture.root.appendingPathComponent("hard-linked.wav")
        try FileManager.default.linkItem(at: existing, to: hardLink)
        rejected = false
        do { try SecureAudioWriter(forWriting: hardLink, format: format()).close() }
        catch { rejected = true }
        try require(rejected, "Hard-linked leaf was accepted")
        try require(try Data(contentsOf: existing) == original, "Hard-linked target was truncated")
        for common in [AVAudioCommonFormat.pcmFormatInt16, .pcmFormatInt32, .pcmFormatFloat32, .pcmFormatFloat64] {
            for interleaved in [false, true] {
                try normalPCM(in: fixture.root, format: format(44_100, channels: 2,
                                                              common: common, interleaved: interleaved))
            }
        }
    }
}
