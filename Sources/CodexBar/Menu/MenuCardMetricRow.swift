import CodexBarCore
import SwiftUI

struct MetricRow: View {
    let metric: UsageMenuCardView.Model.Metric
    let layoutMetric: UsageMenuCardView.Model.Metric
    let title: String
    let progressColor: Color
    var isRetainedMeasurement = false
    var compact = false
    @Environment(\.menuItemHighlighted) private var isHighlighted

    /// Synthetic credit lanes refresh independently of quota measurements.
    var barTint: Color {
        if self.metric.retainedMeasurementOverride ??
            (self.isRetainedMeasurement && !self.metric.isSyntheticCreditLane)
        {
            return UsageMenuCardView.Model.staleProgressColor
        }
        switch self.metric.barSeverity {
        case .weeklyCritical: return Color(nsColor: .systemRed)
        case .blockedByWeekly: return Color(nsColor: .systemOrange)
        case nil: return self.progressColor
        }
    }

    var body: some View {
        let presentation = self.metric.linePresentation(title: self.title)
        let layoutPresentation = self.layoutMetric.linePresentation(title: self.title)
        VStack(alignment: .leading, spacing: 6) {
            if let statusText = self.metric.statusText {
                Text(self.title)
                    .font(.body)
                    .fontWeight(.medium)
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
                if self.metric.showsBlockedStatusBar {
                    UsageProgressBar(
                        percent: 100,
                        tint: self.barTint,
                        accessibilityLabel: self.metric.percentStyle.accessibilityLabel)
                }
            } else {
                MetricRowHeader(
                    title: self.title,
                    layoutTitle: self.title,
                    resetText: self.compact ? nil : presentation.resetText,
                    layoutResetText: self.compact ? nil : layoutPresentation.resetText,
                    isHighlighted: self.isHighlighted,
                    percentText: self.metric.percentLabel,
                    layoutPercentText: self.layoutMetric.percentLabel)
                UsageProgressBar(
                    // Binding-quota providers project a weekly-blocked session as fully used, which
                    // would leave a remaining-style bar empty and its blocked tint invisible.
                    percent: self.metric.barSeverity == .blockedByWeekly ? 100 : self.metric.percent,
                    tint: self.barTint,
                    accessibilityLabel: self.metric.percentStyle.accessibilityLabel,
                    pacePercent: self.metric.pacePercent,
                    paceOnTop: self.metric.paceOnTop,
                    warningMarkerPercents: self.metric.warningMarkerPercents,
                    workdayMarkerPercents: self.metric.workdayMarkerPercents,
                    workdayTickAppearance: self.metric.workdayTickAppearance)
                if !self.compact, let layoutMetaText = layoutPresentation.metaText {
                    self.layoutPreservingText(
                        presentation.metaText,
                        layoutText: layoutMetaText,
                        lineLimit: 2)
                }
                if !self.compact, let layoutDetailText = self.layoutMetric.detailText {
                    self.layoutPreservingText(
                        self.metric.detailText,
                        layoutText: layoutDetailText,
                        lineLimit: 1)
                }
                if !self.compact, let layoutTarget = self.layoutMetric.dailyTargetText {
                    self.layoutPreservingText(self.metric.dailyTargetText, layoutText: layoutTarget, lineLimit: 2)
                }
            }
        }
        .help(self.metric.helpText ?? "")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(self.metric.cardStyle ? 10 : 0)
        .background(self.metric.cardStyle ? Color.secondary.opacity(self.isHighlighted ? 0.2 : 0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: self.metric.cardStyle ? 10 : 0))
    }

    private func layoutPreservingText(
        _ text: String?,
        layoutText: String,
        lineLimit: Int) -> some View
    {
        Text(layoutText)
            .monospacedDigit()
            .font(.footnote)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            // Freeze the measured height, but let updates use the entire metric row width.
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                if let text, !text.isEmpty {
                    Text(text)
                        .monospacedDigit()
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(lineLimit)
                        .truncationMode(.tail)
                }
            }
            .clipped()
    }
}
