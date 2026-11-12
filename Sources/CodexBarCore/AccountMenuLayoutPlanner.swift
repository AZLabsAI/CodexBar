import Foundation

/// Plans the compact ("smart") multi-account menu layout used when a provider
/// surfaces many account rows: the active account keeps its full usage card,
/// inactive accounts collapse to compact rows that summarize their long (weekly
/// and monthly) windows, and a long healthy tail folds behind a single summary row.
///
/// Rows with long-window quota left sort above exhausted rows; inside each group
/// the soonest long-window reset leads. A 5-hour lane never decides the order or
/// the row's headroom: it is only shown beside a long window that still has room.
///
/// Pure projection: inputs are account snapshots plus menu expansion state,
/// output is an ordered row plan. Rendering and interaction stay in the app layer.
public enum AccountMenuLayoutPlanner {
    /// Compact layout only engages once a provider has this many account rows;
    /// below that the classic stacked cards still fit on screen.
    public static let compactLayoutMinimumAccountCount = 4
    public static let criticalHeadroomPercent: Double = 10
    public static let warningHeadroomPercent: Double = 50
    /// Folding fewer healthy rows than this behind a summary row would not save
    /// meaningful menu height.
    public static let minimumCollapsedHealthyRowCount = 2
    public static let sessionWindowMinutes = 300
    public static let weeklyWindowMinutes = 10080
    private static let quotaSummaryWindowIDPrefix = "antigravity-quota-summary-"

    public enum Severity: Equatable, Sendable {
        case critical
        case warning
        case healthy
    }

    public enum ResetPresentation: Equatable, Sendable {
        case standard
        case hidden
        case providerDescription
    }

    /// Window length class. Only long windows decide sort order and headroom.
    public enum Cadence: Equatable, Sendable {
        /// 5-hour lane; it can only be spent while its pool's long window has room.
        case session
        /// Weekly (10080 minutes) or longer, including the tertiary/monthly lane.
        case long
        /// Any other cadence: daily, balance, or unknown length.
        case other
    }

    public struct WindowDetail: Equatable, Sendable {
        public let metricID: String
        public let label: String
        public let window: RateWindow
        public let resetPresentation: ResetPresentation
        public let cadence: Cadence
        /// Lanes sharing a pool gate each other: the main session/weekly pair, or one
        /// quota family when a provider reports per-family lanes.
        public let poolID: String

        public init(
            metricID: String,
            label: String,
            window: RateWindow,
            resetPresentation: ResetPresentation,
            cadence: Cadence = .other,
            poolID: String? = nil)
        {
            self.metricID = metricID
            self.label = label
            self.window = window
            self.resetPresentation = resetPresentation
            self.cadence = cadence
            self.poolID = poolID ?? metricID
        }

        public var isExhausted: Bool {
            self.window.remainingPercent <= 0
        }
    }

    /// One long window on a compact row, with its pool's 5-hour lane attached only
    /// while the long window still has quota left.
    public struct LongWindowSummary: Equatable, Sendable {
        public let window: WindowDetail
        public let session: WindowDetail?
    }

    public struct CompactRow: Equatable, Sendable {
        public let accountID: ProviderAccountIdentity
        public let label: String
        /// Lowest remaining percent across the account's long windows (every window when
        /// it reports none); nil when the account reported no usable windows.
        public let headroomPercent: Double?
        public let severity: Severity?
        /// Every visible long window in snapshot order. Accounts without long windows fall
        /// back to their constrained windows, or the least remaining one when healthy.
        /// Keep reset metadata attached to its own quota until the app formats it.
        public let windowDetails: [WindowDetail]
        /// Visible long windows with their gated 5-hour lanes; empty when none exist.
        public let longWindows: [LongWindowSummary]
        /// True when no deciding window has quota left, including accounts without data.
        public let isExhausted: Bool
        /// Soonest reset among deciding windows that still have room, or among all deciding
        /// windows when the account is exhausted.
        public let nextResetAt: Date?
        public let lastKnownUsageCapturedAt: Date?
        public let hasError: Bool
        public let canActivate: Bool
        /// Marks the inactive account with the most usable headroom — the best
        /// candidate to switch to next. Only healthy accounts qualify.
        public let isBestCandidate: Bool
    }

