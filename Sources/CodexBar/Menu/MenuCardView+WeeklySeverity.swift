import CodexBarCore

extension UsageMenuCardView.Model.Metric {
    enum BarSeverity: Equatable {
        /// Weekly lane at or past `weeklyCriticalUsedPercent`.
        case weeklyCritical
        /// Session lane whose weekly lane is exhausted; a session reset cannot restore access.
        case blockedByWeekly
    }

    /// Unavailable lanes render as text only; a weekly-blocked one keeps a bar so the block reads at a glance.
    var showsBlockedStatusBar: Bool {
        self.statusText != nil && self.barSeverity == .blockedByWeekly
    }
}

extension UsageMenuCardView.Model {
    static let weeklyCriticalUsedPercent: Double = 90
    private static let sessionWindowMinutes = 300
    private static let weeklyWindowMinutes = 10080

    private struct SeverityLane {
        let window: RateWindow
        let usageKnown: Bool
        /// Lanes sharing a group gate each other: Antigravity pairs lanes per quota family,
        /// other providers pair the primary session lane with the secondary weekly lane.
        let group: String
        let blocksGroup: Bool
    }

    static func weeklySeverityMetrics(_ metrics: [Metric], input: Input) -> [Metric] {
        guard let snapshot = input.snapshot else { return metrics }
        let lanes = metrics.map { Self.severityLane(for: $0, input: input, snapshot: snapshot) }
        let exhaustedGroups = Set(lanes.compactMap { lane -> String? in
            guard let lane, lane.blocksGroup, lane.usageKnown, lane.window.usedPercent >= 100 else { return nil }
            return lane.group
        })
        return zip(metrics, lanes).map { metric, lane in
            guard let lane else { return metric }
            var result = metric
            let minutes = lane.window.windowMinutes
            if minutes == Self.weeklyWindowMinutes, lane.usageKnown,
               lane.window.usedPercent >= Self.weeklyCriticalUsedPercent
            {
                result.barSeverity = .weeklyCritical
            } else if minutes == Self.sessionWindowMinutes, exhaustedGroups.contains(lane.group) {
                result.barSeverity = .blockedByWeekly
            }
            return result
        }
    }

    private static func severityLane(
        for metric: Metric,
        input: Input,
        snapshot: UsageSnapshot) -> SeverityLane?
    {
        // Provider-specific by design: Antigravity splits quota into Gemini and Claude/GPT families,
        // and each family's session lane is gated only by that family's weekly lane.
        if input.provider == .antigravity, AntigravityStatusSnapshot.isQuotaSummaryWindowID(metric.id) {
            guard let named = snapshot.extraRateWindows?.first(where: { $0.id == metric.id }) else { return nil }
            let family = AntigravityQuotaFamilyVisibility.knownFamily(windowID: named.id, title: named.title)
            return SeverityLane(
                window: named.window,
                usageKnown: named.usageKnown,
                group: family?.rawValue ?? named.id,
                blocksGroup: named.window.windowMinutes == Self.weeklyWindowMinutes)
        }
        let mainGroup = "main"
        switch metric.id {
        case "primary":
            let window = input.codexProjection?.rateWindow(for: .session) ?? snapshot.primary
            return window.flatMap { $0.isSyntheticPlaceholder ? nil : $0 }.map {
                SeverityLane(window: $0, usageKnown: true, group: mainGroup, blocksGroup: false)
            }
        case "secondary":
            let window = input.codexProjection?.rateWindow(for: .weekly) ?? snapshot.secondary
            return window.flatMap { $0.isSyntheticPlaceholder ? nil : $0 }.map {
                SeverityLane(
                    window: $0,
                    usageKnown: true,
                    group: mainGroup,
                    blocksGroup: $0.windowMinutes == Self.weeklyWindowMinutes)
            }
        default:
            guard let named = snapshot.extraRateWindows?.first(where: { $0.id == metric.id }) else { return nil }
            return SeverityLane(window: named.window, usageKnown: named.usageKnown, group: named.id, blocksGroup: false)
        }
    }
}
