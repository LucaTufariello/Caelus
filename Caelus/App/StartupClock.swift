//
//  StartupClock.swift
//  Caelus
//
//  Opt-in startup timing. `CAELUS_STARTUP_LOG=1` prints one line per phase
//  to stderr, which is how the figures in the README's performance table were
//  measured. Off by default and free when disabled.
//

import Foundation

enum StartupClock {

    private static let origin = DispatchTime.now()

    static let isEnabled = ProcessInfo.processInfo.environment["CAELUS_STARTUP_LOG"] == "1"

    /// Milliseconds since the model was created — effectively process launch.
    static var elapsedMs: Double {
        // Read `origin` before sampling the clock. It is a lazy static, so if
        // this getter is what initialises it, the clock sample would be taken
        // first and the subtraction would underflow.
        let origin = Self.origin.uptimeNanoseconds
        let now = DispatchTime.now().uptimeNanoseconds
        return Double(now &- origin) / 1_000_000
    }

    static func mark(_ phase: String) {
        guard isEnabled else { return }
        FileHandle.standardError.write(Data(String(format: "[startup] %7.1f ms  %@\n",
                                                   elapsedMs, phase).utf8))
    }

    /// Marks a phase that can be reached repeatedly; only the first counts.
    static func markOnce(_ key: String, _ phase: @autoclosure () -> String) {
        guard isEnabled else { return }
        let isFirst = lock.withLock { emitted.insert(key).inserted }
        guard isFirst else { return }
        mark(phase())
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var emitted: Set<String> = []
}
