import os

/// One `Logger` per subsystem area. Filter in Console / `log stream` with
/// `subsystem == "com.stackrover.cue"`.
nonisolated enum Log {
    private static let subsystem = "com.stackrover.cue"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let permission = Logger(subsystem: subsystem, category: "permission")
    static let ocr = Logger(subsystem: subsystem, category: "ocr")
}
