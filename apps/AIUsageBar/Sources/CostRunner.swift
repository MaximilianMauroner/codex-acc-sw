import Foundation

struct CostDay: Identifiable {
    let date: Date
    let cost: Double
    let tokens: UInt64
    let breakdown: [CostBreakdownEntry]

    var id: Date { date }
}

struct CostBreakdownEntry {
    let name: String
    let cost: Double
    let tokens: UInt64
    let models: [String]
}

struct CostHistory {
    let days: [CostDay]
    let source: String
    let pricingSource: String?
    let pricingIsEstimate: Bool
    let generatedAt: Date

    var totalCost: Double {
        days.reduce(0) { $0 + $1.cost }
    }

    var todayCost: Double {
        days.last?.cost ?? 0
    }

    var totalTokens: UInt64 {
        days.reduce(0) { $0 + $1.tokens }
    }

    var maxCost: Double {
        days.map(\.cost).max() ?? 0
    }
}

enum CostRunnerError: LocalizedError {
    case commandNotFound
    case commandFailed(String)
    case timedOut
    case invalidOutput
    case emptyHistory

    var errorDescription: String? {
        switch self {
        case .commandNotFound:
            return "context-bar was not found. Install it with npm, or keep npx available for automatic loading."
        case .commandFailed(let message):
            return message.isEmpty ? "context-bar failed to load cost history." : message
        case .timedOut:
            return "context-bar took too long to load cost history."
        case .invalidOutput:
            return "context-bar returned cost history in an unsupported format."
        case .emptyHistory:
            return "No local Codex or Claude cost rows were found for the last 30 days."
        }
    }
}

struct CostRunner {
    func fetchDailyHistory(dayCount: Int = 30) throws -> CostHistory {
        let request = try resolveCommand()
        let window = dateWindow(dayCount: dayCount)
        let reportArguments = [
            "daily",
            "--json",
            "--instances",
            "--since",
            window.since,
            "--until",
            window.until
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = request.argumentsPrefix + reportArguments
        process.environment = augmentedEnvironment()

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        let waitResult = waitForProcess(process, timeout: 25)
        if waitResult == .timedOut {
            process.terminate()
            throw CostRunnerError.timedOut
        }

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? ""
            throw CostRunnerError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return try parseHistory(
            outputData,
            source: request.displayName,
            dayCount: dayCount,
            startDate: window.startDate
        )
    }

    private func resolveCommand() throws -> CommandRequest {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["CONTEXT_BAR_BIN"], FileManager.default.isExecutableFile(atPath: expandedPath(explicit)) {
            return CommandRequest(
                executable: expandedPath(explicit),
                argumentsPrefix: [],
                displayName: "context-bar"
            )
        }

        if let contextBar = firstExecutable(named: "context-bar") {
            return CommandRequest(
                executable: contextBar,
                argumentsPrefix: [],
                displayName: "context-bar"
            )
        }

        if let npx = firstExecutable(named: "npx") {
            return CommandRequest(
                executable: npx,
                argumentsPrefix: ["--yes", "context-bar@latest"],
                displayName: "npx context-bar@latest"
            )
        }

        throw CostRunnerError.commandNotFound
    }

    private func parseHistory(
        _ data: Data,
        source: String,
        dayCount: Int,
        startDate: Date
    ) throws -> CostHistory {
        let object = try JSONSerialization.jsonObject(with: data)
        let root = object as? [String: Any]
        let reportKind = (root?["kind"] as? String)?.lowercased()
        let isInstanceReport = reportKind == "instances"
        let rows = candidateRows(in: object)
        guard !rows.isEmpty else {
            throw CostRunnerError.invalidOutput
        }

        var groupedRows: [String: CostRow] = [:]
        var summedRows: [String: CostRow] = [:]
        var breakdownRows: [String: [CostBreakdownEntry]] = [:]

        for row in rows {
            guard let label = stringValue(row, keys: ["label", "date", "day"]) else { continue }
            guard let date = parseDay(label) else { continue }
            let normalizedLabel = dayKey(for: date)
            let cost = doubleValue(row, keys: ["cost", "cost_usd", "costUSD", "total_cost", "totalCost", "usd"]) ?? 0
            let tokens = tokenTotal(in: row)
            let costRow = CostRow(date: date, cost: cost, tokens: tokens)

            let kind = stringValue(row, keys: ["kind"])?.lowercased()
            let sublabel = stringValue(row, keys: ["sublabel", "agent", "provider"])
            let normalizedSublabel = sublabel?.lowercased()
            let isTotalRow = !isInstanceReport && (kind == "group" || normalizedSublabel == "all" || normalizedSublabel == "total")

            if isTotalRow {
                groupedRows[normalizedLabel] = costRow
            } else {
                if let entry = breakdownEntry(from: row, fallbackName: sublabel) {
                    breakdownRows[normalizedLabel, default: []].append(entry)
                }

                let existing = summedRows[normalizedLabel]
                summedRows[normalizedLabel] = CostRow(
                    date: date,
                    cost: (existing?.cost ?? 0) + cost,
                    tokens: (existing?.tokens ?? 0) + tokens
                )
            }
        }

        let calendar = Calendar.current
        let days = (0..<dayCount).compactMap { offset -> CostDay? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }
            let key = dayKey(for: date)
            let row = groupedRows[key] ?? summedRows[key]
            return CostDay(
                date: date,
                cost: row?.cost ?? 0,
                tokens: row?.tokens ?? 0,
                breakdown: sortedBreakdown(breakdownRows[key] ?? [])
            )
        }

        guard days.contains(where: { $0.cost > 0 || $0.tokens > 0 }) else {
            throw CostRunnerError.emptyHistory
        }

        return CostHistory(
            days: days,
            source: source,
            pricingSource: root?["pricing_source"] as? String,
            pricingIsEstimate: root?["pricing_is_estimate"] as? Bool ?? true,
            generatedAt: Date()
        )
    }

