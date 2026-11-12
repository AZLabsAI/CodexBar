import CodexBarCore
import Foundation
import Testing

/// Synthetic accounts for the weekly-summary compact layout. Remaining percents and
/// reset hours mirror a five-account Antigravity setup where only long windows matter.
enum WeeklySummaryFixture {
    static let now = Date(timeIntervalSince1970: 1_782_000_000)

    static func window(remaining: Double, minutes: Int?, hours: Double?) -> RateWindow {
        RateWindow(
            usedPercent: 100 - remaining,
            windowMinutes: minutes,
            resetsAt: hours.map { self.now.addingTimeInterval($0 * 3600) },
            resetDescription: nil)
    }

    static func family(
        _ bucket: String,
        title: String,
        weekly: Double,
        resetsIn weeklyHours: Double,
        session: Double = 80,
        sessionResetsIn sessionHours: Double = 2) -> [NamedRateWindow]
    {
        [
            NamedRateWindow(
                id: "antigravity-quota-summary-\(bucket)-5h",
                title: "\(title) 5-hour",
                window: self.window(remaining: session, minutes: 300, hours: sessionHours)),
            NamedRateWindow(
                id: "antigravity-quota-summary-\(bucket)-weekly",
                title: "\(title) weekly",
                window: self.window(remaining: weekly, minutes: 10080, hours: weeklyHours)),
        ]
    }

    static func gemini(_ weekly: Double, _ hours: Double, session: Double = 80) -> [NamedRateWindow] {
        self.family("gemini", title: "Gemini", weekly: weekly, resetsIn: hours, session: session)
    }

    static func claudeGPT(_ weekly: Double, _ hours: Double, session: Double = 80) -> [NamedRateWindow] {
        self.family("3p", title: "Claude/GPT", weekly: weekly, resetsIn: hours, session: session)
    }

    static func argon(_ weekly: Double, _ hours: Double) -> [NamedRateWindow] {
        self.family("gemini-4-argon", title: "Gemini 4 Argon", weekly: weekly, resetsIn: hours)
    }

    static func antigravity(
        _ label: String,
        isActive: Bool = false,
        lanes: [NamedRateWindow]) -> ProviderAccountUsageSnapshot
    {
        // Quota-summary snapshots also copy one lane per family into primary/secondary; the copies
        // here are the 5-hour lanes so a planner that read them would rank by the wrong window.
        let sessions = lanes.filter { $0.window.windowMinutes == 300 }
        return ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "token-account", opaqueID: label),
            provider: .antigravity,
            displayLabel: label,
            isActive: isActive,
            canActivate: !isActive,
            snapshot: UsageSnapshot(
                primary: sessions.first?.window,
                secondary: sessions.dropFirst().first?.window,
                tertiary: nil,
                extraRateWindows: lanes,
                updatedAt: self.now),
            error: nil,
            sourceLabel: "oauth")
    }

    /// Input order is deliberately scrambled; the plan must not depend on it.
    static func fiveAccounts() -> [ProviderAccountUsageSnapshot] {
        [
            self.antigravity("hashtag3d", lanes: self.gemini(0, 82) + self.claudeGPT(0, 83)),
            self.antigravity("gptcodeshoppro", lanes: self.gemini(0, 76) + self.claudeGPT(47, 129) + self.argon(0, 81)),
            self.antigravity("azlabsai", lanes: self.gemini(0, 79) + self.claudeGPT(0, 83)),
            self.antigravity("aubrey.zemba", isActive: true, lanes: self.gemini(0, 79) + self.claudeGPT(0, 83)),
            self.antigravity("vibecodeai", lanes: self.gemini(5, 74) + self.claudeGPT(0, 82)),
        ]
    }

    static func generic(
        _ label: String,
        isActive: Bool = false,
        session: RateWindow? = nil,
        weekly: RateWindow? = nil,
        monthly: RateWindow? = nil) -> ProviderAccountUsageSnapshot
    {
        ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "codex-account", opaqueID: label),
            provider: .codex,
            displayLabel: label,
            isActive: isActive,
            canActivate: !isActive,
            snapshot: UsageSnapshot(
                primary: session,
                secondary: weekly,
                tertiary: monthly,
                updatedAt: self.now),
            error: nil,
            sourceLabel: "fixture")
    }

    static func compactRows(in plan: AccountMenuLayoutPlanner.Plan) -> [AccountMenuLayoutPlanner.CompactRow] {
        plan.rows.compactMap { row in
            if case let .compact(compact) = row { return compact }
            return nil
        }
    }

    static func compactRow(
        _ label: String,
        in accounts: [ProviderAccountUsageSnapshot]) throws -> AccountMenuLayoutPlanner.CompactRow
    {
        try #require(self.compactRows(in: AccountMenuLayoutPlanner.plan(accounts: accounts)).first {
            $0.label == label
        })
    }

    static func hours(_ hours: Double) -> Date {
        self.now.addingTimeInterval(hours * 3600)
    }
}

