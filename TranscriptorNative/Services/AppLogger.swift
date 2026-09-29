import Foundation
import os.log

/// Structured logging system for diagnostics
/// Privacy-first: Never logs user content (audio/text), only technical events
final class AppLogger {
    static let shared = AppLogger()
    
    // MARK: - Log Categories
    
    enum Category: String {
        case app = "App"
        case recording = "Recording"
        case transcription = "Transcription"
        case model = "Model"
        case recovery = "Recovery"
        case memory = "Memory"
        case error = "Error"
        case ui = "UI"
    }
    
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }
    
    // MARK: - Configuration
    
    private let maxLogFileSize: Int = 5 * 1024 * 1024 // 5 MB
    private let maxLogFiles: Int = 3
    
    private let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Transcriptor")
    
    private var logsDir: URL {
        appSupportDir.appendingPathComponent("Logs")
    }
    
    private var currentLogFile: URL {
        logsDir.appendingPathComponent("app.log")
    }
    
    // System logger for Console.app
    private let osLog = OSLog(subsystem: "com.transcriptor.app", category: "general")
    
    // File writing queue
    private let writeQueue = DispatchQueue(label: "com.transcriptor.logger", qos: .utility)
    
    // MARK: - Initialization
    
    private init() {
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        
        // Log app start
        log("App launched", category: .app, metadata: [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString
        ])
    }
    
    // MARK: - Public Logging Methods
    
    /// Log an event with optional metadata
    func log(_ message: String, level: Level = .info, category: Category, metadata: [String: String]? = nil) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        
        var logLine = "[\(timestamp)] [\(level.rawValue)] [\(category.rawValue)] \(message)"
        
        if let metadata = metadata, !metadata.isEmpty {
            let metaString = metadata.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            logLine += " | \(metaString)"
        }
        
        // Write to file
        writeQueue.async { [weak self] in
            self?.writeToFile(logLine)
        }
        
        // Also log to system (visible in Console.app)
        switch level {
        case .debug:
            os_log(.debug, log: osLog, "%{public}@", logLine)
        case .info:
            os_log(.info, log: osLog, "%{public}@", logLine)
        case .warning:
            os_log(.error, log: osLog, "%{public}@", logLine)
        case .error:
            os_log(.fault, log: osLog, "%{public}@", logLine)
        }
        
        #if DEBUG
        print("📝 \(logLine)")
        #endif
    }
    
    /// Log an error with full context
    func logError(_ error: Error, context: String, category: Category) {
        log("\(context): \(error.localizedDescription)", level: .error, category: category, metadata: [
            "errorType": String(describing: type(of: error)),
            "errorDescription": error.localizedDescription
        ])
    }
    
    // MARK: - Diagnostic Export
    
    /// Get all log content for user export (for bug reports)
    func exportLogs() -> String {
        var allLogs = ""
        
        // Read current log
        if let currentContent = try? String(contentsOf: currentLogFile, encoding: .utf8) {
            allLogs += "=== Current Log ===\n\(currentContent)\n\n"
        }
        
        // Read archived logs
        let archivedLogs = getArchivedLogFiles()
        for (index, logFile) in archivedLogs.enumerated() {
            if let content = try? String(contentsOf: logFile, encoding: .utf8) {
                allLogs += "=== Archive \(index + 1) ===\n\(content)\n\n"
            }
        }
        
        // Add system info header
        let header = """
        =====================================
        TRANSCRIPTORX DIAGNOSTIC REPORT
        Generated: \(Date())
        =====================================
        
        System Info:
        - macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        - Memory: \(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)) GB
        - Processors: \(ProcessInfo.processInfo.processorCount)
        
        =====================================
        
        
        """
        
        return header + allLogs
    }
    
    /// Export logs to a temporary file and return its URL
    func exportLogsToFile() -> URL? {
        let content = exportLogs()
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriptor_diagnostics_\(Date().timeIntervalSince1970).txt")
        
        do {
            try content.write(to: exportURL, atomically: true, encoding: .utf8)
            return exportURL
        } catch {
            return nil
        }
    }
    
    /// Get recent log entries (for in-app viewer)
    func getRecentLogs(limit: Int = 100) -> [String] {
        guard let content = try? String(contentsOf: currentLogFile, encoding: .utf8) else {
            return []
        }
        
        let lines = content.components(separatedBy: .newlines)
        return Array(lines.suffix(limit))
    }
    
    // MARK: - Private Helpers
    
    private func writeToFile(_ line: String) {
        let lineWithNewline = line + "\n"
        
        // Check if file exists
        if !FileManager.default.fileExists(atPath: currentLogFile.path) {
            FileManager.default.createFile(atPath: currentLogFile.path, contents: nil)
        }
        
        // Check file size and rotate if needed
        if let attributes = try? FileManager.default.attributesOfItem(atPath: currentLogFile.path),
           let size = attributes[.size] as? Int,
           size > maxLogFileSize {
            rotateLogFiles()
        }
        
        // Append to file
        if let handle = try? FileHandle(forWritingTo: currentLogFile) {
            handle.seekToEndOfFile()
            if let data = lineWithNewline.data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        } else {
            // File doesn't exist or can't be opened, create it
            try? lineWithNewline.write(to: currentLogFile, atomically: true, encoding: .utf8)
        }
    }
    
    private func rotateLogFiles() {
        // Remove oldest log if at limit
        let archivedLogs = getArchivedLogFiles()
        if archivedLogs.count >= maxLogFiles - 1 {
            if let oldest = archivedLogs.last {
                try? FileManager.default.removeItem(at: oldest)
            }
        }
        
        // Rename current to archived
        let archiveName = "app_\(Int(Date().timeIntervalSince1970)).log"
        let archiveURL = logsDir.appendingPathComponent(archiveName)
        try? FileManager.default.moveItem(at: currentLogFile, to: archiveURL)
    }
    
    private func getArchivedLogFiles() -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.creationDateKey]) else {
            return []
        }
        
        return contents
            .filter { $0.lastPathComponent.hasPrefix("app_") && $0.pathExtension == "log" }
            .sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                return date1 > date2
            }
    }
    
    // MARK: - Cleanup
    
    /// Clear all logs (user requested)
    func clearLogs() {
        try? FileManager.default.removeItem(at: currentLogFile)
        for logFile in getArchivedLogFiles() {
            try? FileManager.default.removeItem(at: logFile)
        }
        
        log("Logs cleared by user", category: .app)
    }
}

// MARK: - Convenience Extensions

extension AppLogger {
    /// Log memory usage
    func logMemoryUsage() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            let usedMB = Double(info.resident_size) / (1024 * 1024)
            log("Memory usage", category: .memory, metadata: [
                "resident_mb": String(format: "%.1f", usedMB)
            ])
        }
    }
    
    /// Log model loading/unloading
    func logModelEvent(_ event: String, modelId: String, durationMs: Int? = nil) {
        var metadata: [String: String] = ["modelId": modelId]
        if let duration = durationMs {
            metadata["duration_ms"] = String(duration)
        }
        log(event, category: .model, metadata: metadata)
    }
}
