import Foundation

/// A shared model with one loader at a time. Call `model` on a worker thread: callers wait for an existing load.
/// `release` never waits for model loading, so closing a tool or a memory warning cannot stall the main thread.
/// Active jobs keep their own reference. A release during loading prevents that result being cached afterwards.
final class LoadedModel<M>: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: M?
    private var loading = false
    private var generation: UInt64 = 0
    private let load: () -> M?

    init(_ load: @escaping () -> M?) { self.load = load }

    var model: M? {
        condition.lock()
        while loading { condition.wait() }
        if let value { condition.unlock(); return value }
        loading = true
        let started = generation
        condition.unlock()

        let result = load()

        condition.lock()
        if generation == started { value = result }
        loading = false
        condition.broadcast()
        condition.unlock()
        // A failed load is not cached forever; a later explicit request can recover.
        return result
    }

    func release() {
        condition.lock()
        generation &+= 1
        let previous = value
        value = nil
        condition.unlock()
        // Model destruction may itself take time; never hold the state lock while destroying it.
        withExtendedLifetime(previous) {}
    }
}
