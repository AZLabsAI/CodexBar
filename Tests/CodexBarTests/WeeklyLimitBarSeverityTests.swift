import AppKit
import Foundation
import SwiftUI
import Testing
import XCTest
@testable import CodexBar
@testable import CodexBarCore

struct WeeklyLimitBarSeverityTests {
    static let now = Date(timeIntervalSince1970: 1_788_000_000)

    @Test(arguments: [false, true])
    func `exhausted Antigravity weekly blocks only its own family's session lane`(showUsed: Bool) throws {
        let model = try Self.model(.antigravity, Self.antigravitySnapshot(claudeGPTWeeklyUsed: 53), showUsed: showUsed)
        let geminiWeekly = try Self.metric("antigravity-quota-summary-gemini-weekly", in: model)
        let geminiSession = try Self.metric("antigravity-quota-summary-gemini-5h", in: model)
        let claudeGPTWeekly = try Self.metric("antigravity-quota-summary-3p-weekly", in: model)
        let claudeGPTSession = try Self.metric("antigravity-quota-summary-3p-5h", in: model)

        #expect(geminiWeekly.barSeverity == .weeklyCritical)
        #expect(geminiSession.barSeverity == .blockedByWeekly)
        #expect(geminiSession.showsBlockedStatusBar)
        #expect(claudeGPTWeekly.barSeverity == nil)
        #expect(claudeGPTSession.barSeverity == nil)
    }

    @Test
    func `Antigravity weekly past ninety percent turns critical without blocking its session lane`() throws {
        let model = try Self.model(.antigravity, Self.antigravitySnapshot(claudeGPTWeeklyUsed: 92))
        #expect(try Self.metric("antigravity-quota-summary-3p-weekly", in: model).barSeverity == .weeklyCritical)
        #expect(try Self.metric("antigravity-quota-summary-3p-5h", in: model).barSeverity == nil)
    }

    @Test(arguments: [
        (89.9, nil, nil),
        (90.0, UsageMenuCardView.Model.Metric.BarSeverity.weeklyCritical, nil),
        (100.0, .weeklyCritical, .blockedByWeekly),
    ] as [(Double, UsageMenuCardView.Model.Metric.BarSeverity?, UsageMenuCardView.Model.Metric.BarSeverity?)])
    func `weekly usage drives weekly and session bar severity`(
        weeklyUsed: Double,
        weeklySeverity: UsageMenuCardView.Model.Metric.BarSeverity?,
        sessionSeverity: UsageMenuCardView.Model.Metric.BarSeverity?) throws
    {
        let snapshot = UsageSnapshot(
            primary: Self.window(used: 0, minutes: 300),
            secondary: Self.window(used: weeklyUsed, minutes: 10080),
            updatedAt: Self.now)
        let model = try Self.model(.claude, snapshot)
        #expect(try Self.metric("secondary", in: model).barSeverity == weeklySeverity)
        let session = try Self.metric("primary", in: model)
        #expect(session.barSeverity == sessionSeverity)
        #expect(!session.showsBlockedStatusBar)
    }

    @Test
    func `exhausted model scoped weekly does not block the session lane`() throws {
        let snapshot = UsageSnapshot(
            primary: Self.window(used: 10, minutes: 300),
            secondary: Self.window(used: 40, minutes: 10080),
            extraRateWindows: [NamedRateWindow(
                id: "claude-weekly-scoped-opus",
                title: "Opus only",
                window: Self.window(used: 100, minutes: 10080))],
            updatedAt: Self.now)
        let model = try Self.model(.claude, snapshot)
        #expect(try Self.metric("claude-weekly-scoped-opus", in: model).barSeverity == .weeklyCritical)
        #expect(try Self.metric("primary", in: model).barSeverity == nil)
        #expect(try Self.metric("secondary", in: model).barSeverity == nil)
    }

    static func antigravitySnapshot(claudeGPTWeeklyUsed: Double) -> UsageSnapshot {
        let blockedSession = RateWindow(
            usedPercent: 0,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: "You have hit your weekly limit, the 5-hour limit does not currently apply. "
                + "Your weekly limit will fully refresh in 3 days, 7 hours.")
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini 5-hour",
                    window: blockedSession,
                    usageKnown: false),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini weekly",
                    window: self.window(used: 100, minutes: 10080, reset: self.now.addingTimeInterval(3 * 86400))),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Claude/GPT 5-hour",
                    window: self.window(used: 0, minutes: 300, reset: self.now.addingTimeInterval(5 * 3600))),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude/GPT weekly",
                    window: self.window(
                        used: claudeGPTWeeklyUsed,
                        minutes: 10080,
                        reset: self.now.addingTimeInterval(5 * 86400))),
            ],
            updatedAt: self.now)
    }

    private static func window(used: Double, minutes: Int, reset: Date? = nil) -> RateWindow {
        RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: reset, resetDescription: nil)
    }

    private static func metric(
        _ id: String,
        in model: UsageMenuCardView.Model) throws -> UsageMenuCardView.Model.Metric
    {
        try #require(model.metrics.first { $0.id == id })
    }

    static func model(
        _ provider: UsageProvider,
        _ snapshot: UsageSnapshot,
        showUsed: Bool = false) throws -> UsageMenuCardView.Model
    {
        let metadata = try #require(ProviderDefaults.metadata[provider])
        return UsageMenuCardView.Model.make(.init(
            provider: provider,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: showUsed,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: self.now))
    }
}

@MainActor
final class WeeklyLimitBarSeverityProofTests: XCTestCase {
    func test_syntheticAntigravitySeverityBars() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_WEEKLY_SEVERITY_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_WEEKLY_SEVERITY_PROOF_DIR for synthetic offscreen rendering")
        }
        let model = try WeeklyLimitBarSeverityTests.model(
            .antigravity,
            WeeklyLimitBarSeverityTests.antigravitySnapshot(claudeGPTWeeklyUsed: 92))
        let view = VStack(alignment: .leading, spacing: 16) {
            Text("Antigravity · Synthetic weekly limits").font(.headline)
            ForEach(model.metrics) { metric in
                MetricRow(metric: metric, layoutMetric: metric, title: metric.title, progressColor: model.progressColor)
            }
        }
        .padding(20)
        .frame(width: 360, height: 380, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 380)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("antigravity-weekly-severity.png"))
    }
}
