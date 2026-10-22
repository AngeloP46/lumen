import Foundation
import os

/// How much memory this iPhone lets Lumen use, measured once at launch (iOS doesn't say it directly: what Lumen uses
/// plus what it may still use). Developer reports (Oct 2026): 12 GB iPhones give an app about 3.4 GB by default and
/// about 6 GB with the Increased Memory Limit entitlement (Lumen.entitlements); 4 GB iPhones (13, 13 mini) about 2 GB.
/// The heavy jobs size themselves from this, so every iPhone gets what it can safely do.
enum MemoryBudget {
    /// CI: `-lumenDemoMemoryMB <n>` pretends the phone gives Lumen n MB (the simulator has no real limit).
    static let fakeMB: Int? = DemoMode.isOn ? DemoMode.value("-lumenDemoMemoryMB").flatMap(Int.init) : nil

    static let limitMB: Int = fakeMB ?? (Diagnostics.footprintMB + Int(os_proc_available_memory() / 1_048_576))

    static var deviceGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }

    enum Tier: String { case low, standard, high }
    /// low: about 2 GB (4 GB iPhones); standard: about 3.4 GB; high: the increased limit (about 6 GB).
    static var tier: Tier { limitMB < 2600 ? .low : limitMB < 4500 ? .standard : .high }

    /// The editing preview's long edge.
    static var previewEdge: CGFloat { tier == .low ? 2048 : 2560 }
    /// AI Denoise holds a 1.3 GB model beside the photo: too much for a 2 GB limit.
    static var denoiseFits: Bool { tier != .low }

    static var summary: String { "limit \(limitMB) MB (\(tier.rawValue)), iPhone RAM \(deviceGB) GB" }
}
