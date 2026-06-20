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

    private let runner = CLIRunner()
    private let costRunner = CostRunner()
    private var history = UsageHistory.load()
    private var liveRefreshInFlight = false
    private var costRefreshInFlight = false

    var codexAccounts: [UsageAccount] {
        payload?.accounts.filter { $0.isCodex } ?? []
    }

    var claudeAccount: UsageAccount? {
        payload?.accounts.first { $0.isClaude }
    }

    var activeCodexAccount: UsageAccount? {
        codexAccounts.first { $0.isActive } ?? codexAccounts.first
    }

    var workingCodexAccounts: [UsageAccount] {
        let working = orderedCodexAccounts.filter { hasTopBarBudget($0) }
        let active = working.filter { $0.isActive }
        return active + working.filter { !$0.isActive }
    }

    var workingClaudeAccount: UsageAccount? {
        guard let claudeAccount, hasTopBarBudget(claudeAccount) else {
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
        if !cached {
            guard !liveRefreshInFlight else { return }
            liveRefreshInFlight = true
            DispatchQueue.main.async {
                self.isRefreshing = true
            }
        }

        DispatchQueue.global(qos: cached ? .utility : .userInitiated).async {
            do {
                let payload = try self.runner.fetch(cached: cached)
                DispatchQueue.main.async {
                    self.apply(payload: payload)
                    if !cached {
                        self.isRefreshing = false
                        self.liveRefreshInFlight = false
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.updateStatusSummary()
                    if !cached {
                        self.isRefreshing = false
                        self.liveRefreshInFlight = false
                    }
                }
            }
        }
    }

    func refreshNow() {
        refresh(cached: true)
        refresh(cached: false)
        refreshCostHistory(force: true)
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

    func isTopBarVisible(_ account: UsageAccount) -> Bool {
        canShowInTopBar(account) && !hiddenTopBarAccountIDs.contains(account.id)
    }

    func setTopBarVisible(_ account: UsageAccount, visible: Bool) {
        if visible {
            hiddenTopBarAccountIDs.remove(account.id)
        } else {
            hiddenTopBarAccountIDs.insert(account.id)
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
        self.payload = payload
        self.errorMessage = nil
        history.record(accounts: payload.accounts)
        history.save()
        updateStatusSummary()
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

private enum TopBarPreferences {
    private static let hiddenIDsKey = "AIUsageBar.hiddenTopBarAccountIDs"

    static func loadHiddenIDs() -> Set<String> {
        let values = UserDefaults.standard.stringArray(forKey: hiddenIDsKey) ?? []
        return Set(values)
    }

    static func saveHiddenIDs(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids).sorted(), forKey: hiddenIDsKey)
    }
}
