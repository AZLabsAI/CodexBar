import CodexBarCore
import SwiftUI

/// Compact menu row for an inactive account: identity plus one chip per long
/// (weekly or monthly) window, each with its own reset. A pool's 5-hour lane rides
/// inside its long-window chip only while that long window still has quota left.
/// Accounts without long windows fall back to text quota lines.
/// Clicking the row expands it into the full usage card.
struct MenuCardCompactAccountRowView: View {
    struct WindowChip: Equatable {
        let title: String
        /// Remaining percent, or "OUT" once the window is spent so the reset carries the chip.
        let value: String
        let reset: String?
        /// Same-pool 5-hour lane, e.g. "5h 62%"; only present while this window has room.
        let session: String?
        let remainingPercent: Double
        let isExhausted: Bool
        let isCritical: Bool

        var text: String {
            [self.title, [self.value, self.reset].compactMap(\.self).joined(separator: " · "), self.session]
                .compactMap(\.self)
                .joined(separator: " ")
        }
    }

    struct Model: Equatable {
        let label: String
        let headroomPercent: Double?
        let severity: AccountMenuLayoutPlanner.Severity?
        let detailLines: [String]
        /// Long-window summary chips in snapshot order; empty when the account has none.
        let chips: [WindowChip]
        let isExhausted: Bool
        /// Soonest return of a spent account, formatted for the header.
        let nextResetText: String?
        let hasError: Bool
        let showsBestBadge: Bool
        private let lastKnownLines: [String]

        init(
            row: AccountMenuLayoutPlanner.CompactRow,
            resetTimeDisplayStyle: ResetTimeDisplayStyle,
            hidePersonalInfo: Bool = false,
            privacyOrdinal: PersonalInfoRedactor.AccountOrdinal? = nil,
            now: Date = .init())
        {
            self.label = PersonalInfoRedactor.redactAccountLabel(
                row.label,
                isEnabled: hidePersonalInfo,
                ordinal: privacyOrdinal)
            self.headroomPercent = row.headroomPercent
            self.severity = row.severity
            let redact = { (text: String) in
                PersonalInfoRedactor.redactEmails(in: text, isEnabled: hidePersonalInfo) ?? text
            }
            var details = row.windowDetails.map { detail in
                let title = localizedSessionQuotaLabel(detail.label, windowMinutes: detail.window.windowMinutes)
                let percent = UsageFormatter.percentText(
                    detail.window.remainingPercent,
                    suffix: L("usage_percent_suffix_left"))
                let reset = Self.resetLine(for: detail, style: resetTimeDisplayStyle, now: now)
                let line = ["\(title) \(percent)", reset].compactMap(\.self).filter { !$0.isEmpty }
                    .joined(separator: " · ")
                return redact(line)
            }
            self.chips = row.longWindows.map { summary in
                Self.chip(for: summary, style: resetTimeDisplayStyle, now: now, redact: redact)
            }
            var lastKnown: [String] = []
            if let capturedAt = row.lastKnownUsageCapturedAt {
                lastKnown.append(LastKnownUsagePresentation.message(capturedAt: capturedAt, now: now))
            }
            details.append(contentsOf: lastKnown)
            self.detailLines = details
            self.lastKnownLines = lastKnown
            self.isExhausted = row.isExhausted
            self.nextResetText = row.isExhausted
                ? row.nextResetAt.map { Self.compactReset(date: $0, style: resetTimeDisplayStyle, now: now) }
                : nil
            self.hasError = row.hasError
            self.showsBestBadge = row.isBestCandidate
        }

        /// Text lines rendered under the header: quota lines only when no chip summarizes them.
        var footnoteLines: [String] {
            self.chips.isEmpty ? self.detailLines : self.lastKnownLines
        }

        var accessibilityText: String {
            var parts = [self.label]
            if self.chips.isEmpty, let label = self.headroomLabel {
                parts.append(String(format: L("%@ remaining"), label))
            }
            if self.chips.isEmpty {
                parts.append(contentsOf: self.detailLines)
            } else {
                parts.append(contentsOf: self.chips.map(\.text))
                parts.append(contentsOf: self.lastKnownLines)
            }
            if self.hasError {
                parts.append(L("Account unavailable"))
            }
            return parts.joined(separator: ", ")
        }

