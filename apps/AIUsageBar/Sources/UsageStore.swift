import Foundation

final class UsageStore: ObservableObject {
    @Published private(set) var payload: UsagePayload?
    @Published private(set) var costHistory: CostHistory?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRefreshingCost = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var costErrorMessage: String?
    @Published private(set) var statusSummary = StatusSummary.loading
    @Published private var hiddenTopBarAccountIDs = TopBarPreferences.loadHiddenIDs()
    private var consumedTopBarAliasIDs = TopBarPreferences.loadConsumedAliasIDs()

    private let runner = CLIRunner()
    private let costRunner = CostRunner()
    private var history = UsageHistory.load()
    private var liveRefreshInFlight = false
    private var costRefreshInFlight = false
    private var liveGeneration = 0
    private var completedLiveGeneration = 0

    var codexAccounts: [UsageAccount] {
        payload?.accounts.filter { $0.isCodex } ?? []
    }

    var claudeAccount: UsageAccount? {
        payload?.accounts.first { $0.isClaude }
    }

    var activeCodexAccount: UsageAccount? {
        codexAccounts.first { $0.isActive }
    }

    var workingCodexAccounts: [UsageAccount] {
        let working = orderedCodexAccounts.filter { $0.status == "ok" && hasTopBarBudget($0) }
        let active = working.filter { $0.isActive }
        return active + working.filter { !$0.isActive }
    }

    var workingClaudeAccount: UsageAccount? {
        guard let claudeAccount, claudeAccount.status == "ok", hasTopBarBudget(claudeAccount) else {
            return nil
        }
        return claudeAccount
    }

    var topBarSelectableAccounts: [UsageAccount] {
        orderedCodexAccounts + [claudeAccount].compactMap { $0 }
    }

    var lastUpdatedText: String {
        let dates = payload?.accounts.compactMap { $0.snapshot?.lastSeenDate } ?? []
        return TimeText.relativeAge(dates.max())
    }

    func refresh(cached: Bool) {
        if cached {
            guard !liveRefreshInFlight else { return }
            performCachedRefresh(generation: liveGeneration, pairedWithLive: false)
        } else if let generation = beginLiveRefresh() {
            performLiveRefresh(generation: generation)
        }
    }

    func refreshCachedAndLive() {
        guard !liveRefreshInFlight else { return }
        liveGeneration += 1
        let generation = liveGeneration
        performCachedRefresh(generation: generation, pairedWithLive: true)
        liveRefreshInFlight = true
        isRefreshing = true
        performLiveRefresh(generation: generation)
    }

    private func beginLiveRefresh() -> Int? {
        guard !liveRefreshInFlight else { return nil }
        liveGeneration += 1
        liveRefreshInFlight = true
        isRefreshing = true
        return liveGeneration
    }

