import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct WeeklySummaryCompactRowTests {
    private typealias Fixture = WeeklySummaryFixture

    private func model(_ label: String) throws -> MenuCardCompactAccountRowView.Model {
        try MenuCardCompactAccountRowView.Model(
            row: Fixture.compactRow(label, in: Fixture.fiveAccounts()),
            resetTimeDisplayStyle: .countdown,
            now: Fixture.now)
    }

    @Test
    func `vibecodeai chips show both weekly families and a five hour chip only on the open one`() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let model = try self.model("vibecodeai")
            #expect(model.chips.map(\.title) == ["Gemini weekly", "Claude/GPT weekly"])
            #expect(model.chips.map(\.value) == ["5%", "OUT"])
            #expect(model.chips.map(\.session) == ["5h 80%", nil])
            #expect(model.chips.map(\.isExhausted) == [false, true])
            #expect(model.chips.map(\.isCritical) == [true, true])
            #expect(model.chips.map(\.reset) == [
                UsageFormatter.resetCountdownDuration(from: Fixture.hours(74), now: Fixture.now),
                UsageFormatter.resetCountdownDuration(from: Fixture.hours(82), now: Fixture.now),
            ])
            #expect(model.chips[1].reset == "3d 10h")
            #expect(model.bestRemainingChip?.value == "5%")
            #expect(!model.isExhausted)
            #expect(model.nextResetText == nil)
            // Chips replace the quota text lines; nothing mentions the 5-hour lane except its chip.
            #expect(model.footnoteLines.isEmpty)
            #expect(!model.detailLines.contains { $0.contains("5-hour") })
            #expect(model.accessibilityText.contains("Claude/GPT weekly OUT · 3d 10h"))
        }
    }

    @Test
    func `gptcodeshoppro chips keep the exhausted Gemini and Argon weeklies beside the open Claude pool`() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let model = try self.model("gptcodeshoppro")
            #expect(model.chips.map(\.title) == ["Gemini weekly", "Claude/GPT weekly", "Gemini 4 Argon weekly"])
            #expect(model.chips.map(\.value) == ["OUT", "47%", "OUT"])
            #expect(model.chips.map(\.session) == [nil, "5h 80%", nil])
            #expect(model.chips.map(\.isCritical) == [true, false, true])
            #expect(model.bestRemainingChip?.title == "Claude/GPT weekly")
        }
    }

    @Test
    func `exhausted account leads with its soonest return and shows no five hour chip`() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let model = try self.model("azlabsai")
            #expect(model.isExhausted)
            #expect(model.nextResetText == "3d 7h")
            #expect(model.chips.allSatisfy { $0.session == nil && $0.isExhausted })
            #expect(model.chips.map(\.reset) == ["3d 7h", "3d 11h"])
            #expect(model.bestRemainingChip == nil)
        }
    }

    @Test
    func `absolute reset style formats chip resets as dates`() throws {
        let row = try Fixture.compactRow("azlabsai", in: Fixture.fiveAccounts())
        let model = MenuCardCompactAccountRowView.Model(
            row: row,
            resetTimeDisplayStyle: .absolute,
            now: Fixture.now)
        #expect(model.chips.first?.reset == UsageFormatter.resetDescription(from: Fixture.hours(79), now: Fixture.now))
        #expect(model.nextResetText == model.chips.first?.reset)
    }
}