        var headroomLabel: String? {
            self.headroomPercent.map { "\(Int($0.rounded()))%" }
        }

        /// Most usable long window left on the account; a 5-hour lane never feeds it.
        var bestRemainingChip: WindowChip? {
            self.chips.filter { !$0.isExhausted }.max { $0.remainingPercent < $1.remainingPercent }
        }

        var heightFingerprint: String {
            [
                "compactAccount",
                self.label,
                self.headroomLabel ?? "-",
                self.detailLines.joined(separator: "|"),
                self.chips.map(\.text).joined(separator: "|"),
                self.nextResetText ?? "-",
                self.hasError ? "error" : "ok",
                self.showsBestBadge ? "best" : "plain",
            ].joined(separator: "|")
        }

        private static func chip(
            for summary: AccountMenuLayoutPlanner.LongWindowSummary,
            style: ResetTimeDisplayStyle,
            now: Date,
            redact: (String) -> String) -> WindowChip
        {
            let detail = summary.window
            let remaining = detail.window.remainingPercent
            let session = summary.session.map { session in
                let hours = (session.window.windowMinutes ?? AccountMenuLayoutPlanner.sessionWindowMinutes) / 60
                return "\(hours)h \(UsageFormatter.percentString(session.window.remainingPercent))"
            }
            return WindowChip(
                title: localizedSessionQuotaLabel(detail.label, windowMinutes: detail.window.windowMinutes),
                value: detail.isExhausted ? L("OUT") : UsageFormatter.percentString(remaining),
                reset: Self.chipReset(for: detail, style: style, now: now).map(redact),
                session: session,
                remainingPercent: remaining,
                isExhausted: detail.isExhausted,
                isCritical: remaining <= AccountMenuLayoutPlanner.criticalHeadroomPercent)
        }

        private static func resetLine(
            for detail: AccountMenuLayoutPlanner.WindowDetail,
            style: ResetTimeDisplayStyle,
            now: Date) -> String?
        {
            switch detail.resetPresentation {
            case .standard:
                UsageFormatter.resetLine(for: detail.window, style: style, now: now)
            case .hidden:
                nil
            case .providerDescription:
                detail.window.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        /// Chips drop the "Resets" prefix: the reset is the chip's second half, so a bare
        /// countdown or date keeps two or three chips on one line.
        private static func chipReset(
            for detail: AccountMenuLayoutPlanner.WindowDetail,
            style: ResetTimeDisplayStyle,
            now: Date) -> String?
        {
            if detail.resetPresentation == .standard, let date = detail.window.resetsAt {
                return self.compactReset(date: date, style: style, now: now)
            }
            return self.resetLine(for: detail, style: style, now: now).flatMap { $0.isEmpty ? nil : $0 }
        }

        private static func compactReset(date: Date, style: ResetTimeDisplayStyle, now: Date) -> String {
            guard style == .countdown else { return UsageFormatter.resetDescription(from: date, now: now) }
            let duration = UsageFormatter.resetCountdownDuration(from: date, now: now)
            return duration == "now" ? UsageFormatter.resetCountdownDescription(from: date, now: now) : duration
        }
    }

    static let chipSpacing: CGFloat = 4
    static let chipGaugeHeight: CGFloat = 2

    let model: Model
    let progressColor: Color
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(self.model.label)
                    .font(.subheadline)
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if self.model.showsBestBadge {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(self.isHighlighted
                            ? MenuHighlightStyle.selectionText
                            : Color(nsColor: .systemYellow))
                        .accessibilityLabel(L("Most usable account"))
                }
                Spacer(minLength: 12)
                self.headerStatus
            }
            if !self.model.chips.isEmpty {
                MenuBarLayoutChipFlowLayout(spacing: Self.chipSpacing) {
                    ForEach(Array(self.model.chips.enumerated()), id: \.offset) { _, chip in
                        self.chipView(chip)
                    }
                }
            }
            ForEach(Array(self.model.footnoteLines.enumerated()), id: \.offset) { _, detail in
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(self.model.severity == .critical && self.model.chips.isEmpty
                        ? MenuHighlightStyle.error(self.isHighlighted)
                        : MenuHighlightStyle.secondary(self.isHighlighted))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.vertical, 5)
        .frame(width: self.width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.model.accessibilityText)
    }