    private func performCachedRefresh(generation: Int, pairedWithLive: Bool) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let payload = try self.runner.fetch(cached: true)
                DispatchQueue.main.async {
                    let sameGeneration = generation == self.liveGeneration
                    let liveHasNotFinished = self.completedLiveGeneration < generation
                    let eligible = pairedWithLive
                        ? sameGeneration && liveHasNotFinished
                        : sameGeneration && !self.liveRefreshInFlight
                    if eligible {
                        self.apply(payload: payload)
                    }
                }
            } catch {
                // Cached data is opportunistic; the paired live request owns errors.
            }
        }
    }

    private func performLiveRefresh(generation: Int) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let payload = try self.runner.fetch(cached: false)
                DispatchQueue.main.async {
                    guard generation == self.liveGeneration else { return }
                    self.completedLiveGeneration = generation
                    self.apply(payload: payload)
                    self.isRefreshing = false
                    self.liveRefreshInFlight = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard generation == self.liveGeneration else { return }
                    self.completedLiveGeneration = generation
                    self.errorMessage = error.localizedDescription
                    self.updateStatusSummary()
                    self.isRefreshing = false
                    self.liveRefreshInFlight = false
                }
            }
        }
    }

    func refreshNow() {
        refreshCachedAndLive()
        refreshCostHistory(force: true)
    }

    func accountMutationCompleted() {
        liveGeneration += 1
        liveRefreshInFlight = false
        isRefreshing = false
    }

    func refreshCostHistory(force: Bool = false) {
        if !force, let costHistory, Date().timeIntervalSince(costHistory.generatedAt) < 900 {
            return
        }

        guard !costRefreshInFlight else { return }
        costRefreshInFlight = true
        DispatchQueue.main.async {
            self.isRefreshingCost = true
        }

        DispatchQueue.global(qos: .utility).async {
            do {
                let history = try self.costRunner.fetchDailyHistory()
                DispatchQueue.main.async {
                    self.costHistory = history
                    self.costErrorMessage = nil
                    self.isRefreshingCost = false
                    self.costRefreshInFlight = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.costErrorMessage = error.localizedDescription
                    self.isRefreshingCost = false
                    self.costRefreshInFlight = false
                }
            }
        }
    }

    func historyValues(for account: UsageAccount, period: BudgetPeriod) -> [Double] {
        history.values(for: account, period: period)
    }

    func pace(for account: UsageAccount, period: BudgetPeriod) -> PaceAssessment {
        PaceCalculator.assessment(
            for: account.snapshot,
            period: period,
            history: history.samples(for: account)
        )
    }

    func worstPace(for account: UsageAccount) -> PaceAssessment {
        PaceCalculator.worst(
            for: account.snapshot,
            history: history.samples(for: account)
        )
    }

    func canShowInTopBar(_ account: UsageAccount) -> Bool {
        hasTopBarBudget(account)
    }

    func canConfigureTopBarVisibility(_ account: UsageAccount) -> Bool {
        account.preferenceID != nil && hasTopBarBudget(account)
    }

    func isTopBarVisible(_ account: UsageAccount) -> Bool {
        guard canShowInTopBar(account) else { return false }
        guard let preferenceID = account.preferenceID else { return true }
        return !hiddenTopBarAccountIDs.contains(preferenceID)
    }

    func setTopBarVisible(_ account: UsageAccount, visible: Bool) {
        guard let preferenceID = account.preferenceID else { return }
        if visible {
            hiddenTopBarAccountIDs.remove(preferenceID)
        } else {
            hiddenTopBarAccountIDs.insert(preferenceID)
        }
        TopBarPreferences.saveHiddenIDs(hiddenTopBarAccountIDs)
        updateStatusSummary()
    }

    func topBarPreviewValue(for account: UsageAccount) -> String {
        guard canShowInTopBar(account) else {
            return topBarUnavailableReason(for: account)
        }
        if account.stale || account.hasProblem {
            return "Cached \(shortValue(for: account))"
        }
        return shortValue(for: account)
    }

    private func apply(payload: UsagePayload) {
        migrateStableTopBarPreferences(accounts: payload.accounts)
        discardAmbiguousLegacyTopBarPreferences(accounts: payload.accounts)
        self.payload = payload
        self.errorMessage = nil
        history.record(accounts: payload.accounts)
        history.save()
        updateStatusSummary()
    }

    private func migrateStableTopBarPreferences(accounts: [UsageAccount]) {
        let originalHiddenIDs = hiddenTopBarAccountIDs
        let originalConsumedAliases = consumedTopBarAliasIDs
        let migrated = TopBarPreferences.migratedHiddenIDs(
            hiddenTopBarAccountIDs,
            accounts: accounts,
            consumedAliasIDs: &consumedTopBarAliasIDs
        )
        guard migrated != originalHiddenIDs || consumedTopBarAliasIDs != originalConsumedAliases else {
            return
        }
        hiddenTopBarAccountIDs = migrated
        TopBarPreferences.saveHiddenIDs(hiddenTopBarAccountIDs)
        TopBarPreferences.saveConsumedAliasIDs(consumedTopBarAliasIDs)
    }

    private func discardAmbiguousLegacyTopBarPreferences(accounts: [UsageAccount]) {
        let legacyIDs = Set(accounts.map(\.id))
        let originalCount = hiddenTopBarAccountIDs.count
        hiddenTopBarAccountIDs.subtract(legacyIDs)
        let changed = hiddenTopBarAccountIDs.count != originalCount
        if changed {
            TopBarPreferences.saveHiddenIDs(hiddenTopBarAccountIDs)
        }
    }

    private func updateStatusSummary() {
        if let errorMessage, payload == nil {
            statusSummary = StatusSummary(
                title: "AI",
                tooltip: errorMessage,
                severity: .critical
            )
            return
        }

        guard payload != nil else {
            statusSummary = .loading
            return
        }

        let active = activeCodexAccount
        let claude = claudeAccount
        let visibleCodexAccounts = workingCodexAccounts.filter { isTopBarVisible($0) }
        let visibleClaudeAccount = workingClaudeAccount.flatMap { isTopBarVisible($0) ? $0 : nil }
        let title = titleText(codexAccounts: visibleCodexAccounts, claudeAccount: visibleClaudeAccount)

        if let errorMessage {
            statusSummary = StatusSummary(
                title: "Warning \(title)",
                tooltip: "Live refresh failed: \(errorMessage)",
                severity: .critical
            )
            return
        }

        let workingCandidates = workingCodexAccounts + [workingClaudeAccount].compactMap { $0 }
        let problemCandidates = [active, claude].compactMap { $0 }.filter { $0.hasProblem }
        let worst = workingCandidates
            .map { worstPace(for: $0) }
            .max { $0.severity < $1.severity } ?? .learning
        let severity: PaceSeverity = problemCandidates.isEmpty ? worst.severity : .critical
        let tooltip = (workingCandidates + problemCandidates)
            .map { tooltipLine(for: $0) }
            .joined(separator: "\n")

        statusSummary = StatusSummary(
            title: title,
            tooltip: tooltip.isEmpty ? "Usage unavailable" : tooltip,
            severity: severity
        )
    }

    private var orderedCodexAccounts: [UsageAccount] {
        let active = codexAccounts.filter { $0.isActive }
        return active + codexAccounts.filter { !$0.isActive }
    }

    private func hasTopBarBudget(_ account: UsageAccount) -> Bool {
        guard let snapshot = account.snapshot else { return false }
        return !snapshot.isFreePlan && snapshot.limitingBudget != nil
    }

    private func topBarUnavailableReason(for account: UsageAccount) -> String {
        if account.snapshot?.isFreePlan == true {
            return "Free plan"
        }
        if account.hasProblem {
            if !account.message.isEmpty {
                return account.message
            }
            return account.status.replacingOccurrences(of: "_", with: " ").capitalized
        }
        if account.snapshot == nil {
            return "No usage snapshot yet"
        }
        return "No remaining-budget value"
    }

    private func codexTitleValue(for accounts: [UsageAccount]) -> String {
        let parts = accounts.map { account in
            "\(compactName(account.name)) \(shortValue(for: account))"
        }
        return parts.isEmpty ? "--" : parts.joined(separator: " ")
    }

    private func titleText(codexAccounts: [UsageAccount], claudeAccount: UsageAccount?) -> String {
        var parts: [String] = []
        if !codexAccounts.isEmpty {
            parts.append("CX \(codexTitleValue(for: codexAccounts))")
        }
        if let claudeAccount {
            parts.append("CC \(shortValue(for: claudeAccount))")
        }
        return parts.isEmpty ? "AI" : parts.joined(separator: " | ")
    }

    private func compactName(_ name: String) -> String {
        if name.count <= 6 {
            return name
        }
        return String(name.prefix(6))
    }

    private func tooltipLine(for account: UsageAccount) -> String {
        if account.hasProblem {
            let detail = account.message.isEmpty
                ? account.status.replacingOccurrences(of: "_", with: " ")
                : account.message
            return "\(account.displayName): \(detail)"
        }
        return "\(account.displayName): \(worstPace(for: account).detail)"
    }

    private func shortValue(for account: UsageAccount?) -> String {
        guard let account, let snapshot = account.snapshot else { return "--" }
        if snapshot.isFreePlan { return "free" }
        guard let budget = snapshot.limitingBudget else { return "--" }
        let stalePrefix = account.stale ? "~" : ""
        let percent = TimeText.percent(budget.remainingPercent)
        let reset = TimeText.compactSingleUnitReset(budget.resetDate)
        return "\(stalePrefix)\(budget.period.titleLabel)\(percent) \(reset)"
    }
}

