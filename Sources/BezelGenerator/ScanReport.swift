//
// BezelGenerator
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

// MARK: - Scan entry

/// Why a device appears in the scan results.
enum ScanKind: Sendable {

    /// Present in Xcode's catalog but absent from the database.
    case new

    /// Present in both, with a corner radius that does not match.
    case drift
}

/// What the scan decided to do about one device.
enum ScanOutcome: Sendable {

    /// Taken from the profile catalog on ``Triage``'s word, without a boot.
    case accepted(source: DeviceSource, value: Double, note: String)

    /// Confirmed by booting a simulator. Recorded as ground truth.
    case verified(value: Double, note: String)

    /// Needs a simulator boot that this run did not perform.
    case awaitingVerification(String)

    /// A boot was needed and attempted, but could not produce a value.
    case verificationFailed(String)

    var writesValue: Bool {
        switch self {
        case .accepted, .verified: return true
        case .awaitingVerification, .verificationFailed: return false
        }
    }
}

/// One device's scan result.
struct ScanEntry: Sendable {
    let identifier:     String
    let name:           String
    let existingValue:  Double?
    let existingSource: DeviceSource?
    let profileValue:   Double
    let kind:           ScanKind
    let verdict:        TriageVerdict
    var outcome:        ScanOutcome
}

// MARK: - Scan report

/// The full result of one `scan` run.
struct ScanReport: Sendable {

    /// Devices that are new or whose radius drifted. Devices that agree are counted, not listed.
    var entries: [ScanEntry] = []

    /// Identifiers whose database name disagrees with Xcode's, as (identifier, old, new).
    var renames: [(identifier: String, from: String, to: String)] = []

    /// Devices present in both sources whose radius already matched.
    var confirmedCount: Int = 0

    /// Devices where Xcode's catalog disagrees with a measured value, but a boot has already
    /// adjudicated that exact disagreement in the measurement's favour.
    var settledCount: Int = 0

    /// Devices in the database that Xcode no longer ships a device type for. Never touched —
    /// these are historical entries the catalog cannot speak to.
    var legacyOnlyCount: Int = 0

    var accepted:  [ScanEntry] { entries.filter { if case .accepted  = $0.outcome { return true }; return false } }
    var verified:  [ScanEntry] { entries.filter { if case .verified  = $0.outcome { return true }; return false } }
    var awaiting:  [ScanEntry] { entries.filter { if case .awaitingVerification = $0.outcome { return true }; return false } }
    var failed:    [ScanEntry] { entries.filter { if case .verificationFailed   = $0.outcome { return true }; return false } }

    var hasChanges: Bool { entries.contains { $0.outcome.writesValue } || !renames.isEmpty }

    // MARK: - Verification targets

    /// The devices this run should boot a simulator for, as identifier → simulator name.
    ///
    /// Under ``VerificationMode/unverified`` this deliberately reaches past the diff to
    /// include entries already stored as ``DeviceSource/profile``. Those were accepted on
    /// ``Triage``'s judgement when no runtime was available; once one exists they get
    /// promoted to ground truth, so no value stays plist-derived indefinitely.
    func identifiersNeedingSimulator(
        mode: VerificationMode,
        database: DeviceDatabase,
        catalog: [String: DeviceProfile]
    ) -> [String: String] {
        guard mode != .none else { return [:] }

        var targets: [String: String] = [:]

        for entry in entries {
            switch entry.outcome {
            case .awaitingVerification:
                targets[entry.identifier] = entry.name
            case .accepted where mode == .unverified:
                targets[entry.identifier] = entry.name
            default:
                break
            }
        }

        if mode == .unverified {
            for (identifier, info) in database.allDevices where !info.isRuntimeVerified {
                targets[identifier] = catalog[identifier]?.simulatorName ?? info.name
            }
        }

        return targets
    }
}

// MARK: - Markdown rendering

extension ScanReport {

    /// A summary suitable for a pull request body or a CI job summary.
    func markdown() -> String {
        var md = "## Device scan\n\n"

        md += "| | Count |\n| --- | --- |\n"
        md += "| Confirmed unchanged | \(confirmedCount) |\n"
        if settledCount > 0 { md += "| Settled disagreements | \(settledCount) |\n" }
        md += "| Verified by simulator | \(verified.count) |\n"
        md += "| Accepted from Xcode catalog | \(accepted.count) |\n"
        md += "| Awaiting verification | \(awaiting.count) |\n"
        if !failed.isEmpty  { md += "| Verification failed | \(failed.count) |\n" }
        if !renames.isEmpty { md += "| Name corrections | \(renames.count) |\n" }
        md += "| Legacy (no longer in Xcode) | \(legacyOnlyCount) |\n\n"

        md += section("Verified by simulator boot", verified, note: "Ground truth — read from `UIScreen._displayCornerRadius`.")
        md += section("Accepted from Xcode catalog", accepted, note: "Trusted without a boot. Re-verified automatically once a runtime is available.")
        md += section("Awaiting verification", awaiting, note: "**Not written.** A simulator boot is required before these can be accepted.")
        md += section("Verification failed", failed, note: "A boot was required but could not produce a value. Moved to `problematic` for retry.")

        if !renames.isEmpty {
            md += "### Name corrections\n\n| Identifier | Was | Now |\n| --- | --- | --- |\n"
            for rename in renames {
                md += "| `\(rename.identifier)` | \(rename.from) | \(rename.to) |\n"
            }
            md += "\n"
        }

        if !hasChanges && awaiting.isEmpty && failed.isEmpty {
            md += "No changes — the database matches Xcode's device catalog.\n"
        }

        return md
    }

    private func section(_ title: String, _ items: [ScanEntry], note: String) -> String {
        guard !items.isEmpty else { return "" }

        var md = "### \(title)\n\n\(note)\n\n"
        md += "| Identifier | Device | Was | Now | Reason |\n| --- | --- | --- | --- | --- |\n"

        for entry in items {
            let was = entry.existingValue.map { Triage.format($0) } ?? "—"
            let now: String
            switch entry.outcome {
            case .accepted(_, let value, _), .verified(let value, _):
                now = Triage.format(value)
            case .awaitingVerification, .verificationFailed:
                now = "\(Triage.format(entry.profileValue)) (proposed)"
            }
            let reason: String
            switch entry.outcome {
            case .accepted(_, _, let note), .verified(_, let note):    reason = note
            case .awaitingVerification(let note), .verificationFailed(let note): reason = note
            }
            md += "| `\(entry.identifier)` | \(entry.name) | \(was) | \(now) | \(reason) |\n"
        }

        return md + "\n"
    }
}
