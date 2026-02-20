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
        case author  = "Author"
        case project = "Project"
        case website = "Website"
    }
}

struct DeviceCategories: Codable {
    var iPad:   [String: DeviceInfo]
    var iPhone: [String: DeviceInfo]
    var iPod:   [String: DeviceInfo]
}

struct DeviceInfo: Codable {
    var bezel: Double
    var name:  String
}

struct PendingDeviceInfo: Codable {
    var name: String
}

// MARK: - xcrun simctl list devices -j

struct SimctlDeviceList: Decodable {
    let devices: [String: [SimulatorDevice]]
}

struct SimulatorDevice: Decodable {
    let name:        String
    let udid:        String
    let state:       String
    let isAvailable: Bool
}

// MARK: - xcrun simctl list runtimes -j

struct SimctlRuntimeList: Decodable {
    let runtimes: [SimulatorRuntime]
}

struct SimulatorRuntime: Decodable {
    let version:              String
    let identifier:           String
    let isAvailable:          Bool
    let supportedDeviceTypes: [SupportedDeviceType]
}

struct SupportedDeviceType: Decodable {
    let name:       String
    let identifier: String
}

// MARK: - FetchBezel app output (Documents/output.json)

struct AppOutput: Decodable {
    let identifiers: String
    let bezel:       Double
}

// MARK: - Internal resolved simulator work type

/// A unique simulator (by name) that represents one or more device identifiers.
/// Multiple identifiers share a single simulator when they have the same display name
/// (e.g. iPad17,1 and iPad17,2 are both "iPad Pro 11-inch (M5)" — Wi-Fi vs Cellular).
struct ResolvedSimulator {
    let identifiers: [String]   // all device identifiers that share this simulator name
    let name:        String
    let udid:        String
    var bezel:       Double?
}
