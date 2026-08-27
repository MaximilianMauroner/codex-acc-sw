import Foundation

struct HistorySample: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let currentRemaining: Double?
    let weeklyRemaining: Double?
    let currentResetDate: Date?
    let weeklyResetDate: Date?
    let currentWindowMinutes: Double?
    let weeklyWindowMinutes: Double?

    init(
        timestamp: Date,
        currentRemaining: Double?,
        weeklyRemaining: Double?,
        currentResetDate: Date? = nil,
        weeklyResetDate: Date? = nil,
        currentWindowMinutes: Double? = nil,
        weeklyWindowMinutes: Double? = nil
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.currentRemaining = currentRemaining
        self.weeklyRemaining = weeklyRemaining
        self.currentResetDate = currentResetDate
        self.weeklyResetDate = weeklyResetDate
        self.currentWindowMinutes = currentWindowMinutes
        self.weeklyWindowMinutes = weeklyWindowMinutes
    }
}

struct UsageHistory: Codable {
    private(set) var samplesByAccount: [String: [HistorySample]] = [:]

    init(samplesByAccount: [String: [HistorySample]] = [:]) {
        self.samplesByAccount = samplesByAccount
    }

    static func load() -> UsageHistory {
        let url = historyURL()
        guard let data = try? Data(contentsOf: url) else {
            return UsageHistory()
        }
        return (try? JSONDecoder().decode(UsageHistory.self, from: data)) ?? UsageHistory()
    }

    mutating func record(accounts: [UsageAccount]) {
        let aliasCounts = accounts
            .flatMap(\.historyAliasIDs)
            .reduce(into: [String: Int]()) { counts, alias in
                counts[alias, default: 0] += 1
            }
        for account in accounts {
            guard account.status == "ok", !account.stale, let snapshot = account.snapshot else {
                continue
            }
            guard let historyID = account.historyID else { continue }
            var samples = samplesByAccount[historyID] ?? []
            for aliasID in account.historyAliasIDs where aliasCounts[aliasID] == 1 {
                guard aliasID != historyID, let legacySamples = samplesByAccount.removeValue(forKey: aliasID) else {
                    continue
                }
                samples.append(contentsOf: legacySamples)
                samples.sort { $0.timestamp < $1.timestamp }
                samples = Array(samples.suffix(240))
            }
            let timestamp = snapshot.lastSeenDate ?? Date()
            let sample = HistorySample(
                timestamp: timestamp,
                currentRemaining: snapshot.currentRemainingPercent,
                weeklyRemaining: snapshot.weeklyRemainingPercent,
                currentResetDate: snapshot.currentResetDate,
                weeklyResetDate: snapshot.weeklyResetDate,
                currentWindowMinutes: BudgetPeriod.current.windowMinutes(in: snapshot),
                weeklyWindowMinutes: BudgetPeriod.weekly.windowMinutes(in: snapshot)
            )
            if let last = samples.last, abs(last.timestamp.timeIntervalSince(timestamp)) < 30 {
                samples[samples.count - 1] = sample
            } else {
                samples.append(sample)
            }
            samples = Array(samples.suffix(240))
            samplesByAccount[historyID] = samples
        }
    }

    func samples(for account: UsageAccount) -> [HistorySample] {
        guard let historyID = account.historyID else { return [] }
        return samplesByAccount[historyID] ?? []
    }

    func values(for account: UsageAccount, period: BudgetPeriod) -> [Double] {
        samples(for: account).compactMap { sample in
            switch period {
            case .current: return sample.currentRemaining
            case .weekly: return sample.weeklyRemaining
            }
        }
    }

    func save() {
        let url = Self.historyURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func historyURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("AIUsageBar", isDirectory: true)
            .appendingPathComponent("history.json")
    }
}
