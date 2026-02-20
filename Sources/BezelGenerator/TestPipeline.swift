//
// BezelGenerator
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import ArgumentParser
import Foundation

// MARK: - test subcommand

struct TestPipeline: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Runs the full simulator pipeline on one device without touching the database.",
        discussion: """
            Builds FetchBezel, boots the named simulator, reads its bezel value, then
            tears down — without reading or writing apple-device-database.json.

            Example:
              swift run BezelGenerator test --name "iPhone 16 Pro"
            """
    )

    // MARK: - Options

    @Option(
        name: [.short, .long],
        help: ArgumentHelp(
            "Simulator display name to test (e.g. \"iPhone 16 Pro\").",
            valueName: "name"
        )
    )
    var name: String

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Path to the FetchBezel Xcode project.",
            valueName: "path"
        )
    )
    var project: String = "./FetchBezel/FetchBezel.xcodeproj"

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Scheme name for the FetchBezel Xcode project.",
            valueName: "name"
        )
    )
    var scheme: String = "FetchBezel"

    @Option(
        name: [.long, .customShort("b")],
        help: ArgumentHelp(
            "Bundle ID for the FetchBezel app.",
            valueName: "id"
        )
    )
    var bundleId: String = "com.markbattistella.FetchBezel"

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Output directory for Xcode build artifacts.",
            valueName: "path"
        )
    )
    var appOutput: String = "./output"

    // MARK: - Run

    mutating func run() async throws {
        let logger = Logger(verbose: true, logDirectory: "./logs")

        let runner = SimulatorRunner(
            logger:      logger,
            bundleId:    bundleId,
            projectPath: project,
            scheme:      scheme,
            appOutput:   appOutput
        )

        // Find an existing available simulator, or install a fresh one
        let udid: String
        if let existing = try runner.findSimulator(named: name) {
            logger.info("Found existing simulator: \(name)", indent: 2)
            udid = existing.udid
        } else {
            logger.info("No existing simulator found — looking for a supported runtime...", indent: 2)
            guard let runtime = try runner.findSupportedRuntime(for: name) else {
                logger.warn("No supported runtime for: \(name)")
                logger.log("- Install the appropriate Xcode simulator runtime and try again", indent: 6)
                return
            }
            let newUdid = try runner.installSimulator(
                name:        name,
                simulatorId: runtime.simulatorId,
                runtimeId:   runtime.runtimeId
            )
            guard !newUdid.isEmpty else {
                logger.warn("Failed to install simulator for: \(name)")
                return
            }
            logger.success("Installed simulator: \(name) (\(newUdid))", indent: 2)
            udid = newUdid
        }

        // Build app and run the full lifecycle
        let appPath = try runner.buildApp()
        let resolved = ResolvedSimulator(identifiers: ["test"], name: name, udid: udid)
        let result = try await runner.runSimulator(resolved, appPath: appPath, index: 0, total: 1)

        // Clean up build artifacts (same as the main generate command does)
        if (try? FileManager.default.removeItem(atPath: appOutput)) != nil {
            logger.success("Deleted build directory: \(appOutput)")
        }

        // Report outcome
        if let bezel = result.bezel {
            logger.success("Test passed — '\(name)': bezel = \(bezel)")
        } else {
            logger.warn("No bezel data returned for '\(name)'")
        }
    }
}
