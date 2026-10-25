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
    try restored.enterMapContext(packedMap: 0x2000)
    try restored.acknowledgeMapSelection(packedMap: 0x2000)
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
    arrivalState.packedMap = 0x1000; arrivalState.city = 1; arrivalState.currentCity = 1; arrivalState.gameCity = 1
    arrivalState.returnContext = OriginalCampaignReturnContext(packedMap: 4096, x: 9, y: 10)
    let arrivalVM = try CampaignVM(program: program([destination]), state: arrivalState)
    let arrived = try arrivalVM.commitWorldArrival(city: 2)
    try check(arrived == OriginalCampaignEvent(kind: 4, arguments: [255, 2]), "world arrival produces the exact source event arguments")
    try check(arrivalVM.state.currentCity == 2 && arrivalVM.state.gameCity == 2 && arrivalVM.state.city == 1 &&
              arrivalVM.state.returnContext == OriginalCampaignReturnContext(packedMap: 4096, x: 9, y: 10),
              "world arrival changes city while preserving saved7A76 and script-map context ownership")
    try check(try arrivalVM.dispatch(event: arrived), "world arrival selects its matching source phase record")
    var exit = instruction(0x29, 0, "battle-exit", [3]); exit.interpreterStatus = 7
    let exitRecord = record(0, once, [exit, instruction(20, 1, "flag", [9, 0]), end])
    let exitProgram = program([exitRecord])
    let exitVM = try CampaignVM(program: exitProgram, supportedHostOpcodes: [0x29])
    guard case .sourceAction = try exitVM.start() else { throw EngineError.invalid("Source exit was not sent to host") }
    try exitVM.resumeHostAction(opcode: 0x29, sourceOffset: 0)
    guard case .interpreterReturn(let returned) = try exitVM.advance() else {
        throw EngineError.invalid("Source interpreter return was swallowed")
    }
    try check(returned.status == 7 && returned.opcode == 0x29 && exitVM.state.instructionIndex == 1,
              "source29 returns before consuming the next instruction")
    try check(try !exitVM.state.flag(9) && exitVM.state.completedRecords == 0,
              "interpreter return does not imply phase or flag effects")
    let exitRestored = try CampaignVM(program: exitProgram, state: exitVM.snapshot(), supportedHostOpcodes: [0x29])
    guard case .interpreterReturn(let restoredReturn) = try exitRestored.advance() else {
        throw EngineError.invalid("Restored source return resumed an abandoned record")
    }
    try check(restoredReturn == returned, "source return is stable across checkpoint restore")
    let boundedFirst = record(0, once, kind: 7, [instruction(0x13, 0, "next-phase"), end])
    let boundedNext = record(0, once, block: 1, [instruction(20, 0, "flag", [25, 0]), end])
    let boundedVM = try CampaignVM(program: program([boundedFirst, boundedNext]))
    try check(try boundedVM.queryInvocation(event: .init(kind: 7, arguments: [])), "bounded source query selects objective record")
    guard case .invocationReturn(let nextPhaseReturn) = try boundedVM.advance() else {
        throw EngineError.invalid("Bounded phase transition did not return")
    }
    try check(nextPhaseReturn.status == 5 && !boundedVM.state.flag(25), "source13 returns before the next automatic lookup")
    _ = try boundedVM.takeInvocationReturn()
    try check(try !boundedVM.queryInvocation(event: .init(kind: 12, arguments: [4])), "next event query does not auto-run an unrelated phase")
    try check(try boundedVM.queryInvocation(event: .automatic), "calling dispatcher explicitly queries automatic phase")
    guard case .invocationReturn(let boundedEnd) = try boundedVM.advance() else { throw EngineError.invalid("Bounded FF did not return") }
    try check(boundedEnd.status == 1 && boundedVM.state.flag(25), "bounded FF preserves raw normal return")
    let motionRecord = record(0, once, kind: 7, [instruction(1, 0, "commands", commands: [Command("move", person: 4, x: 2, y: 3)]),
        instruction(20, 1, "flag", [26, 0]), end])
    let motionVM = try CampaignVM(program: program([motionRecord]))
    _ = try motionVM.queryInvocation(event: .init(kind: 7, arguments: []))
    guard case .commands = try motionVM.advance() else { throw EngineError.invalid("Source motion was not queued") }
    guard case .invocationReturn(let movedReturn) = try motionVM.advance() else { throw EngineError.invalid("Source motion did not return") }
    try check(movedReturn.status == 5 && !motionVM.state.flag(26), "movement boundary retains unexecuted following instruction")
    _ = try motionVM.takeInvocationReturn()
    try check(try motionVM.queryInvocation(event: .init(kind: 12, arguments: [99])), "busy source wrapper resumes without a new predicate")
    _ = try motionVM.advance()
    try check(try motionVM.state.flag(26), "motion continuation executes its original cursor")
    try vm.setCityFlags(chapter: 0, flags: [3,2,0,129])
    try vm.applyCityAvailability(clearFirst: true, cities: [1,3])
    try check(vm.state.cityFlags == [3,2,1,128], "city operation preserves other bits and does not mutate inventory")
    var cacheState = OriginalCampaignState()
    cacheState.currentCity = 2; cacheState.gameCity = 2; cacheState.city = 2; cacheState.packedMap = 0x2000
    cacheState.actorCacheCity = 2; cacheState.actorCacheMap = 0x2000; cacheState.actorCacheDirty = true
    cacheState.music = 7; cacheState.currentMusic = 7
    cacheState.actorCache[0] = .init(person: 0, x: 3, y: 4, flags: 0, sourceFacing: 0)
    cacheState.actorCache[1] = .init(person: 4, x: 5, y: 6, flags: 0, sourceFacing: 2)
    let cacheVM = try CampaignVM(program: program([first]), state: cacheState)
    try cacheVM.setSourceMusic(selection: 4)
    let replay = try cacheVM.replaySettlementCache()
    try check(replay.restored && replay.actors.map(\.person) == [4] && replay.music == 7,
              "settlement reentry restores only nonplayer identities and cached script music")
    try check(cacheVM.state.currentMusic == 4 && !cacheVM.state.actorCacheDirty,
              "device music stinger does not replace saved script music; replay clears dirty first")
    try check(try !cacheVM.replaySettlementCache().restored, "clean settlement cache does not replay twice")
    cacheState.actorCacheMap = 0x2001
    let mismatched = try CampaignVM(program: program([first]), state: cacheState)
    let noReplay = try mismatched.replaySettlementCache()
    try check(!noReplay.restored && mismatched.state.actorCacheDirty && mismatched.state.actorCache[1].person == 4,
              "mismatched map marks cache dirty without clearing or changing its owner")
    let deferredRecord = record(0, once, [instruction(9, 0, "load-map", [0x1004]), end])
    let deferred = try CampaignVM(program: program([deferredRecord]), state: cacheState)
    _ = try deferred.queryInvocation(event: .automatic)
    guard case .loadMap = try deferred.advance() else { throw EngineError.invalid("Deferred map selection was not produced") }
    try deferred.acknowledgeMapSelection(packedMap: 0x1004)
    try check(deferred.state.city == 2 && deferred.state.currentCity == 2,
              "source09 acknowledgement does not perform the deferred game selector or map context entry")
    let selectedReturn = try deferred.takeInvocationReturn()
    try check(selectedReturn.status == 2 && deferred.state.currentRecordID == deferredRecord.id,
              "source09 returns two with its continuation intact")
    try deferred.selectScriptMap(packedMap: 0x1004);try deferred.enterMapContext(packedMap: 0x1004)
    try check(deferred.state.city == 4 && deferred.state.gameCity == 4 && deferred.state.currentCity == 2,
              "outer selector changes Game+4 before context entry without changing player current city")
    try deferred.selectScriptMap(packedMap: 0x2001)
    try check(deferred.state.gameCity == 4 && deferred.state.currentCity == 2,
              "palace selector preserves both city fields")
    let savedContext = record(0, once, [instruction(0x1D, 0, "return-context", [0x1004,7,9]),
        instruction(5, 1, "commands", commands: [Command("show")]), end])
    let contextVM = try CampaignVM(program: program([savedContext]))
    _ = try contextVM.start()
    try check(contextVM.state.returnContext == OriginalCampaignReturnContext(packedMap: 0x1004, x: 7, y: 9) &&
              contextVM.state.packedMap == 0 && contextVM.state.currentCity == nil,
              "source1D writes return context without changing active map/current city")
    print("Original campaign VM self-tests passed: \(count)")
}
