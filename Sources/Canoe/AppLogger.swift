import Logging
import OSLogHandler

/// Canoe's swift-log loggers: every level of every call site ends up in the
/// Darwin unified logging system through `OSLogHandler` (subsystem
/// `app.canoe`, one os category per logger label), with `metadata` values
/// redacted unless marked `Sensitivity.public`.
///
/// Logs are viewable in Console.app or via:
/// ```sh
/// log stream --predicate 'subsystem == "app.canoe"'
/// ```
enum AppLogger {
    private static let subsystem = "app.canoe"

    /// Installs the handler factory and has to run before the first logger
    /// is built - `LoggingSystem.bootstrap` traps when called twice. The
    /// `Logger` statics below are lazy, so their construction picks up this
    /// factory.
    static func bootstrap() {
        LoggingSystem.bootstrap { label in
            var handler = OSLogHandler(subsystem: subsystem, category: label)
            #if !DEBUG
                // Release builds drop debug and trace the way the old
                // `#if DEBUG` gate did; the levels stay cheap because the
                // message and metadata arguments are autoclosures.
                handler.logLevel = .info
            #endif
            return handler
        }
    }

    static let app = Logger(label: "App")
    static let vault = Logger(label: "Vault")
    static let webSocket = Logger(label: "WebSocket")
    static let settings = Logger(label: "Settings")
    static let send = Logger(label: "Send")
    static let scripts = Logger(label: "Scripts")
    static let response = Logger(label: "Response")
}
