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

    func testHistoryConsumesOneUnambiguousSubjectAlias() {
        let legacyID = "codex:legacy-subject"
        let canonicalID = "codex:strong-account"
        let legacySample = HistorySample(
            timestamp: Date().addingTimeInterval(-60),
            currentRemaining: 95,
            weeklyRemaining: nil
        )
        var history = UsageHistory(samplesByAccount: [legacyID: [legacySample]])
        let account = makeAccount(
            name: "upgraded",
            identity: "strong-account",
            aliases: ["legacy-subject"]
        )

        history.record(accounts: [account])

        XCTAssertEqual(history.samples(for: account).count, 2)
        XCTAssertNil(history.samplesByAccount[legacyID])
        XCTAssertNotNil(history.samplesByAccount[canonicalID])
    }

    func testSharedSubjectAliasDoesNotMergeDifferentAccounts() {
        let legacyID = "codex:shared-subject"
        let legacySample = HistorySample(
            timestamp: Date().addingTimeInterval(-60),
            currentRemaining: 95,
            weeklyRemaining: nil
        )
        var history = UsageHistory(samplesByAccount: [legacyID: [legacySample]])
        let accountA = makeAccount(name: "a", identity: "account-a", aliases: ["shared-subject"])
        let accountB = makeAccount(name: "b", identity: "account-b", aliases: ["shared-subject"])

        history.record(accounts: [accountA, accountB])

        XCTAssertEqual(history.samples(for: accountA).count, 1)
        XCTAssertEqual(history.samples(for: accountB).count, 1)
        XCTAssertEqual(history.samplesByAccount[legacyID]?.count, 1)
    }

    func testTopBarPreferenceMigrationRejectsAmbiguousAlias() {
        let aliasID = "codex:owner:shared-subject"
        let accountA = makeAccount(name: "a", identity: "account-a", aliases: ["shared-subject"])
        let accountB = makeAccount(name: "b", identity: "account-b", aliases: ["shared-subject"])

        let migrated = TopBarPreferences.migratedHiddenIDs([aliasID], accounts: [accountA, accountB])

        XCTAssertEqual(migrated, Set([aliasID]))
    }

    func testTopBarPreferenceConsumesOneUnambiguousAlias() {
        let aliasID = "codex:owner:legacy-subject"
        let account = makeAccount(name: "upgraded", identity: "strong-account", aliases: ["legacy-subject"])

        let migrated = TopBarPreferences.migratedHiddenIDs([aliasID], accounts: [account])

        XCTAssertEqual(migrated, Set(["codex:owner:strong-account"]))
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

    private func makeAccount(name: String, identity: String, aliases: [String]) -> UsageAccount {
        UsageAccount(
            provider: "codex",
            name: name,
            accountIdentity: identity,
            accountIdentityAliases: aliases,
            isActive: false,
            status: "ok",
            message: "",
            stale: false,
            snapshot: makeSnapshot(
                now: Date(),
                remaining: 90,
                reset: Date().addingTimeInterval(4 * 60 * 60)
            )
        )
    }
}

private struct LegacyHistorySample: Codable {
    let id: UUID
    let timestamp: Date
    let currentRemaining: Double?
    let weeklyRemaining: Double?
}
