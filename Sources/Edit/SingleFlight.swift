import Foundation

/// "One at a time, and only the newest" (quality checklist A23, 23 Oct 2026). Owner's phone, 0.1.533: undo, redo, HDR and a
/// finished heal each asked for the photo to be decoded again within one second; three decodes, each with its own copy
/// of the photo, were alive together and memory went from 1.2 to 3.4 GB. Now a request that arrives while a decode is
/// running does not start another; it only remembers that the newest settings are still to be shown, and one more decode
/// (of the settings as they are then) follows the running one.
struct SingleFlight {
    private(set) var running = false
    private var again = false

    /// Something asked for a run. True: start it now. False: one is running; it will be followed by one more.
    mutating func request() -> Bool {
        if running { again = true; return false }
        running = true
        again = false
        return true
    }

    /// The running one is over. True: requests came in meanwhile, so start one more now (still counts as running).
    mutating func finish() -> Bool {
        if again { again = false; return true }
        running = false
        return false
    }
}
