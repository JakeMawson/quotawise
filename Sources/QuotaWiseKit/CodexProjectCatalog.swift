import Foundation
import SQLite3

/// Read-only project metadata. Usage amounts and reset evidence never come from
/// this catalog; it supplies identities and names for the existing history.
struct CodexProjectCatalog {
    private struct Record {
        let id: String
        let name: String
        let roots: [String]
    }

    private struct StoreSnapshot {
        let records: [Record]
        let threads: [[String?]]
    }

    let projects: [ProjectSummary]
    private let roots: [(alias: String, project: ProjectSummary)]
    private let memberships: [String: ProjectSummary]
    private let labels: [String: String]

    init(home: URL) {
        let data = try? Data(contentsOf: home.appending(path: ".codex-global-state.json"))
        let state = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let labels = state["electron-workspace-root-labels"] as? [String: String] ?? [:]
        self.labels = labels
        let legacy = state["local-projects"] as? [String: [String: Any]] ?? [:]
        let snapshot = Self.readStore(home: home)
        var records = snapshot?.records ?? legacy.keys.sorted().compactMap { id in
            guard let item = legacy[id], let paths = item["rootPaths"] as? [String], !paths.isEmpty else { return nil }
            return Record(id: id, name: item["name"] as? String ?? "", roots: paths)
        }
        if snapshot == nil, records.isEmpty {
            records = (state["electron-saved-workspace-roots"] as? [String] ?? []).map {
                Record(id: $0, name: labels[$0] ?? URL(filePath: $0).displayProjectName, roots: [$0])
            }
        }

        var byID: [String: ProjectSummary] = [:]
        var byCanonicalRoot: [String: ProjectSummary] = [:]
        var aliases: [(String, ProjectSummary)] = []
        for record in records.sorted(by: { $0.id < $1.id }) {
            guard let first = record.roots.first, first.hasPrefix("/") else { continue }
            // The registered path remains the display/filter identity. Resolved
            // paths are aliases, including an old symlink after a project move.
            let path = Self.lexicalPath(first)
            let canonical = Self.resolvedPath(first)
            let project = byCanonicalRoot[canonical] ?? ProjectSummary(
                path: path,
                name: record.name.isEmpty ? URL(filePath: path).displayProjectName : record.name,
                provider: .codex, credits: 0, lastUsed: .distantPast, hasRecordedUsage: false
            )
            byCanonicalRoot[canonical] = project
            byID[record.id] = project
            for root in record.roots where root.hasPrefix("/") {
                aliases.append((Self.lexicalPath(root), project))
                aliases.append((Self.resolvedPath(root), project))
            }
        }

        // Current Codex versions migrate legacy project IDs to the state DB.
        // Only consume mappings belonging to this configured local Codex home.
        let migrations = state["app-server-project-id-by-legacy-project-id-by-host"] as? [String: [String: String]] ?? [:]
        for (host, mapping) in migrations where host.hasPrefix("local:")
            && Self.resolvedPath(String(host.dropFirst("local:".count))) == Self.resolvedPath(home.path) {
            for (oldID, newID) in mapping { byID[oldID] = byID[newID] }
        }
        let assignments = state["thread-project-assignments"] as? [String: [String: String]] ?? [:]
        var memberships: [String: ProjectSummary] = [:]
        for (thread, assignment) in assignments where assignment["projectKind"] == "local" {
            if let id = assignment["projectId"], let project = byID[id] { memberships[thread.lowercased()] = project }
        }
        for row in snapshot?.threads ?? [] {
            guard let id = row[0], let projectID = row[2], let project = byID[projectID] else { continue }
            memberships[id.lowercased()] = project
        }
        self.memberships = memberships
        roots = aliases.sorted { $0.0.count > $1.0.count }
        projects = Array(Set(byID.values)).sorted { $0.path < $1.path }
    }

