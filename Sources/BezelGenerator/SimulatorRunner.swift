//
// BezelGenerator
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

// MARK: - Simulator runner

struct SimulatorRunner {

    let logger:      Logger
    let bundleId:    String
    let projectPath: String
    let scheme:      String
    let appOutput:   String

    // MARK: - Discover simulators

    func availableSimulators() throws -> [String: [SimulatorDevice]] {
        let json = try Shell.xcrun("simctl", "list", "devices", "-j")
        let list = try JSONDecoder().decode(SimctlDeviceList.self, from: Data(json.utf8))
        return list.devices
    }

    func availableRuntimes() throws -> [SimulatorRuntime] {
        let json = try Shell.xcrun("simctl", "list", "runtimes", "-j")
        let list = try JSONDecoder().decode(SimctlRuntimeList.self, from: Data(json.utf8))
        return list.runtimes
            .filter { $0.isAvailable }
            .sorted { (Double($0.version) ?? 0) > (Double($1.version) ?? 0) }
    }

    /// Returns the first simulator with the given name that has an available runtime.
    /// Stale entries (runtime deleted, `isAvailable == false`) are skipped so a fresh
    /// simulator can be created instead.
    func findSimulator(named name: String) throws -> SimulatorDevice? {
        let simulators = try availableSimulators()
        for (_, devices) in simulators {
            if let found = devices.first(where: { $0.name == name && $0.isAvailable }) {
                return found
            }
        }
        return nil
    }

    func findSupportedRuntime(for name: String) throws -> (simulatorId: String, runtimeId: String)? {
        let runtimes = try availableRuntimes()   // already filtered to isAvailable == true
        for runtime in runtimes {
            if let device = runtime.supportedDeviceTypes.first(where: { $0.name == name }) {
                return (device.identifier, runtime.identifier)
            }
        }
        return nil
    }

    // MARK: - Install simulator

    func installSimulator(name: String, simulatorId: String, runtimeId: String) throws -> String {
        try Shell.xcrun("simctl", "create", name, simulatorId, runtimeId)
    }

    // MARK: - Resolve pending → simulators

    /// Groups pending devices by simulator name so identifiers that share a name
    /// (e.g. iPad17,1 and iPad17,2 are both "iPad Pro 11-inch (M5)") are processed
    /// in a single simulator boot rather than once each.
    func resolveSimulators(
        from pending: [String: PendingDeviceInfo]
    ) throws -> (found: [ResolvedSimulator], unfound: [ResolvedSimulator]) {
        var found:   [ResolvedSimulator] = []
        var unfound: [ResolvedSimulator] = []

        // Group identifiers by simulator display name
        var groups: [String: [String]] = [:]   // name → [identifier]
        for (identifier, info) in pending {
            groups[info.name, default: []].append(identifier)
        }

        for (name, identifiers) in groups {
            let sortedIdentifiers = identifiers.sorted()

            if let existing = try findSimulator(named: name) {
                logger.log("- Found '\(name)' → \(sortedIdentifiers.joined(separator: ", "))", indent: 4)
                found.append(ResolvedSimulator(
                    identifiers: sortedIdentifiers,
                    name:        name,
                    udid:        existing.udid
                ))
                continue
            }

            guard let runtime = try findSupportedRuntime(for: name) else {
                logger.warn("No supported runtime for: \(name)")
                unfound.append(ResolvedSimulator(identifiers: sortedIdentifiers, name: name, udid: ""))
                continue
            }

            let udid = try installSimulator(
                name:        name,
                simulatorId: runtime.simulatorId,
                runtimeId:   runtime.runtimeId
            )

            if udid.isEmpty {
                logger.warn("Failed to install simulator for: \(name)")
                unfound.append(ResolvedSimulator(identifiers: sortedIdentifiers, name: name, udid: ""))
            } else {
                logger.log("- Installed '\(name)' → \(sortedIdentifiers.joined(separator: ", "))", indent: 4)
                found.append(ResolvedSimulator(identifiers: sortedIdentifiers, name: name, udid: udid))
            }
        }

        return (found, unfound)
    }

    // MARK: - Build FetchBezel app

    /// Builds the Xcode project silently. On failure, prints the captured output.
    /// Returns the path to the compiled .app bundle.
    func buildApp() throws -> String {
        logger.info("Building FetchBezel app...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = [
            "-project", projectPath,
            "-scheme",  scheme,
            "-sdk",     "iphonesimulator",
            "-configuration", "Debug",
            "-derivedDataPath", appOutput,
            "clean", "build"
        ]

        // Capture all output silently — only surface it on failure
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = pipe

        try process.run()
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            // Print the captured build log so the user can diagnose the failure
            let outputString = String(data: outputData, encoding: .utf8) ?? ""
            for line in outputString.components(separatedBy: "\n") {
                if !line.lowercased().contains("warning:") {
                    logger.error(line)
                }
            }
            throw ShellError.nonZeroExit(command: "xcodebuild", code: process.terminationStatus)
        }

