import Foundation
import XCTest
@testable import QuotaWiseKit

final class HistoryRetentionTests: XCTestCase {
    private func fixture() throws -> (root: URL, codex: URL, claude: URL, cache: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "quotawise-history-\(UUID())")
        let codex = root.appending(path: ".codex")
        let claude = root.appending(path: ".claude")
        try FileManager.default.createDirectory(at: codex.appending(path: "sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude.appending(path: "projects/example"), withIntermediateDirectories: true)
        return (root, codex, claude, root.appending(path: "index.json"))
    }

    private func writeCodex(_ file: URL, session: String, at date: Date, count: Int = 65) throws {
        let formatter = ISO8601DateFormatter()
        var rows: [[String: Any]] = [
            ["timestamp": formatter.string(from: date), "type": "session_meta", "payload": ["id": session, "cwd": "/example"]],
            ["timestamp": formatter.string(from: date), "type": "turn_context", "payload": ["model": "gpt-5.6-sol", "cwd": "/example"]],
        ]
        for total in 1...count {
            rows.append(["timestamp": formatter.string(from: date.addingTimeInterval(Double(total))), "type": "event_msg", "payload": [
                "type": "token_count", "info": ["total_token_usage": ["input_tokens": total * 100, "output_tokens": total]]
            ]])
        }
        try write(rows, to: file)
    }

    private func write(_ rows: [[String: Any]], to file: URL) throws {
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        try data.write(to: file)
    }

    func testMissingCompactedSourcesSurviveScanRestartAndReturn() async throws {
        let f = try fixture()
        let date = Date().addingTimeInterval(-3 * 86_400)
        let first = f.codex.appending(path: "sessions/first.jsonl")
        let second = f.codex.appending(path: "sessions/second.jsonl")
        try writeCodex(first, session: "first", at: date)
        try writeCodex(second, session: "second", at: date)
        let scanner = LocalUsageScanner(codexHome: f.codex, claudeHome: f.claude, cacheURL: f.cache)
        let before = await scanner.scanAll()
        XCTAssertTrue(before.events.allSatisfy { $0.id.hasPrefix("hour:") })
        XCTAssertEqual(before.events.reduce(0) { $0 + $1.tokens.input }, 13_000)
        // Only generated fixture files move; original provider history is never touched.
        let migrated = f.root.appending(path: "migrated.jsonl")
        try FileManager.default.moveItem(at: first, to: migrated)
        let after = await scanner.scanAll()
        XCTAssertEqual(after.events, before.events)
        let reopened = LocalUsageScanner(codexHome: f.codex, claudeHome: f.claude, cacheURL: f.cache)
        let restarted = await reopened.scanAll()
        XCTAssertEqual(restarted.events, before.events)
        let cached = try Data(contentsOf: f.cache)
        _ = await reopened.scanAll()
        XCTAssertEqual(try Data(contentsOf: f.cache), cached)
        try FileManager.default.copyItem(at: migrated, to: first)
        let returned = await reopened.scanAll()
        XCTAssertEqual(returned.events, before.events)
    }

    func testArchivedSessionIsNotAddedToItsRetainedCompactedCopy() async throws {
        let f = try fixture()
        let file = f.codex.appending(path: "sessions/original.jsonl")
        let date = Date().addingTimeInterval(-3 * 86_400)
        try writeCodex(file, session: "same-session", at: date)
        let scanner = LocalUsageScanner(codexHome: f.codex, claudeHome: f.claude, cacheURL: f.cache)
        let before = await scanner.scanAll()
        let archive = f.codex.appending(path: "archived_sessions")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        // A different filename ensures deduplication follows session identity.
        let moved = archive.appending(path: "renamed.jsonl")
        try FileManager.default.moveItem(at: file, to: moved)
        let after = await scanner.scanAll()
        XCTAssertEqual(after.events, before.events)
        try writeCodex(moved, session: "same-session", at: date, count: 66)
        let appended = await scanner.scanAll()
        XCTAssertEqual(appended.events.reduce(0) { $0 + $1.tokens.input }, 6_600)
        XCTAssertEqual(appended.events.reduce(0) { $0 + $1.tokens.output }, 66)
        try FileManager.default.copyItem(at: moved, to: file)
        let restoredCopy = await scanner.scanAll()
        XCTAssertEqual(restoredCopy.events, appended.events)
    }

    func testMissingClaudeSourceRetainsUsage() async throws {
        let f = try fixture()
        let file = f.claude.appending(path: "projects/example/session.jsonl")
        try write([["timestamp": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)), "type": "assistant", "uuid": "row", "cwd": "/example", "message": ["id": "message", "model": "claude-opus-4-8", "usage": ["input_tokens": 100, "output_tokens": 10], "content": []]]], to: file)
        let scanner = LocalUsageScanner(codexHome: f.codex, claudeHome: f.claude, cacheURL: f.cache)
        let before = await scanner.scanAll()
        XCTAssertEqual(before.events.count, 1)
        try FileManager.default.moveItem(at: file, to: f.root.appending(path: "migrated-claude.jsonl"))
        let after = await scanner.scanAll()
        XCTAssertEqual(after.events, before.events)
    }

    func testForkedRolloutsSharingParentMetadataKeepIndependentHourlyUsage() async throws {
        let f = try fixture()
        let date = Date().addingTimeInterval(-3 * 86_400)
        let names = [
            "rollout-2026-10-17T00-00-00-01a11564-cfa5-7272-8919-827ffebf9f64.jsonl",
            "rollout-2026-10-17T00-00-01-01a11564-cfa5-7272-8919-827ffebf9f64_01a11566-8c28-72e0-923a-7df04c8910f0.jsonl",
        ]
        for name in names {
            try writeCodex(f.codex.appending(path: "sessions/" + name), session: "shared-parent", at: date)
        }
        let scanner = LocalUsageScanner(codexHome: f.codex, claudeHome: f.claude, cacheURL: f.cache)
        let before = await scanner.scanAll()
        XCTAssertEqual(before.events.reduce(0) { $0 + $1.tokens.input }, 13_000)
        try FileManager.default.moveItem(at: f.codex.appending(path: "sessions/" + names[1]), to: f.root.appending(path: "migrated-fork.jsonl"))
        let retained = await scanner.scanAll()
        XCTAssertEqual(retained.events, before.events)
    }

    func testMissingSourcesExpireByEventDateAndCannotLeakAcrossHomes() async throws {
        let f = try fixture()
        let now = Date()
        let file = f.codex.appending(path: "sessions/expiring.jsonl")
        try writeCodex(file, session: "expiring", at: now.addingTimeInterval(-3 * 86_400))
        let scanner = LocalUsageScanner(codexHome: f.codex, claudeHome: f.claude, cacheURL: f.cache)
        let initial = await scanner.scanAll(now: now)
        XCTAssertFalse(initial.events.isEmpty)
        try FileManager.default.moveItem(at: file, to: f.root.appending(path: "migrated.jsonl"))
        let expired = await scanner.scanAll(now: now.addingTimeInterval(36 * 86_400))
        XCTAssertTrue(expired.events.isEmpty)
        let empty = try JSONSerialization.jsonObject(with: Data(contentsOf: f.cache)) as? [String: Any]
        XCTAssertEqual(empty?.count, 0)

        try writeCodex(file, session: "expiring", at: now.addingTimeInterval(-60))
        _ = await scanner.scanAll(now: now)
        let other = LocalUsageScanner(codexHome: f.root.appending(path: "other-codex"), claudeHome: f.root.appending(path: "other-claude"), cacheURL: f.cache)
        let unrelated = await other.scanAll(now: now)
        XCTAssertTrue(unrelated.events.isEmpty)
    }
}
