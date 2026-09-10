//
// BezelGenerator
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import ArgumentParser
import Foundation

// MARK: - Verification mode

/// How aggressively `scan` boots simulators to confirm profile-derived values.
enum VerificationMode: String, ExpressibleByArgument, CaseIterable, Sendable {

    /// Never boot. Report only — useful for a fast local look at what changed.
    case none

    /// Boot only devices ``Triage`` could not vouch for. The default.
    case flagged

    /// Boot everything not yet confirmed by a simulator: triage-flagged devices, every newly
    /// discovered device, and every entry still marked ``DeviceSource/profile`` from an
    /// earlier run. This is the mode for scheduled CI, where boots are cheap and the goal is
    /// that no value stays plist-derived for long.
    case unverified
}

// MARK: - scan subcommand

struct ScanCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Discovers device bezel data from Xcode's device type catalog.",
        discussion: """
            Reads DeviceCornerRadius from the .simdevicetype bundles Xcode installs, diffs it
            against the database, and decides which values can be accepted directly and which
            need confirming with a simulator boot.

            Reports without writing by default:
              swift run BezelGenerator scan

            Apply the results, booting simulators where confirmation is needed:
              swift run BezelGenerator scan --apply

            Scheduled CI use — confirm everything not yet simulator-verified:
              swift run BezelGenerator scan --apply --verify unverified
            """
    )

    // MARK: - Options

    @Option(name: .long, help: ArgumentHelp("Path to the Apple device database JSON file.", valueName: "path"))
    var database: String = "./apple-device-database.json"

    @Option(name: .long, help: ArgumentHelp("Output path for the minified bezel.min.json package resource.", valueName: "path"))
    var output: String = "../Sources/BezelKit/Resources/bezel.min.json"

    @Option(name: .long, help: ArgumentHelp("Path to the FetchBezel Xcode project.", valueName: "path"))
    var project: String = "./FetchBezel/FetchBezel.xcodeproj"

    @Option(name: .long, help: ArgumentHelp("Scheme name for the FetchBezel Xcode project.", valueName: "name"))
    var scheme: String = "FetchBezel"

    @Option(name: [.long, .customShort("b")], help: ArgumentHelp("Bundle ID for the FetchBezel app.", valueName: "id"))
    var bundleId: String = "com.markbattistella.FetchBezel"

    @Option(name: .long, help: ArgumentHelp("Output directory for Xcode build artifacts.", valueName: "path"))
    var appOutput: String = "./output"

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Directory containing .simdevicetype bundles. Repeatable. Defaults to the "
            + "CoreSimulator profiles directory plus the selected Xcode's platforms.",
            valueName: "path"
        )
    )
    var profilesPath: [String] = []

    @Option(
        name: .long,
        help: ArgumentHelp("How much to confirm by booting simulators.", valueName: "none|flagged|unverified")
    )
    var verify: VerificationMode = .flagged

    @Flag(name: .long, help: "Write the results to the database and package resource. Without this, scan only reports.")
    var apply: Bool = false

    @Option(name: .long, help: ArgumentHelp("Write a markdown summary of the scan to this path.", valueName: "path"))
    var summary: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Enable verbose logging. Use --no-verbose to silence output.")
    var verbose: Bool = true

    // MARK: - Run

    mutating func run() async throws {
        let logger = Logger(verbose: verbose, logDirectory: "./logs")
        let dbManager = DatabaseManager(databasePath: database, logger: logger)

        logger.info("Loading database: \(database)")
        var db = try dbManager.loadDatabase()

        logger.info("Reading Xcode device type catalog...")
        let searchPaths = profilesPath.isEmpty
            ? DeviceProfileCatalog.defaultSearchPaths()
            : profilesPath
        let catalog = DeviceProfileCatalog(logger: logger).load(searchPaths: searchPaths)

        guard !catalog.isEmpty else {
            logger.error("No .simdevicetype bundles found. Searched:")
            for path in searchPaths { logger.log("- \(path)", indent: 6) }
            throw ExitCode.failure
        }
        logger.success("Catalog: \(catalog.count) device identifier(s)")

        // Compare, triage, and decide what needs a simulator
        var report = buildReport(database: db, catalog: catalog)
        logger.info("Comparing against \(db.allDevices.count) known device(s)...")

        let toVerify = report.identifiersNeedingSimulator(mode: verify, database: db, catalog: catalog)
        if !toVerify.isEmpty {
            logger.info("Booting simulators to confirm \(toVerify.count) device(s)...")
            try await runVerification(
                for:      toVerify,
                catalog:  catalog,
                database: db,
                report:   &report,
                logger:   logger
            )
        } else if verify != .none {
            logger.success("Nothing needs simulator confirmation")
        }

        // Fold outcomes back into the database
        applyOutcomes(report: report, into: &db)

        render(report: report, logger: logger)

        if let summary {
            try report.markdown().write(toFile: summary, atomically: true, encoding: .utf8)
            logger.info("Wrote summary: \(summary)")
        }

        guard apply else {
            logger.warn("Dry run — nothing written. Re-run with --apply to save.")
            return
        }

        guard report.hasChanges else {
            logger.success("Database already up to date 🎉")
            return
        }

        logger.info("Saving output files...")
        try dbManager.save(database: db, cacheOutputPath: database, minifiedOutputPath: output)
        dbManager.deleteOutputDirectory(appOutput)
        logger.success("Done.")
    }
}

