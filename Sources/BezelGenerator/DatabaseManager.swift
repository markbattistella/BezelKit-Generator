//
// BezelGenerator
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

// MARK: - Database manager

struct DatabaseManager {

    let databasePath: String
    let logger: Logger

    // MARK: - Read

    func loadDatabase() throws -> DeviceDatabase {
        let url  = URL(fileURLWithPath: databasePath)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(DeviceDatabase.self, from: data)
    }

    // MARK: - Extract pending (filters already-processed devices)

    func extractPending(from database: DeviceDatabase) -> [String: PendingDeviceInfo] {
        var combined = database.pending
        for (key, value) in database.problematic {
            combined[key] = value
        }

        let processed = Set(
            Array(database.devices.iPad.keys) +
            Array(database.devices.iPhone.keys) +
            Array(database.devices.iPod.keys)
        )

        return combined.filter { !processed.contains($0.key) }
    }

    // MARK: - Merge results into database

    /// Writes the bezel result to every identifier that shares the simulator name.
    func merge(results: [ResolvedSimulator], into database: inout DeviceDatabase) {
        for sim in results {
            guard let bezel = sim.bezel else { continue }
            let category = sim.name.components(separatedBy: " ").first ?? "iPhone"
            let info = DeviceInfo(bezel: bezel, name: sim.name)
            for identifier in sim.identifiers {
                switch category {
                case "iPad":  database.devices.iPad[identifier]   = info
                case "iPod":  database.devices.iPod[identifier]   = info
                default:      database.devices.iPhone[identifier] = info
                }
            }
        }
    }

    // MARK: - Clean (reset pending, move unfound to problematic)

    func clean(database: inout DeviceDatabase, unfound: [ResolvedSimulator]) {
        database.pending = [:]
        for sim in unfound {
            for identifier in sim.identifiers {
                if database.problematic[identifier] == nil {
                    database.problematic[identifier] = PendingDeviceInfo(name: sim.name)
                }
            }
        }

        // Remove from problematic any identifiers now successfully in devices
        let processed = Set(
            Array(database.devices.iPad.keys) +
            Array(database.devices.iPhone.keys) +
            Array(database.devices.iPod.keys)
        )
        database.problematic = database.problematic.filter { !processed.contains($0.key) }
    }

    // MARK: - Save

    func save(
        database: DeviceDatabase,
        cacheOutputPath: String,
        minifiedOutputPath: String
    ) throws {
        let cacheData = buildJSON(database, minify: false)
        try cacheData.write(
            to: URL(fileURLWithPath: cacheOutputPath),
            atomically: true,
            encoding: .utf8
        )
        logger.log("- \(cacheOutputPath)", indent: 6)

        let miniData = buildJSON(database, minify: true)
        try miniData.write(
            to: URL(fileURLWithPath: minifiedOutputPath),
            atomically: true,
            encoding: .utf8
        )
        logger.log("- \(minifiedOutputPath)", indent: 6)
    }

    // MARK: - Delete build directory

    func deleteOutputDirectory(_ path: String) {
        do {
            try FileManager.default.removeItem(atPath: path)
            logger.log("- Deleted \(path)", indent: 6)
        } catch {
            logger.warn("Could not delete '\(path)': \(error.localizedDescription)")
        }
    }
}

// MARK: - Custom ordered JSON encoding

extension DatabaseManager {

    /// Builds the full JSON string for the database with custom-sorted keys.
    /// When `minify` is true, omits `pending` and `problematic` and produces compact JSON.
    private func buildJSON(_ database: DeviceDatabase, minify: Bool) -> String {
        var root = OrderedJSONObject()

        // _metadata
        var meta = OrderedJSONObject()
        meta.append("Author",  .string(database.metadata.author))
        meta.append("Project", .string(database.metadata.project))
        meta.append("Website", .string(database.metadata.website))
        root.append("_metadata", meta.jsonValue)

        // devices
        var devicesObj = OrderedJSONObject()
        devicesObj.append("iPad",   deviceSection(database.devices.iPad))
        devicesObj.append("iPhone", deviceSection(database.devices.iPhone))
        devicesObj.append("iPod",   deviceSection(database.devices.iPod))
        root.append("devices", devicesObj.jsonValue)

        if !minify {
            root.append("pending",     pendingSection(database.pending))
            root.append("problematic", pendingSection(database.problematic))
        }

        return root.serialize(pretty: !minify, indent: 0)
    }

