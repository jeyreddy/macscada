import Foundation
import os.log

/// Application-wide logging utility
class Logger {
    // MARK: - Singleton
    
    static let shared = Logger()
    
    // MARK: - Properties
    
    private let subsystem = "com.industrialhmi.app"
    private let osLog: OSLog
    
    // MARK: - Initialization
    
    private init() {
        osLog = OSLog(subsystem: subsystem, category: "general")
    }
    
    // MARK: - Logging Methods
    
    /// Log debug message (only in debug builds)
    func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "[\(fileName):\(line)] \(function) - \(message)"
        os_log("%{public}@", log: osLog, type: .debug, logMessage)
        #endif
    }
    
    /// Log informational message
    func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "[\(fileName):\(line)] \(message)"
        os_log("%{public}@", log: osLog, type: .info, logMessage)
    }
    
    /// Log warning message
    func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "[\(fileName):\(line)] WARNING: \(message)"
        os_log("%{public}@", log: osLog, type: .default, logMessage)
    }
    
    /// Log error message
    func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "[\(fileName):\(line)] ERROR: \(message)"
        os_log("%{public}@", log: osLog, type: .error, logMessage)
    }
    
    /// Log critical fault
    func fault(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "[\(fileName):\(line)] FAULT: \(message)"
        os_log("%{public}@", log: osLog, type: .fault, logMessage)
    }
}

// MARK: - Convenience Extensions

extension Logger {
    /// Log error with Error object
    func error(_ error: Error, file: String = #file, function: String = #function, line: Int = #line) {
        self.error(error.localizedDescription, file: file, function: function, line: line)
    }
}
