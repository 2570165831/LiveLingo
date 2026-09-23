import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Owns exactly two seconds of PCM at the hardware input format. The callback
/// copies into this ring and signals a coalescing DispatchSource. The consumer
/// reads a no-copy view of owned storage; its region remains reserved until the
/// synchronous consumer returns, including any slow file write.
final class OwnedAudioCaptureBuffer: @unchecked Sendable {
    struct Span: Sendable {
        var frames = 0
        var consumed = 0
        var observedStart: TimeInterval = 0
    }
    struct Failure: Sendable {
        let reason: String
        let observedStart: TimeInterval
        let observedEnd: TimeInterval
        let rejectedFrames: Int64
        let processedFrames: Int64
    }
    enum Submission: Equatable { case accepted, paused, closed, overflow }
    let format: AVAudioFormat
    let capacityFrames: Int
    let capacityBytes: Int
    private let backing: AVAudioPCMBuffer
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let source: DispatchSourceUserDataAdd
    private let consume: @Sendable (AVAudioPCMBuffer, Span) throws -> Void
    private let failed: @Sendable (Failure) -> Void
    private let readList: UnsafeMutableAudioBufferListPointer
    private let copyList: UnsafeMutableAudioBufferListPointer
    private let bytesPerFrame: Int
    private var spans: [Span]
    private var spanHead = 0
    private var spanTail = 0
    private var spanCount = 0
    private var readFrame = 0
    private var writeFrame = 0
    private var occupiedFrames = 0
    private var processedFrames: Int64 = 0
    private var accepting = true
    private var paused = false
    private var failure: Failure?
    private var failureDelivered = false
    private var lastAcceptedEnd: TimeInterval?

