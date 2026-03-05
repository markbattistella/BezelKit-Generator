//
// BezelGenerator
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

// MARK: - Release Manager

struct ReleaseManager {

    /// Path to the minified bezel.min.json (relative to Generator/).
    /// Used to diff old vs new devices for release notes.
    let inputPath: String

    private let generatorRepo = "."
    private let parentRepo    = ".."

    // MARK: - Entry point

    func run() throws {
        let today = Date()
        let commitMessage = isoDate(today)
        let tag           = versionTag(today)

        print("\nPreparing release \(tag)...")

        let notes = buildReleaseNotes()

        // 1. Commit + push Generator repo
        print("\n[1/4] Committing Generator repo...")
        try commitIfNeeded(repoPath: generatorRepo, message: commitMessage)
        try push(repoPath: generatorRepo)

        // 2. Commit + push parent repo (after Generator so the submodule pointer is current)
        print("\n[2/4] Committing parent repo...")
        try commitIfNeeded(repoPath: parentRepo, message: commitMessage)
        try push(repoPath: parentRepo)

        // 3. Tag parent repo and push the tag
        print("\n[3/4] Tagging \(tag)...")
        try Shell.run("/usr/bin/git", arguments: ["-C", parentRepo, "tag", tag])
        try Shell.run("/usr/bin/git", arguments: ["-C", parentRepo, "push", "origin", tag])

        // 4. Create GitHub release
        print("\n[4/4] Creating GitHub release...")
        let repo = try githubRepo()
        try Shell.run("/usr/bin/env", arguments: [
            "gh", "release", "create", tag,
            "--title", tag,
            "--notes", notes,
            "-R", repo
        ])

        print("\nRelease \(tag) published successfully.")
        print("\nRelease notes:\n\(notes)")
    }

    // MARK: - Date helpers

    private func isoDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Produces a tag like "26.3.6" — two-digit year, no zero padding.
    private func versionTag(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return "\(c.year! % 100).\(c.month!).\(c.day!)"
    }

    // MARK: - Git helpers

    private func commitIfNeeded(repoPath: String, message: String) throws {
        let status = try Shell.run("/usr/bin/git", arguments: ["-C", repoPath, "status", "--porcelain"])
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("  Nothing to commit in \(repoPath)")
            return
        }
        try Shell.run("/usr/bin/git", arguments: ["-C", repoPath, "add", "-A"])
        try Shell.run("/usr/bin/git", arguments: ["-C", repoPath, "commit", "-m", message])
    }

    private func push(repoPath: String) throws {
        try Shell.run("/usr/bin/git", arguments: ["-C", repoPath, "push"])
    }

    /// Parses the GitHub "owner/repo" slug from the parent repo's origin remote URL.
    /// Handles both SSH (`git@github.com:owner/repo.git`) and HTTPS formats.
    private func githubRepo() throws -> String {
        let remote = try Shell.run(
            "/usr/bin/git",
            arguments: ["-C", parentRepo, "remote", "get-url", "origin"]
        )
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip known prefixes
        for prefix in ["git@github.com:", "https://github.com/", "http://github.com/"] {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
                break
            }
        }

        // Strip trailing .git
        if s.hasSuffix(".git") {
            s = String(s.dropLast(4))
        }

        return s
    }

    // MARK: - Release notes

    private func buildReleaseNotes() -> String {
        do {
            return try buildReleaseNotesOrThrow()
        } catch {
            return "No changelog available."
        }
    }

    private func buildReleaseNotesOrThrow() throws -> String {
        // Read current (just-written) minified JSON
        let currentData = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        let current     = try JSONDecoder().decode(MinJSON.self, from: currentData)

        // Derive the path relative to the parent repo root.
        // inputPath is like "../Sources/BezelKit/Resources/bezel.min.json"
        var gitRelPath = inputPath
        if gitRelPath.hasPrefix("../") { gitRelPath = String(gitRelPath.dropFirst(3)) }

        // Fetch the committed version from the parent repo's HEAD
        let oldContent: String
        do {
            oldContent = try Shell.run(
                "/usr/bin/git",
                arguments: ["-C", parentRepo, "show", "HEAD:\(gitRelPath)"]
            )
        } catch {
            // No previous commit — list everything as new
            return formatNotes(entries: allEntries(from: current))
        }

        let old     = try JSONDecoder().decode(MinJSON.self, from: Data(oldContent.utf8))
        let added   = diffEntries(old: old, current: current)
        return formatNotes(entries: added)
    }

    private func allEntries(from json: MinJSON) -> [DeviceEntry] {
        var result: [DeviceEntry] = []
        let pairs: [(String, [String: MinJSON.Entry])] = [
            ("iPad",   json.devices.iPad),
            ("iPhone", json.devices.iPhone),
            ("iPod",   json.devices.iPod)
        ]
        for (cat, dict) in pairs {
            let sorted = dict.keys.sorted(by: DatabaseManager.deviceKeyComparator)
            for id in sorted {
                result.append(DeviceEntry(category: cat, identifier: id, name: dict[id]!.name))
            }
        }
        return result
    }

    private func diffEntries(old: MinJSON, current: MinJSON) -> [DeviceEntry] {
        var result: [DeviceEntry] = []
        let pairs: [(String, [String: MinJSON.Entry], [String: MinJSON.Entry])] = [
            ("iPad",   old.devices.iPad,   current.devices.iPad),
            ("iPhone", old.devices.iPhone, current.devices.iPhone),
            ("iPod",   old.devices.iPod,   current.devices.iPod)
        ]
        for (cat, oldDict, newDict) in pairs {
            let oldKeys = Set(oldDict.keys)
            let added   = newDict.keys
                .filter { !oldKeys.contains($0) }
                .sorted(by: DatabaseManager.deviceKeyComparator)
            for id in added {
                result.append(DeviceEntry(category: cat, identifier: id, name: newDict[id]!.name))
            }
        }
        return result
    }

    private func formatNotes(entries: [DeviceEntry]) -> String {
        guard !entries.isEmpty else { return "No new devices added." }

        var notes = "## Added Devices\n\n"
        let grouped = Dictionary(grouping: entries, by: \.category)

        for cat in ["iPad", "iPhone", "iPod"] {
            guard let devices = grouped[cat], !devices.isEmpty else { continue }
            notes += "### \(cat)\n\n"
            for d in devices {
                notes += "- \(d.name) (`\(d.identifier)`)\n"
            }
            notes += "\n"
        }

        return notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Supporting types

private struct DeviceEntry {
    let category:   String
    let identifier: String
    let name:       String
}

/// Minimal decodable representation of bezel.min.json for diffing.
private struct MinJSON: Decodable {
    let devices: Categories

    struct Categories: Decodable {
        let iPad:   [String: Entry]
        let iPhone: [String: Entry]
        let iPod:   [String: Entry]
    }

    struct Entry: Decodable {
        let name:  String
        let bezel: Double
    }
}
