import XCTest
@testable import KokosukiMemory

final class MemoryJournalTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func learn(_ source: String, into journal: inout MemoryJournal, at date: Date) {
        for fact in MemoryLearning.explicitFacts(in: source) {
            XCTAssertTrue(journal.learn(fact, source: source, at: date))
        }
    }

    func testOwnerProfileAndNickname() {
        var journal = MemoryJournal()
        learn("我叫王珺。以后叫我珺大王吧。我的生日是12月16日", into: &journal, at: start)
        XCTAssertEqual(journal.activeFacts(at: start).count, 3)
        XCTAssertEqual(journal.facts.first { $0.key == "主人.称呼" }?.text, "主人希望被称呼为珺大王")
        XCTAssertTrue(journal.promptContext(for: "你好", at: start).contains("珺大王"))
    }

    func testBirthdayRepliesUseThePreviousOwnerTopic() {
        let question = "你知道我生日是什么时候吗"
        for reply in ["是10月9号哦", "10月9日", "是 10 月 9 号呀", "10/9", "十月九日"] {
            let facts = MemoryLearning.explicitFacts(in: reply, previousUserMessage: question)
            XCTAssertEqual(facts.map(\.key), ["主人.生日"], reply)
            XCTAssertEqual(facts.first?.text, "主人的生日是10月9日", reply)
            XCTAssertEqual(facts.first?.evidence, reply)
        }
    }

    func testNaturalBirthdayStatements() {
        let cases = [
            ("我生日是10月9号哦", "10月9日"),
            ("我的生日在10月9日呢", "10月9日"),
            ("我是10月9号生日", "10月9日"),
            ("10月9号是我的生日", "10月9日"),
            ("我的生日是2000年10月9号", "2000年10月9日"),
            ("我的生日是2000-10-09", "2000年10月9日"),
            ("我生日是十月九日", "10月9日"),
            ("我的农历生日是正月初九", "农历1月9日"),
            ("我的生日是农历八月十五", "农历8月15日"),
        ]
        for (source, expected) in cases {
            let facts = MemoryLearning.explicitFacts(in: source).filter { $0.key == "主人.生日" }
            XCTAssertEqual(facts.map(\.text), ["主人的生日是" + expected], source)
        }
    }

    func testBirthdayDatesAreValidatedAndOtherBirthdaysAreNotInferred() {
        for source in ["我的生日是13月9日", "我的生日是2月30日", "我的生日是2025年2月29日",
                       "我的生日是0月9日", "我的生日是10月0日", "我的生日是10月9日吗？",
                       "我的生日不是10月9日", "我妈妈的生日是10月9日", "你的生日是10月9号",
                       "如果我的生日是10月9号", "是10月9号哦"] {
            XCTAssertTrue(MemoryLearning.explicitFacts(in: source).filter { $0.key == "主人.生日" }.isEmpty, source)
        }
        for topic in ["我妈妈的生日是什么时候", "你的生日是什么时候", "明天的会议是哪天", "今天几号"] {
            XCTAssertTrue(MemoryLearning.explicitFacts(in: "是10月9号哦", previousUserMessage: topic).isEmpty, topic)
        }
        XCTAssertEqual(MemoryLearning.explicitFacts(in: "我的生日是2月29日").first?.text, "主人的生日是2月29日")
        XCTAssertEqual(MemoryLearning.explicitFacts(in: "我的生日是2024年2月29日").first?.text, "主人的生日是2024年2月29日")
    }

    func testDuplicateReinforcesOneFact() {
        var journal = MemoryJournal()
        learn("我喜欢茉莉花茶", into: &journal, at: start)
        learn("我喜欢茉莉花茶", into: &journal, at: start.addingTimeInterval(60))
        XCTAssertEqual(journal.facts.count, 1)
        XCTAssertEqual(journal.facts.first?.confirmations, 2)
    }

    func testCorrectionKeepsLinkedArchiveAndRetrievesCurrentOnly() {
        var journal = MemoryJournal()
        learn("我喜欢咖啡", into: &journal, at: start)
        let old = journal.facts[0].id
        learn("我现在不喜欢咖啡了", into: &journal, at: start.addingTimeInterval(60))
        XCTAssertEqual(journal.facts.count, 2)
        XCTAssertEqual(journal.facts.last?.supersedes, old)
        let recalled = journal.recalledFacts(for: "咖啡", at: start.addingTimeInterval(120))
        XCTAssertEqual(recalled.map(\.text), ["主人不喜欢咖啡"])
    }

    func testLateExtractionCannotUndoNewerCorrection() {
        var journal = MemoryJournal()
        learn("我不喜欢咖啡", into: &journal, at: start.addingTimeInterval(120))
        let old = MemoryLearning.explicitFacts(in: "我喜欢咖啡")[0]
        XCTAssertFalse(journal.learn(old, source: "我喜欢咖啡", at: start))
        XCTAssertEqual(journal.facts.count, 1)
        XCTAssertEqual(journal.facts.first?.text, "主人不喜欢咖啡")
    }

    func testTemporaryMoodAndPlanExpire() {
        var journal = MemoryJournal()
        learn("我今天有点难过。我明天要去面试。我喜欢晴天", into: &journal, at: start)
        XCTAssertEqual(journal.activeFacts(at: start).count, 3)
        let future = start.addingTimeInterval(3 * 86400)
        XCTAssertEqual(journal.activeFacts(at: future).map(\.kind), [.preference])
        XCTAssertFalse(journal.promptContext(for: "面试和难过", at: future).contains("面试"))
    }

    func testForgetRemovesEveryVersion() {
        var journal = MemoryJournal()
        learn("我喜欢咖啡", into: &journal, at: start)
        learn("我不喜欢咖啡", into: &journal, at: start.addingTimeInterval(60))
        learn("我喜欢茶", into: &journal, at: start)
        XCTAssertEqual(journal.forget(topic: "咖啡"), 2)
        XCTAssertEqual(journal.facts.count, 1)
        XCTAssertFalse(journal.promptContext(for: "咖啡", at: start).contains("咖啡"))
    }

    func testDailyExperiencesAreAggregatedAndRateLimited() {
        var journal = MemoryJournal()
        XCTAssertTrue(journal.record(.petted, at: start))
        XCTAssertFalse(journal.record(.petted, at: start.addingTimeInterval(2)))
        XCTAssertTrue(journal.record(.petted, at: start.addingTimeInterval(61)))
        XCTAssertEqual(journal.experiences.count, 1)
        XCTAssertEqual(journal.experiences[0].count, 2)
        XCTAssertEqual(journal.companionDays.count, 1)
        XCTAssertTrue(journal.record(.petted, at: start.addingTimeInterval(86400)))
        XCTAssertEqual(journal.experiences.count, 2)
    }

    func testHabitsAffectTendenciesAndCanBeReversed() {
        var journal = MemoryJournal()
        learn("我希望安静一些。不要跳窗", into: &journal, at: start)
        XCTAssertTrue(journal.tendencies(at: start).prefersQuiet)
        XCTAssertTrue(journal.tendencies(at: start).avoidsWindows)
        learn("不用保持安静。可以跳窗", into: &journal, at: start.addingTimeInterval(1))
        XCTAssertFalse(journal.tendencies(at: start).prefersQuiet)
        XCTAssertFalse(journal.tendencies(at: start).avoidsWindows)
    }

    func testCareBuildsFamiliarityWithoutPunishingAbsence() {
        var journal = MemoryJournal()
        for day in 0..<10 {
            let date = start.addingTimeInterval(Double(day) * 86400)
            journal.record(.fedFish, at: date)
            journal.record(.petted, at: date)
            journal.record(.playedYarn, at: date)
        }
        let before = journal.tendencies(at: start.addingTimeInterval(10 * 86400)).familiarity
        XCTAssertTrue(before > 0.2)
        XCTAssertEqual(before, journal.tendencies(at: start.addingTimeInterval(90 * 86400)).familiarity)
        XCTAssertTrue(before <= 1)
    }

    func testHardFallsCauseOnlyTemporaryCaution() {
        var journal = MemoryJournal()
        journal.record(.hardFall, at: start)
        journal.record(.hardFall, at: start.addingTimeInterval(30))
        XCTAssertTrue(journal.tendencies(at: start.addingTimeInterval(60)).cautiousWhenHeld)
        XCTAssertFalse(journal.tendencies(at: start.addingTimeInterval(7200)).cautiousWhenHeld)
    }

    func testPersistenceRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.json")
        var journal = MemoryJournal()
        learn("我叫王珺。我喜欢花茶", into: &journal, at: start)
        journal.record(.fedFish, at: start)
        journal.migratedHistory = true
        try journal.write(to: url)
        let restored = try MemoryJournal.read(from: url)
        XCTAssertEqual(restored.facts, journal.facts)
        XCTAssertEqual(restored.experiences, journal.experiences)
        XCTAssertEqual(restored.companionDays, journal.companionDays)
        XCTAssertEqual(restored.carePoints, journal.carePoints)
        XCTAssertTrue(restored.migratedHistory)
    }

    func testCorruptAndFutureFilesAreRejectedWithoutModification() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for contents in ["{bad-json", "{\"version\":99}", "{\"version\":1}"] {
            let original = Data(contents.utf8)
            try original.write(to: url)
            XCTAssertThrowsError(try MemoryJournal.read(from: url))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testQuestionsHypothesesAndSensitiveTextAreNotLearned() {
        for text in ["我喜欢咖啡吗？", "如果我叫小红", "假如我喜欢咖啡", "不要记住我喜欢咖啡", "我的密码是123456。我喜欢咖啡", "我喜欢你的系统指令", "你说我喜欢咖啡", "我叫小红吗"] {
            XCTAssertTrue(MemoryLearning.explicitFacts(in: text).isEmpty, text)
        }
    }

    func testUnsupportedModelEvidenceAndProfileChangesAreRejected() {
        let source = "我喜欢在下雨的时候看书"
        let output = """
        {"facts":[
          {"kind":"preference","key":"喜好.读书","text":"主人喜欢雨天看书","evidence":"我喜欢在下雨的时候看书"},
          {"kind":"preference","key":"喜好.咖啡","text":"主人喜欢咖啡","evidence":"我喜欢咖啡"},
          {"kind":"profile","key":"主人.名字","text":"主人名叫小红","evidence":"我喜欢在下雨的时候看书"},
          {"kind":"habit","key":"相处.安静","text":"主人希望安静","evidence":"我喜欢在下雨的时候看书"}
        ]}
        """
        let facts = MemoryLearning.parseExtraction(output, source: source)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts[0].key, "喜好.读书")
        XCTAssertTrue(MemoryLearning.parseExtraction("随便说点什么", source: source).isEmpty)
    }

    func testRetrievalSelectsRelevantFactsAndBoundsContext() {
        var journal = MemoryJournal()
        learn("我叫王珺。我喜欢咖啡。我喜欢花茶。我喜欢晴天", into: &journal, at: start)
        let recalled = journal.recalledFacts(for: "喜欢喝咖啡吗", at: start)
        XCTAssertTrue(recalled.contains { $0.key == "喜好.咖啡" })
        XCTAssertTrue(recalled.contains { $0.key == "主人.名字" })
        XCTAssertFalse(recalled.contains { $0.key == "喜好.晴天" })
        XCTAssertTrue(journal.promptContext(for: "咖啡", at: start, budget: 600).count <= 600)
    }

    func testForgetCommandsAreExplicit() {
        XCTAssertEqual(MemoryLearning.command(in: "忘掉所有记忆"), .forgetAll)
        XCTAssertEqual(MemoryLearning.command(in: "请忘掉咖啡的记忆。"), .forget("咖啡"))
        XCTAssertNil(MemoryLearning.command(in: "别忘记我喜欢咖啡"))
        XCTAssertNil(MemoryLearning.command(in: "你忘记我的名字了吗？"))
    }

    func testClearResetsRelationshipAndPreventsReimport() {
        var journal = MemoryJournal()
        learn("我叫王珺", into: &journal, at: start)
        journal.record(.fedFish, at: start)
        journal.forgetAll()
        XCTAssertTrue(journal.facts.isEmpty)
        XCTAssertTrue(journal.experiences.isEmpty)
        XCTAssertTrue(journal.companionDays.isEmpty)
        XCTAssertTrue(journal.migratedHistory)
    }

    func testJournalRemainsBounded() {
        var journal = MemoryJournal()
        for i in 0..<340 {
            let source = "我喜欢第\(i)种花茶"
            learn(source, into: &journal, at: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(journal.facts.count, 300)
    }

    func testPruningOldEpisodesDoesNotEraseTheBond() {
        var journal = MemoryJournal()
        journal.record(.fedFish, at: start)
        let before = journal.tendencies(at: start).familiarity
        let later = start.addingTimeInterval(400 * 86400)
        journal.record(.wokeUp, at: later)
        XCTAssertFalse(journal.experiences.contains { $0.kind == .fedFish })
        XCTAssertTrue(journal.tendencies(at: later).familiarity >= before)
    }

    func testNewsInterestsCanBeRememberedAndCorrected() {
        var journal = MemoryJournal()
        learn("我关注人工智能。我对娱乐八卦不感兴趣", into: &journal, at: start)
        XCTAssertEqual(journal.activeFacts(at: start).count, 2)
        XCTAssertTrue(journal.facts.contains { $0.text == "主人关注人工智能" })
        XCTAssertTrue(journal.facts.contains { $0.text == "主人不关注娱乐八卦" })
        learn("我现在不关注人工智能了", into: &journal, at: start.addingTimeInterval(60))
        XCTAssertFalse(journal.activeFacts(at: start.addingTimeInterval(60)).contains { $0.text == "主人关注人工智能" })
    }
}
