import Foundation
import XCTest
@testable import AIUsageBar

final class PaceCalculatorTests: XCTestCase {
    func testPaceIgnoresSamplesFromPreviousResetWindow() {
        let now = Date()
        let currentReset = now.addingTimeInterval(4 * 60 * 60 + 55 * 60)
        let previousReset = now.addingTimeInterval(-5 * 60)
        let snapshot = makeSnapshot(now: now, remaining: 90, reset: currentReset)
        let history = [
            HistorySample(
                timestamp: now.addingTimeInterval(-20 * 60),
                currentRemaining: 95,
                weeklyRemaining: nil,
                currentResetDate: previousReset,
                currentWindowMinutes: 300
            ),
            HistorySample(
                timestamp: now,
                currentRemaining: 90,
                weeklyRemaining: nil,
                currentResetDate: currentReset,
                currentWindowMinutes: 300
            ),
        ]

        let assessment = PaceCalculator.assessment(for: snapshot, period: .current, history: history)

        XCTAssertEqual(assessment.severity, .unavailable)
    }

    func testPaceUsesSamplesFromMatchingResetWindow() {
        let now = Date()
        let currentReset = now.addingTimeInterval(4 * 60 * 60 + 55 * 60)
        let snapshot = makeSnapshot(now: now, remaining: 90, reset: currentReset)
        let history = [
            HistorySample(
                timestamp: now.addingTimeInterval(-10 * 60),
                currentRemaining: 100,
                weeklyRemaining: nil,
                currentResetDate: currentReset,
                currentWindowMinutes: 300
            ),
            HistorySample(
                timestamp: now,
                currentRemaining: 90,
                weeklyRemaining: nil,
                currentResetDate: currentReset,
                currentWindowMinutes: 300
            ),
        ]

        let assessment = PaceCalculator.assessment(for: snapshot, period: .current, history: history)

        XCTAssertEqual(assessment.severity, .critical)
    }

    func testLegacyHistorySampleStillDecodesWithoutWindowFields() throws {
        let legacy = LegacyHistorySample(
            id: UUID(),
            timestamp: Date(),
            currentRemaining: 80,
            weeklyRemaining: 70
        )
        let data = try JSONEncoder().encode(legacy)

        let decoded = try JSONDecoder().decode(HistorySample.self, from: data)

        XCTAssertNil(decoded.currentResetDate)
        XCTAssertNil(decoded.weeklyResetDate)
        XCTAssertNil(decoded.currentWindowMinutes)
        XCTAssertNil(decoded.weeklyWindowMinutes)
    }

    private func makeSnapshot(now: Date, remaining: Double, reset: Date) -> UsageSnapshot {
        let formatter = ISO8601DateFormatter()
        return UsageSnapshot(
            lastSeenAt: formatter.string(from: now),
            planType: "plus",
            currentRemainingPercent: remaining,
            weeklyRemainingPercent: nil,
            currentWindowMinutes: 300,
            weeklyWindowMinutes: nil,
            currentResetsAt: formatter.string(from: reset),
            weeklyResetsAt: nil
        )
    }
}

private struct LegacyHistorySample: Codable {
    let id: UUID
    let timestamp: Date
    let currentRemaining: Double?
    let weeklyRemaining: Double?
}