enum TopBarPreferences {
    private static let hiddenIDsKey = "AIUsageBar.hiddenTopBarAccountIDs"
    private static let consumedAliasIDsKey = "AIUsageBar.consumedTopBarAliasIDs"

    static func loadHiddenIDs() -> Set<String> {
        let values = UserDefaults.standard.stringArray(forKey: hiddenIDsKey) ?? []
        return Set(values)
    }

    static func saveHiddenIDs(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids).sorted(), forKey: hiddenIDsKey)
    }

    static func loadConsumedAliasIDs() -> Set<String> {
        let values = UserDefaults.standard.stringArray(forKey: consumedAliasIDsKey) ?? []
        return Set(values)
    }

    static func saveConsumedAliasIDs(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids).sorted(), forKey: consumedAliasIDsKey)
    }

    static func migratedHiddenIDs(
        _ ids: Set<String>,
        accounts: [UsageAccount],
        consumedAliasIDs: inout Set<String>
    ) -> Set<String> {
        let identityOccupants = accounts.flatMap { account in
            [account.preferenceID].compactMap { $0 } + account.preferenceAliasIDs
        }
        let aliasCounts = identityOccupants
            .reduce(into: [String: Int]()) { counts, identity in
                counts[identity, default: 0] += 1
            }
        var result = ids
        for account in accounts {
            guard let preferenceID = account.preferenceID else { continue }
            for aliasID in account.preferenceAliasIDs
                where !consumedAliasIDs.contains(aliasID) {
                if aliasCounts[aliasID] == 1, result.remove(aliasID) != nil {
                    result.insert(preferenceID)
                }
                consumedAliasIDs.insert(aliasID)
            }
        }
        return result
    }

    static func migratedHiddenIDs(_ ids: Set<String>, accounts: [UsageAccount]) -> Set<String> {
        var consumedAliasIDs: Set<String> = []
        return migratedHiddenIDs(ids, accounts: accounts, consumedAliasIDs: &consumedAliasIDs)
    }
}
