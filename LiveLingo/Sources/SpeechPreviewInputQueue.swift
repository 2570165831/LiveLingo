import Foundation

enum SpeechPreviewInputQueue {
    /// At 100 ms ingress, 16 kHz conversion produces 10 packets/s. The measured
    /// 48 kHz converter produces 109 packets/10 s, including four-packet bursts.
    /// 900 packets therefore hold about 90 / 82.6 seconds respectively, while
    /// allowing bursts to survive a temporarily unscheduled consumer. This is
    /// a packet cap, not a promise of a fixed duration for every input format.
    /// At mono float32/16 kHz and at most 1601 frames per packet, retained PCM
    /// is at most 900 * 1601 * 4 = 5,763,600 bytes, excluding object overhead.
    /// A persistently stalled analyzer loses the oldest preview audio instead
    /// of retaining an unlimited backlog; the recording path is independent.
    static let capacity = 900
    static func makeStream<Element: Sendable>(of: Element.Type) -> (
        stream: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation
    ) {
        AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(capacity))
    }
}
