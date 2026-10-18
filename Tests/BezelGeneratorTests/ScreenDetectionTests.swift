//
// BezelGenerator
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation
import Testing

@testable import BezelGenerator

/// Builds fake `.simdevicetype` bundles and checks how the catalog reads their displays.
///
/// The shapes mirror a real Xcode profile: `displays` in `capabilities.plist`, one dictionary
/// per display, with `displayType` telling built-in screens from external ones.
@Suite(.serialized)
struct ScreenDetectionTests {

    // MARK: - Fixtures

    private static func display(
        _ size: (Double, Double),
        corners: (Double, Double, Double, Double)? = (62, 62, 62, 62),
        type: String = "integrated"
    ) -> [String: Any] {
        var display: [String: Any] = [
            "displayType": type,
            "width": size.0,
            "height": size.1,
        ]
        if let corners {
            display["cornerRadiusUL"] = corners.0
            display["cornerRadiusUR"] = corners.1
            display["cornerRadiusLL"] = corners.2
            display["cornerRadiusLR"] = corners.3
        }
        return display
    }

    /// Writes a bundle for one device into a fresh directory and returns it.
    private static func catalog(
        identifier: String = "iPhone99,1",
        name: String = "Test Phone",
        radius: Double = 62,
        displays: [[String: Any]]
    ) throws -> [String: DeviceProfile] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BezelGeneratorTests-\(UUID().uuidString)")
        let resources = root.appendingPathComponent("\(name).simdevicetype/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func write(_ object: [String: Any], to file: String) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
            try data.write(to: resources.appendingPathComponent(file))
        }

        try write(["modelIdentifier": identifier], to: "profile.plist")
        try write(
            ["capabilities": ["DeviceCornerRadius": radius, "displays": displays]],
            to: "capabilities.plist"
        )

        return DeviceProfileCatalog(logger: Logger(verbose: false)).load(searchPaths: [root.path])
    }

    // MARK: - Ordinary devices

    @Test("A single screen with uniform corners needs no per-screen data")
    func ordinaryPhone() throws {
        let profile = try #require(Self.catalog(displays: [Self.display((1206, 2622))])["iPhone99,1"])

        #expect(profile.screens.isEmpty)
        #expect(!profile.hasIncompleteScreenData)
    }

    @Test("External displays are not counted as screens")
    func externalDisplaysIgnored() throws {
        let profile = try #require(
            Self.catalog(displays: [
                Self.display((1206, 2622)),
                Self.display((1920, 1080), corners: nil, type: "external"),
                Self.display((7680, 4320), corners: nil, type: "external"),
            ])["iPhone99,1"]
        )

        #expect(profile.screens.isEmpty)
        #expect(!profile.hasIncompleteScreenData)
    }

    // MARK: - Devices that need per-screen data

    @Test("Two built-in screens are recorded, in Xcode's order")
    func twoScreens() throws {
        let profile = try #require(
            Self.catalog(displays: [
                Self.display((1398, 2034), corners: (8, 59, 8, 59)),
                Self.display((2007, 2853), corners: (55, 55, 55, 55)),
                Self.display((1920, 1080), corners: nil, type: "external"),
            ])["iPhone99,1"]
        )

        #expect(profile.screens.count == 2)
        #expect(profile.screens.map(\.name) == ["Screen 1", "Screen 2"])
        #expect(profile.screens[0].nativeSize == [1398, 2034])
        #expect(profile.screens[0].corners == .init(topLeft: 8, topRight: 59, bottomLeft: 8, bottomRight: 59))
        #expect(profile.screens[1].corners == .init(topLeft: 55, topRight: 55, bottomLeft: 55, bottomRight: 55))
        #expect(!profile.hasIncompleteScreenData)
    }

    @Test("Two built-in screens are recorded even when both have uniform corners")
    func twoUniformScreens() throws {
        let profile = try #require(
            Self.catalog(displays: [
                Self.display((1000, 2000), corners: (40, 40, 40, 40)),
                Self.display((1500, 2500), corners: (50, 50, 50, 50)),
            ])["iPhone99,1"]
        )

        #expect(profile.screens.count == 2)
    }

    @Test("A single screen with uneven corners is recorded")
    func unevenSingleScreen() throws {
        let profile = try #require(
            Self.catalog(displays: [Self.display((1206, 2622), corners: (62, 62, 30, 30))])["iPhone99,1"]
        )

        #expect(profile.screens.count == 1)
        #expect(profile.screens[0].corners.bottomLeft == 30)
    }

    // MARK: - Flagging

    @Test("Several screens with one missing its corners are flagged, and nothing is recorded")
    func incompleteIsFlagged() throws {
        let profile = try #require(
            Self.catalog(displays: [
                Self.display((1398, 2034), corners: (8, 59, 8, 59)),
                Self.display((2007, 2853), corners: nil),
            ])["iPhone99,1"]
        )

        #expect(profile.hasIncompleteScreenData)
        #expect(profile.screens.isEmpty)
    }

    @Test("Several screens with no corner data at all are flagged")
    func noCornerDataIsFlagged() throws {
        let profile = try #require(
            Self.catalog(displays: [
                Self.display((1398, 2034), corners: nil),
                Self.display((2007, 2853), corners: nil),
            ])["iPhone99,1"]
        )

        #expect(profile.hasIncompleteScreenData)
    }

    @Test("One screen missing its corners is not flagged — there is only one number to record")
    func singleScreenMissingCornersNotFlagged() throws {
        let profile = try #require(Self.catalog(displays: [Self.display((1206, 2622), corners: nil)])["iPhone99,1"])

        #expect(!profile.hasIncompleteScreenData)
        #expect(profile.screens.isEmpty)
    }

    // MARK: - Keeping names

    @Test("A name already stored for a screen of the same size is kept")
    func namesAreKept() {
        let fresh = [
            ScreenInfo(name: "Screen 1", nativeSize: [1398, 2034], corners: .init(topLeft: 8, topRight: 59, bottomLeft: 8, bottomRight: 59)),
            ScreenInfo(name: "Screen 2", nativeSize: [2007, 2853], corners: .init(topLeft: 55, topRight: 55, bottomLeft: 55, bottomRight: 55)),
        ]
        let stored = [
            ScreenInfo(name: "Outer", nativeSize: [1398, 2034], corners: .init(topLeft: 1, topRight: 1, bottomLeft: 1, bottomRight: 1))
        ]

        let merged = ScanCommand.mergingNames(fresh, from: stored)

        #expect(merged?.map(\.name) == ["Outer", "Screen 2"])
        #expect(merged?[0].corners.topRight == 59, "numbers come from Xcode, not the stored entry")
        #expect(ScanCommand.mergingNames([], from: stored) == nil)
    }
}