// MARK: - Building the report

extension ScanCommand {

    /// Diffs the catalog against the database and runs every difference past ``Triage``.
    private func buildReport(database db: DeviceDatabase, catalog: [String: DeviceProfile]) -> ScanReport {
        let triage = Triage(database: db, catalog: catalog)
        var report = ScanReport()

        for (identifier, profile) in catalog.sorted(by: { $0.key < $1.key }) {
            guard profile.category != nil else { continue }
            let verdict = triage.verdict(for: profile)

            guard let existing = db[identifier] else {
                report.entries.append(
                    ScanEntry(
                        identifier: identifier,
                        name: profile.simulatorName,
                        existingValue: nil,
                        existingSource: nil,
                        profileValue: profile.cornerRadius,
                        kind: .new,
                        verdict: verdict,
                        outcome: verdict.needsVerification
                            ? .awaitingVerification(verdict.reason)
                            : .accepted(source: .profile, value: profile.cornerRadius, note: verdict.reason)
                    )
                )
                continue
            }

            // Names come from Xcode, so the catalog is authoritative for labelling even when
            // the measurement itself is not in question.
            if existing.name != profile.simulatorName {
                report.renames.append((identifier, existing.name, profile.simulatorName))
            }

            let agrees = abs(round(profile.cornerRadius * 100) / 100 - existing.bezel) < 0.005
            if agrees {
                report.confirmedCount += 1
                continue
            }

            // A boot has already weighed this exact catalog value against the measured one
            // and the measurement won. Settled — don't re-open it every run.
            if existing.hasAdjudicated(profile.cornerRadius) {
                report.settledCount += 1
                continue
            }

            // A simulator-verified value is ground truth: a plist read never overwrites it.
            // Only a fresh boot can change it, so drift here is always a verification request.
            let outcome: ScanOutcome
            if existing.isRuntimeVerified {
                outcome = .awaitingVerification(
                    "database value is simulator-verified — a boot is required to change it"
                )
            } else if verdict.needsVerification {
                outcome = .awaitingVerification(verdict.reason)
            } else {
                outcome = .accepted(source: .profile, value: profile.cornerRadius, note: verdict.reason)
            }

            report.entries.append(
                ScanEntry(
                    identifier: identifier,
                    name: profile.simulatorName,
                    existingValue: existing.bezel,
                    existingSource: existing.source ?? .simulator,
                    profileValue: profile.cornerRadius,
                    kind: .drift,
                    verdict: verdict,
                    outcome: outcome
                )
            )
        }

        report.legacyOnlyCount = db.allDevices.keys.filter { catalog[$0] == nil }.count
        return report
    }
}
