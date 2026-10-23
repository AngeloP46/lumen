import Foundation

/// A shared model with one loader at a time. Call `model` on a worker thread: callers wait for an existing load.
/// `release` never waits for model loading, so closing a tool or a memory warning cannot stall the main thread.
/// Active jobs keep their own reference. A release during loading prevents that result being cached afterwards, but
/// the callers already waiting for that load still get it (before 23 Oct they each started a load of their own: a
/// second multi-hundred-MB load straight after the release that was meant to free memory; quality checklist A9).
final class LoadedModel<M>: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: M?
    private var loading = false
    private var generation: UInt64 = 0
    private var loadNumber: UInt64 = 0
    private var finished: (number: UInt64, result: M?) = (0, nil)
    private let load: () -> M?

    init(_ load: @escaping () -> M?) { self.load = load }

    var model: M? {
        condition.lock()
        if loading {
            let waitingFor = loadNumber
            while loading && loadNumber == waitingFor { condition.wait() }
            // the load this call waited for is over: use its result, released meanwhile or not
            if finished.number == waitingFor { let r = finished.result; condition.unlock(); return r }
        }
        if let value { condition.unlock(); return value }
        loading = true
        loadNumber &+= 1
        let mine = loadNumber
        let started = generation
        condition.unlock()

        let result = load()

        condition.lock()
        if generation == started { value = result }
        finished = (mine, result)
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
