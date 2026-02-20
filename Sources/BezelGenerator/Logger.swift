//
// BezelGenerator
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

// MARK: - Logger

final class Logger {

    // MARK: - ANSI codes

    private enum ANSI {
        static let reset         = "\u{1B}[0m"
        static let dim           = "\u{1B}[2m"
        static let bold          = "\u{1B}[1m"

        // Bright foreground colors
        static let brightRed     = "\u{1B}[91m"
        static let brightGreen   = "\u{1B}[92m"
        static let brightYellow  = "\u{1B}[93m"
        static let brightBlue    = "\u{1B}[94m"
        static let brightMagenta = "\u{1B}[95m"
        static let brightCyan    = "\u{1B}[96m"
        static let brightWhite   = "\u{1B}[97m"

        // Background colors
        static let bgBlue        = "\u{1B}[44m"
    }

    // MARK: - State

    private let isVerbose:   Bool
    private let logFilePath: String?

    // MARK: - Init

    init(verbose: Bool, logDirectory: String = "./logs") {
        self.isVerbose = verbose
        if verbose {
            self.logFilePath = Self.setupLogFile(in: logDirectory)
        } else {
            self.logFilePath = nil
        }
    }

    // MARK: - Log rotation

    /// Archives the current `_console.log` and purges old logs, keeping 14 total.
    /// Returns the path for the new active `_console.log`.
    private static func setupLogFile(in logDir: String) -> String {
        let fm      = FileManager.default
        let logFile = "\(logDir)/_console.log"

        if !fm.fileExists(atPath: logDir) {
            try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        }

        if fm.fileExists(atPath: logFile) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let ts = formatter.string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: ".", with: "-")
            let archive = "\(logDir)/console_\(ts).log"
            try? fm.moveItem(atPath: logFile, toPath: archive)
            purgeOldLogs(in: logDir)
        }

        return logFile
    }

    /// Keeps only the 13 newest log files (so total including new session = 14 max).
    private static func purgeOldLogs(in logDir: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: logDir) else { return }

        let sorted = entries.compactMap { name -> (String, Date)? in
            let path = "\(logDir)/\(name)"
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { return nil }
            return (name, mtime)
        }.sorted { $0.1 > $1.1 }

        for (name, _) in sorted.dropFirst(13) {
            try? fm.removeItem(atPath: "\(logDir)/\(name)")
        }
    }

    // MARK: - Internal write

    private func write(_ line: String, toStderr: Bool = false) {
        let handle = toStderr ? FileHandle.standardError : FileHandle.standardOutput
        if let data = (line + "\n").data(using: .utf8) {
            handle.write(data)
        }

        guard let path = logFilePath else { return }
        let entry = "[\(timestamp())] \(line)\n"
        guard let entryData = entry.data(using: .utf8) else { return }

        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(entryData)
                handle.closeFile()
            }
        } else {
            fm.createFile(atPath: path, contents: entryData)
        }
    }

    private func timestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .medium
        return fmt.string(from: Date())
    }

    // MARK: - Public log API

    func error(_ message: String, indent: Int = 0) {
        let pad = String(repeating: " ", count: indent)
        write("\(pad)\(ANSI.brightRed)[✗]\(ANSI.reset) \(message)", toStderr: true)
    }

    func warn(_ message: String, indent: Int = 0) {
        let pad = String(repeating: " ", count: indent)
        write("\(pad)\(ANSI.brightYellow)[!]\(ANSI.reset) \(message)", toStderr: true)
    }

    func info(_ message: String, indent: Int = 0) {
        guard isVerbose else { return }
        let pad = String(repeating: " ", count: indent)
        write("\(pad)\(ANSI.brightCyan)[i]\(ANSI.reset) \(message)")
    }

    func success(_ message: String, indent: Int = 0) {
        guard isVerbose else { return }
        let pad = String(repeating: " ", count: indent)
        write("\(pad)\(ANSI.brightGreen)[✓]\(ANSI.reset) \(message)")
    }

    /// Dim secondary detail line. The caller is responsible for any `- ` prefix.
    func log(_ message: String, indent: Int = 0) {
        guard isVerbose else { return }
        let pad = String(repeating: " ", count: indent)
        write("\(pad)\(ANSI.dim)\(message)\(ANSI.reset)")
    }

    func banner(_ message: String) {
        guard isVerbose else { return }
        write("\n\(ANSI.bold)\(ANSI.bgBlue)\(ANSI.brightWhite) \(message) \(ANSI.reset)\n")
    }
}
