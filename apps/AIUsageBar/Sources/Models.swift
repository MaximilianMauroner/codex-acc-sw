import Foundation
import SwiftUI

struct UsagePayload: Decodable {
    let generatedAt: String?
    let mode: String
    let activeCodexAccount: String?
    let accounts: [UsageAccount]

    var generatedDate: Date? {
        DateParser.parse(generatedAt)
    }
}

struct UsageAccount: Decodable, Identifiable {
    let provider: String
    let name: String
    let isActive: Bool
    let status: String
    let message: String
    let stale: Bool
    let snapshot: UsageSnapshot?

    var id: String {
        "\(provider):\(name)"
    }

    var isClaude: Bool {
        provider == "claude"
    }

    var isCodex: Bool {
        provider == "codex"
    }

    var displayName: String {
        if isClaude { return "Claude" }
        return name
    }

    var hasProblem: Bool {
        status != "ok"
    }
}

struct UsageSnapshot: Decodable {
    let lastSeenAt: String?
    let planType: String?
    let currentRemainingPercent: Double?
    let weeklyRemainingPercent: Double?
    let currentWindowMinutes: Double?
    let weeklyWindowMinutes: Double?
    let currentResetsAt: String?
    let weeklyResetsAt: String?

    var lastSeenDate: Date? {
        DateParser.parse(lastSeenAt)
    }

    var currentResetDate: Date? {
        DateParser.parse(currentResetsAt)
    }

    var weeklyResetDate: Date? {
        DateParser.parse(weeklyResetsAt)
    }

    var isFreePlan: Bool {
        planType == "free"
    }

    var limitingRemainingPercent: Double? {
        limitingBudget?.remainingPercent
    }
}

enum BudgetPeriod: String, CaseIterable {
    case current
    case weekly

    var label: String {
        switch self {
        case .current: return "5h"
        case .weekly: return "Week"
        }
    }

    var titleLabel: String {
        switch self {
        case .current: return "5h"
        case .weekly: return "wk"
        }
    }

    func remaining(in snapshot: UsageSnapshot) -> Double? {
        switch self {
        case .current: return snapshot.currentRemainingPercent
        case .weekly: return snapshot.weeklyRemainingPercent
        }
    }

    func resetDate(in snapshot: UsageSnapshot) -> Date? {
        switch self {
        case .current: return snapshot.currentResetDate
        case .weekly: return snapshot.weeklyResetDate
        }
    }

    func windowMinutes(in snapshot: UsageSnapshot) -> Double {
        switch self {
        case .current: return snapshot.currentWindowMinutes ?? 300
        case .weekly: return snapshot.weeklyWindowMinutes ?? 10_080
        }
    }
}

struct LimitingBudgetValue {
    let period: BudgetPeriod
    let remainingPercent: Double
    let resetDate: Date?
}

extension UsageSnapshot {
    var limitingBudget: LimitingBudgetValue? {
        switch (currentRemainingPercent, weeklyRemainingPercent) {
        case let (current?, weekly?):
            if current <= weekly {
                return LimitingBudgetValue(period: .current, remainingPercent: current, resetDate: currentResetDate)
            }
            return LimitingBudgetValue(period: .weekly, remainingPercent: weekly, resetDate: weeklyResetDate)
        case let (current?, nil):
            return LimitingBudgetValue(period: .current, remainingPercent: current, resetDate: currentResetDate)
        case let (nil, weekly?):
            return LimitingBudgetValue(period: .weekly, remainingPercent: weekly, resetDate: weeklyResetDate)
        case (nil, nil):
            return nil
        }
    }
}

enum PaceSeverity: Int, Comparable {
    case unavailable = 0
    case steady = 1
    case tight = 2
    case critical = 3

    static func < (lhs: PaceSeverity, rhs: PaceSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .unavailable: return "Learning"
        case .steady: return "On pace"
        case .tight: return "Tight"
        case .critical: return "Fast"
        }
    }

    var color: Color {
        switch self {
        case .unavailable: return Color(nsColor: .secondaryLabelColor)
        case .steady: return Color(nsColor: .systemGreen)
        case .tight: return Color(nsColor: .systemOrange)
        case .critical: return Color(nsColor: .systemRed)
        }
    }

    var nsColor: NSColor {
        switch self {
        case .unavailable: return .tertiaryLabelColor
        case .steady: return .systemGreen
        case .tight: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

struct PaceAssessment {
    let severity: PaceSeverity
    let label: String
    let detail: String
    let projectedRemaining: Double?

    static let learning = PaceAssessment(
        severity: .unavailable,
        label: "Learning",
        detail: "Needs more samples",
        projectedRemaining: nil
    )
}

struct StatusSummary {
    let title: String
    let tooltip: String
    let severity: PaceSeverity

    static let loading = StatusSummary(
        title: "AI",
        tooltip: "Loading usage",
        severity: .unavailable
    )
}