        let appPath = "\(appOutput)/Build/Products/Debug-iphonesimulator/\(scheme).app"
        logger.success("Built app: \(appPath)")
        return appPath
    }

    // MARK: - Current simulator state

    private func currentState(of udid: String) throws -> String {
        let json = try Shell.xcrun("simctl", "list", "devices", "-j")
        let list = try JSONDecoder().decode(SimctlDeviceList.self, from: Data(json.utf8))
        for (_, devices) in list.devices {
            if let dev = devices.first(where: { $0.udid == udid }) {
                return dev.state
            }
        }
        return "Shutdown"
    }

    // MARK: - Per-simulator lifecycle

    func runSimulator(
        _ sim: ResolvedSimulator,
        appPath: String,
        index: Int,
        total: Int
    ) async throws -> ResolvedSimulator {

        logger.banner("** Start work on simulator: \(index + 1) / \(total) **")
        logger.info("Current device: \(sim.name)", indent: 2)
        logger.log("- Name:        \(sim.name)",                                    indent: 6)
        logger.log("- Identifiers: \(sim.identifiers.joined(separator: ", "))",     indent: 6)
        logger.log("- UDID:        \(sim.udid)",                                    indent: 6)

        // Ensure shutdown before boot
        let state = try currentState(of: sim.udid)
        if state != "Shutdown" {
            logger.warn("Simulator not shut down, shutting down now", indent: 2)
            try Shell.xcrun("simctl", "shutdown", sim.udid)
            logger.success("Simulator shut down", indent: 2)
        }

        // Boot and wait until fully ready before proceeding
        logger.info("Booting the simulator for testing", indent: 2)
        try Shell.xcrun("simctl", "boot", sim.udid)
        logger.log("- Waiting for simulator to be ready", indent: 6)
        try Shell.xcrun("simctl", "bootstatus", sim.udid, "-b")

        // Install + launch
        logger.info("Installing local project with bundle ID: \(bundleId)", indent: 2)
        logger.log("- Installing app", indent: 6)
        try Shell.xcrun("simctl", "install", sim.udid, appPath)

        logger.log("- Launching app", indent: 6)
        try Shell.xcrun("simctl", "launch", sim.udid, bundleId)

        // Wait for app to write output
        logger.log("- Waiting 5 seconds", indent: 6)
        await Shell.sleep(seconds: 5)

        // Read bezel data
        logger.log("- Reading bezel data from device", indent: 6)
        let containerPath = try Shell.xcrun("simctl", "get_app_container", sim.udid, bundleId, "data")
        let outputJsonPath = "\(containerPath)/Documents/output.json"
        let outputData = try Data(contentsOf: URL(fileURLWithPath: outputJsonPath))
        let appOutputData = try JSONDecoder().decode(AppOutput.self, from: outputData)

        var result = sim
        result.bezel = appOutputData.bezel
        logger.log("- Found device data (bezel: \(appOutputData.bezel))", indent: 6)

        // Second wait
        logger.log("- Waiting 5 seconds", indent: 6)
        await Shell.sleep(seconds: 5)

        // Teardown
        logger.log("- Terminating app", indent: 6)
        _ = try? Shell.xcrun("simctl", "terminate", sim.udid, bundleId)

        logger.log("- Deleting app from simulator", indent: 6)
        try Shell.xcrun("simctl", "uninstall", sim.udid, bundleId)

        logger.info("Shutting down the simulator\n", indent: 2)
        try Shell.xcrun("simctl", "shutdown", sim.udid)

        return result
    }

    // MARK: - Run all simulators sequentially

    /// Runs each simulator, collecting bezel data. Any simulator that fails (e.g. missing
    /// runtime, boot error) is moved to `failed` rather than crashing the whole run.
    func generateBezelData(
        for simulators: [ResolvedSimulator]
    ) async throws -> (processed: [ResolvedSimulator], failed: [ResolvedSimulator]) {
        let appPath = try buildApp()
        var processed: [ResolvedSimulator] = []
        var failed:    [ResolvedSimulator] = []

        for (index, sim) in simulators.enumerated() {
            do {
                let result = try await runSimulator(sim, appPath: appPath, index: index, total: simulators.count)
                processed.append(result)
            } catch {
                logger.warn("Simulator '\(sim.name)' failed: \(error.localizedDescription)")
                logger.log("- \(sim.identifiers.joined(separator: ", ")) → moving to problematic", indent: 6)
                failed.append(sim)
            }
        }

        return (processed, failed)
    }
}
