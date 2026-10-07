import AudioToolbox
import AVFoundation
import Darwin
import Foundation

/// WAV creation and every AudioToolbox callback are bound to one exclusively
/// created descriptor. No audio API is given the user's output path.
final class SecureAudioWriter: @unchecked Sendable {
    enum Failure: Error {
        case invalidFormat
        case closed
        case audio(OSStatus)
        case system(Int32)
    }

    /// Acquiring the directory separately lets callers keep creation bound to
    /// it even when its pathname is subsequently renamed or replaced.
    final class Directory: @unchecked Sendable {
        private let directory: SensitiveFileIO.Directory

        private init(_ directory: SensitiveFileIO.Directory) { self.directory = directory }

        static func open(at url: URL) throws -> Directory {
            Directory(try SensitiveFileIO.Directory.open(at: url, create: false, tighten: false))
        }

        func makeWriter(named name: String, format: AVAudioFormat) throws -> SecureAudioWriter {
            // Validate before creating a file, so a bad format leaves no leaf.
            let fileFormat = try SecureAudioWriter.waveFormat(format)
            let fd = try directory.createPrivateFile(named: name)
            let descriptor = Descriptor(fd)
            return try SecureAudioWriter(descriptor: descriptor, format: format, fileFormat: fileFormat)
        }
    }

    /// Kept alive until both AudioFile objects have finalized their headers.
    /// The callbacks do positional IO only; they never reopen a pathname.
    private final class Descriptor {
        private(set) var fd: Int32
        var ioError: Int32?

        init(_ fd: Int32) { self.fd = fd }
        deinit { if fd >= 0 { _ = Darwin.close(fd) } }

        func close() -> Int32? {
            guard fd >= 0 else { return nil }
            let closing = fd
            fd = -1
            return Darwin.close(closing) == 0 ? nil : errno
        }

        private static func instance(_ context: UnsafeMutableRawPointer?) -> Descriptor? {
            context.map { Unmanaged<Descriptor>.fromOpaque($0).takeUnretainedValue() }
        }

        static func read(_ context: UnsafeMutableRawPointer?, position: Int64, count: UInt32,
                         buffer: UnsafeMutableRawPointer?, actual: UnsafeMutablePointer<UInt32>?) -> OSStatus {
            guard let self = instance(context), let buffer, let actual,
                  position >= 0, position <= Int64.max - Int64(count) else { return OSStatus(paramErr) }
            actual.pointee = 0
            while actual.pointee < count {
                let done = Int(actual.pointee)
                let read = pread(self.fd, buffer.advanced(by: done), Int(count) - done, off_t(position + Int64(done)))
                if read < 0 {
                    if errno == EINTR { continue }
                    self.ioError = errno
                    return OSStatus(errno)
                }
                if read == 0 { break }
                actual.pointee += UInt32(read)
            }
            return noErr
        }

        static func write(_ context: UnsafeMutableRawPointer?, position: Int64, count: UInt32,
                          buffer: UnsafeRawPointer?, actual: UnsafeMutablePointer<UInt32>?) -> OSStatus {
            guard let self = instance(context), let buffer, let actual,
                  position >= 0, position <= Int64.max - Int64(count) else { return OSStatus(paramErr) }
            actual.pointee = 0
            while actual.pointee < count {
                let done = Int(actual.pointee)
                let written = pwrite(self.fd, buffer.advanced(by: done), Int(count) - done, off_t(position + Int64(done)))
                if written < 0 {
                    if errno == EINTR { continue }
                    self.ioError = errno
                    return OSStatus(errno)
                }
                if written == 0 {
                    self.ioError = EIO
                    return OSStatus(EIO)
                }
                actual.pointee += UInt32(written)
            }
            return noErr
        }

        static func size(_ context: UnsafeMutableRawPointer?) -> Int64 {
            guard let self = instance(context) else { return -1 }
            var info = stat()
            guard fstat(self.fd, &info) == 0 else {
                self.ioError = errno
                return -1
            }
            return Int64(info.st_size)
        }

        static func setSize(_ context: UnsafeMutableRawPointer?, size: Int64) -> OSStatus {
            guard let self = instance(context), size >= 0 else { return OSStatus(paramErr) }
            while ftruncate(self.fd, off_t(size)) != 0 {
                if errno == EINTR { continue }
                self.ioError = errno
                return OSStatus(errno)
            }
            return noErr
        }
    }

    private let lock = NSLock()
    private let descriptor: Descriptor
    let processingFormat: AVAudioFormat
    private var audioFile: AudioFileID?
    private var extendedFile: ExtAudioFileRef?
    private var writtenFrames: AVAudioFramePosition = 0
    private var closeFailure: Failure?

    var length: AVAudioFramePosition { lock.withLock { writtenFrames } }