    private func waitForProcess(_ process: Process, timeout: TimeInterval) -> DispatchTimeoutResult {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }
        return group.wait(timeout: .now() + timeout)
    }

    private func candidateRows(in object: Any) -> [[String: Any]] {
        if let array = object as? [[String: Any]] {
            return array
        }

        guard let dictionary = object as? [String: Any] else {
            return []
        }

        let preferredKeys = ["rows", "by_day", "days", "items"]
        for key in preferredKeys {
            if let rows = dictionary[key] as? [[String: Any]] {
                return rows
            }
        }

        for key in ["data", "report", "result"] {
            if let nested = dictionary[key] {
                let rows = candidateRows(in: nested)
                if !rows.isEmpty {
                    return rows
                }
            }
        }

        return []
    }

    private func breakdownEntry(from row: [String: Any], fallbackName: String?) -> CostBreakdownEntry? {
        let name = fallbackName ?? stringValue(row, keys: ["name", "account", "project"]) ?? "Usage"
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return nil }

        let cost = doubleValue(row, keys: ["cost", "cost_usd", "costUSD", "total_cost", "totalCost", "usd"]) ?? 0
        let tokens = tokenTotal(in: row)
        guard cost > 0 || tokens > 0 else { return nil }

        return CostBreakdownEntry(
            name: normalizedName,
            cost: cost,
            tokens: tokens,
            models: stringArrayValue(row, keys: ["models", "model"])
        )
    }

    private func sortedBreakdown(_ entries: [CostBreakdownEntry]) -> [CostBreakdownEntry] {
        entries.sorted {
            if $0.cost == $1.cost {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.cost > $1.cost
        }
    }

    private func tokenTotal(in row: [String: Any]) -> UInt64 {
        let directTotal = uintValue(row, keys: ["tokens", "total_tokens", "totalTokens"])
        if let directTotal {
            return directTotal
        }

        let input = uintValue(row, keys: ["input"]) ?? 0
        let output = uintValue(row, keys: ["output"]) ?? 0
        let cacheCreation = uintValue(row, keys: ["cache_creation", "cacheCreation"]) ?? 0
        let cacheRead = uintValue(row, keys: ["cache_read", "cacheRead"]) ?? 0
        return input + output + cacheCreation + cacheRead
    }

    private func dateWindow(dayCount: Int) -> (startDate: Date, since: String, until: String) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startDate = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) ?? today
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return (
            startDate,
            formatter.string(from: startDate),
            formatter.string(from: today)
        )
    }

    private func parseDay(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar.current
        for format in ["yyyy-MM-dd", "yyyyMMdd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return Calendar.current.startOfDay(for: date)
            }
        }
        return nil
    }

    private func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func stringValue(_ row: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = row[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func doubleValue(_ row: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = row[key] as? Double {
                return value
            }
            if let value = row[key] as? Int {
                return Double(value)
            }
            if let value = row[key] as? String, let parsed = Double(value) {
                return parsed
            }
        }
        return nil
    }

    private func uintValue(_ row: [String: Any], keys: [String]) -> UInt64? {
        for key in keys {
            if let value = row[key] as? UInt64 {
                return value
            }
            if let value = row[key] as? Int, value >= 0 {
                return UInt64(value)
            }
            if let value = row[key] as? Double, value >= 0 {
                return UInt64(value)
            }
            if let value = row[key] as? String, let parsed = UInt64(value) {
                return parsed
            }
        }
        return nil
    }

    private func stringArrayValue(_ row: [String: Any], keys: [String]) -> [String] {
        for key in keys {
            if let values = row[key] as? [String] {
                return values
            }
            if let value = row[key] as? String, !value.isEmpty {
                return [value]
            }
        }
        return []
    }

    private func firstExecutable(named executableName: String) -> String? {
        executableSearchPaths()
            .map { "\($0)/\(executableName)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func executableSearchPaths() -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configuredPath = environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        return [
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ] + configuredPath
    }

    private func augmentedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existing = environment["PATH"] ?? ""
        environment["PATH"] = (executableSearchPaths() + [existing])
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        return environment
    }

    private func expandedPath(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(String(path.dropFirst(2)))
            .path
    }
}

private struct CommandRequest {
    let executable: String
    let argumentsPrefix: [String]
    let displayName: String
}

private struct CostRow {
    let date: Date
    let cost: Double
    let tokens: UInt64
}
