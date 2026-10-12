import Foundation

enum SpeechPreviewInputQueue {
    /// Converter output is audio, including packets without their own time
    /// anchor. Retain every packet until the analyzer takes it: evicting even
    /// a small continuation both loses samples and changes its inferred time.
    /// The pipeline owns finish/cancel and releases the stream on shutdown.
    static func makeStream<Element: Sendable>(of: Element.Type) -> (
        stream: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation
    ) {
        AsyncStream<Element>.makeStream(bufferingPolicy: .unbounded)
    }
}