    private func deviceSection(_ dict: [String: DeviceInfo]) -> JSONValue {
        var section = OrderedJSONObject()
        for key in dict.keys.sorted(by: Self.deviceKeyComparator) {
            let info = dict[key]!
            var entry = OrderedJSONObject()
            entry.append("bezel", .number(info.bezel))
            entry.append("name",  .string(info.name))
            section.append(key, entry.jsonValue)
        }
        return section.jsonValue
    }

    private func pendingSection(_ dict: [String: PendingDeviceInfo]) -> JSONValue {
        var section = OrderedJSONObject()
        for key in dict.keys.sorted(by: Self.deviceKeyComparator) {
            var entry = OrderedJSONObject()
            entry.append("name", .string(dict[key]!.name))
            section.append(key, entry.jsonValue)
        }
        return section.jsonValue
    }
}

// MARK: - Key sort (replicates Node.js parseFloat(key.match(/\d+(?:,\d+)?/)))

extension DatabaseManager {

    /// Extracts the numeric sort value from a device identifier.
    /// Matches Node.js: `parseFloat(a.match(/\d+(?:,\d+)?/))`.
    /// E.g. "iPhone14,1" → match "14,1" → replace comma with "." → Double("14.1") = 14.1
    static func numericSortKey(for key: String) -> Double {
        guard let range = key.range(of: #"\d+(?:,\d+)?"#, options: .regularExpression) else {
            return .infinity
        }
        let matched = String(key[range]).replacingOccurrences(of: ",", with: ".")
        return Double(matched) ?? .infinity
    }

    static func deviceKeyComparator(_ a: String, _ b: String) -> Bool {
        let na = numericSortKey(for: a)
        let nb = numericSortKey(for: b)
        if na != nb { return na < nb }
        return a < b
    }
}

// MARK: - Ordered JSON building types

enum JSONValue {
    case string(String)
    case number(Double)
    case object(OrderedJSONObject)
    case null
}

struct OrderedJSONObject {
    private var pairs: [(String, JSONValue)] = []

    mutating func append(_ key: String, _ value: JSONValue) {
        pairs.append((key, value))
    }

    var jsonValue: JSONValue { .object(self) }

    func serialize(pretty: Bool, indent: Int) -> String {
        let i  = pretty ? String(repeating: "  ", count: indent)     : ""
        let i1 = pretty ? String(repeating: "  ", count: indent + 1) : ""
        let nl = pretty ? "\n" : ""
        let sp = pretty ? " "  : ""

        var out = "{\(nl)"
        for (idx, (key, value)) in pairs.enumerated() {
            let comma = idx < pairs.count - 1 ? "," : ""
            out += "\(i1)\(jsonEscape(key)):\(sp)"
            out += serializeValue(value, pretty: pretty, indent: indent + 1)
            out += "\(comma)\(nl)"
        }
        out += "\(i)}"
        return out
    }
}

private func serializeValue(_ value: JSONValue, pretty: Bool, indent: Int) -> String {
    switch value {
    case .string(let s):
        return jsonEscape(s)
    case .number(let n):
        // Whole numbers → no decimal point (matches JSON.stringify behaviour)
        if n.truncatingRemainder(dividingBy: 1) == 0, !n.isInfinite, !n.isNaN {
            return String(Int(n))
        }
        return String(n)
    case .object(let obj):
        return obj.serialize(pretty: pretty, indent: indent)
    case .null:
        return "null"
    }
}

private func jsonEscape(_ s: String) -> String {
    var result = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        default:
            if scalar.value < 0x20 {
                result += String(format: "\\u%04x", scalar.value)
            } else {
                result += String(scalar)
            }
        }
    }
    result += "\""
    return result
}
