import Foundation
import os

/// Restore outcomes, so unexpected resets are measurable. An `unexpectedReset` means saved
/// progress existed but the reader ended up at the first page anyway. Treat any occurrence as a
/// high-priority defect.
public protocol RestoreTelemetry: AnyObject {
    func record(_ event: RestoreEvent, _ detail: String)
}

public extension RestoreTelemetry {
    func record(_ event: RestoreEvent) { record(event, "") }
}

/// Same names as Android, so the analytics backend can treat both apps alike.
public enum RestoreEvent: String, CaseIterable, Sendable {
    /// Opened with no saved position: started at the beginning, as intended.
    case firstOpen = "FIRST_OPEN"
    case restoredLocal = "RESTORED_LOCAL"
    case restoredRemote = "RESTORED_REMOTE"
    /// A newer position from another device arrived after opening and was applied.
    case remoteAppliedLate = "REMOTE_APPLIED_LATE"
    /// The reader landed somewhere other than the restore target.
    case restoreMismatch = "RESTORE_MISMATCH"
    case unexpectedReset = "UNEXPECTED_RESET"
    case userRestart = "USER_RESTART"
}

/// Logs every event to the unified log (subsystem `io.github.satyanvm.reader`, category
/// `ReaderRestore`) and keeps lifetime counters on the device. `UNEXPECTED_RESET` is logged as a
/// fault, so it shows up in Console and in `log show --predicate 'category == "ReaderRestore"'`.
public final class LocalRestoreTelemetry: RestoreTelemetry {
    private let log = Logger(subsystem: "io.github.satyanvm.reader", category: "ReaderRestore")
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func record(_ event: RestoreEvent, _ detail: String) {
        let message = "\(event.rawValue) \(detail)".trimmingCharacters(in: .whitespaces)
        switch event {
        case .unexpectedReset: log.fault("\(message, privacy: .public)")
        case .restoreMismatch: log.warning("\(message, privacy: .public)")
        default: log.info("\(message, privacy: .public)")
        }
        let key = "restore_telemetry.\(event.rawValue)"
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }

    public func counts() -> [String: Int] {
        Dictionary(uniqueKeysWithValues: RestoreEvent.allCases.map {
            ($0.rawValue, defaults.integer(forKey: "restore_telemetry.\($0.rawValue)"))
        })
    }
}