    public enum Row: Equatable, Sendable {
        case card(ProviderAccountIdentity)
        case compact(CompactRow)
        /// Healthy accounts folded behind one summary row; `count` is how many are hidden.
        case collapsedHealthy(count: Int)
    }

    public struct Plan: Equatable, Sendable {
        public let rows: [Row]
        public let usesCompactLayout: Bool
    }

    public static func plan(
        accounts: [ProviderAccountUsageSnapshot],
        expandedAccountIDs: Set<ProviderAccountIdentity> = [],
        healthyTailExpanded: Bool = false,
        hiddenMetricIDs: Set<String> = []) -> Plan
    {
        guard accounts.count >= self.compactLayoutMinimumAccountCount else {
            return Plan(rows: accounts.map { .card($0.id) }, usesCompactLayout: false)
        }

        var rows: [Row] = accounts.filter(\.isActive).map { .card($0.id) }

        let inactive = accounts.filter { !$0.isActive }
        let compactRows = self.sortedCompactRows(for: inactive, hiddenMetricIDs: hiddenMetricIDs)

        let collapsible = healthyTailExpanded
            ? []
            : compactRows.filter { $0.severity == .healthy && !$0.isBestCandidate && !$0.hasError &&
                $0.lastKnownUsageCapturedAt == nil &&
                !expandedAccountIDs.contains($0.accountID)
            }
        let collapsedIDs: Set<ProviderAccountIdentity> =
            collapsible.count >= self.minimumCollapsedHealthyRowCount
                ? Set(collapsible.map(\.accountID))
                : []

        var insertedCollapsedRow = false
        for row in compactRows {
            if collapsedIDs.contains(row.accountID) {
                // The summary takes the first folded row's slot so it stays above exhausted accounts.
                if !insertedCollapsedRow {
                    rows.append(.collapsedHealthy(count: collapsedIDs.count))
                    insertedCollapsedRow = true
                }
            } else if expandedAccountIDs.contains(row.accountID) {
                rows.append(.card(row.accountID))
            } else {
                rows.append(.compact(row))
            }
        }
        return Plan(rows: rows, usesCompactLayout: true)
    }

    public static func severity(forHeadroom headroom: Double) -> Severity {
        if headroom <= self.criticalHeadroomPercent {
            return .critical
        }
        if headroom <= self.warningHeadroomPercent {
            return .warning
        }
        return .healthy
    }

    /// Lowest remaining percent across the account's long windows, or across every
    /// real usage window when the account reports no long window.
    public static func headroomPercent(for account: ProviderAccountUsageSnapshot) -> Double? {
        self.decidingWindows(in: self.labeledWindows(for: account)).map(\.window.remainingPercent).min()
    }

    public static func cadence(metricID: String, window: RateWindow) -> Cadence {
        if let minutes = window.windowMinutes {
            if minutes == self.sessionWindowMinutes { return .session }
            if minutes >= self.weeklyWindowMinutes { return .long }
            return .other
        }
        return metricID == "secondary" || metricID == "tertiary" ? .long : .other
    }

    private static func decidingWindows(in windows: [WindowDetail]) -> [WindowDetail] {
        let long = windows.filter { $0.cadence == .long }
        return long.isEmpty ? windows : long
    }

    private struct SortKey {
        let isExhausted: Bool
        let reset: Double
        let remaining: Double
        let label: String
        let offset: Int

        static func precedes(_ lhs: SortKey, _ rhs: SortKey) -> Bool {
            if lhs.isExhausted != rhs.isExhausted { return !lhs.isExhausted }
            if lhs.reset != rhs.reset { return lhs.reset < rhs.reset }
            if lhs.remaining != rhs.remaining { return lhs.remaining < rhs.remaining }
            let order = lhs.label.localizedStandardCompare(rhs.label)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.offset < rhs.offset
        }
    }