    @ViewBuilder
    private var headerStatus: some View {
        if self.model.hasError, self.model.headroomPercent == nil {
            Image(systemName: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(MenuHighlightStyle.error(self.isHighlighted))
                .accessibilityLabel(L("Account unavailable"))
        } else if !self.model.chips.isEmpty, self.model.isExhausted {
            HStack(spacing: 3) {
                Image(systemName: self.model.nextResetText == nil ? "nosign" : "arrow.clockwise")
                    .font(.caption2.weight(.semibold))
                if let reset = self.model.nextResetText {
                    Text(reset)
                        .font(.footnote.monospacedDigit().weight(.semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(MenuHighlightStyle.error(self.isHighlighted))
            .accessibilityHidden(true)
        } else if let best = self.model.bestRemainingChip {
            Text(best.value)
                .font(.footnote.monospacedDigit().weight(.semibold))
                .foregroundStyle(self.toneColor(isCritical: best.isCritical))
                .lineLimit(1)
                .accessibilityHidden(true)
        } else if let label = self.model.headroomLabel {
            Text(label)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(self.toneColor(isCritical: self.model.severity == .critical))
                .lineLimit(1)
                .frame(minWidth: 34, alignment: .trailing)
        }
    }

    private func chipView(_ chip: WindowChip) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(chip.title)
                .font(.caption2)
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(chip.value)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(self.toneColor(isCritical: chip.isCritical))
                if let reset = chip.reset {
                    // A spent window is only interesting for when it comes back, so its reset is the loud part.
                    Text("· \(reset)")
                        .font(.caption.monospacedDigit().weight(chip.isExhausted ? .semibold : .regular))
                        .foregroundStyle(chip.isExhausted
                            ? MenuHighlightStyle.primary(self.isHighlighted)
                            : MenuHighlightStyle.secondary(self.isHighlighted))
                }
                if let session = chip.session {
                    Text(session)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .padding(.horizontal, 3)
                        .background(Capsule().fill(MenuHighlightStyle.progressTrack(self.isHighlighted)))
                }
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.top, 3)
        .padding(.bottom, 3 + Self.chipGaugeHeight)
        .background(RoundedRectangle(cornerRadius: 5).fill(MenuHighlightStyle.progressTrack(self.isHighlighted)))
        .overlay(alignment: .bottomLeading) {
            GeometryReader { proxy in
                Rectangle()
                    .fill(chip.isCritical
                        ? MenuHighlightStyle.error(self.isHighlighted)
                        : MenuHighlightStyle.progressTint(self.isHighlighted, fallback: self.progressColor))
                    .frame(
                        width: proxy.size.width * min(100, max(0, chip.remainingPercent)) / 100,
                        height: Self.chipGaugeHeight)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .overlay {
            if chip.isExhausted {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(MenuHighlightStyle.error(self.isHighlighted).opacity(0.45), lineWidth: 1)
            }
        }
        .fixedSize()
    }

    private func toneColor(isCritical: Bool) -> Color {
        guard !self.isHighlighted else { return MenuHighlightStyle.selectionText }
        return isCritical ? Color(nsColor: .systemRed) : MenuHighlightStyle.normalSecondaryText
    }
}

/// Summary row standing in for the healthy accounts hidden by the compact
/// multi-account layout; clicking it reveals the individual rows.
struct MenuCardCollapsedAccountsRowView: View {
    let count: Int
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var title: String {
        String(format: L("%d more accounts ready"), self.count)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
            Text(self.title)
                .font(.footnote)
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
            Spacer(minLength: 12)
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.vertical, 5)
        .frame(width: self.width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.title)
        .accessibilityHint(L("Shows the hidden accounts"))
    }
}