    init(format: AVAudioFormat, queue: DispatchQueue,
         consume: @escaping @Sendable (AVAudioPCMBuffer, Span) throws -> Void,
         failed: @escaping @Sendable (Failure) -> Void) throws {
        let frames = Int((format.sampleRate * 2).rounded(.down))
        let bpf = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard frames > 0, frames <= Int(UInt32.max), bpf > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw SpeechPipeline.PipelineError.invalidInputFormat
        }
        self.format = format; self.queue = queue
        capacityFrames = frames; bytesPerFrame = bpf; backing = buffer
        let buffers = Int(buffer.audioBufferList.pointee.mNumberBuffers)
        capacityBytes = frames * bpf * buffers
        // One descriptor per possible one-frame callback is a fixed metadata
        // ceiling. Audio bytes themselves have no additional staging buffer.
        spans = Array(repeating: Span(), count: frames)
        readList = Self.allocateList(count: buffers)
        copyList = Self.allocateList(count: buffers)
        readList.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(buffers)
        copyList.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(buffers)
        self.consume = consume; self.failed = failed
        source = DispatchSource.makeUserDataAddSource(queue: queue)
        source.setEventHandler { [weak self] in self?.drainAvailable() }
        source.resume()
    }
    deinit {
        source.cancel()
        UnsafeMutableRawPointer(readList.unsafeMutablePointer).deallocate()
        UnsafeMutableRawPointer(copyList.unsafeMutablePointer).deallocate()
    }
    private static func allocateList(count: Int) -> UnsafeMutableAudioBufferListPointer {
        let size = MemoryLayout<AudioBufferList>.size + (count - 1) * MemoryLayout<AudioBuffer>.stride
        let memory = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        list.pointee.mNumberBuffers = UInt32(count)
        return UnsafeMutableAudioBufferListPointer(list)
    }
    var pendingFrames: Int { lock.withLock { occupiedFrames } }
    var lastAcceptedUptime: TimeInterval? { lock.withLock { lastAcceptedEnd } }
    var failureSnapshot: Failure? { lock.withLock { failure } }
    func setPaused(_ value: Bool) { lock.withLock { paused = value } }
    func seal() { lock.withLock { accepting = false }; source.add(data: 1) }

    @discardableResult
    func submit(_ buffer: AVAudioPCMBuffer, observedEnd: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Submission {
        copy(buffer.audioBufferList, frames: Int(buffer.frameLength), observedEnd: observedEnd)
    }
    /// The pointer is borrowed only for this synchronous copy, including on 27.
    @discardableResult
    func copy(_ input: UnsafePointer<AudioBufferList>, frames: Int,
              observedEnd: TimeInterval) -> Submission {
        lock.lock()
        defer { lock.unlock(); source.add(data: 1) }
        if paused { return .paused }
        guard accepting else { noteRejected(frames: frames, end: observedEnd); return .closed }
        guard frames > 0 else { return .accepted }
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let destination = UnsafeMutableAudioBufferListPointer(backing.mutableAudioBufferList)
        guard inputList.count == destination.count,
              inputList.allSatisfy({ $0.mData != nil && Int($0.mDataByteSize) >= frames * bytesPerFrame }) else {
            recordFailure("采集音频格式变化，当前缓冲未写入。", frames: frames, end: observedEnd)
            return .overflow
        }
        guard frames <= capacityFrames - occupiedFrames, spanCount < spans.count else {
            recordFailure("磁盘处理跟不上采集，两秒音频缓冲已耗尽。", frames: frames, end: observedEnd)
            return .overflow
        }
        let first = min(frames, capacityFrames - writeFrame)
        for plane in 0..<destination.count {
            let dst = destination[plane].mData!
            let src = inputList[plane].mData!
            memcpy(dst.advanced(by: writeFrame * bytesPerFrame), src, first * bytesPerFrame)
            if first < frames { memcpy(dst, src.advanced(by: first * bytesPerFrame), (frames - first) * bytesPerFrame) }
        }
        accepted(frames: frames, observedEnd: observedEnd)
        return .accepted
    }
    /// CoreMedia copies directly into the owned ring. It never creates or
    /// retains a PCM buffer for a ScreenCaptureKit callback.
    @discardableResult
    func submit(_ sampleBuffer: CMSampleBuffer, observedEnd: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Submission {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return .closed }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        lock.lock()
        defer { lock.unlock(); source.add(data: 1) }
        if paused { return .paused }
        guard accepting else { noteRejected(frames: frames, end: observedEnd); return .closed }
        guard frames > 0 else { return .accepted }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mSampleRate == format.sampleRate,
              asbd.pointee.mChannelsPerFrame == format.channelCount,
              asbd.pointee.mBytesPerFrame == format.streamDescription.pointee.mBytesPerFrame,
              asbd.pointee.mFormatFlags == format.streamDescription.pointee.mFormatFlags else {
            recordFailure("系统音频格式发生变化。", frames: frames, end: observedEnd); return .overflow
        }
        guard frames <= capacityFrames - occupiedFrames, spanCount < spans.count else {
            recordFailure("磁盘处理跟不上采集，两秒音频缓冲已耗尽。", frames: frames, end: observedEnd); return .overflow
        }
        let first = min(frames, capacityFrames - writeFrame)
        setList(copyList, offset: writeFrame, frames: first)
        var status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0,
                           frameCount: Int32(first), into: copyList.unsafeMutablePointer)
        if status == noErr, first < frames {
            setList(copyList, offset: 0, frames: frames - first)
            status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: Int32(first),
                frameCount: Int32(frames - first), into: copyList.unsafeMutablePointer)
        }
        guard status == noErr else {
            recordFailure("系统音频复制失败（\(status)）。", frames: frames, end: observedEnd); return .overflow
        }
        accepted(frames: frames, observedEnd: observedEnd)
        return .accepted
    }
    private func accepted(frames: Int, observedEnd: TimeInterval) {
        lastAcceptedEnd = observedEnd
        spans[spanTail] = Span(frames: frames, observedStart: observedEnd - Double(frames) / format.sampleRate)
        spanTail = (spanTail + 1) % spans.count; spanCount += 1
        writeFrame = (writeFrame + frames) % capacityFrames
        occupiedFrames += frames
    }
    private func recordFailure(_ reason: String, frames: Int, end: TimeInterval) {
        accepting = false
        guard failure == nil else { return }
        failure = Failure(reason: reason, observedStart: end - Double(frames) / format.sampleRate,
                          observedEnd: end, rejectedFrames: Int64(frames), processedFrames: processedFrames)
    }
    private func noteRejected(frames: Int, end: TimeInterval) {
        guard let old = failure, frames > 0 else { return }
        failure = Failure(reason: old.reason, observedStart: old.observedStart,
            observedEnd: max(old.observedEnd, end), rejectedFrames: old.rejectedFrames + Int64(frames),
            processedFrames: processedFrames)
    }
    private func setList(_ list: UnsafeMutableAudioBufferListPointer, offset: Int, frames: Int) {
        let original = UnsafeMutableAudioBufferListPointer(backing.mutableAudioBufferList)
        for plane in 0..<list.count {
            list[plane] = AudioBuffer(mNumberChannels: original[plane].mNumberChannels,
                mDataByteSize: UInt32(frames * bytesPerFrame),
                mData: original[plane].mData!.advanced(by: offset * bytesPerFrame))
        }
    }
    private func drainAvailable() {
        while true {
            let next = lock.withLock { () -> (Int, Span)? in
                guard spanCount > 0 else { return nil }
                let entry = spans[spanHead]
                let frames = min(entry.frames - entry.consumed, capacityFrames - readFrame, 4_096)
                setList(readList, offset: readFrame, frames: frames)
                return (frames, Span(frames: frames,
                    observedStart: entry.observedStart + Double(entry.consumed) / format.sampleRate))
            }
            guard let (frames, span) = next else { break }
            do {
                try autoreleasepool {
                    guard let view = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: readList.unsafePointer, deallocator: nil) else {
                        throw SpeechPipeline.PipelineError.invalidInputFormat
                    }
                    view.frameLength = AVAudioFrameCount(frames)
                    try consume(view, span)
                }
                lock.withLock {
                    processedFrames += Int64(frames)
                    occupiedFrames -= frames; readFrame = (readFrame + frames) % capacityFrames
                    spans[spanHead].consumed += frames
                    if spans[spanHead].consumed == spans[spanHead].frames {
                        spanHead = (spanHead + 1) % spans.count; spanCount -= 1
                    }
                }
            } catch {
                lock.withLock {
                    accepting = false
                    failure = Failure(reason: "音频写入或处理失败：\(error.localizedDescription)",
                        observedStart: span.observedStart, observedEnd: ProcessInfo.processInfo.systemUptime,
                        rejectedFrames: Int64(occupiedFrames), processedFrames: processedFrames)
                    occupiedFrames = 0; spanCount = 0
                }
                break
            }
        }
        let notification = lock.withLock { () -> Failure? in
            guard let failure, !failureDelivered else { return nil }
            failureDelivered = true
            return Failure(reason: failure.reason, observedStart: failure.observedStart,
                           observedEnd: failure.observedEnd, rejectedFrames: failure.rejectedFrames,
                           processedFrames: processedFrames)
        }
        if let notification { failed(notification) }
    }
    func drain() async {
        await withCheckedContinuation { continuation in
            queue.async { self.drainAvailable(); continuation.resume() }
        }
    }
    /// Only call from a non-consumer queue, after sealing a removed device tap.
    func drainSynchronously() { queue.sync { drainAvailable() } }
}

/// The decoder suspends until the serial consumer returns. That ownership
/// transfer makes this framework buffer safe to carry across that one hop.
struct DecodedAudioTransfer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// Detached from the pipeline before one recovery task stops the old stream.
/// Delegate callbacks only test identity; they do not operate this stream again.
struct DetachedSystemAudioStream: @unchecked Sendable {
    let stream: SCStream
}

/// Each stream owns its callback sink. An obsolete stream can only write into
/// its own sealed ring; it has no route to the next session's audio buffers.
final class SystemAudioCaptureSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let ingress: OwnedAudioCaptureBuffer
    let onError: @Sendable (SCStream, Error) -> Void
    init(ingress: OwnedAudioCaptureBuffer, onError: @escaping @Sendable (SCStream, Error) -> Void) {
        self.ingress = ingress; self.onError = onError
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        ingress.submit(sampleBuffer)
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) { onError(stream, error) }
}
