//
// BezelGenerator
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

// MARK: - Device profile catalog

/// Reads device corner-radius data directly from the `.simdevicetype` bundles that Xcode
/// installs, without booting a simulator.
///
/// Each bundle carries two property lists:
///
/// - `profile.plist` — identity: `modelIdentifier`, `representedModelIdentifiers`, and
///   `chromeIdentifier` (Apple's chassis-design ID, used by ``Triage`` for corroboration).
/// - `capabilities.plist` — `DeviceCornerRadius`, the display corner radius in points.
///
/// The radius here is static data shipped with Xcode, so a full catalog read costs
/// milliseconds rather than one simulator boot per device. It is not a perfect substitute
/// for the runtime value — see ``Triage`` for the cases where it is known to drift.
struct DeviceProfileCatalog {
    let logger: Logger

    /// Locations searched for `.simdevicetype` bundles, in order.
    ///
    /// CoreSimulator installs the shared set into `/Library`; platform-specific copies may
    /// also live inside the selected Xcode. Both are scanned so a side-by-side Xcode (a beta
    /// or RC) contributes its newer device types.
    static func defaultSearchPaths() -> [String] {
        var paths = ["/Library/Developer/CoreSimulator/Profiles/DeviceTypes"]

        if let developerDir = try? Shell.run("/usr/bin/xcode-select", arguments: ["-p"]) {
            for platform in ["iPhoneOS", "iPadOS"] {
                paths.append(
                    "\(developerDir)/Platforms/\(platform).platform/Library/Developer"
                        + "/CoreSimulator/Profiles/DeviceTypes"
                )
            }
        }

        return paths
    }

    // MARK: - Load

    /// Parses every `.simdevicetype` bundle found in `searchPaths`.
    ///
    /// Only iPhone, iPad and iPod identifiers are returned — the database has no category for
    /// Watch, Apple TV or Vision devices. Bundles with no corner-radius capability (older
    /// device types that predate the key) are skipped.
    func load(searchPaths: [String]) -> [String: DeviceProfile] {
        var catalog: [String: DeviceProfile] = [:]
        var scannedBundles = 0

        for path in searchPaths {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
                continue
            }

            for entry in entries.sorted() where entry.hasSuffix(".simdevicetype") {
                scannedBundles += 1
                guard let profile = parseBundle(at: "\(path)/\(entry)") else { continue }

                for identifier in profile.identifiers {
                    guard DeviceCategory(identifier: identifier) != nil else { continue }

                    // A later search path wins, but a genuine value conflict is worth surfacing
                    // rather than silently resolving.
                    if let existing = catalog[identifier],
                        abs(existing.cornerRadius - profile.cornerRadius) > 0.0001
                    {
                        logger.warn(
                            "Conflicting radius for \(identifier): "
                                + "\(existing.cornerRadius) (\(existing.simulatorName)) vs "
                                + "\(profile.cornerRadius) (\(profile.simulatorName))"
                        )
                    }

                    catalog[identifier] = DeviceProfile(
                        identifier: identifier,
                        simulatorName: profile.simulatorName,
                        cornerRadius: profile.cornerRadius,
                        chromeIdentifier: profile.chromeIdentifier
                    )
                }
            }
        }

        logger.log("- Scanned \(scannedBundles) device type bundle(s)", indent: 6)
        return catalog
    }

    // MARK: - Bundle parsing

    private struct ParsedBundle {
        let identifiers: [String]
        let simulatorName: String
        let cornerRadius: Double
        let chromeIdentifier: String?
    }

    private func parseBundle(at bundlePath: String) -> ParsedBundle? {
        let resources = "\(bundlePath)/Contents/Resources"

        guard let profile = readPlist(at: "\(resources)/profile.plist"),
            let capabilities = readPlist(at: "\(resources)/capabilities.plist")
        else { return nil }

        // `capabilities.plist` nests everything under a `capabilities` dictionary in current
        // Xcode versions, but older bundles store the keys flat. Accept either shape.
        let caps = (capabilities["capabilities"] as? [String: Any]) ?? capabilities

        guard let radius = (caps["DeviceCornerRadius"] as? NSNumber)?.doubleValue else {
            return nil
        }

        let identifiers: [String]
        if let represented = profile["representedModelIdentifiers"] as? [String], !represented.isEmpty {
            identifiers = represented
        }
        else if let single = profile["modelIdentifier"] as? String {
            identifiers = [single]
        }
        else {
            return nil
        }

        let name = URL(fileURLWithPath: bundlePath)
            .deletingPathExtension()
            .lastPathComponent

        return ParsedBundle(
            identifiers: identifiers,
            simulatorName: name,
            cornerRadius: radius,
            chromeIdentifier: profile["chromeIdentifier"] as? String
        )
    }

    private func readPlist(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil)
        return parsed as? [String: Any]
    }
}
