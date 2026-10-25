// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct OriginalCampaignCheckpoint:Codable {
    var format = 1
    var vm:OriginalCampaignState
    var people:[OriginalPersonDefinition]
    var roster:OriginalRoster
    var rng:OriginalRNG
    var money:Int?
    var stage:Snapshot
    var liveUnits:[OriginalLiveUnit]?
    var turns:OriginalTurnState?
    var battleValue24:Int?
}

/// Owns native state effects for registered source operations. A VM instruction
/// is acknowledged only after its handler completed; unregistered effects stop
/// at the exact original record/offset. The record browser never advances this.
final class OriginalCampaignHost {
    let data:DataSet
    let source:OriginalGameData
    let vm:CampaignVM
    let stage:Runtime
    let exploration:OriginalExplorationCatalog
    let story:OriginalStoryCatalog
    let retirementCatalog:OriginalRetirementCatalog
    let people:OriginalPeople
    private(set) var roster = OriginalRoster()
    private(set) var rng:OriginalRNG
    // MAIN1276F..12779 clears DS6390..<E6D0, including7A80+0. The
    // new-game BAK actor loader does not deserialize player/save money.
    private(set) var money:Int? = 0
    private(set) var battle:OriginalBattleSession?
    private(set) var checkpoint:OriginalCampaignCheckpoint?
    private(set) var waiting:CampaignVMWaiting?
    private(set) var choice:CampaignVMChoice?
    private(set) var saveRequest:OriginalCampaignInstruction?
    private(set) var failure:CampaignVMFailure?
    private(set) var interpreterReturn:OriginalCampaignInterpreterReturn?
    private(set) var ending:OriginalEndingSession?
    private var endingMicroseconds:Int64 = 0
    private var carryover:OriginalPartyCarryover?
    private(set) var partySelection:OriginalPartySelection?
    private var partyInstruction:OriginalCampaignInstruction?
    private var pendingTurnHook:OriginalTurnHook?
    private var hookProbeIndex = 0
    private var hookAutomatic = false
    private var retirement:OriginalRetirementOperation?
    private var retirementBattle:OriginalBattleSession?
    private var retirementProbe:OriginalRetirementProbe?
    private var invocationReturn:OriginalCampaignInterpreterReturn?
    private var turnInvocationPending = false
    private var controllerInvocationPending = false
    private var controllerIdle = false
    private var controllerAfterInvocationFacings:[OriginalExplorationFacing] = []
    private(set) var retirementPresentation:OriginalRetirementPresentation?
    private(set) var retirementText:String?
    private var retirementPresentationStep:OriginalRetirementStep?
    var battleInputReady:Bool {
        waiting != nil && stage.hostWaiting && failure == nil && choice == nil && saveRequest == nil &&
        partySelection == nil && pendingTurnHook == nil && retirement == nil && interpreterReturn == nil &&
        !controllerInvocationPending && (battle?.turns.stage != .unstarted || controllerIdle)
    }
    private var pendingCache:[Command] = []
    private var currentEventPerson:Int?
    private var started = false
    private var explorationInput:OriginalExplorationInputPlan?
    private var pendingBattleMap:CampaignVMMapRequest?
    private var controllerMap:CampaignVMMapRequest?
    var explorationInputReady:Bool {
        waiting != nil && stage.hostWaiting && failure == nil && choice == nil && saveRequest == nil &&
        partySelection == nil && pendingTurnHook == nil && retirement == nil && interpreterReturn == nil && explorationInput == nil &&
        controllerIdle && !controllerInvocationPending && vm.state.currentRecordID == nil
    }
    var status:String {
        if let ending = ending {
            if case .unsupported(let frontier) = ending.output { return "엔딩 미복원 경계: \(frontier.resource) @\(frontier.offset) · \(frontier.reason)" }
            return "원작 엔딩 재생"
        }
        if let result = interpreterReturn { return "원작 외부 반환 \(result.status) · \(result.recordID) · 현재 캠페인 종료" }
        if let failure = failure { return "미복원: \(failure.recordID ?? "") @\(failure.sourceOffset ?? 0) · \(failure.reason)" }
        if choice != nil { return "원작 선택지 입력 대기" }
        if saveRequest != nil { return "자체 엔진 형식의 저장 여부를 선택하세요." }
        if let waiting = waiting { return "\(waiting.chapter):\(waiting.member):\(waiting.block):\(waiting.groupBase) · 원작 이벤트 대기 \(waiting.eventKinds)" }
        return "\(vm.state.chapter):\(vm.state.member):\(vm.state.block):\(vm.state.groupBase)"
    }
    init(data:DataSet,rng:OriginalRNG) throws {
        self.data = data;self.rng = rng;source = try OriginalGameData(root:data.root)
        people = try OriginalPeople(catalog:source.people,tables:source.combat)
        exploration = try OriginalExplorationCatalog.load(from:data.root.appendingPathComponent("exploration.json"))
        story = try OriginalStoryCatalog.load(from:data.root.appendingPathComponent("story.json"))
        retirementCatalog = try OriginalRetirementCatalog.load(from:data.root.appendingPathComponent("retirement.json"))
        let program = try OriginalCampaignProgram.load(from:data.root.appendingPathComponent("campaign.json"))
        vm = try CampaignVM(program:program,supportedHostOpcodes:[2,3,7,0x10,0x11,0x1B,0x1C,0x20,0x22,0x23,0x24,0x26,0x27,0x28,0x29,0x2A,0x2D,0x2F,0x33,0x34,0x35,0x37,0x39,0x3A,0x2B,0x36,0x38,0x3B,0x3C,0x3D])
        stage = Runtime(data,hostDriven:true)
    }
    func acknowledge() throws {
        guard failure == nil,choice == nil,saveRequest == nil else { return }
        stage.acknowledge()
        if !started {
            started = true;waiting = vm.waitingState();try controllerAutomaticTick();return
        }
        try pump()
    }
    func advance(microseconds:Int64) throws {
        if let ending = ending {
            guard microseconds >= 0,microseconds <= Int64.max-endingMicroseconds else { throw EngineError.invalid("Native ending clock is invalid") }
            endingMicroseconds += microseconds
            _ = try ending.advance(sourceTicks:Int(endingMicroseconds/10_000));endingMicroseconds %= 10_000
            return
        }
        guard started,failure == nil else { return }
        stage.advance(microseconds:microseconds);try pump()
        if explorationInput != nil,stage.hostWaiting { try completeExplorationInput() }
        if retirement != nil { _ = try continueRetirement() }
        if pendingTurnHook != nil { _ = try continueTurnHook() }
        try controllerAutomaticTick()
    }
    func choose(_ index:Int) throws {
        guard choice != nil else { throw EngineError.invalid("No original campaign choice is pending") }
        try vm.choose(index:index);choice = nil;try pump()
    }
    func completeSaveRequest() throws {
        guard let request = saveRequest else { throw EngineError.invalid("No original save request is pending") }
        try vm.resumeHostAction(opcode:request.opcode,sourceOffset:request.offset);saveRequest = nil;try pump()
    }
    func toggleParty(person:Int) throws {
        guard var selection = partySelection else { throw EngineError.invalid("No original party selection is pending") }
        try selection.toggle(person:person);partySelection = selection
    }
    func confirmParty() throws {
        guard let selection = partySelection,let instruction = partyInstruction else { throw EngineError.invalid("No original party confirmation is pending") }
        roster = try selection.confirm().roster
        try vm.resumeHostAction(opcode:instruction.opcode,sourceOffset:instruction.offset)
        partySelection = nil;partyInstruction = nil;try pump()
    }
    func talk(to person:Int) throws {
        try beginExplorationInput(OriginalExplorationInput.townActor(state:vm.state,stage:stage,person:person,enabled:explorationInputReady))
    }
    func travel(toCity city:Int) throws {
        try beginExplorationInput(OriginalExplorationInput.worldCity(catalog:exploration,state:vm.state,stage:stage,cityID:city,enabled:explorationInputReady))
    }
    func walk(to point:GridPoint) throws {
        try beginExplorationInput(OriginalExplorationInput.townCell(catalog:exploration,state:vm.state,stage:stage,point:point,enabled:explorationInputReady))
    }
    /// Marker identity is a diagnostic input only. Ambiguous destinations need
    /// an explicit source cell rather than an invented nearest-door policy.
    func townDestination(marker:Int) throws {
        guard let map = stage.currentMap,let w = map.walkWidth,let bytes = map.walkBytes else { throw EngineError.invalid("Original destination markers are unavailable") }
        let matches = bytes.indices.filter{bytes[$0] == marker}
        guard matches.count == 1,let index = matches.first else { throw EngineError.invalid("Original destination marker is absent or requires an explicit cell") }
        try walk(to:GridPoint(x:index%w,y:index/w))
    }
    private func beginExplorationInput(_ plan:OriginalExplorationInputPlan) throws {
        guard let last = plan.route.last else { throw EngineError.invalid("Original exploration input has an empty source route") }
        try stage.enqueueSourceRoute(person:plan.playerPerson,route:plan.route,finalFacing:last.facing)
        explorationInput = plan
        if stage.hostWaiting { try completeExplorationInput() }
    }
    private func completeExplorationInput() throws {
        guard let plan = explorationInput else { return }
        let arrival = try OriginalExplorationInput.arrive(plan,catalog:exploration,state:vm.state,stage:stage)
        for facing in arrival.facings { try stage.setNativeFacing(person:facing.person,direction:facing.nativeDirection) }
        var event = arrival.event
        if plan.kind == .worldCity { event = try vm.commitWorldArrival(city:arrival.currentCity) }
        explorationInput = nil
        if let event = event {
            controllerAfterInvocationFacings = arrival.afterInvocationFacings
            let matched = try dispatch(event,currentPerson:plan.targetPerson)
            if !matched { try restoreInputFacings() }
            if !matched,let boundary = arrival.unmatchedBuiltinBoundary {
                failure = CampaignVMFailure(recordID:vm.activeRecord?.id,opcode:nil,sourceOffset:nil,reason:boundary)
                throw EngineError.invalid(boundary)
            }
        }
    }
    private func restoreInputFacings() throws {
        for facing in controllerAfterInvocationFacings where stage.actors[facing.person] != nil {
            try stage.setNativeFacing(person:facing.person,direction:facing.nativeDirection)
        }
        controllerAfterInvocationFacings.removeAll()
    }
    /// MAIN248A1/20D7D call automatic0 once per outer controller tick. The
    /// interpreter itself must not consume the following automatic record.
    private func controllerAutomaticTick() throws {
        guard started,waiting != nil,stage.hostWaiting,choice == nil,saveRequest == nil,partySelection == nil,
              failure == nil,interpreterReturn == nil,explorationInput == nil,retirement == nil,
              pendingTurnHook == nil,!controllerInvocationPending,
              stage.palette != 3 || battle?.turns.stage == .unstarted else { return }
        let matched = try vm.queryInvocation(event:.automatic)
        if matched { controllerIdle = false;controllerInvocationPending = true;waiting = nil;try pump() }
        else { controllerIdle = true;waiting = vm.waitingState() }
    }
    @discardableResult
    func beginRetirement(_ notice:OriginalRetirementNotice) throws -> Bool {
        guard retirement == nil,battleInputReady,let battle = battle else {
            throw EngineError.invalid("Original retirement cannot replace a pending source operation")
        }
        retirement = try OriginalRetirementOperation(notice:notice);retirementBattle = battle
        return try continueRetirement()
    }
    func acknowledgeRetirement() throws {
        guard let operation = retirement,let step = retirementPresentationStep else {
            throw EngineError.invalid("No original retirement presentation is pending")
        }
        try operation.acknowledge(step);retirementPresentation = nil;retirementText = nil;retirementPresentationStep = nil
        _ = try continueRetirement()
    }
    private func continueRetirement() throws -> Bool {
        guard let operation = retirement,let battle = retirementBattle else { return true }
        guard retirementPresentation == nil,stage.hostWaiting,choice == nil,saveRequest == nil,
              partySelection == nil,failure == nil,interpreterReturn == nil else { return false }
        for _ in 0..<4096 {
            if let probe = retirementProbe {
                guard let returned = invocationReturn else { return false }
                try operation.resumeProbe(probe,response:.interpreterReturned(returned.status))
                retirementProbe = nil;invocationReturn = nil
            }
            guard let unit = battle.units[operation.notice.runtimeSlot] else { throw BattleError.invalid("Original retirement lost its owned live slot") }
            let context = OriginalRetirementContext(runtimeSlot:unit.slot,person:unit.person,battleResult:battle.turns.result,objectives:battle.header.objectives)
            let step = try operation.advance(context:context)
            switch step {
            case .probe(let probe):
                currentEventPerson = unit.person
                if try vm.queryInvocation(event:probe.event) {
                    retirementProbe = probe;waiting = nil;try pump()
                    guard stage.hostWaiting,choice == nil,saveRequest == nil,partySelection == nil,
                          failure == nil,interpreterReturn == nil else { return false }
                } else { try operation.resumeProbe(probe,response:.noMatch) }
            case .effect(let effect):
                switch effect {
                case .battleResult(let value):try battle.acceptSourceResult(value)
                case .music(let selection):try vm.setSourceMusic(selection:selection)
                case .unitStatus(let value):var changed = unit;changed.status = value;battle.units[unit.slot] = changed
                }
                try operation.acknowledge(step)
            case .presentation(let presentation):
                let name = try people.person(unit.person).name
                if let text = try retirementCatalog.text(for:presentation,personName:name),!text.isEmpty {
                    retirementPresentation = presentation;retirementText = text;retirementPresentationStep = step;return false
                }
                try operation.acknowledge(step)
            case .finished:
                retirement = nil;retirementBattle = nil;waiting = vm.waitingState();return true
            }
        }
        throw EngineError.invalid("Original retirement source invocation budget reached")
    }
    @discardableResult
    func beginTurnHook(_ hook:OriginalTurnHook) throws -> Bool {
        guard pendingTurnHook == nil,battleInputReady else { throw EngineError.invalid("Original battle source hook cannot replace a pending operation") }
        if hook.kind == .unitConditions {
            guard let slot = hook.runtimeSlot,let unit = battle?.units[slot],unit.status == 2,unit.scriptFlags&4 == 0 else { return true }
        }
        pendingTurnHook = hook;hookProbeIndex = 0;hookAutomatic = false
        return try continueTurnHook()
    }
    private func continueTurnHook() throws -> Bool {
        guard let hook = pendingTurnHook,let battle = battle else { return true }
        guard waiting != nil,stage.hostWaiting,choice == nil,saveRequest == nil,partySelection == nil,failure == nil,interpreterReturn == nil else { return false }
        let count = hook.kind == .unitConditions ? 6 : 1
        func returned(_ status:Int) {
            if hook.kind == .globalConditions {
                if battle.turns.result != 0 { hookProbeIndex = count }
                return
            }
            if hookAutomatic {
                if ![5,6].contains(status) { hookProbeIndex += 1;hookAutomatic = false }
            } else if ![5,6].contains(status) || battle.turns.result != 0 {
                if hook.kind == .unitConditions { hookAutomatic = true }
                else { hookProbeIndex += 1 }
            }
        }
        for _ in 0..<4096 {
            if turnInvocationPending {
                guard let value = invocationReturn else { return false }
                invocationReturn = nil;turnInvocationPending = false;returned(value.status)
            }
            if hookProbeIndex >= count || (!hookAutomatic && (battle.turns.result != 0 || stage.palette != 3)) {
                pendingTurnHook = nil;return true
            }
            let primary:OriginalCampaignEvent,fallback:OriginalCampaignEvent?
            if hookAutomatic { primary = .automatic;fallback = nil }
            else if hook.kind == .unitConditions {
                let index = hookProbeIndex
                guard let slot = hook.runtimeSlot,let probe = try battle.sourceUnitProbe(slot,kind:index == 0 ? 6 : index == 1 ? 11 : 4,
                    direction:index < 2 ? nil : index-2,sourcePerson:hook.sourcePerson) else { hookAutomatic = true;continue }
                primary = probe.primary;fallback = probe.friendlyFallback
            } else { primary = try hook.campaignEvent();fallback = hook.kind == .numberedRound ? .automatic : nil }
            if let person = hook.sourcePerson { currentEventPerson = person }
            var matched = try vm.queryInvocation(event:primary)
            if !matched,let fallback = fallback { matched = try vm.queryInvocation(event:fallback) }
            if matched {
                turnInvocationPending = true;waiting = nil;try pump()
                guard stage.hostWaiting,choice == nil,saveRequest == nil,partySelection == nil,
                      failure == nil,interpreterReturn == nil,invocationReturn != nil else { return false }
            } else if hook.kind == .globalConditions { hookProbeIndex = count }
            else { returned(1) }
        }
        throw EngineError.invalid("Original native hook source invocation budget reached")
    }
    @discardableResult
    func dispatch(_ event:OriginalCampaignEvent,currentPerson:Int? = nil) throws -> Bool {
        guard waiting != nil,stage.hostWaiting,choice == nil,saveRequest == nil,failure == nil else {
            throw EngineError.invalid("Original campaign cannot accept an event while a source operation is running")
        }
        if let currentPerson = currentPerson { currentEventPerson = currentPerson }
        guard !controllerInvocationPending,retirement == nil,pendingTurnHook == nil else { throw EngineError.invalid("Original input invocation has another source caller") }
        let matched = try vm.queryInvocation(event:event)
        if matched { controllerIdle = false;controllerInvocationPending = true;waiting = nil;try pump() }
        return matched
    }
    private func cacheCompletedCommands() throws {
        for c in pendingCache {
            if c.op == "remove",let person = c.person { try vm.invalidateCachedActor(person:person) }
            else if c.op == "place" || c.op == "move",let person = c.person,let x = c.x,let y = c.y,let facing = try c.genericPlacementDirection() {
                try vm.cacheActor(person:person,x:x,y:y,sourceFacing:facing,completedMovement:c.op == "move")
            }
        }
        pendingCache.removeAll()
    }
    private func failCommand(_ command:Command,error:Error) {
        let record = vm.activeRecord
        let instruction = command.source.flatMap { source in record?.instructions.first(where:{$0.commands.contains(where:{$0.source == source})}) }
        failure = CampaignVMFailure(recordID:record?.id,opcode:instruction?.opcode,sourceOffset:instruction?.offset,reason:"\(error)")
    }
    func pump() throws {
        guard started,stage.hostWaiting,choice == nil,saveRequest == nil,partySelection == nil,failure == nil,waiting == nil,interpreterReturn == nil else {
            if let termination = stage.termination,termination != .sourceBoundary {
                let record = vm.activeRecord
                let source = stage.trace.last?.source
                let instruction = source.flatMap { origin in record?.instructions.first(where:{$0.commands.contains(where:{$0.source == origin})}) }
                failure = CampaignVMFailure(recordID:record?.id,opcode:instruction?.opcode,sourceOffset:instruction?.offset,reason:stage.endReason ?? "Native stage failed")
            }
            return
        }
        try cacheCompletedCommands()
        // A work bound stops pathological script cycles without declaring EOF
        // or inventing a phase transition. Caller can explicitly continue.
        for _ in 0..<4096 {
            let result = try vm.advance()
            switch result {
            case .commands(let commands):
                pendingCache = commands
                if stage.palette == 3,let battle = battle {
                    for command in commands {
                        do {
                            if ["place","move","remove"].contains(command.op) { _ = try battle.applyScriptMapCommand(command,roster:roster) }
                            else { try stage.enqueue([command]) }
                        } catch {
                            failCommand(command,error:error)
                            return
                        }
                    }
                } else {
                    for command in commands where command.op == "place" {
                        do {
                            guard let person = command.person else { throw EngineError.invalid("Original placement has no person identity") }
                            _ = try OriginalExplorationInput.placementEffects(packedMap:vm.state.packedMap,person:person,rng:&rng)
                        } catch { failCommand(command,error:error);return }
                    }
                    try stage.enqueue(commands)
                }
                if !stage.hostWaiting { return };try cacheCompletedCommands()
            case .loadMap(let request):
                if stage.palette == 3,let battle = battle,battle.turns.result != 0 {
                    guard pendingBattleMap == nil else { throw EngineError.invalid("Original battle map exit already owns a deferred selection") }
                    pendingBattleMap = request
                } else if controllerInvocationPending {
                    guard controllerMap == nil else { throw EngineError.invalid("Original controller already owns a deferred map selection") }
                    controllerMap = request
                } else if !completeSelectedMap(request) { return }
                try vm.acknowledgeMapSelection(packedMap:request.packedMap)
            case .sourceAction(let instruction):
                if instruction.kind == "save-prompt" { saveRequest = instruction;return }
                if instruction.opcode == 0x23 {
                    partySelection = try OriginalParty.prepareSelection(people:people,roster:roster,profile:source.party,combat:source.combat)
                    partyInstruction = instruction;return
                }
                do { try apply(instruction) }
                catch {
                    failure = CampaignVMFailure(recordID:vm.activeRecord?.id,opcode:instruction.opcode,
                        sourceOffset:instruction.offset,reason:"\(error)")
                    return
                }
                try vm.resumeHostAction(opcode:instruction.opcode,sourceOffset:instruction.offset)
                if instruction.kind == "checkpoint-capture" { checkpoint = snapshot() }
            case .choice(let value):choice = value;return
            case .waiting(let value):waiting = value;return
            case .unsupported(let value):failure = value;return
            case .interpreterReturn(let value):interpreterReturn = value;return
            case .invocationReturn:
                guard retirementProbe != nil || turnInvocationPending || controllerInvocationPending else { throw EngineError.invalid("Original bounded interpreter return has no owning source caller") }
                let returned = try vm.takeInvocationReturn();waiting = vm.waitingState()
                if controllerInvocationPending {
                    controllerInvocationPending = false;controllerIdle = false;try restoreInputFacings()
                    if let request = controllerMap {
                        guard completeSelectedMap(request) else { return }
                        controllerMap = nil
                    }
                } else { invocationReturn = returned }
                return
            case .budgetReached:
                failure = CampaignVMFailure(recordID:vm.activeRecord?.id,opcode:nil,sourceOffset:nil,reason:"Original VM instruction work budget reached")
                return
            }
        }
        failure = CampaignVMFailure(recordID:vm.activeRecord?.id,opcode:nil,sourceOffset:nil,reason:"Original host work budget reached")
    }
    /// Source09 selects context and returns2; an active battle keeps its old
    /// map until its caller/attack context returns and the outer loop exits.
    func finishBattleLoop() throws {
        guard let request = pendingBattleMap else { return }
        guard let battle = battle,battle.turns.result != 0,stage.hostWaiting,retirement == nil,
              pendingTurnHook == nil,!controllerInvocationPending,choice == nil,saveRequest == nil,
              partySelection == nil,failure == nil,interpreterReturn == nil else {
            throw EngineError.invalid("Original battle exit still has an owning source operation")
        }
        rng = battle.rng
        if battle.turns.result == 2 { carryover = try battle.finishBattleForCarryover() }
        guard completeSelectedMap(request) else { return }
        pendingBattleMap = nil;controllerIdle = false;waiting = vm.waitingState()
    }
    private func completeSelectedMap(_ request:CampaignVMMapRequest) -> Bool {
        do { try loadSelectedMap(request);return true }
        catch {
            failure = CampaignVMFailure(recordID:request.recordID,opcode:9,sourceOffset:request.sourceOffset,reason:"\(error)")
            return false
        }
    }
    private func loadSelectedMap(_ request:CampaignVMMapRequest) throws {
        try constructCitiesIfNeeded()
        try vm.selectScriptMap(packedMap:request.packedMap)
        try vm.enterMapContext(packedMap:request.packedMap)
        try stage.setPalette(request.packedMap>>12)
        if request.packedMap>>12 == 3 {
            guard let id = request.battleID,let definition = source.battles.battles.first(where:{$0.id == id}) else {
                throw EngineError.invalid("Reached source battle map has no source load-site identity")
            }
            battle = try OriginalBattleSession(definition:definition,roster:&roster,people:people,
                combat:source.combat,movement:source.movement,rng:rng,carryover:carryover)
        } else {
            if request.packedMap>>12 < 2 {
                try exploration.configure(stage:stage,packed:request.packedMap,chapter:vm.state.chapter,people:people)
            } else if request.packedMap>>12 == 2,let map = data.resources.maps[String(request.packedMap)] {
                try stage.configureMap(request.packedMap,resource:map,actors:nil)
            } else { throw EngineError.invalid("Reached original map is unavailable") }
            try stage.enqueue([Command("map",map:request.packedMap)])
            if [0,2].contains(request.packedMap>>12) {
                let facts = try vm.replaySettlementCache()
                let replay = try OriginalExplorationInput.settlementCacheReplay(replay:facts,packedMap:request.packedMap,rng:rng)
                try stage.enqueue(replay.commands);rng = replay.rngAfter
                if let music = facts.music { try vm.setSourceMusic(selection:music) }
            }
        }
    }
    private func apply(_ instruction:OriginalCampaignInstruction) throws {
        let args = instruction.arguments
        let scriptActions:Set<Int> = [2,0x10,0x26,0x27,0x28,0x2D,0x33,0x34,0x35]
        let expected:[Int:Int] = [3:0,7:2,0x11:2,0x1B:1,0x22:0,0x24:2,0x29:1,0x2A:1,0x2F:2,0x37:2,0x39:2,0x3A:2,0x2B:2,0x36:0,0x38:1,0x3B:2,0x3C:1]
        guard scriptActions.contains(instruction.opcode) || instruction.opcode == 0x1C || instruction.opcode == 0x20 || expected[instruction.opcode] == args.count else { throw EngineError.invalid("Original host operands do not match their registered contract") }
        if scriptActions.contains(instruction.opcode) {
            guard let battle = battle else { throw BattleError.unsupported("Original battle action has no native battle context") }
            _ = try battle.applyScriptAction(opcode:instruction.opcode,arguments:args,mapIndex:vm.state.packedMap&255)
            return
        }
        switch instruction.opcode {
        case 0x20:
            guard let clear = args.first else { throw EngineError.invalid("Original city availability has no clear-first operand") }
            try constructCitiesIfNeeded()
            try vm.applyCityAvailability(clearFirst:clear != 0,cities:Array(args.dropFirst()))
        case 3,0x22:
            try roster.apply(source.rosters.program(chapter:vm.state.chapter,member:vm.state.member,offset:instruction.offset),flags:vm.state)
        case 7:
            try stage.beginStory(image:story.picture(args[0],mode:args[1],palette:stage.palette),mode:args[1],source:instruction.source)
        case 0x38: break // VM owns the source music selection; audio output remains unimplemented.
        case 0x36: break // Full native snapshot is captured after host acknowledgement below.
        case 0x2A:
            let catalog = try OriginalEndingCatalog.load(from:data.root.appendingPathComponent("ending.json"))
            ending = try OriginalEndingSession(catalog:catalog,selection:args[0])
        case 0x11,0x29:
            let mode = instruction.opcode == 0x11 ? args[1] : args[0]
            guard [0,1,3].contains(mode) else { throw EngineError.invalid("Original map return mode is invalid") }
            // MAIN336FA only changes battle state under the battle palette.
            if stage.palette == 3,let battle = battle {
                try battle.acceptSourceResult(mode == 0 ? 2 : 3)
                if mode == 3 { try vm.setSourceMusic(selection:4) }
            }
        case 0x3B:try stage.worldCamera(x:args[0],y:args[1],source:instruction.source)
        case 0x3C:try stage.worldFollow(person:args[0],source:instruction.source)
        case 0x1C:
            guard let battle = battle else { throw BattleError.unsupported("Original AI-order effect requires its battle context") }
            _ = try battle.applyScriptAttribute(arguments:args)
        case 0x1B:
            let recipient:Int
            if vm.state.packedMap>>12 == 3 {
                guard let person = currentEventPerson else { throw BattleError.unsupported("Original battle item recipient has no source event-person identity") }
                recipient = person
            } else { recipient = 0 }
            _ = try people.grantScriptItem(person:recipient,itemID:args[0])
        case 0x24:try people.setAffiliation(person:args[0],value:args[1])
        case 0x2F:
            try people.update(args[0]) { $0.sourceRole = args[1] }
            if stage.currentMap?.geometry == "world" {
                try exploration.configure(stage:stage,packed:vm.state.packedMap,chapter:vm.state.chapter,people:people)
            }
        case 0x37:try people.update(args[0]) { $0.sourceFlags = args[1] == 0 ? ($0.sourceFlags & ~0x40) : ($0.sourceFlags|0x40) }
        case 0x39:try people.update(args[0]) { $0.level = min(99,$0.level+args[1]) }
        case 0x3A:try people.update(args[0]) { $0.classID = args[1] }
        case 0x2B:
            if args[0] == 2 {
                guard let current = money else { throw EngineError.invalid("Original initial player money has not been established") }
                money = min(10000,Int(UInt16(truncatingIfNeeded:current+args[1])))
            }
            else if args[0] == 4,let battle = battle { battle.scriptValue24 = UInt8(truncatingIfNeeded:args[1]) }
            else { throw EngineError.invalid("Reached campaign value selector has no restored host effect") }
        default:throw EngineError.invalid("Unregistered original host effect")
        }
    }
    private func constructCitiesIfNeeded() throws {
        guard vm.state.cityFlagsChapter != vm.state.chapter else { return }
        guard let mapping = exploration.chapterMappings.first(where:{$0.chapter == vm.state.chapter}) else { throw EngineError.invalid("Original city constructor has no chapter mapping") }
        try vm.setCityFlags(chapter:vm.state.chapter,flags:Array(repeating:3,count:mapping.cityCount))
    }
    func snapshot() -> OriginalCampaignCheckpoint {
        OriginalCampaignCheckpoint(vm:vm.snapshot(),people:people.values.values.sorted{$0.id < $1.id},roster:roster,
            rng:battle?.rng ?? rng,money:money,stage:stage.snapshot(),
            liveUnits:battle?.units.values.sorted{$0.slot < $1.slot},turns:battle?.turns,battleValue24:battle.map{Int($0.scriptValue24)})
    }
}
