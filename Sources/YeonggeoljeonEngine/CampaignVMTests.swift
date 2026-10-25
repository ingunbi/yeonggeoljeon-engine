// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func campaignVMSelfTests() throws {
    var count = 0
    func check(_ predicate: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try predicate() else { throw EngineError.invalid("Original campaign VM self-test failed: \(name)") }
        count += 1
    }
    func instruction(_ opcode: Int, _ offset: Int, _ kind: String, _ args: [Int] = [],
                     commands: [Command] = [], target: Int? = nil,
                     positive: [Int]? = nil, negative: [Int]? = nil,
                     options: [String]? = nil) -> OriginalCampaignInstruction {
        OriginalCampaignInstruction(opcode: opcode, offset: offset, kind: kind,
            arguments: args, commands: commands, positiveFlags: positive,
            negativeFlags: negative, skipTarget: target, options: options)
    }
    func record(_ ordinal: Int, _ group: OriginalCampaignGroup, kind: Int = 0,
                words: [Int] = [0, 0, 0], block: Int = 0, member: Int = 0, chapter: Int = 0,
                _ instructions: [OriginalCampaignInstruction]) -> OriginalCampaignRecord {
        OriginalCampaignRecord(id: "s:\(chapter):\(member):\(block):\(ordinal)", chapter: chapter,
            member: member, block: block, ordinal: ordinal, kind: kind & 127,
            inverted: kind & 128 != 0, rawKind: kind, words: words,
            group: group, instructions: instructions)
    }
    func program(_ records: [OriginalCampaignRecord]) -> OriginalCampaignProgram {
        OriginalCampaignProgram(format: 1, records: records)
    }
    let once = OriginalCampaignGroup(base: 0, count: 1, repeating: false)
    let repeatPair = OriginalCampaignGroup(base: 0, count: 2, repeating: true)
    let end = instruction(255, 90, "end-record")

    var flags = OriginalCampaignState()
    try flags.setFlag(0, true); try flags.setFlag(7, true); try flags.setFlag(255, true)
    try check(flags.flags[0] == 0x81 && flags.flags[31] == 1, "source bitmap is MSB first")
    try flags.setFlag(0, false)
    try check(try flags.flag(7) && !flags.flag(0), "source flag clear preserves adjacent bits")

    let first = record(0, once, [instruction(20, 0, "flag", [3, 0]), end])
    let second = record(0, once, block: 1, [instruction(0, 0, "commands", commands: [Command("say", text: "synthetic")]), end])
    let vm = try CampaignVM(program: program([first, second]))
    guard case .commands(let commands) = try vm.start() else { throw EngineError.invalid("VM did not advance its source phase") }
    try check(commands[0].text == "synthetic" && vm.state.block == 1, "FF advances source block and preserves flags")
    try check(try vm.state.flag(3), "typed flag effects persist across source blocks")
    try vm.cacheActor(person: 4, x: 5, y: 6, sourceFacing: 2)
    try check(vm.state.actorCache[0].person == 4 && vm.state.actorCache[0].x == 5, "cache uses first available physical slot")
    vm.clearActorCache()
    try check(vm.state.actorCache[0].person == 65535 && vm.state.actorCache[0].x == 5 &&
              vm.state.actorCache[0].sourceFacing == 2, "cache clear preserves source coordinate and facing bytes")
    try vm.cacheActor(person: 4, x: 7, y: 8, sourceFacing: 6)
    try vm.invalidateCachedActor(person: 4)
    try check(vm.state.actorCache[0].person == 65535 && vm.state.actorCache[0].x == 7, "remove invalidates cache identity without compacting slots")

    let repeated = record(0, repeatPair, kind: 3, words: [42, 0, 0],
        [instruction(20, 0, "flag", [5, 0]), end])
    let fallback = record(1, repeatPair, kind: 1, [end])
    let repeatingVM = try CampaignVM(program: program([repeated, fallback]))
    _ = try repeatingVM.dispatch(event: OriginalCampaignEvent(kind: 3, arguments: [42]))
    guard case .waiting = try repeatingVM.advance() else { throw EngineError.invalid("Repeated source group should wait after FF") }
    try check(repeatingVM.state.groupBase == 0 && repeatingVM.state.block == 0, "repeat marker holds source group")
    try check(try repeatingVM.state.flag(5), "event matching executes literal original effects")
    _ = try repeatingVM.dispatch(event: OriginalCampaignEvent(kind: 3, arguments: [99]))
    try check(repeatingVM.state.currentRecordID == fallback.id, "kind one is source fallback descriptor")

    let inverted = record(0, once, kind: 0x83, words: [1, 0, 0], [end])
    let inverseVM = try CampaignVM(program: program([inverted]))
    try check(try inverseVM.dispatch(event: OriginalCampaignEvent(kind: 3, arguments: [2])), "header high bit inverts event predicate")

    let condition = instruction(33, 0, "conditional-skip", [1], target: 20, positive: [8], negative: [9])
    let conditionalRecord = record(0, once, [condition, instruction(20, 10, "flag", [10, 0]), instruction(0, 20, "commands", commands: [Command("say", text: "target")]), end])
    let conditionalVM = try CampaignVM(program: program([conditionalRecord]))
    _ = try conditionalVM.start()
    try check(try !conditionalVM.state.flag(10), "false condition follows precomputed original skip target")

    let predicateGroup = OriginalCampaignGroup(base: 0, count: 1, repeating: true)
    let predicateRecord = record(0, predicateGroup, [condition, instruction(0, 20, "commands", commands: [Command("say", text: "predicate")]), end])
    var enabled = OriginalCampaignState(); try enabled.setFlag(8, true)
    let predicateVM = try CampaignVM(program: program([predicateRecord]), state: enabled)
    _ = try predicateVM.start()
    try check(predicateVM.state.instructionIndex == 2, "leading 21 is consumed by repeated default predicate")

    let selectionGroup = OriginalCampaignGroup(base: 0, count: 1, repeating: false)
    let branchGroup = OriginalCampaignGroup(base: 1, count: 2, repeating: false)
    let menu = record(0, selectionGroup, [instruction(37, 0, "choice-record", options: ["first", "second"]), end])
    let branchA = record(1, branchGroup, [instruction(0, 0, "commands", commands: [Command("say", text: "A")]), end])
    let branchB = record(2, branchGroup, [instruction(0, 0, "commands", commands: [Command("say", text: "B")]), end])
    let menuVM = try CampaignVM(program: program([menu, branchA, branchB]))
    guard case .choice = try menuVM.start() else { throw EngineError.invalid("VM menu did not yield") }
    try menuVM.choose(index: 1)
    guard case .commands(let branchCommands) = try menuVM.advance() else { throw EngineError.invalid("VM menu did not load its descriptor") }
    try check(branchCommands[0].text == "B" && menuVM.state.groupBase == 0, "25 selects descriptor relative to unchanged phase base")
    // Its selected descriptor belongs to another group; FF still advances the
    // source's original phase rather than that descriptor's group metadata.
    _ = try menuVM.advance()
    try check(menuVM.state.groupBase == 1, "menu branch FF advances source phase group")

    let mapRecord = record(0, once, [instruction(9, 0, "load-map", [0x2000]), end])
    let mapVM = try CampaignVM(program: program([mapRecord]))
    try mapVM.setCurrentCity(1)
    guard case .loadMap(let mapRequest) = try mapVM.start() else { throw EngineError.invalid("VM map selection did not yield") }
    try check(mapRequest.packedMap == 0x2000 && mapVM.state.pending?.kind == "map", "map selection suspends source cursor")
    let restoredState = try JSONDecoder().decode(OriginalCampaignState.self, from: JSONEncoder().encode(mapVM.snapshot()))
    let restored = try CampaignVM(program: program([mapRecord]), state: restoredState)
    guard case .loadMap = try restored.advance() else { throw EngineError.invalid("Pending map was lost on restore") }
    try restored.resumeMap(packedMap: 0x2000)
    try check(restored.state.pending == nil, "exact map completion resumes source cursor")

    let unknown = record(0, once, [instruction(3, 0, "unsupported", [1]), end])
    let unknownVM = try CampaignVM(program: program([unknown]))
    guard case .unsupported(let unsupported) = try unknownVM.start() else { throw EngineError.invalid("Unknown source effect was silently executed") }
    try check(unsupported.opcode == 3 && unknownVM.state.instructionIndex == 0, "unknown effect preserves precise source cursor")

    let rect = record(0, once, kind: 11, words: [4, 0x0201, 0x0503], [end])
    let rectVM = try CampaignVM(program: program([rect]))
    try check(try rectVM.dispatch(event: OriginalCampaignEvent(kind: 11, arguments: [4, 3, 5])), "source rectangle event includes boundary coordinates")
    let storyRecord = record(0, once, [instruction(7, 0, "story-layout", [3, 0]),
        instruction(8, 1, "commands", commands: [Command("say", text: "A")]),
        instruction(20, 2, "flag", [14, 0]),
        instruction(8, 3, "commands", commands: [Command("say", text: "B")]), end])
    let storyVM = try CampaignVM(program: program([storyRecord]), supportedHostOpcodes: [7])
    guard case .sourceAction = try storyVM.start() else { throw EngineError.invalid("Story layout did not yield to its host") }
    try storyVM.resumeHostAction(opcode: 7, sourceOffset: 0)
    _ = try storyVM.advance()
    try check(storyVM.state.storyPanelActive == true, "source08 retains an active source panel")
    guard case .commands(let close) = try storyVM.advance() else { throw EngineError.invalid("Hidden source effect did not close story panel") }
    try check(close.first?.op == "close-story" && storyVM.state.instructionIndex == 2,
              "panel close yields without consuming the hidden source instruction")
    try check(try !storyVM.state.flag(14), "panel close precedes its following source flag effect")
    guard case .commands(let afterHidden) = try storyVM.advance() else { throw EngineError.invalid("Source flag/story flow did not resume") }
    try check(afterHidden.first?.text == "B" && storyVM.state.storyPanelActive == false &&
              (try storyVM.state.flag(14)), "hidden flag then08 does not reopen the previous panel")
    let terminalStory = record(0, once, [instruction(7, 0, "story-layout", [3, 0]),
        instruction(8, 1, "commands", commands: [Command("say", text: "last")]), end])
    let terminalVM = try CampaignVM(program: program([terminalStory]), supportedHostOpcodes: [7])
    _ = try terminalVM.start(); try terminalVM.resumeHostAction(opcode: 7, sourceOffset: 0)
    _ = try terminalVM.advance()
    guard case .commands(let terminalClose) = try terminalVM.advance() else { throw EngineError.invalid("FF did not close the source story panel") }
    try check(terminalClose.first?.op == "close-story" && terminalVM.state.instructionIndex == 2 &&
              terminalVM.state.completedRecords == 0, "FF panel close preserves the source phase until the next advance")
    let destination = record(0, predicateGroup, kind: 4, words: [255, 2, 0], [end])
    var arrivalState = OriginalCampaignState()
    arrivalState.packedMap = 0x1000; arrivalState.city = 1; arrivalState.currentCity = 1
    let arrivalVM = try CampaignVM(program: program([destination]), state: arrivalState)
    let arrived = try arrivalVM.commitWorldArrival(city: 2, x: 3, y: 4)
    try check(arrived == OriginalCampaignEvent(kind: 4, arguments: [255, 2]), "world arrival produces the exact source event arguments")
    try check(arrivalVM.state.currentCity == 2 && arrivalVM.state.city == 1 &&
              arrivalVM.state.playerPosition == OriginalCampaignPlayerPosition(packedMap: 4096, x: 3, y: 4),
              "world arrival preserves separate global/player and script-map context ownership")
    try check(try arrivalVM.dispatch(event: arrived), "world arrival selects its matching source phase record")
    print("Original campaign VM self-tests passed: \(count)")
}