    private static func sortedCompactRows(
        for accounts: [ProviderAccountUsageSnapshot],
        hiddenMetricIDs: Set<String>) -> [CompactRow]
    {
        let bestCandidateID = self.bestCandidateID(in: accounts)
        let keyed = accounts.enumerated().map { offset, account in
            let deciding = self.decidingWindows(in: self.labeledWindows(for: account))
            let usable = deciding.filter { !$0.isExhausted }
            let row = self.compactRow(
                for: account,
                isBestCandidate: account.id == bestCandidateID,
                hiddenMetricIDs: hiddenMetricIDs)
            let key = SortKey(
                isExhausted: row.isExhausted,
                reset: row.nextResetAt?.timeIntervalSinceReferenceDate ?? .infinity,
                remaining: usable.map(\.window.remainingPercent).min() ?? 0,
                label: account.displayLabel,
                offset: offset)
            return (row: row, key: key)
        }
        return keyed.sorted { SortKey.precedes($0.key, $1.key) }.map(\.row)
    }

    private static func compactRow(
        for account: ProviderAccountUsageSnapshot,
        isBestCandidate: Bool,
        hiddenMetricIDs: Set<String>) -> CompactRow
    {
        let windows = self.labeledWindows(for: account)
        let deciding = self.decidingWindows(in: windows)
        let usable = deciding.filter { !$0.isExhausted }
        let headroom = deciding.map(\.window.remainingPercent).min()
        let nextReset = (usable.isEmpty ? deciding : usable).compactMap(\.window.resetsAt).min()

        let visible = windows.filter { !hiddenMetricIDs.contains($0.metricID) }
        let visibleLong = visible.filter { $0.cadence == .long }
        var claimedSessionIDs: Set<String> = []
        let longWindows = visibleLong.map { long -> LongWindowSummary in
            guard !long.isExhausted,
                  let session = visible.first(where: {
                      $0.cadence == .session && $0.poolID == long.poolID && !claimedSessionIDs.contains($0.metricID)
                  })
            else { return LongWindowSummary(window: long, session: nil) }
            claimedSessionIDs.insert(session.metricID)
            return LongWindowSummary(window: long, session: session)
        }

        let details: [WindowDetail]
        if visibleLong.isEmpty {
            let ranked = visible.sorted { $0.window.remainingPercent < $1.window.remainingPercent }
            let constrained = ranked.filter { $0.window.remainingPercent <= self.warningHeadroomPercent }
            details = constrained.isEmpty ? Array(ranked.prefix(1)) : constrained
        } else {
            details = visibleLong
        }
        return CompactRow(
            accountID: account.id,
            label: account.displayLabel,
            headroomPercent: headroom,
            severity: headroom.map(self.severity(forHeadroom:)),
            windowDetails: details,
            longWindows: longWindows,
            isExhausted: usable.isEmpty,
            nextResetAt: nextReset,
            lastKnownUsageCapturedAt: account.usesLastKnownUsage ? account.snapshot?.updatedAt : nil,
            hasError: account.error != nil,
            canActivate: account.canActivate,
            isBestCandidate: isBestCandidate)
    }

    private static func bestCandidateID(
        in accounts: [ProviderAccountUsageSnapshot]) -> ProviderAccountIdentity?
    {
        accounts
            .compactMap { account -> (id: ProviderAccountIdentity, headroom: Double)? in
                guard account.canActivate, account.error == nil, !account.usesLastKnownUsage,
                      let headroom = self.headroomPercent(for: account),
                      self.severity(forHeadroom: headroom) == .healthy
                else { return nil }
                return (account.id, headroom)
            }
            .max { $0.headroom < $1.headroom }?
            .id
    }

