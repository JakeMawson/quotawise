import Foundation
import SQLite3
import XCTest
@testable import QuotaWiseKit

final class ProjectDetectionTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "quotawise-projects-\(UUID())")
        try FileManager.default.createDirectory(at: root.appending(path: ".codex/sessions"), withIntermediateDirectories: true)
        return root
    }

    private func writeJSON(_ object: Any, to file: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
    }

    private func writeSession(_ home: URL, id: String, cwd: String, at date: Date) throws {
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": id, "cwd": cwd]],
            ["type": "turn_context", "payload": ["model": "gpt-5.6-sol", "cwd": cwd]],
            ["timestamp": ISO8601DateFormatter().string(from: date), "type": "event_msg", "payload": [
                "type": "token_count", "info": ["total_token_usage": ["input_tokens": 100, "output_tokens": 20]],
                "rate_limits": ["primary": ["used_percent": 40, "window_minutes": 300, "resets_at": Int(date.timeIntervalSince1970 + 300)]]
            ]]
        ]
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        try data.write(to: home.appending(path: "sessions/rollout-\(id).jsonl"))
    }

    func testFamilyWorktreesWithExplicitMembershipAreOneProject() async throws {
        let root = try fixture(), home = root.appending(path: ".codex")
        let project = root.appending(path: "familysimpl").path
        let ids = [UUID().uuidString.lowercased(), UUID().uuidString.lowercased(), UUID().uuidString.lowercased()]
        try writeJSON([
            "local-projects": ["family": ["id": "family", "name": "FamilySimpl", "rootPaths": [project]]],
            "thread-project-assignments": Dictionary(uniqueKeysWithValues: ids.map { ($0, ["projectKind": "local", "projectId": "family"]) })
        ], to: home.appending(path: ".codex-global-state.json"))
        for (index, id) in ids.enumerated() {
            let cwd = index == 0 ? project : home.appending(path: "worktrees/\(index)/familysimpl").path
            try writeSession(home, id: id, cwd: cwd, at: Date().addingTimeInterval(Double(index - 10)))
        }
        let result = await LocalUsageScanner(codexHome: home, claudeHome: root.appending(path: "no-claude"), cacheURL: root.appending(path: "cache.json")).scanAll()
        XCTAssertEqual(result.events.count, 3)
        XCTAssertEqual(Set(result.events.map(\.projectPath)), [project])
        XCTAssertEqual(Set(result.events.map(\.projectName)), ["FamilySimpl"])
        XCTAssertEqual(result.events.reduce(0) { $0 + $1.tokens.total }, 360)
        XCTAssertEqual(result.observations.count, 3)
    }

    private func database(_ home: URL, sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appending(path: "state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    func testSavedDatabaseProjectsAppearWithoutUsageAndDatabaseIsReadOnly() async throws {
        let root = try fixture(), home = root.appending(path: ".codex")
        try database(home, sql: """
            CREATE TABLE projects(id TEXT,name TEXT);
            CREATE TABLE project_roots(project_id TEXT,position INTEGER,path TEXT);
            CREATE TABLE threads(id TEXT,cwd TEXT,project_id TEXT);
            INSERT INTO projects VALUES('one','Current name'),('two','No history');
            INSERT INTO project_roots VALUES('one',0,'/projects/one'),('two',0,'/projects/two');
            """)
        try writeJSON(["local-projects": ["stale": ["rootPaths": ["/projects/deleted"], "name": "Deleted"]]], to: home.appending(path: ".codex-global-state.json"))
        let url = home.appending(path: "state_5.sqlite"), before = try Data(contentsOf: url)
        let scan = await LocalUsageScanner(codexHome: home, claudeHome: root.appending(path: "none"), cacheURL: root.appending(path: "cache.json")).scanAll()
        let projects = ProjectSummary.combining(events: scan.events, detected: scan.projects)
        XCTAssertEqual(Set(projects.map(\.name)), ["Current name", "No history"])
        XCTAssertTrue(projects.allSatisfy { !$0.hasRecordedUsage })
        XCTAssertTrue(scan.events.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testCurrentMembershipAndLegacyIDMigrationResolveRemovedWorktrees() throws {
        let root = try fixture(), home = root.appending(path: ".codex"), thread = UUID().uuidString.lowercased()
        try database(home, sql: """
            CREATE TABLE projects(id TEXT,name TEXT);
            CREATE TABLE project_roots(project_id TEXT,position INTEGER,path TEXT);
            CREATE TABLE threads(id TEXT,cwd TEXT,project_id TEXT);
            INSERT INTO projects VALUES('current','FamilySimpl');
            INSERT INTO project_roots VALUES('current',0,'/projects/family');
            """)
        try writeJSON([
            "app-server-project-id-by-legacy-project-id-by-host": ["local:" + home.path: ["legacy": "current"]],
            "thread-project-assignments": [thread: ["projectKind": "local", "projectId": "legacy"]]
        ], to: home.appending(path: ".codex-global-state.json"))
        let catalog = CodexProjectCatalog(home: home)
        let source = "/missing/rollout-parent_\(thread).jsonl"
        XCTAssertEqual(catalog.project(for: "/removed/worktree/familysimpl", sourcePath: source).path, "/projects/family")
        try database(home, sql: "INSERT INTO projects VALUES('new','Moved chat'); INSERT INTO project_roots VALUES('new',0,'/projects/new'); INSERT INTO threads VALUES('\(thread)','/removed/worktree','new');")
        XCTAssertEqual(CodexProjectCatalog(home: home).project(for: "/removed/worktree", sourcePath: source).path, "/projects/new")
    }

    func testNestedRootsMultipleRootsAndEqualBasenamesRemainDistinct() throws {
        let root = try fixture(), home = root.appending(path: ".codex")
        try writeJSON(["local-projects": [
            "outer": ["name": "Outer", "rootPaths": ["/projects/site"]],
            "inner": ["name": "Inner", "rootPaths": ["/projects/site/inner", "/other/inner"]],
            "same": ["name": "Different site", "rootPaths": ["/elsewhere/site"]]
        ]], to: home.appending(path: ".codex-global-state.json"))
        let catalog = CodexProjectCatalog(home: home)
        XCTAssertEqual(catalog.project(for: "/projects/site/inner/src").path, "/projects/site/inner")
        XCTAssertEqual(catalog.project(for: "/other/inner/src").path, "/projects/site/inner")
        XCTAssertEqual(catalog.project(for: "/elsewhere/site/src").path, "/elsewhere/site")
        XCTAssertEqual(catalog.project(for: "/projects/site-sibling").path, "/projects/site-sibling")
        XCTAssertEqual(catalog.projects.count, 3)
    }

    func testSymlinkMoveAndGitCommonDirectoryGroupWithoutBasenameGuessing() throws {
        let root = try fixture(), home = root.appending(path: ".codex")
        let moved = root.appending(path: "moved/site"), old = root.appending(path: "site")
        try FileManager.default.createDirectory(at: moved.appending(path: ".git/worktrees/branch"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: old, withDestinationURL: moved)
        let worktree = root.appending(path: "worktree/site")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(moved.appending(path: ".git/worktrees/branch").path)\n".write(to: worktree.appending(path: ".git"), atomically: false, encoding: .utf8)
        try "../..\n".write(to: moved.appending(path: ".git/worktrees/branch/commondir"), atomically: false, encoding: .utf8)
        try writeJSON(["local-projects": ["site": ["name": "Site", "rootPaths": [old.path]]]], to: home.appending(path: ".codex-global-state.json"))
        let catalog = CodexProjectCatalog(home: home)
        XCTAssertEqual(catalog.project(for: moved.appending(path: "missing/subfolder").path).path, old.path)
        XCTAssertEqual(catalog.project(for: worktree.appending(path: "src").path).path, old.path)
    }

    func testCatalogChangesReclassifyCachedUsageWithoutChangingResetsOrCache() async throws {
        let root = try fixture(), home = root.appending(path: ".codex"), id = UUID().uuidString.lowercased()
        let cache = root.appending(path: "cache.json"), now = Date()
        try writeSession(home, id: id, cwd: "/missing/worktree/site", at: now.addingTimeInterval(-10))
        let scanner = LocalUsageScanner(codexHome: home, claudeHome: root.appending(path: "none"), cacheURL: cache)
        let before = await scanner.scanAll(now: now), bytes = try Data(contentsOf: cache)
        try writeJSON([
            "local-projects": ["site": ["name": "Site", "rootPaths": ["/projects/site"]]],
            "thread-project-assignments": [id: ["projectKind": "local", "projectId": "site"]]
        ], to: home.appending(path: ".codex-global-state.json"))
        let after = await scanner.scanAll(now: now)
        XCTAssertEqual(after.events.first?.projectPath, "/projects/site")
        XCTAssertEqual(after.events.map(\.id), before.events.map(\.id))
        XCTAssertEqual(after.events.map(\.tokens), before.events.map(\.tokens))
        XCTAssertEqual(after.events.map(\.apiEquivalentUSD), before.events.map(\.apiEquivalentUSD))
        XCTAssertEqual(after.events.map(\.timestamp), before.events.map(\.timestamp))
        XCTAssertEqual(after.resetEvents, before.resetEvents)
        XCTAssertEqual(after.observations, before.observations)
        XCTAssertEqual(try Data(contentsOf: cache), bytes)
    }

    func testUnavailableDatabaseFallsBackAndDoesNotCreateDatabase() throws {
        let root = try fixture(), home = root.appending(path: ".codex")
        try writeJSON(["electron-saved-workspace-roots": ["/projects/one"], "electron-workspace-root-labels": ["/projects/one": "Renamed"]], to: home.appending(path: ".codex-global-state.json"))
        XCTAssertEqual(CodexProjectCatalog(home: home).projects.first?.name, "Renamed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: "state_5.sqlite").path))
    }
}
