//
// BezelGenerator
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

// MARK: - Device Database (apple-device-database.json)

struct DeviceDatabase: Codable {
    var metadata: Metadata
    var devices: DeviceCategories
    var pending: [String: PendingDeviceInfo]
    var problematic: [String: PendingDeviceInfo]

    enum CodingKeys: String, CodingKey {
        case metadata = "_metadata"
        case devices, pending, problematic
    }
}

struct Metadata: Codable {
    let author: String
    let project: String
    let website: String

    enum CodingKeys: String, CodingKey {
        case author = "Author"
        case project = "Project"
        case website = "Website"
    }
}

struct DeviceCategories: Codable {
    var iPad: [String: DeviceInfo]
    var iPhone: [String: DeviceInfo]
    var iPod: [String: DeviceInfo]
}

struct DeviceInfo: Codable {
    var bezel: Double
    var name: String

    /// How the radius was obtained.
    ///
    /// Absent in databases written before provenance tracking existed. Those entries all
    /// predate the profile-catalog path, so a missing value means simulator-verified.
    var source: DeviceSource?

    /// The `DeviceCornerRadius` this entry was last checked against.
    ///
    /// Set when a simulator boot resolves a disagreement with Xcode's catalog. Recording the
    /// rejected figure means a settled case — iPhone 12's catalog value of `47` against a
    /// measured `47.33` — is not re-flagged and re-booted on every later scan. It is
    /// re-opened only if Xcode itself changes the value.
    var profileBezel: Double?

    /// Whether this value came from an actual simulator boot rather than a plist read.
    /// Only these entries are allowed to corroborate others in ``Triage``.
    var isRuntimeVerified: Bool { (source ?? .simulator) == .simulator }

    /// Whether a boot has already adjudicated this exact catalog value.
    func hasAdjudicated(_ catalogValue: Double) -> Bool {
        guard isRuntimeVerified, let profileBezel else { return false }
        return abs(profileBezel - catalogValue) < 0.005
    }
}

/// Where a bezel value came from.
enum DeviceSource: String, Codable, Sendable {
    /// Read from `UIScreen._displayCornerRadius` inside a booted simulator. Ground truth.
    case simulator

    /// Read from `DeviceCornerRadius` in an Xcode `.simdevicetype` bundle, and accepted by
    /// ``Triage``. Re-verified by a simulator boot when a runtime becomes available.
    case profile
}

// MARK: - Device categories

/// The three identifier families the database tracks.
enum DeviceCategory: String, Sendable, CaseIterable {
    case iPad
    case iPhone
    case iPod

    /// Derives the category from a device identifier such as `iPhone17,1`.
    /// Returns `nil` for Watch, Apple TV and Vision identifiers, which the database
    /// does not cover.
    init?(identifier: String) {
        switch true {
            case identifier.hasPrefix("iPhone"): self = .iPhone
            case identifier.hasPrefix("iPad"): self = .iPad
            case identifier.hasPrefix("iPod"): self = .iPod
            default: return nil
        }
    }
}

// MARK: - Xcode device type profile

/// One device identifier's entry in the Xcode-installed `.simdevicetype` catalog.
struct DeviceProfile: Sendable {
    /// Model identifier, e.g. `iPhone17,1`.
    let identifier: String

    /// Simulator display name, e.g. `iPhone 16 Pro`.
    let simulatorName: String

    /// `DeviceCornerRadius` from `capabilities.plist`, in points.
    let cornerRadius: Double

    /// Apple's chassis-design ID from `profile.plist`, e.g.
    /// `com.apple.dt.devicekit.chrome.phone11`. Devices sharing one are the same physical
    /// design, which is what makes cross-device corroboration meaningful.
    let chromeIdentifier: String?

    var category: DeviceCategory? { DeviceCategory(identifier: identifier) }
}

struct PendingDeviceInfo: Codable {
    var name: String
}

// MARK: - xcrun simctl list devices -j

struct SimctlDeviceList: Decodable {
    let devices: [String: [SimulatorDevice]]
}

struct SimulatorDevice: Decodable {
    let name: String
    let udid: String
    let state: String
    let isAvailable: Bool
}

// MARK: - xcrun simctl list runtimes -j

struct SimctlRuntimeList: Decodable {
    let runtimes: [SimulatorRuntime]
}

struct SimulatorRuntime: Decodable {
    let version: String
    let identifier: String
    let isAvailable: Bool
    let supportedDeviceTypes: [SupportedDeviceType]
}

struct SupportedDeviceType: Decodable {
    let name: String
    let identifier: String
}

// MARK: - FetchBezel app output (Documents/output.json)

struct AppOutput: Decodable {
    let identifiers: String
    let bezel: Double
}

// MARK: - Internal resolved simulator work type

/// A unique simulator (by name) that represents one or more device identifiers.
/// Multiple identifiers share a single simulator when they have the same display name
/// (e.g. iPad17,1 and iPad17,2 are both "iPad Pro 11-inch (M5)" — Wi-Fi vs Cellular).
struct ResolvedSimulator {
    let identifiers: [String] // all device identifiers that share this simulator name
    let name: String
    let udid: String
    var bezel: Double?
}

// MARK: - Database convenience access

extension DeviceDatabase {
    /// Every processed device across all three categories, keyed by identifier.
    var allDevices: [String: DeviceInfo] {
        var combined = devices.iPhone
        combined.merge(devices.iPad) { current, _ in current }
        combined.merge(devices.iPod) { current, _ in current }
        return combined
    }

    /// Reads or writes a device entry, routing to the category its identifier implies.
    /// Identifiers outside the three tracked families are ignored on write.
    subscript(identifier: String) -> DeviceInfo? {
        get {
            switch DeviceCategory(identifier: identifier) {
                case .iPad: return devices.iPad[identifier]
                case .iPhone: return devices.iPhone[identifier]
                case .iPod: return devices.iPod[identifier]
                case nil: return nil
            }
        }
        set {
            switch DeviceCategory(identifier: identifier) {
                case .iPad: devices.iPad[identifier] = newValue
                case .iPhone: devices.iPhone[identifier] = newValue
                case .iPod: devices.iPod[identifier] = newValue
                case nil: break
            }
        }
    }
}