    private static func labeledWindows(
        for account: ProviderAccountUsageSnapshot) -> [WindowDetail]
    {
        guard let snapshot = account.snapshot else { return [] }
        let metadata = ProviderDefaults.metadata[account.provider]
        let extras = (snapshot.extraRateWindows ?? []).filter(\.usageKnown)
        // Provider-specific by design: Antigravity quota-summary snapshots copy one lane per family into
        // primary/secondary; the per-family extras are authoritative, so the copies would double count.
        let hasFamilyLanes = extras.contains { $0.id.hasPrefix(self.quotaSummaryWindowIDPrefix) }
        var windows: [WindowDetail] = []
        if !hasFamilyLanes, let primary = snapshot.primary, !primary.isSyntheticPlaceholder {
            windows.append(WindowDetail(
                metricID: "primary",
                label: (account.provider == .cursor ? CursorProviderDescriptor.primaryLabel(snapshot: snapshot) : nil)
                    ?? metadata?.sessionLabel ?? "Session",
                window: primary,
                resetPresentation: self.primaryResetPresentation(for: account, window: primary),
                cadence: self.cadence(metricID: "primary", window: primary),
                poolID: "main"))
        }
        if !hasFamilyLanes, let secondary = snapshot.secondary {
            windows.append(WindowDetail(
                metricID: "secondary",
                label: metadata?.weeklyLabel ?? "Weekly",
                window: secondary,
                resetPresentation: .standard,
                cadence: self.cadence(metricID: "secondary", window: secondary),
                poolID: "main"))
        }
        if let tertiary = snapshot.tertiary {
            windows.append(WindowDetail(
                metricID: "tertiary",
                label: metadata?.opusLabel ?? "Monthly",
                window: tertiary,
                resetPresentation: .standard,
                cadence: self.cadence(metricID: "tertiary", window: tertiary)))
        }
        for extra in extras {
            windows.append(WindowDetail(
                metricID: extra.id,
                label: self.shortLabel(forWindowTitle: extra.title),
                window: extra.window,
                resetPresentation: .standard,
                cadence: self.cadence(metricID: extra.id, window: extra.window),
                poolID: self.familyPoolID(for: extra)))
        }
        return windows
    }

    /// Family lanes are titled "<family> 5-hour" / "<family> weekly"; the family half pairs them.
    private static func familyPoolID(for extra: NamedRateWindow) -> String {
        guard extra.id.hasPrefix(self.quotaSummaryWindowIDPrefix) else { return extra.id }
        let title = extra.title.trimmingCharacters(in: .whitespaces).lowercased()
        for suffix in [" 5-hour", " weekly"] where title.hasSuffix(suffix) {
            let family = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            if !family.isEmpty { return "family:\(family)" }
        }
        var key = String(extra.id.dropFirst(self.quotaSummaryWindowIDPrefix.count)).lowercased()
            .replacingOccurrences(of: "_", with: "-")
        for suffix in ["-5h", "-5-hour", "-session", "-weekly"] where key.hasSuffix(suffix) {
            key.removeLast(suffix.count)
            break
        }
        return "family:\(key)"
    }

    private static func primaryResetPresentation(
        for account: ProviderAccountUsageSnapshot,
        window: RateWindow) -> ResetPresentation
    {
        let policy = ProviderDescriptorRegistry.descriptor(for: account.provider).presentation.menuCard
        if policy.clearsPrimaryReset ||
            ((policy.hidesPrimaryResetWithoutDate || policy.usesAbacusPace) && window.resetsAt == nil)
        {
            return .hidden
        }
        if policy.usesRawPrimaryResetDescription {
            return .providerDescription
        }
        if policy.primaryDescriptionPlacement == .reset,
           let description = window.resetDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .providerDescription
        }
        return .standard
    }

    /// Scoped weekly windows are titled "<model> only" for the card view; the
    /// compact row's constraint summary reads better without the suffix.
    public static func shortLabel(forWindowTitle title: String) -> String {
        guard title.hasSuffix(" only") else { return title }
        let trimmed = String(title.dropLast(" only".count))
        return trimmed.isEmpty ? title : trimmed
    }
}
