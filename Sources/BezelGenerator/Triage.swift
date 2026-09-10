//
// BezelGenerator
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

// MARK: - Triage verdict

/// Whether a profile-derived radius can be taken at face value, or needs a simulator boot
/// to confirm.
enum TriageVerdict: Sendable {
    case trust(reason: String)
    case verify(reason: String)

    var needsVerification: Bool {
        if case .verify = self { return true }
        return false
    }

    var reason: String {
        switch self {
            case .trust(let reason), .verify(let reason): return reason
        }
    }
}

// MARK: - Triage

/// Decides which profile-derived radii are safe to accept without booting a simulator.
///
/// `DeviceCornerRadius` in `capabilities.plist` is correct for the overwhelming majority of
/// devices, but has two known failure modes, both measured against the runtime-verified
/// values already in the database:
///
/// 1. **Lossy rounding.** iPhone 12 / 12 Pro / 12 Pro Max store `47`/`53` where the runtime
///    reports `47.33`/`53.33`. The same chassis in the iPhone 13 generation stores the full
///    `47.33333206176758`, so the precision loss is a per-generation authoring slip.
/// 2. **Panel geometry vs. reported geometry.** iPad Air (3rd generation) stores `18`, but
///    iOS reports `0` because it does not mask the display corners.
///
/// Both are caught by two signals:
///
/// - A **fractional** value has not been rounded, so it is the real hardware figure.
/// - A **whole** value is trustworthy when a device sharing its `chromeIdentifier` — Apple's
///   chassis-design ID — has already been verified at that exact radius.
///
/// Corroboration deliberately counts only entries marked ``DeviceSource/simulator``. If
/// profile-derived values were allowed to corroborate each other, one bad reading would
/// bootstrap itself into looking verified.
struct Triage {
    /// Radii confirmed by an actual simulator boot, grouped by chassis-design ID.
    private let verifiedRadii: [String: Set<Double>]

    // MARK: - Init

    init(database: DeviceDatabase, catalog: [String: DeviceProfile]) {
        var grouped: [String: Set<Double>] = [:]

        for (identifier, info) in database.allDevices where info.isRuntimeVerified {
            guard let chrome = catalog[identifier]?.chromeIdentifier else { continue }
            grouped[chrome, default: []].insert(info.bezel)
        }

        self.verifiedRadii = grouped
    }

    // MARK: - Verdict

    func verdict(for profile: DeviceProfile) -> TriageVerdict {
        let radius = profile.cornerRadius

        if radius.truncatingRemainder(dividingBy: 1) != 0 {
            return .trust(reason: "fractional value — not rounded, so it is the hardware figure")
        }

        guard let chrome = profile.chromeIdentifier else {
            return .verify(reason: "whole value and no chassis ID to corroborate against")
        }

        guard let peers = verifiedRadii[chrome], !peers.isEmpty else {
            return .verify(reason: "whole value and no verified device yet in chassis family '\(shortChrome(chrome))'")
        }

        if peers.contains(where: { abs($0 - radius) < 0.005 }) {
            return .trust(
                reason: "whole value corroborated by \(peers.count) verified radius/radii in '\(shortChrome(chrome))'"
            )
        }

        let listed = peers.sorted().map { Self.format($0) }.joined(separator: ", ")
        return .verify(
            reason:
                "whole value \(Self.format(radius)) conflicts with verified '\(shortChrome(chrome))' radii [\(listed)]"
        )
    }

    // MARK: - Helpers

    /// Trims `com.apple.dt.devicekit.chrome.phone11` down to `phone11` for readable output.
    private func shortChrome(_ chrome: String) -> String {
        chrome.components(separatedBy: ".").last ?? chrome
    }

    static func format(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%g", value)
    }
}
