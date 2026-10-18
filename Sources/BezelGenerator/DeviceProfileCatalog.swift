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
                        chromeIdentifier: profile.chromeIdentifier,
                        screens: profile.screens,
                        hasIncompleteScreenData: profile.hasIncompleteScreenData
                    )
                }
            }
        }

        logger.log("- Scanned \(scannedBundles) device type bundle(s)", indent: 6)
        return catalog
    }

    // MARK: - Bundle parsing

    struct ParsedBundle {
        let identifiers: [String]
        let simulatorName: String
        let cornerRadius: Double
        let chromeIdentifier: String?
        let screens: [ScreenInfo]
        let hasIncompleteScreenData: Bool
    }

    /// The built-in screens of a device, or `[]` when one radius already describes it.
    ///
    /// Xcode lists every display a device type has, including external ones such as CarPlay, so
    /// only `integrated` displays count. A device needs per-screen data when it has more than
    /// one of them or when any one has uneven corners — a single-screen device with uniform
    /// corners, which is almost all of them, is left to the scalar radius.
    ///
    /// When there is more than one built-in screen but one is missing its size or corners, the
    /// data can't be trusted as a set, so nothing is recorded and the device is flagged instead.
    func parseScreens(_ caps: [String: Any]) -> (screens: [ScreenInfo], incomplete: Bool) {
        let displays = (caps["displays"] as? [[String: Any]]) ?? []
        let integrated = displays.filter { ($0["displayType"] as? String) == "integrated" }

        let screens: [ScreenInfo] = integrated.compactMap { display in
            func number(_ key: String) -> Double? { (display[key] as? NSNumber)?.doubleValue }

            guard
                let width = number("width"), let height = number("height"),
                let topLeft = number("cornerRadiusUL"), let topRight = number("cornerRadiusUR"),
                let bottomLeft = number("cornerRadiusLL"), let bottomRight = number("cornerRadiusLR")
            else { return nil }

            return ScreenInfo(
                name: nil,
                nativeSize: [width, height],
                corners: .init(
                    topLeft: topLeft,
                    topRight: topRight,
                    bottomLeft: bottomLeft,
                    bottomRight: bottomRight
                )
            )
        }

        // More screens than we could read: don't record half a device.
        if integrated.count > 1, screens.count < integrated.count {
            return ([], true)
        }

        // Xcode doesn't label them, so number them in its order. A name already stored in the
        // database for a screen of the same size takes precedence — see `mergingNames`.
        let named = screens.enumerated().map { index, screen -> ScreenInfo in
            var screen = screen
            screen.name = "Screen \(index + 1)"
            return screen
        }

        let uneven = screens.contains {
            Set([$0.corners.topLeft, $0.corners.topRight, $0.corners.bottomLeft, $0.corners.bottomRight]).count > 1
        }
        return ((screens.count > 1 || uneven) ? named : [], false)
    }

    func parseBundle(at bundlePath: String) -> ParsedBundle? {
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

        let (screens, incomplete) = parseScreens(caps)

        return ParsedBundle(
            identifiers: identifiers,
            simulatorName: name,
            cornerRadius: radius,
            chromeIdentifier: profile["chromeIdentifier"] as? String,
            screens: screens,
            hasIncompleteScreenData: incomplete
        )
    }

    private func readPlist(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil)
        return parsed as? [String: Any]
    }
}