    convenience init(forWriting url: URL, format: AVAudioFormat) throws {
        let directory = try SensitiveFileIO.Directory.open(at: url.deletingLastPathComponent(),
                                                           create: false, tighten: false)
        let fileFormat = try Self.waveFormat(format)
        let fd = try directory.createPrivateFile(named: url.lastPathComponent)
        try self.init(descriptor: Descriptor(fd), format: format, fileFormat: fileFormat)
    }

    private init(descriptor: Descriptor, format: AVAudioFormat,
                 fileFormat: AudioStreamBasicDescription) throws {
        self.descriptor = descriptor
        processingFormat = format
        var fileFormat = fileFormat
        var file: AudioFileID?
        var extended: ExtAudioFileRef?
        // A failed setup must dispose its callbacks before the fd owner dies.
        defer {
            if audioFile == nil {
                if let extended { _ = ExtAudioFileDispose(extended) }
                if let file { _ = AudioFileClose(file) }
            }
        }
        try check(AudioFileInitializeWithCallbacks(
            Unmanaged.passUnretained(descriptor).toOpaque(),
            { Descriptor.read($0, position: $1, count: $2, buffer: $3, actual: $4) },
            { Descriptor.write($0, position: $1, count: $2, buffer: $3, actual: $4) },
            { Descriptor.size($0) },
            { Descriptor.setSize($0, size: $1) },
            kAudioFileWAVEType, &fileFormat, AudioFileFlags(rawValue: 0), &file
        ))
        guard let file else { throw Failure.audio(kAudioFileUnspecifiedError) }
        try check(ExtAudioFileWrapAudioFileID(file, true, &extended))
        guard let extended else { throw Failure.audio(kAudioFileUnspecifiedError) }
        var client = format.streamDescription.pointee
        try check(ExtAudioFileSetProperty(extended, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout.size(ofValue: client)), &client))
        audioFile = file
        extendedFile = extended
    }

    deinit { try? close() }

    func write(from buffer: AVAudioPCMBuffer) throws {
        try lock.withLock {
            guard let extendedFile else { throw closeFailure ?? Failure.closed }
            guard buffer.format == processingFormat,
                  writtenFrames <= Int64.max - Int64(buffer.frameLength) else { throw Failure.invalidFormat }
            guard buffer.frameLength > 0 else { return }
            try check(ExtAudioFileWrite(extendedFile, buffer.frameLength, buffer.audioBufferList))
            writtenFrames += Int64(buffer.frameLength)
        }
    }

    /// Dispose the converter, finalize RIFF on the same fd, and flush before
    /// releasing it. Repeated close calls preserve any finalization error.
    func close() throws {
        try lock.withLock {
            guard audioFile != nil || extendedFile != nil else {
                if let closeFailure { throw closeFailure }
                return
            }
            var failure: Failure?
            if let extendedFile {
                let status = ExtAudioFileDispose(extendedFile)
                if status != noErr { failure = .audio(status) }
                self.extendedFile = nil
            }
            if let audioFile {
                let status = AudioFileClose(audioFile)
                if status != noErr, failure == nil { failure = .audio(status) }
                self.audioFile = nil
            }
            if let code = descriptor.ioError { failure = .system(code) }
            while fsync(descriptor.fd) != 0 {
                if errno == EINTR { continue }
                if failure == nil { failure = .system(errno) }
                break
            }
            if let code = descriptor.close(), failure == nil { failure = .system(code) }
            closeFailure = failure
            if let failure { throw failure }
        }
    }

    private func check(_ status: OSStatus) throws {
        if let code = descriptor.ioError { throw Failure.system(code) }
        guard status == noErr else { throw Failure.audio(status) }
    }

    private static func waveFormat(_ format: AVAudioFormat) throws -> AudioStreamBasicDescription {
        var file = format.streamDescription.pointee
        guard file.mFormatID == kAudioFormatLinearPCM,
              file.mSampleRate.isFinite, file.mSampleRate > 0,
              file.mChannelsPerFrame > 0, file.mFramesPerPacket == 1,
              file.mBytesPerFrame > 0, [16, 32, 64].contains(file.mBitsPerChannel) else {
            throw Failure.invalidFormat
        }
        // WAV stores interleaved little-endian samples. Preserve the sample
        // representation, bit depth, sample rate and channel count; the client
        // ASBD tells ExtAudioFile how to interleave the capture PCM buffers.
        if file.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            let bytes = file.mBytesPerFrame.multipliedReportingOverflow(by: file.mChannelsPerFrame)
            guard !bytes.overflow else { throw Failure.invalidFormat }
            file.mBytesPerFrame = bytes.partialValue
            file.mBytesPerPacket = file.mBytesPerFrame
        }
        file.mFormatFlags &= ~(kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian)
        return file
    }
}
