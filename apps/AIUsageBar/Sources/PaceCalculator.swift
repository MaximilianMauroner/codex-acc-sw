import Foundation

enum PaceCalculator {
    static func assessment(
        for snapshot: UsageSnapshot?,
        period: BudgetPeriod,
        history: [HistorySample]
    ) -> PaceAssessment {
        guard let snapshot else { return .learning }
        if snapshot.isFreePlan {
            return PaceAssessment(
                severity: .unavailable,
                label: "Free",
                detail: "Free plan",
                projectedRemaining: nil
            )
        }
        guard let remaining = period.remaining(in: snapshot) else {
            return .learning
        }
        if remaining <= 0 {
            return PaceAssessment(
                severity: .critical,
                label: "Empty",
                detail: "\(period.label) is empty",
                projectedRemaining: 0
            )
        }
        guard let resetDate = period.resetDate(in: snapshot) else {
            return .learning
        }

        let baseDate = snapshot.lastSeenDate ?? Date()
        let secondsToReset = max(0, resetDate.timeIntervalSince(baseDate))
        let burnPerSecond = recentBurnRate(for: period, history: history)
            ?? windowBurnRate(snapshot: snapshot, period: period, secondsToReset: secondsToReset)

        guard let burnPerSecond else {
            return PaceAssessment(
                severity: .steady,
                label: "Idle",
                detail: "\(period.label) has no recent burn",
                projectedRemaining: remaining
            )
        }

        let projectedRemaining = remaining - burnPerSecond * secondsToReset
        if projectedRemaining <= 0 {
            let secondsUntilEmpty = max(0, remaining / max(burnPerSecond, 0.000_001))
            let earlyBy = max(0, secondsToReset - secondsUntilEmpty)
            return PaceAssessment(
                severity: .critical,
                label: "Fast",
                detail: "Empty \(TimeText.compactDuration(earlyBy, hideMinutesIfDays: period == .weekly)) before reset",
                projectedRemaining: projectedRemaining
            )
        }

        if projectedRemaining < 12 {
            return PaceAssessment(
                severity: .tight,
                label: "Tight",
                detail: "Projected \(TimeText.percent(projectedRemaining)) at reset",
                projectedRemaining: projectedRemaining
            )
        }

        return PaceAssessment(
            severity: .steady,
            label: "On pace",
            detail: "Projected \(TimeText.percent(projectedRemaining)) at reset",
            projectedRemaining: projectedRemaining
        )
    }

    static func worst(for snapshot: UsageSnapshot?, history: [HistorySample]) -> PaceAssessment {
        BudgetPeriod.allCases
            .map { assessment(for: snapshot, period: $0, history: history) }
            .max { $0.severity < $1.severity } ?? .learning
    }

    private static func recentBurnRate(for period: BudgetPeriod, history: [HistorySample]) -> Double? {
        let horizon: TimeInterval = period == .current ? 60 * 60 : 6 * 60 * 60
        let minimumSpan: TimeInterval = period == .current ? 5 * 60 : 20 * 60
        let cutoff = Date().addingTimeInterval(-horizon)
        let recent = history
            .filter { $0.timestamp >= cutoff }
            .compactMap { sample -> (Date, Double)? in
                let value: Double?
                switch period {
                case .current: value = sample.currentRemaining
                case .weekly: value = sample.weeklyRemaining
                }
                guard let value else { return nil }
                return (sample.timestamp, value)
            }
            .sorted { $0.0 < $1.0 }

        guard let first = recent.first, let last = recent.last else {
            return nil
        }
        let span = last.0.timeIntervalSince(first.0)
        guard span >= minimumSpan else { return nil }
        let burned = first.1 - last.1
        guard burned > 0.2 else { return nil }
        return burned / span
    }

    private static func windowBurnRate(
        snapshot: UsageSnapshot,
        period: BudgetPeriod,
        secondsToReset: TimeInterval
    ) -> Double? {
        guard let remaining = period.remaining(in: snapshot) else { return nil }
        let windowSeconds = max(1, period.windowMinutes(in: snapshot) * 60)
        let elapsed = max(0, windowSeconds - secondsToReset)
        let minimumElapsed: TimeInterval = period == .current ? 10 * 60 : 60 * 60
        guard elapsed >= minimumElapsed else { return nil }

        let used = max(0, 100 - remaining)
        guard used > 0.5 else { return nil }
        return used / elapsed
    }
}
