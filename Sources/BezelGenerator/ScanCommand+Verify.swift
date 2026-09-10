//
// BezelGenerator
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

// MARK: - Simulator verification

extension ScanCommand {
    /// Boots simulators for `targets` and folds the measured values back into the report.
    ///
    /// Reuses the same resolve/build/boot machinery as `generate`, so a value confirmed here
    /// is identical to one produced by a full run — it just covers a handful of devices
    /// instead of the whole database.
    func runVerification(
        for targets: [String: String],
        catalog: [String: DeviceProfile],
        database: DeviceDatabase,
        report: inout ScanReport,
        logger: Logger
    ) async throws {
        let runner = SimulatorRunner(
            logger: logger,
            bundleId: bundleId,
            projectPath: project,
            scheme: scheme,
            appOutput: appOutput
        )

        let pending = targets.mapValues { PendingDeviceInfo(name: $0) }
        let (found, unfound) = try runner.resolveSimulators(from: pending)

        var processed: [ResolvedSimulator] = []
        var failed: [ResolvedSimulator] = []

        if !found.isEmpty {
            (processed, failed) = try await runner.generateBezelData(for: found)
        }

        for sim in processed {
            guard let bezel = sim.bezel else { continue }
            for identifier in sim.identifiers {
                record(
                    identifier: identifier,
                    outcome: .verified(value: bezel, note: "confirmed by simulator boot"),
                    measuredName: sim.name,
                    catalog: catalog,
                    database: database,
                    report: &report
                )
            }
        }

        for sim in unfound + failed {
            for identifier in sim.identifiers {
                record(
                    identifier: identifier,
                    outcome: .verificationFailed("no simulator runtime available for '\(sim.name)'"),
                    measuredName: sim.name,
                    catalog: catalog,
                    database: database,
                    report: &report
                )
            }
        }
    }

    /// Updates the entry for `identifier`, creating one if verification reached past the diff
    /// (as ``VerificationMode/unverified`` does when promoting older profile-derived values).
    private func record(
        identifier: String,
        outcome: ScanOutcome,
        measuredName: String,
        catalog: [String: DeviceProfile],
        database: DeviceDatabase,
        report: inout ScanReport
    ) {
        var outcome = outcome

        if let index = report.entries.firstIndex(where: { $0.identifier == identifier }) {
            // A device the triage was willing to vouch for should not lose its value just
            // because no runtime happened to be installed to double-check it. Fall back to
            // the triage decision rather than dropping the device on the floor.
            if case .verificationFailed(let note) = outcome,
                case .trust(let reason) = report.entries[index].verdict
            {
                outcome = .accepted(
                    source: .profile,
                    value: report.entries[index].profileValue,
                    note: "\(reason) — \(note), so accepted without confirmation"
                )
            }
            report.entries[index].outcome = outcome
            return
        }

        guard let profile = catalog[identifier] else { return }
        let existing = database[identifier]

        // Verification we reached for but could not perform on an already-stored device
        // changes nothing, so it is not worth a report line.
        if case .verificationFailed = outcome, existing != nil { return }

        // Only worth reporting if the boot actually changed something — either the value
        // moved, or a profile-derived entry was promoted to simulator-verified.
        if case .verified(let value, _) = outcome,
            let existing,
            abs(existing.bezel - value) < 0.005,
            existing.isRuntimeVerified
        {
            return
        }

        report.entries.append(
            ScanEntry(
                identifier: identifier,
                name: measuredName,
                existingValue: existing?.bezel,
                existingSource: existing?.source ?? (existing != nil ? .simulator : nil),
                profileValue: profile.cornerRadius,
                kind: existing == nil ? .new : .drift,
                verdict: .trust(reason: "re-verified"),
                outcome: outcome
            )
        )
    }
}

// MARK: - Applying outcomes

extension ScanCommand {
    /// Writes accepted and verified values into the database, corrects names, and parks
    /// anything still unconfirmed in `problematic` so later runs retry it.
    func applyOutcomes(report: ScanReport, into database: inout DeviceDatabase) {
        for entry in report.entries {
            switch entry.outcome {
                case .accepted(let source, let value, _):
                    database[entry.identifier] = DeviceInfo(bezel: value, name: entry.name, source: source)
                    database.problematic.removeValue(forKey: entry.identifier)

                case .verified(let value, _):
                    database[entry.identifier] = DeviceInfo(
                        bezel: value,
                        name: entry.name,
                        source: .simulator,
                        profileBezel: entry.profileValue
                    )
                    database.problematic.removeValue(forKey: entry.identifier)

                case .awaitingVerification, .verificationFailed:
                    if database[entry.identifier] == nil {
                        database.problematic[entry.identifier] = PendingDeviceInfo(name: entry.name)
                    }
            }
        }

        // Names are Xcode's to define. Apply them even where the measurement was untouched.
        for rename in report.renames {
            guard var info = database[rename.identifier] else { continue }
            info.name = rename.to
            database[rename.identifier] = info
        }
    }
}

// MARK: - Console rendering

extension ScanCommand {
    func render(report: ScanReport, logger: Logger) {
        logger.banner("** Scan results **")

        var counts = "Unchanged: \(report.confirmedCount)"
        if report.settledCount > 0 { counts += "   Settled: \(report.settledCount)" }
        counts += "   Legacy (not in Xcode): \(report.legacyOnlyCount)"
        logger.info(counts, indent: 2)

        describe(report.verified, "Verified by simulator", logger: logger, success: true)
        describe(report.accepted, "Accepted from Xcode catalog", logger: logger, success: true)
        describe(report.awaiting, "Needs a simulator boot", logger: logger, success: false)
        describe(report.failed, "Verification failed", logger: logger, success: false)

        if !report.renames.isEmpty {
            logger.info("Name corrections: \(report.renames.count)", indent: 2)
            for rename in report.renames {
                logger.log("- \(rename.identifier): '\(rename.from)' → '\(rename.to)'", indent: 6)
            }
        }

        if !report.hasChanges && report.awaiting.isEmpty && report.failed.isEmpty {
            logger.success("Database matches Xcode's device catalog 🎉", indent: 2)
        }
    }

    private func describe(_ entries: [ScanEntry], _ title: String, logger: Logger, success: Bool) {
        guard !entries.isEmpty else { return }

        if success {
            logger.success("\(title): \(entries.count)", indent: 2)
        }
        else {
            logger.warn("\(title): \(entries.count)", indent: 2)
        }

        for entry in entries {
            let was = entry.existingValue.map { "\(Triage.format($0)) → " } ?? ""
            let now: String
            switch entry.outcome {
                case .accepted(_, let value, _), .verified(let value, _): now = Triage.format(value)
                case .awaitingVerification, .verificationFailed: now = "\(Triage.format(entry.profileValue))?"
            }
            logger.log("- \(entry.identifier) (\(entry.name)): \(was)\(now)", indent: 6)
            logger.log("  \(entry.outcome.detail)", indent: 6)
        }
    }
}

// MARK: - Outcome detail

extension ScanOutcome {
    var detail: String {
        switch self {
            case .accepted(_, _, let note),
                .verified(_, let note),
                .awaitingVerification(let note),
                .verificationFailed(let note):
                return note
        }
    }
}
