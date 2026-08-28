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
    private(set) var consumedAliasIDs: Set<String> = []

    init(
        samplesByAccount: [String: [HistorySample]] = [:],
        consumedAliasIDs: Set<String> = []
    ) {
        self.samplesByAccount = samplesByAccount
        self.consumedAliasIDs = consumedAliasIDs
    }

    private enum CodingKeys: String, CodingKey {
        case samplesByAccount
        case consumedAliasIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        samplesByAccount = try container.decodeIfPresent(
            [String: [HistorySample]].self,
            forKey: .samplesByAccount
        ) ?? [:]
        consumedAliasIDs = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .consumedAliasIDs
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(samplesByAccount, forKey: .samplesByAccount)
        try container.encode(consumedAliasIDs, forKey: .consumedAliasIDs)
    }

    static func load() -> UsageHistory {
        let url = historyURL()
        guard let data = try? Data(contentsOf: url) else {
            return UsageHistory()
        }
        return (try? JSONDecoder().decode(UsageHistory.self, from: data)) ?? UsageHistory()
    }

    mutating func record(accounts: [UsageAccount]) {
        let identityOccupants = accounts.flatMap { account in
            [account.historyID].compactMap { $0 } + account.historyAliasIDs
        }
        let aliasCounts = identityOccupants
            .reduce(into: [String: Int]()) { counts, identity in
                counts[identity, default: 0] += 1
            }
        for account in accounts {
            guard let historyID = account.historyID else { continue }
            var samples = samplesByAccount[historyID] ?? []
            var migratedLegacySamples = false
            for aliasID in account.historyAliasIDs
                where !consumedAliasIDs.contains(aliasID) {
                if aliasCounts[aliasID] == 1,
                   aliasID != historyID,
                   let legacySamples = samplesByAccount.removeValue(forKey: aliasID) {
                    samples.append(contentsOf: legacySamples)
                    samples.sort { $0.timestamp < $1.timestamp }
                    samples = Array(samples.suffix(240))
                    migratedLegacySamples = true
                }
                consumedAliasIDs.insert(aliasID)
            }
            if migratedLegacySamples {
                samplesByAccount[historyID] = samples
            }
            guard account.status == "ok", !account.stale, let snapshot = account.snapshot else {
                continue
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