struct WeeklySummaryAccountPlannerTests {
    private typealias Fixture = WeeklySummaryFixture

    @Test
    func `five account fixture keeps remaining pools above exhausted ones and orders by soonest reset`() {
        let accounts = Fixture.fiveAccounts()
        let plan = AccountMenuLayoutPlanner.plan(accounts: accounts)
        let labels = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.displayLabel) })
        let order = plan.rows.map { row -> String in
            switch row {
            case let .card(id): "card:\(labels[id] ?? "?")"
            case let .compact(compact): compact.label
            case let .collapsedHealthy(count): "collapsed:\(count)"
            }
        }
        #expect(order == [
            "card:aubrey.zemba",
            "vibecodeai",
            "gptcodeshoppro",
            "azlabsai",
            "hashtag3d",
        ])
        let compacts = Fixture.compactRows(in: plan)
        #expect(compacts.map(\.isExhausted) == [false, false, true, true])
        #expect(compacts.map(\.nextResetAt) == [
            Fixture.hours(74),
            Fixture.hours(129),
            Fixture.hours(79),
            Fixture.hours(82),
        ])
    }

    @Test
    func `vibecodeai summarizes both weekly families and gates the five hour lane on its weekly`() throws {
        let row = try Fixture.compactRow("vibecodeai", in: Fixture.fiveAccounts())
        #expect(row.longWindows.map(\.window.label) == ["Gemini weekly", "Claude/GPT weekly"])
        #expect(row.longWindows.map(\.window.window.remainingPercent) == [5, 0])
        #expect(row.longWindows.map(\.window.window.resetsAt) == [Fixture.hours(74), Fixture.hours(82)])
        #expect(row.longWindows.map { $0.session?.label } == ["Gemini 5-hour", nil])
        #expect(row.windowDetails.map(\.metricID) == [
            "antigravity-quota-summary-gemini-weekly",
            "antigravity-quota-summary-3p-weekly",
        ])
        #expect(row.windowDetails.allSatisfy { $0.window.windowMinutes == 10080 })
        // 80% left on the 5-hour lane never lifts the row: headroom comes from long windows only.
        #expect(row.headroomPercent == 0)
        #expect(row.severity == .critical)
    }

    @Test
    func `gptcodeshoppro shows every family weekly including Argon with only the open pool's five hour lane`() throws {
        let row = try Fixture.compactRow("gptcodeshoppro", in: Fixture.fiveAccounts())
        #expect(row.longWindows.map(\.window.label) == ["Gemini weekly", "Claude/GPT weekly", "Gemini 4 Argon weekly"])
        #expect(row.longWindows.map(\.window.window.remainingPercent) == [0, 47, 0])
        #expect(row.longWindows.map { $0.session?.metricID } == [nil, "antigravity-quota-summary-3p-5h", nil])
        #expect(!row.isExhausted)
    }

    @Test
    func `an exhausted family keeps its five hour lane off the row`() throws {
        let row = try Fixture.compactRow("azlabsai", in: Fixture.fiveAccounts())
        #expect(row.longWindows.count == 2)
        #expect(row.longWindows.allSatisfy { $0.session == nil })
        #expect(row.isExhausted)
        #expect(row.nextResetAt == Fixture.hours(79))
    }

    @Test
    func `three percent weekly left outranks every exhausted account and exhausted rows order by reset`() {
        let session = Fixture.window(remaining: 100, minutes: 300, hours: 1)
        let accounts = [
            Fixture.generic(
                "active",
                isActive: true,
                session: session,
                weekly: Fixture.window(remaining: 0, minutes: 10080, hours: 10)),
            Fixture.generic(
                "late-out",
                session: session,
                weekly: Fixture.window(remaining: 0, minutes: 10080, hours: 90)),
            Fixture.generic(
                "soon-out",
                session: session,
                weekly: Fixture.window(remaining: 0, minutes: 10080, hours: 20)),
            Fixture.generic(
                "three-left",
                session: Fixture.window(remaining: 0, minutes: 300, hours: 4),
                weekly: Fixture.window(remaining: 3, minutes: 10080, hours: 150)),
            Fixture.generic(
                "monthly-only-left",
                weekly: Fixture.window(remaining: 0, minutes: 10080, hours: 5),
                monthly: Fixture.window(remaining: 40, minutes: nil, hours: 300)),
        ]
        let rows = Fixture.compactRows(in: AccountMenuLayoutPlanner.plan(accounts: accounts))
        #expect(rows.map(\.label) == ["three-left", "monthly-only-left", "soon-out", "late-out"])
        let threeLeft = rows[0]
        // The spent 5-hour lane neither ranks the row nor hides the weekly that still has room.
        #expect(threeLeft.headroomPercent == 3)
        #expect(threeLeft.longWindows.map { $0.session?.metricID } == ["primary"])
        let monthly = rows[1]
        #expect(monthly.longWindows.map(\.window.metricID) == ["secondary", "tertiary"])
        #expect(monthly.nextResetAt == Fixture.hours(300))
        #expect(rows[2].longWindows.first?.session == nil)
    }

    @Test
    func `same reset ties break on the more drained long window then label`() {
        let accounts = [
            Fixture.generic("active", isActive: true, weekly: Fixture.window(remaining: 50, minutes: 10080, hours: 1)),
            Fixture.generic("b-more-left", weekly: Fixture.window(remaining: 30, minutes: 10080, hours: 24)),
            Fixture.generic("c-tie", weekly: Fixture.window(remaining: 20, minutes: 10080, hours: 24)),
            Fixture.generic("a-tie", weekly: Fixture.window(remaining: 20, minutes: 10080, hours: 24)),
            Fixture.generic("z-out", weekly: Fixture.window(remaining: 0, minutes: 10080, hours: 24)),
            Fixture.generic("y-out", weekly: Fixture.window(remaining: 0, minutes: 10080, hours: 24)),
        ]
        let rows = Fixture.compactRows(in: AccountMenuLayoutPlanner.plan(accounts: accounts))
        #expect(rows.map(\.label) == ["a-tie", "c-tie", "b-more-left", "y-out", "z-out"])
    }

    @Test
    func `collapsed healthy summary stays above exhausted accounts`() {
        let healthy = { (label: String, hours: Double) in
            Fixture.generic(label, weekly: Fixture.window(remaining: 90, minutes: 10080, hours: hours))
        }
        let accounts = [
            Fixture.generic("active", isActive: true, weekly: Fixture.window(remaining: 50, minutes: 10080, hours: 1)),
            Fixture.generic("spent", weekly: Fixture.window(remaining: 0, minutes: 10080, hours: 2)),
            healthy("ready-1", 10),
            healthy("ready-2", 20),
            healthy("ready-3", 30),
        ]
        let rows = AccountMenuLayoutPlanner.plan(accounts: accounts).rows
        #expect(rows.count == 4)
        #expect(rows[2] == .collapsedHealthy(count: 2))
        guard case let .compact(last) = rows[3] else {
            Issue.record("expected the exhausted account last, got \(rows)")
            return
        }
        #expect(last.label == "spent")
    }
}
