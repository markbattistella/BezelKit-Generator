//
// BezelGenerator
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

// MARK: - Shell errors

enum ShellError: Error, CustomStringConvertible {
    case nonZeroExit(command: String, code: Int32)
    case launchFailed(command: String, underlying: Error)

    var description: String {
        switch self {
        case .nonZeroExit(let cmd, let code):
            return "Command exited with code \(code): \(cmd)"
        case .launchFailed(let cmd, let underlying):
            return "Failed to launch '\(cmd)': \(underlying.localizedDescription)"
        }
    }
}

// MARK: - Shell runner

struct Shell {

    // MARK: - Core runner

    /// Runs an executable with the given arguments, captures stdout, and returns it.
    /// Arguments are passed directly — no shell injection risk.
    @discardableResult
    static func run(
        _ executable: String,
        arguments: [String],
        mergeStderr: Bool = false
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        if mergeStderr {
            process.standardError = stdoutPipe
        } else {
            process.standardError = FileHandle.standardError
        }

        do {
            try process.run()
        } catch {
            let cmd = ([executable] + arguments).joined(separator: " ")
            throw ShellError.launchFailed(command: cmd, underlying: error)
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let cmd = ([executable] + arguments).joined(separator: " ")
            throw ShellError.nonZeroExit(command: cmd, code: process.terminationStatus)
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - xcrun convenience

    /// Runs an xcrun command. Wraps the given subcommand arguments.
    @discardableResult
    static func xcrun(_ arguments: String...) throws -> String {
        try run("/usr/bin/xcrun", arguments: Array(arguments))
    }

    /// Runs an xcrun command with an array of arguments.
    @discardableResult
    static func xcrun(args: [String]) throws -> String {
        try run("/usr/bin/xcrun", arguments: args)
    }

    // MARK: - Async delay

    static func sleep(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
