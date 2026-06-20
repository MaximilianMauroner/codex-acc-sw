import Foundation

struct AccountCommandOutput {
    let succeeded: Bool
    let title: String
    let detail: String
}

struct AccountCommandRunner {
    func run(_ arguments: [String]) -> AccountCommandOutput {
        guard let command = resolveCommand() else {
            return AccountCommandOutput(
                succeeded: false,
                title: "Command unavailable",
                detail: "codex-account-switch was not found. Install it or set CODEX_ACCOUNT_SWITCH_BIN."
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.environment = augmentedEnvironment()

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        do {
            input.fileHandleForWriting.closeFile()
            try process.run()
            process.waitUntilExit()
        } catch {
            return AccountCommandOutput(
                succeeded: false,
                title: "Command failed",
                detail: error.localizedDescription
            )
        }

        let outputText = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorText = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let detail = stripANSI([outputText, errorText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n"))
        let succeeded = process.terminationStatus == 0

        return AccountCommandOutput(
            succeeded: succeeded,
            title: succeeded ? "Done" : "Command failed",
            detail: detail.isEmpty ? "Exit code \(process.terminationStatus)" : detail
        )
    }

    func openCodexLoginTerminal(accountName: String) -> AccountCommandOutput {
        let path = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")
        let finishedMessage = "Saved \(accountName). You can close this window."
        let command = [
            "export PATH=\(shellQuoted(path)):\"$PATH\"",
            "codex login",
            "codex-account-switch save \(shellQuoted(accountName))",
            "echo",
            "echo \(shellQuoted(finishedMessage))"
        ].joined(separator: " && ")
        let script = """
        tell application "Terminal"
            activate
            do script "\(appleScriptEscaped(command))"
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return AccountCommandOutput(
                succeeded: false,
                title: "Terminal failed",
                detail: error.localizedDescription
            )
        }

        let outputText = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorText = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let detail = [outputText, errorText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let succeeded = process.terminationStatus == 0

        return AccountCommandOutput(
            succeeded: succeeded,
            title: succeeded ? "Login opened" : "Terminal failed",
            detail: detail.isEmpty
                ? "Terminal is running codex login, then saving \(accountName)."
                : detail
        )
    }

    private var home: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func resolveCommand() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["CODEX_ACCOUNT_SWITCH_BIN"],
           FileManager.default.isExecutableFile(atPath: explicit) {
            return explicit
        }

        let candidates = [
            "\(home)/.local/bin/codex-account-switch",
            "/opt/homebrew/bin/codex-account-switch",
            "/usr/local/bin/codex-account-switch",
            "/usr/bin/codex-account-switch"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func augmentedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let additions = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existing = environment["PATH"] ?? ""
        environment["PATH"] = (additions + [existing]).filter { !$0.isEmpty }.joined(separator: ":")
        return environment
    }

    private func stripANSI(_ value: String) -> String {
        value.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
