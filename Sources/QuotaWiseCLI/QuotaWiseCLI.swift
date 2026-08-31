import Darwin
import Foundation
import QuotaWiseKit

@main
struct QuotaWiseCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let accepted = Set(["--json", "--offline", "-O"])
        var positional: [String] = []
        var project: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--project" {
                guard index + 1 < arguments.count, !arguments[index + 1].isEmpty else {
                    FileHandle.standardError.write(Data("codexusage-native: --project requires a value\n".utf8))
                    exit(2)
                }
                project = arguments[index + 1]
                index += 2
            } else if argument.hasPrefix("--project=") {
                let value = String(argument.dropFirst("--project=".count))
                guard !value.isEmpty else {
                    FileHandle.standardError.write(Data("codexusage-native: --project requires a value\n".utf8))
                    exit(2)
                }
                project = value
                index += 1
            } else if accepted.contains(argument) {
                index += 1
            } else {
                positional.append(argument)
                index += 1
            }
        }

        guard positional == ["codex", "daily"] else {
            FileHandle.standardError.write(
                Data("Usage: codexusage-native codex daily --json [--offline]\n".utf8)
            )
            exit(2)
        }

        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(filePath: NSString(string: $0).expandingTildeInPath, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        let report = await CodexUsageReporter.daily(codexHome: codexHome, project: project)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        do {
            let data = try encoder.encode(report)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            FileHandle.standardError.write(Data("codexusage-native: \(error)\n".utf8))
            exit(1)
        }
    }
}
