import Foundation

enum CLIRunnerError: LocalizedError {
    case commandNotFound
    case commandFailed(String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .commandNotFound:
            return "codex-account-switch was not found. Install it or set CODEX_ACCOUNT_SWITCH_BIN."
        case .commandFailed(let message):
            return message.isEmpty ? "Usage command failed." : message
        case .invalidOutput:
            return "Usage command returned invalid JSON."
        }
    }
}

struct CLIRunner {
    func fetch(cached: Bool) throws -> UsagePayload {
        guard let command = resolveCommand() else {
            throw CLIRunnerError.commandNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = cached
            ? ["widget", "--format", "json", "--cached"]
            : ["widget", "--format", "json", "--timeout", "8"]
        process.environment = augmentedEnvironment()

        let result = try ProcessCapture.run(process, timeout: 30)
        guard result.status == 0, !result.timedOut else {
            let message = String(data: result.error, encoding: .utf8) ?? ""
            throw CLIRunnerError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(UsagePayload.self, from: result.output)
        } catch {
            throw CLIRunnerError.invalidOutput
        }
    }

    private func resolveCommand() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["CODEX_ACCOUNT_SWITCH_BIN"], FileManager.default.isExecutableFile(atPath: explicit) {
            return explicit
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
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
        let home = FileManager.default.homeDirectoryForCurrentUser.path
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
}
