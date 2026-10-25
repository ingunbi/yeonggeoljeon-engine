// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func originalRetirementSelfTests() throws {
    var checks = 0
    func check(_ value: Bool, _ reason: String) throws {
        checks += 1
        if !value { throw EngineError.invalid("Original retirement regression: \(reason)") }
    }
    func probe(_ step: OriginalRetirementStep) throws -> OriginalRetirementProbe {
        guard case .probe(let value) = step else { throw EngineError.invalid("Expected original retirement probe") }
        return value
    }
    let notice = OriginalRetirementNotice(sequence: 3, runtimeSlot: 1, person: 42)
    var context = OriginalRetirementContext(runtimeSlot: 1, person: 42, battleResult: 0,
        objectives: [.init(eventKind: 8, enabled: true, person: 42), .init(eventKind: 7, enabled: true, person: 42)])
    let operation = try OriginalRetirementOperation(notice: notice)
    let first = try probe(operation.advance(context: context))
    try check(first.event == .init(kind: 7, arguments: []) && first.kind == .firstObjective,
              "first source objective pair wins even when typed input array is reversed")
    try check(try operation.advance(context: context) == .probe(first), "unacknowledged source lookup is stable")
    let restored = try JSONDecoder().decode(OriginalRetirementOperation.self, from: JSONEncoder().encode(operation))
    try restored.resumeProbe(first, response: .noMatch)
    let automatic = try probe(restored.advance(context: context))
    try check(automatic.kind == .automatic, "failed objective lookup falls back to source automatic query")
    try restored.resumeProbe(automatic, response: .interpreterReturned(5))
    context.person = 9
    context.objectives = [.init(eventKind: 8, enabled: true, person: 9)]
    let changed = try probe(restored.advance(context: context))
    try check(changed.event.kind == 8, "source loop rereads the current slot person after a script")
    try restored.resumeProbe(changed, response: .interpreterReturned(1))
    let generic = try probe(restored.advance(context: context))
    try check(generic.event == .init(kind: 12, arguments: [9]), "generic lookup follows objective handling with current identity")
    try restored.resumeProbe(generic, response: .noMatch)
    let wildcard = try probe(restored.advance(context: context))
    try check(wildcard.event == .init(kind: 12, arguments: [0x400]), "friendly wildcard follows missing exact-person script")
    try restored.resumeProbe(wildcard, response: .noMatch)
    guard case .finished(let handled) = try restored.advance(context: context) else { throw EngineError.invalid("Handled retirement fell into default presentation") }
    try check(handled.handledBySourceScript && handled.probes == 5, "objective script alone suppresses default retreat")

    let enemyNotice = OriginalRetirementNotice(sequence: 4, runtimeSlot: 15, person: 7)
    var enemyContext = OriginalRetirementContext(runtimeSlot: 15, person: 7, battleResult: 0, objectives: [])
    let enemy = try OriginalRetirementOperation(notice: enemyNotice)
    let auto = try probe(enemy.advance(context: enemyContext))
    try check(auto.kind == .automatic, "no objective match still queries source automatic phase")
    try enemy.resumeProbe(auto, response: .noMatch)
    let exact = try probe(enemy.advance(context: enemyContext))
    try enemy.resumeProbe(exact, response: .noMatch)
    let quote = try enemy.advance(context: enemyContext)
    try check(quote == .presentation(.quote(person: 7, bank: 0)), "enemy has no friendly wildcard and receives source retreat quote")
    try check(try enemy.advance(context: enemyContext) == quote, "presentation blocks without consuming another source step")
    try enemy.acknowledge(quote)
    let popup = try enemy.advance(context: enemyContext)
    try check(popup == .presentation(.retreated(person: 7)), "unhandled ordinary retirement reports retreat")
    try enemy.acknowledge(popup)
    guard case .finished(let plain) = try enemy.advance(context: enemyContext) else { throw EngineError.invalid("Retreat popup did not finish") }
    try check(!plain.handledBySourceScript, "default path retains absent handler evidence")

    let leaderNotice = OriginalRetirementNotice(sequence: 5, runtimeSlot: 0, person: 0)
    var leaderContext = OriginalRetirementContext(runtimeSlot: 0, person: 0, battleResult: 0, objectives: [])
    let leader = try OriginalRetirementOperation(notice: leaderNotice)
    for _ in 0..<3 {
        let query = try probe(leader.advance(context: leaderContext))
        try leader.resumeProbe(query, response: .noMatch)
    }
    let result = try leader.advance(context: leaderContext)
    try check(result == .effect(.battleResult(3)), "only unhandled source person zero sets raw result3")
    leaderContext.battleResult = 3
    try leader.acknowledge(result)
    let music = try leader.advance(context: leaderContext)
    try check(music == .effect(.music(4)), "source default result is followed by music4")
    try leader.acknowledge(music)
    let leaderQuote = try leader.advance(context: leaderContext)
    try check(leaderQuote == .presentation(.quote(person: 0, bank: 1)), "leader uses source quote bank1")
    try leader.acknowledge(leaderQuote)
    let defeat = try leader.advance(context: leaderContext)
    try check(defeat == .presentation(.leaderDefeat), "source leader message follows its quote")
    try leader.acknowledge(defeat)
    guard case .finished = try leader.advance(context: leaderContext) else { throw EngineError.invalid("Result3 should suppress later retirement popup/status5") }
    checks += 1

    enemyContext.battleResult = 2
    let ended = try OriginalRetirementOperation(notice: enemyNotice)
    let endedQuote = try ended.advance(context: enemyContext)
    try check(endedQuote == .presentation(.quote(person: 7, bank: 0)), "nonzero battle result skips script probes without inventing new result")
    var foreign = enemyContext; foreign.runtimeSlot = 14
    do { _ = try ended.advance(context: foreign); throw EngineError.invalid("foreign slot accepted") }
    catch BattleError.invalid(let reason) where reason.contains("live source slot") { checks += 1 }

    // Production VM + dispatcher boundary: objective changes phase, automatic
    // script changes phase again, then generic retirement waits for a choice.
    func instruction(_ opcode: Int, _ offset: Int, _ kind: String, _ args: [Int] = [], target: Int? = nil,
                     options: [String]? = nil) -> OriginalCampaignInstruction {
        OriginalCampaignInstruction(opcode: opcode, offset: offset, kind: kind, arguments: args,
                                    commands: [], skipTarget: target, options: options)
    }
    let finish = instruction(255, 90, "end-record")
    func record(_ block: Int, _ kind: Int, _ words: [Int], _ instructions: [OriginalCampaignInstruction]) -> OriginalCampaignRecord {
        OriginalCampaignRecord(id: "synthetic:\(block)", chapter: 0, member: 0, block: block, ordinal: 0,
            kind: kind, inverted: false, rawKind: kind, words: words,
            group: .init(base: 0, count: 1, repeating: false), instructions: instructions)
    }
    let program = OriginalCampaignProgram(format: 1, records: [
        record(0, 7, [0,0,0], [instruction(20, 0, "flag", [1,0]), instruction(19, 10, "next-phase"), finish]),
        record(1, 0, [0,0,0], [instruction(20, 0, "flag", [2,0]), instruction(19, 10, "next-phase"), finish]),
        record(2, 12, [5,0,0], [instruction(21, 0, "choice-skip", [1], target: 20, options: ["No","Yes"]),
            instruction(20, 10, "flag", [4,0]), instruction(20, 20, "flag", [3,0]), finish])])
    var integrationVM = try CampaignVM(program: program)
    var integration = try OriginalRetirementOperation(notice: .init(sequence: 6, runtimeSlot: 2, person: 5))
    let integrationContext = OriginalRetirementContext(runtimeSlot: 2, person: 5, battleResult: 0,
        objectives: [.init(eventKind: 7, enabled: true, person: 5)])
    var completed = false, choices = 0
    for _ in 0..<16 {
        let step = try integration.advance(context: integrationContext)
        if case .finished(let report) = step {
            try check(report.handledBySourceScript, "bounded generic script suppresses the source default path")
            completed = true; break
        }
        let query = try probe(step)
        if try !integrationVM.queryInvocation(event: query.event) {
            try integration.resumeProbe(query, response: .noMatch); continue
        }
        var returned: OriginalCampaignInterpreterReturn?
        for _ in 0..<8 {
            let output = try integrationVM.advance()
            if case .choice = output {
                choices += 1
                try check(try !integrationVM.state.flag(3) && integration.advance(context: integrationContext) == step,
                          "retirement and following effects remain blocked by native source choice")
                integration = try JSONDecoder().decode(OriginalRetirementOperation.self, from: JSONEncoder().encode(integration))
                let saved = try JSONDecoder().decode(OriginalCampaignState.self, from: JSONEncoder().encode(integrationVM.snapshot()))
                integrationVM = try CampaignVM(program: program, state: saved)
                try integrationVM.choose(index: 1)
            } else if case .invocationReturn = output {
                returned = try integrationVM.takeInvocationReturn(); break
            } else { throw EngineError.invalid("Unexpected bounded retirement VM output") }
        }
        guard let returned = returned else { throw EngineError.invalid("Bounded retirement VM did not return") }
        try integration.resumeProbe(query, response: .interpreterReturned(returned.status))
    }
    try check(completed && choices == 1, "retirement resumes exactly once through objective/automatic/generic sequence")
    try check(try integrationVM.state.flag(1) && integrationVM.state.flag(2) && integrationVM.state.flag(3) && !integrationVM.state.flag(4),
              "restored choice preserves original flag order and skips only its selected source instruction")
    print("Original retirement self-tests: \(checks) assertions passed")
}
