//
// BezelGenerator
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import ArgumentParser
import Foundation

// MARK: - generate-docs subcommand

struct GenerateDocs: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "generate-docs",
        abstract: "Generates SupportedDeviceList.md from the minified bezel.min.json resource.",
        discussion: """
            Reads the minified bezel JSON and produces a markdown table of all supported
            devices, grouped by category (iPad, iPhone, iPod).

            Designed to be run from the Generator/ directory:
              swift run BezelGenerator generate-docs

            Or from the repo root via the pre-push hook:
              (cd ./Generator && swift run BezelGenerator generate-docs)
            """
    )

    // MARK: - Options

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Path to the minified bezel.min.json input file.",
            valueName: "path"
        )
    )
    var input: String = "../Sources/BezelKit/Resources/bezel.min.json"

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Output path for SupportedDeviceList.md.",
            valueName: "path"
        )
    )
    var output: String = "../SupportedDeviceList.md"

    @Flag(
        name: .long,
        help: """
            After generating docs, commit both repos (yyyy-MM-dd), push, tag the \
            parent repo (yy.m.d), and publish a GitHub release with a device diff \
            as the release notes. Requires the `gh` CLI to be installed.
            """
    )
    var release: Bool = false

    // MARK: - Run

    mutating func run() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: input))
        let json = try JSONDecoder().decode(BezelMinJSON.self, from: data)
        let markdown = buildMarkdown(from: json)
        try markdown.write(toFile: output, atomically: true, encoding: .utf8)
        print("Generated: \(output)")

        if release {
            let manager = ReleaseManager(inputPath: input)
            try manager.run()
        }
    }

    // MARK: - Markdown builder

    private func buildMarkdown(from json: BezelMinJSON) -> String {
        var md = "# Supported Device List\n\n"
        md += "Below is the current supported list of devices `BezelKit` can return data for.\n\n"

        let categories: [(String, [String: DeviceInfo])] = [
            ("iPad",   json.devices.iPad),
            ("iPhone", json.devices.iPhone),
            ("iPod",   json.devices.iPod)
        ]

        for (category, devices) in categories {
            if devices.isEmpty { continue }
            md += "## \(category)\n\n"
            md += buildTable(devices: devices)
            md += "\n"
        }

        md += buildMultiScreenSection(categories.flatMap { $0.1 })

        md += "---\n\n"
        let authorCell  = "[\(json.metadata.author)](\(json.metadata.website))"
        let projectCell = json.metadata.project
        let col1 = max("Author".count,  authorCell.count)
        let col2 = max("Project".count, projectCell.count)
        md += "| \("Author".padding(toLength: col1, withPad: " ", startingAt: 0)) | \("Project".padding(toLength: col2, withPad: " ", startingAt: 0)) |\n"
        md += "| \(String(repeating: "-", count: col1)) | \(String(repeating: "-", count: col2)) |\n"
        md += "| \(authorCell.padding(toLength: col1, withPad: " ", startingAt: 0)) | \(projectCell.padding(toLength: col2, withPad: " ", startingAt: 0)) |\n"

        return md.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Lists per-screen corner radii for devices whose display is not one uniform shape.
    ///
    /// The main table can only show one number per device, so these devices get a second
    /// table with each screen's four physical corners (portrait-up).
    private func buildMultiScreenSection(_ devices: [(key: String, value: DeviceInfo)]) -> String {
        let rows: [[String]] = devices
            .filter { !($0.value.screens ?? []).isEmpty }
            .sorted { DatabaseManager.deviceKeyComparator($0.key, $1.key) }
            .flatMap { id, device in
                (device.screens ?? []).map { screen in
                    [
                        device.name,
                        "`\(id)`",
                        screen.name ?? "",
                        screen.nativeSize.map { formatBezel($0) }.joined(separator: " × "),
                        formatBezel(screen.corners.topLeft),
                        formatBezel(screen.corners.topRight),
                        formatBezel(screen.corners.bottomLeft),
                        formatBezel(screen.corners.bottomRight)
                    ]
                }
            }
        guard !rows.isEmpty else { return "" }

        let headers = ["Device", "Model Identifier", "Screen", "Native Size (px)", "Top Left", "Top Right", "Bottom Left", "Bottom Right"]
        let widths = headers.indices.map { c in rows.reduce(headers[c].count) { max($0, $1[c].count) } }
        func line(_ cells: [String]) -> String {
            "| " + cells.indices.map { cells[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: " | ") + " |\n"
        }

        var md = "## Multi-screen devices\n\n"
        md += "These devices have screens with different corner radii. `BezelKit` picks the active screen and rotates its corners to match the interface orientation. Values are the physical corners with the device held upright (portrait), in points.\n\n"
        md += line(headers)
        md += "| " + widths.map { String(repeating: "-", count: $0) }.joined(separator: " | ") + " |\n"
        for row in rows { md += line(row) }
        return md + "\n"
    }

    /// Builds a padded, markdownlint-compliant table for one device category.
    private func buildTable(devices: [String: DeviceInfo]) -> String {
        let sortedKeys = devices.keys.sorted(by: DatabaseManager.deviceKeyComparator)

        // Collect cell strings for every row
        let rows: [(col1: String, col2: String, col3: String)] = sortedKeys.map { modelId in
            let device = devices[modelId]!
            return (device.name, "`\(modelId)`", "`\(formatBezel(device.bezel))`")
        }

        // Compute column widths: max of header vs. each data cell
        let w1 = rows.reduce("Device".count)           { max($0, $1.col1.count) }
        let w2 = rows.reduce("Model Identifier".count) { max($0, $1.col2.count) }
        let w3 = rows.reduce("Bezel Size".count)       { max($0, $1.col3.count) }

        func pad(_ s: String, _ w: Int) -> String {
            s.padding(toLength: w, withPad: " ", startingAt: 0)
        }

        var table = ""
        table += "| \(pad("Device", w1)) | \(pad("Model Identifier", w2)) | \(pad("Bezel Size", w3)) |\n"
        table += "| \(String(repeating: "-", count: w1)) | \(String(repeating: "-", count: w2)) | \(String(repeating: "-", count: w3)) |\n"
        for row in rows {
            table += "| \(pad(row.col1, w1)) | \(pad(row.col2, w2)) | \(pad(row.col3, w3)) |\n"
        }
        return table
    }

    /// Formats a Double bezel value the same way JavaScript does:
    /// whole numbers have no decimal point (e.g. 62.0 → "62", 47.33 → "47.33").
    private func formatBezel(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0, !value.isInfinite, !value.isNaN {
            return String(Int(value))
        }
        return String(value)
    }
}

// MARK: - Minimal decodable type for bezel.min.json

/// The minified JSON omits `pending` and `problematic`, so we use a separate
/// type rather than the full `DeviceDatabase`.
private struct BezelMinJSON: Decodable {
    let metadata: Metadata
    let devices:  DeviceCategories

    enum CodingKeys: String, CodingKey {
        case metadata = "_metadata"
        case devices
    }
}