    func project(for path: String, sourcePath: String? = nil) -> (path: String, name: String) {
        if let sourcePath {
            let name = URL(filePath: sourcePath).deletingPathExtension().lastPathComponent
            let thread = UUID(uuidString: String(name.suffix(36)))?.uuidString.lowercased() ?? name.lowercased()
            if let project = memberships[thread] { return (project.path, project.name) }
        }
        let lexical = Self.lexicalPath(path)
        let resolved = Self.resolvedPath(path)
        if let project = matchingRoot(lexical) ?? matchingRoot(resolved) { return (project.path, project.name) }
        if let commonRoot = Self.gitWorktreeRoot(for: resolved) {
            let project = matchingRoot(commonRoot)
            return (project?.path ?? commonRoot, project?.name ?? URL(filePath: commonRoot).displayProjectName)
        }
        let label = labels.keys.filter { lexical == $0 || lexical.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        return (lexical, label.flatMap { labels[$0] } ?? URL(filePath: lexical).displayProjectName)
    }

    private func matchingRoot(_ path: String) -> ProjectSummary? {
        roots.first { alias, _ in
            path == alias || (alias != "/" && alias != FileManager.default.homeDirectoryForCurrentUser.path
                && path.hasPrefix(alias + "/"))
        }?.project
    }

    private static func lexicalPath(_ path: String) -> String {
        guard path.hasPrefix("/") || path.hasPrefix("~") else { return path }
        return URL(filePath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }

    private static func resolvedPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var ancestor = URL(filePath: path), missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var result = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missing.reversed() { result.append(path: component) }
        return result.path
    }

    private static func gitWorktreeRoot(for path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var directory = URL(filePath: path)
        while directory.path != "/" {
            let git = directory.appending(path: ".git")
            if let pointer = try? String(contentsOf: git, encoding: .utf8), pointer.hasPrefix("gitdir:") {
                let value = pointer.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                let gitDirectory = URL(fileURLWithPath: value, isDirectory: true,
                    relativeTo: URL(fileURLWithPath: directory.path, isDirectory: true)).standardizedFileURL
                guard let common = try? String(contentsOf: gitDirectory.appending(path: "commondir"), encoding: .utf8) else { return nil }
                let shared = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines),
                    isDirectory: true, relativeTo: gitDirectory).standardizedFileURL
                guard shared.lastPathComponent == ".git" else { return nil }
                return resolvedPath(shared.deletingLastPathComponent().path)
            }
            if FileManager.default.fileExists(atPath: git.path) { return nil }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private static func readStore(home: URL) -> StoreSnapshot? {
        let files = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        let databases = files.compactMap { url -> (Int, URL)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (version, url)
        }.sorted { $0.0 > $1.0 }
        guard let url = databases.first?.1 else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)
        sqlite3_exec(database, "PRAGMA query_only=ON; BEGIN", nil, nil, nil)
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }

        func rows(_ sql: String) -> [[String?]]? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            var values: [[String?]] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return values }
                guard result == SQLITE_ROW else { return nil }
                values.append((0..<sqlite3_column_count(statement)).map { column in
                    sqlite3_column_text(statement, column).map { String(cString: $0) }
                })
            }
        }
        guard let saved = rows("SELECT p.id,p.name,r.path FROM projects p JOIN project_roots r ON r.project_id=p.id ORDER BY p.id,r.position") else { return nil }
        let grouped = Dictionary(grouping: saved, by: { $0[0] ?? "" })
        let records = grouped.compactMap { id, rows -> Record? in
            let paths = rows.compactMap { $0[2] }
            guard !id.isEmpty, !paths.isEmpty else { return nil }
            return Record(id: id, name: rows.first?[1] ?? "", roots: paths)
        }
        let threads = rows("SELECT id,cwd,project_id FROM threads") ?? []
        return StoreSnapshot(records: records, threads: threads)
    }
}

extension ProjectSummary {
    static func combining(events: [UsageEvent], detected: [ProjectSummary]) -> [ProjectSummary] {
        let grouped = Dictionary(grouping: events, by: { "\($0.provider.rawValue):\($0.projectPath)" })
        var summaries = Dictionary(uniqueKeysWithValues: detected.map { ("\($0.provider.rawValue):\($0.path)", $0) })
        for (id, values) in grouped {
            guard let latest = values.max(by: { $0.timestamp < $1.timestamp }) else { continue }
            summaries[id] = ProjectSummary(path: latest.projectPath, name: latest.projectName, provider: latest.provider,
                credits: values.reduce(0) { $0 + $1.credits }, lastUsed: latest.timestamp)
        }
        return summaries.values.sorted {
            if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
            if $0.lastUsed != $1.lastUsed { return $0.lastUsed > $1.lastUsed }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.path < $1.path
        }
    }
}
