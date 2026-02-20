//
// BezelGenerator
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import ArgumentParser
import Foundation

// MARK: - Entry point

@main
struct BezelGeneratorCLI: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "BezelGenerator",
        abstract: "Tools for generating and documenting BezelKit device data.",
        version: "3.0.0",
        subcommands: [GenerateData.self, GenerateDocs.self, TestPipeline.self],
        defaultSubcommand: GenerateData.self
    )
}

// MARK: - generate (default subcommand)

struct GenerateData: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Extracts bezel (corner radius) data from iOS simulators.",
        discussion: """
            Reads pending devices from the Apple device database, boots the corresponding
            iOS simulators, runs the FetchBezel app to capture each device's corner radius
            via the private UIScreen API, and writes the results back to the database.

            The tool is designed to be run from the Generator/ directory of the BezelKit repo.
            """
    )

    // MARK: - Options

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Path to the Apple device database JSON file.",
            valueName: "path"
        )
    )
    var database: String = "./apple-device-database.json"

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
            "Output path for the minified bezel.min.json package resource.",
            valueName: "path"
        )
    )
    var output: String = "../Sources/BezelKit/Resources/bezel.min.json"

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Output directory for Xcode build artifacts.",
            valueName: "path"
        )
    )
    var appOutput: String = "./output"

    @Flag(
        name: .long,
        inversion: .prefixedNo,
        help: "Enable verbose logging. Use --no-verbose to silence output."
    )
    var verbose: Bool = true

    // MARK: - Run

    mutating func run() async throws {
        let orchestrator = Orchestrator(config: self)
        try await orchestrator.run()
    }
}
