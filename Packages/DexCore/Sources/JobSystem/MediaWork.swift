import Dispatch
import Synchronization

/// Cancellation flag that blocking media code can poll between frames or
/// pages, bridged from Swift task cancellation.
public final class CancellationToken: Sendable {
    private let cancelled = Atomic(false)

    public init() {}

    public var isCancelled: Bool { cancelled.load(ordering: .acquiring) }

    public func cancel() { cancelled.store(true, ordering: .releasing) }

    public func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// Runs blocking media work (ImageIO encodes, large decodes) off the Swift
/// concurrency pool.
///
/// The cooperative pool has one thread per core. ImageIO's HEIF/AVIF encoder
/// blocks waiting on internal work, so running encodes directly on that pool
/// deadlocks once every thread is inside an encoder (observed on macOS 27
/// with 12 parallel encodes). A dedicated dispatch queue avoids that.
public enum MediaWork {
    private static let queue = DispatchQueue(
        label: "com.vxkram.dex.media-work", qos: .userInitiated, attributes: .concurrent
    )

    public static func run<T: Sendable>(
        _ body: @escaping @Sendable (CancellationToken) throws -> T
    ) async throws -> T {
        let token = CancellationToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result { try token.check(); return try body(token) })
                }
            }
        } onCancel: {
            token.cancel()
        }
    }
}
