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

/// Host continuation owners when source36 captured a battle checkpoint.
struct OriginalRetryHostState:Codable,Equatable {
    var battleID:String
    var controllerInvocationPending:Bool
    var controllerIdle:Bool
    var currentEventPerson:Int?
}

/// Native engine resume point taken at a source3D save prompt. This is not
/// an original MSAVE slot: MAIN's own save/load (CF5:B58C, title item one)
/// is not replicated. It retains host-owned continuation state so the same
/// source cursor continues after the prompt.
struct OriginalCampaignResume:Codable {
    static let maximumBytes = 32 * 1024 * 1024
    var format = 1
    var kind = "native-engine-resume"
    var checkpoint:OriginalCampaignCheckpoint
    /// Source3D offset, or nil for an idle field-menu save (CF5:F0CE).
    var saveOffset:Int?
    var controllerInvocationPending:Bool
    var controllerIdle:Bool
    var controllerAfterInvocationFacings:[OriginalExplorationFacing]
    var currentEventPerson:Int?
    var carryover:OriginalPartyCarryover?
    var retryCheckpoint:OriginalCampaignCheckpoint?
    var retryHost:OriginalRetryHostState?
    var uncertainReturnContext:OriginalCampaignReturnContext?
    var limitations:[String]

    static func read(from url:URL) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
        guard let size = attributes[.size] as? NSNumber,(1...maximumBytes).contains(size.intValue) else {
            throw EngineError.invalid("Native resume file exceeds its input bound")
        }
        let value = try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
        guard value.format == 1,value.kind == "native-engine-resume" else {
            throw EngineError.invalid("Native resume file has an unsupported format")
        }
        return value
    }
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
    private var retryHost:OriginalRetryHostState?
    private(set) var waiting:CampaignVMWaiting?
    private(set) var choice:CampaignVMChoice?
    private(set) var saveRequest:OriginalCampaignInstruction?
    private(set) var failure:CampaignVMFailure?
    private(set) var interpreterReturn:OriginalCampaignInterpreterReturn?
    private(set) var frameworkReturn:OriginalFrameworkReturn?
    /// Native notice for a source effect that is reached but not drawn.
    private(set) var notice:String?
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
        frameworkReturn == nil && !controllerInvocationPending && (battle?.turns.stage != .unstarted || controllerIdle)
    }
    private var pendingCache:[Command] = []
    private var currentEventPerson:Int?
    private var started = false
    private var explorationInput:OriginalExplorationInputPlan?
    private var pendingBattleMap:CampaignVMMapRequest?
    /// Source11 writes script context+0A without an interpreter return. Its
    /// selection is entered only when the enclosing battle loop finishes.
    private var battleReturnSelection:CampaignVMMapRequest?
    /// 1CB6:1924 copies the player actor slot position. When no player actor
    /// is displayed, that stale slot value is not modeled; this records the
    /// context written with an unknown position so a later 7D exit stops.
    private var uncertainReturnContext:OriginalCampaignReturnContext?
    private var controllerMap:CampaignVMMapRequest?
    var explorationInputReady:Bool {
        waiting != nil && stage.hostWaiting && failure == nil && choice == nil && saveRequest == nil &&
        partySelection == nil && pendingTurnHook == nil && retirement == nil && interpreterReturn == nil && frameworkReturn == nil && explorationInput == nil &&
        controllerIdle && !controllerInvocationPending && vm.state.currentRecordID == nil
    }
    var status:String {
        if let ending = ending {
            if case .unsupported(let frontier) = ending.output { return "엔딩 미복원 경계: \(frontier.resource) @\(frontier.offset) · \(frontier.reason)" }
            return "원작 엔딩 재생"
        }
        if let value = frameworkReturn {
            switch value.outcome {
            case .restart: return "원작 재시작 선택 · MAIN 다시 실행"
            case .quit: return "원작 종료 선택 · 종료 그림(MAIN1E3A8) 미복원 · 입력하면 창을 닫습니다"
            case .pending:
                return value.asksRetry ? "원작 재시작 선택 대기 · 반환 마스크 \(String(format:"%02X",value.mask)) · \(value.producer)"
                    : "원작 외부 반환 마스크 \(String(format:"%02X",value.mask)) · \(value.producer)"
            }
        }
        if let result = interpreterReturn { return "원작 외부 반환 \(result.status) · \(result.recordID) · 현재 캠페인 종료" }
        if let failure = failure { return "미복원: \(failure.recordID ?? "") @\(failure.sourceOffset ?? 0) · \(failure.reason)" }
        if choice != nil { return "원작 선택지 입력 대기" }
        if saveRequest != nil { return "자체 엔진 형식의 저장 여부를 선택하세요." }
        if let waiting = waiting { return "\(waiting.chapter):\(waiting.member):\(waiting.block):\(waiting.groupBase) · 원작 이벤트 대기 \(waiting.eventKinds)" }
        return "\(vm.state.chapter):\(vm.state.member):\(vm.state.block):\(vm.state.groupBase)"
    }
    convenience init(data:DataSet,rng:OriginalRNG) throws { try self.init(data:data,rng:rng,vmState:nil) }
    private init(data:DataSet,rng:OriginalRNG,vmState:OriginalCampaignState?) throws {
        self.data = data;self.rng = rng;source = try OriginalGameData(root:data.root)
        people = try OriginalPeople(catalog:source.people,tables:source.combat)
        exploration = try OriginalExplorationCatalog.load(from:data.root.appendingPathComponent("exploration.json"))
        story = try OriginalStoryCatalog.load(from:data.root.appendingPathComponent("story.json"))
        retirementCatalog = try OriginalRetirementCatalog.load(from:data.root.appendingPathComponent("retirement.json"))
        let program = try OriginalCampaignProgram.load(from:data.root.appendingPathComponent("campaign.json"))
        vm = try CampaignVM(program:program,state:vmState ?? OriginalCampaignState(),supportedHostOpcodes:[2,3,7,0x10,0x11,0x1B,0x1C,0x20,0x22,0x23,0x24,0x26,0x27,0x28,0x29,0x2A,0x2D,0x2F,0x33,0x34,0x35,0x37,0x39,0x3A,0x2B,0x36,0x38,0x3B,0x3C,0x3D])
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
        notice = nil
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
            // MAIN26A8D..26A9C: an unmatched talk makes the person say the
            // DS:397A line. Its bytes are not cp949 text and use the original
            // font's own codes, so the engine states the omission instead.
            if !matched,plan.kind == .townActor {
                notice = "원작 기본 대사(MAIN DS:397A)는 원작 글꼴 코드라 아직 표시하지 않습니다."
            }
            if let builtin = arrival.builtin {
                // MAIN252B8..2535A: room and world fallbacks require query
                // FFFF (or the unreached 4); marker7D also accepts zero.
                if !matched { try enterSettlementBuiltin(builtin) }
                else if builtin == .returnToContext {
                    let reason = "Original matched palace-exit script followed by its built-in 7A76 return is not restored"
                    failure = CampaignVMFailure(recordID:vm.activeRecord?.id,opcode:nil,sourceOffset:nil,reason:reason)
                    throw EngineError.invalid(reason)
                }
            }
        }
    }
    /// MAIN252C5..253B4 rewrites the game object, then the framework loop
    /// enters that map with native entry byte7=1 (MAIN1E1FE..1E242).
    private func enterSettlementBuiltin(_ builtin:OriginalSettlementBuiltin) throws {
        do {
            guard let current = stage.mapID,[0,2].contains(current>>12),let player = stage.actors[0] else {
                throw EngineError.invalid("Original settlement fallback has no native settlement map or player actor")
            }
            switch builtin {
            case .roomEntry(let marker):
                // 1CB6:1924 saves game map and the player's position; game
                // position becomes (8,15). Arrival cleared game+9 (MAIN25230).
                try vm.setReturnContext(packedMap:current,x:player.position.x,y:player.position.y)
                uncertainReturnContext = nil
                try enterNativeMap(packedMap:0x2000|marker,spawn:OriginalSettlementBuiltin.roomEntryPoint,sourceFacing:0)
            case .returnToContext:
                // Kind/index/position come from 7A76; game+9=1 selects raw facing4.
                guard let back = vm.state.returnContext,back != uncertainReturnContext else {
                    throw EngineError.invalid("Original palace exit has no established 7A76 return position")
                }
                try enterNativeMap(packedMap:back.packedMap,spawn:GridPoint(x:back.x,y:back.y),sourceFacing:4)
            case .worldExit:
                // Game index is player+12. Source12 stores the new chapter
                // there (MAIN1C7D8..1C7DA, 1EBA2..1EBA7); CF5:777A maps it
                // through DS:0EBC to the city group (MAIN1B0CA..1B0DC).
                try enterNativeMap(packedMap:0x1000|(vm.state.chapter & 0xFF),spawn:nil,sourceFacing:0)
            }
        } catch {
            failure = CampaignVMFailure(recordID:vm.activeRecord?.id,opcode:nil,sourceOffset:nil,reason:"\(error)")
            throw error
        }
    }
    /// Native game-object entry (byte7=1). World entry places the default
    /// player at the current city (MAIN20B46); settlement entry places player
    /// 0200 at the game position (MAIN2464A..24691), then replays the cache
    /// (MAIN24C6A). Native entry music (MAIN24BD6..24C1A) is not modeled.
    private func enterNativeMap(packedMap:Int,spawn:GridPoint?,sourceFacing:Int) throws {
        let kind = packedMap>>12
        guard [0,1,2].contains(kind),(0...0xFFFF).contains(packedMap) else {
            throw EngineError.invalid("Original native entry selected a non-exploration map")
        }
        if packedMap == 0x2007 {
            throw EngineError.invalid("Original palace7 native entry places special actor 0376 (MAIN24BD6..24BEF), which is not restored")
        }
        try constructCitiesIfNeeded()
        try vm.enterMapContext(packedMap:packedMap)
        try stage.setPalette(kind)
        if kind < 2 {
            try exploration.configure(stage:stage,packed:packedMap,chapter:vm.state.chapter,people:people)
        } else if let map = data.resources.maps[String(packedMap)] {
            try stage.configureMap(packedMap,resource:map,actors:nil)
        } else { throw EngineError.invalid("Original room/palace map \(packedMap) is unavailable") }
        try stage.enqueue([Command("map",map:packedMap)])
        if kind == 1 {
            let boot = try OriginalExplorationInput.worldBootstrap(catalog:exploration,state:vm.state,entry:.nativeCityDefault,rng:rng)
            try stage.enqueue(boot.commands);rng = boot.rngAfter
        } else {
            guard let spawn = spawn else { throw EngineError.invalid("Original settlement native entry has no game position") }
            var after = rng
            _ = try OriginalExplorationInput.placementEffects(packedMap:packedMap,person:0,rng:&after)
            try stage.enqueue([Command("place",person:0,x:spawn.x,y:spawn.y,sourcePlacementFacing:sourceFacing)]);rng = after
            let facts = try vm.replaySettlementCache()
            let replay = try OriginalExplorationInput.settlementCacheReplay(replay:facts,packedMap:packedMap,rng:rng)
            try stage.enqueue(replay.commands);rng = replay.rngAfter
            if let music = facts.music { try vm.setSourceMusic(selection:music) }
        }
        // Native entry has no script05. The framework loop presents the new
        // map itself (MAIN1E2A1..1E2B9); its fade timing is not restored.
        try stage.enqueue([Command("show")])
        controllerIdle = false;waiting = vm.waitingState()
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
        guard started,stage.hostWaiting,choice == nil,saveRequest == nil,partySelection == nil,failure == nil,waiting == nil,
              interpreterReturn == nil,frameworkReturn == nil else {
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
                if instruction.kind == "checkpoint-capture" {
                    checkpoint = snapshot()
                    retryHost = stage.palette == 3 ? battle.map { OriginalRetryHostState(battleID:$0.definition.id,
                        controllerInvocationPending:controllerInvocationPending,controllerIdle:controllerIdle,
                        currentEventPerson:currentEventPerson) } : nil
                }
            case .choice(let value):choice = value;return
            case .waiting(let value):waiting = value;return
            case .unsupported(let value):failure = value;return
            case .interpreterReturn(let value):
                interpreterReturn = value
                // Status8 also selected the ending session in apply(2A). A
                // source29 inside battle wrote raw result3 as well, which the
                // battle dispatcher maps to the same mask20.
                if value.status == 7,let mask = OriginalFrameworkReturn.mask(interpreterStatus:value.status) {
                    frameworkReturn = OriginalFrameworkReturn(mask:mask,producer:"interpreter-status-7",
                        recordID:value.recordID,sourceOffset:value.sourceOffset)
                }
                return
            case .invocationReturn:
                guard retirementProbe != nil || turnInvocationPending || controllerInvocationPending else { throw EngineError.invalid("Original bounded interpreter return has no owning source caller") }
                let returned = try vm.takeInvocationReturn();waiting = vm.waitingState()
                if controllerInvocationPending {
                    controllerInvocationPending = false;controllerIdle = false;try restoreInputFacings()
                    if let request = controllerMap {
                        // MAIN264B2..264B7: a settlement invocation returning
                        // status2 saves game map and player position (1924)
                        // before C86C. The world wrapper does not (2226D).
                        if returned.status == 2,let current = stage.mapID,[0,2].contains(current>>12) {
                            if let player = stage.actors[0] {
                                try vm.setReturnContext(packedMap:current,x:player.position.x,y:player.position.y)
                                uncertainReturnContext = nil
                            } else {
                                let old = vm.state.returnContext
                                try vm.setReturnContext(packedMap:current,x:old?.x ?? 0,y:old?.y ?? 0)
                                uncertainReturnContext = vm.state.returnContext
                            }
                        }
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
    /// Source09/11 select script context+0A; an active battle keeps its old map
    /// until its caller/attack context returns and the outer loop exits.
    /// `OriginalBattleExit` owns the dispatcher's raw-result interpretation.
    func finishBattleLoop() throws {
        guard let battle = battle,battle.turns.result != 0,stage.palette == 3,frameworkReturn == nil,failure == nil else { return }
        guard stage.hostWaiting,retirement == nil,
              pendingTurnHook == nil,!controllerInvocationPending,choice == nil,saveRequest == nil,
              partySelection == nil,interpreterReturn == nil else {
            throw EngineError.invalid("Original battle exit still has an owning source operation")
        }
        rng = battle.rng
        let selections = [pendingBattleMap,battleReturnSelection].compactMap{$0}
        switch OriginalBattleExit.decide(result:battle.turns.result,contextMap:vm.state.packedMap,selectionMaps:selections.map(\.packedMap)) {
        case .restoreCheckpoint:
            do { try restartBattleFromCheckpoint(battle) }
            catch { failure = CampaignVMFailure(recordID:nil,opcode:nil,sourceOffset:nil,reason:"\(error)") }
        case .framework(let mask):
            frameworkReturn = OriginalFrameworkReturn(mask:mask,producer:"battle-result-\(battle.turns.result)",recordID:nil,sourceOffset:nil)
            pendingBattleMap = nil;battleReturnSelection = nil;waiting = nil
        case .unsupported(let reason):
            failure = CampaignVMFailure(recordID:nil,opcode:nil,sourceOffset:nil,reason:reason)
        case .enterMap(let index):
            if battle.turns.result == 2 { carryover = try battle.finishBattleForCarryover() }
            guard completeSelectedMap(selections[index]) else { return }
            pendingBattleMap = nil;battleReturnSelection = nil;controllerIdle = false;waiting = vm.waitingState()
        }
    }
    /// MAIN1E347..1E368: result one restores the source36 script context,
    /// the persons named by its setup rows and the player object (CF5:7FE0,
    /// ADB4), then reruns the battle loop. RNG, cities and 7A76 continue.
    /// A preserved-slot battle refuses retreat, so it has no carryover here.
    private func restartBattleFromCheckpoint(_ finished:OriginalBattleSession) throws {
        guard let saved = checkpoint,let host = retryHost,host.battleID == finished.definition.id,
              saved.stage.palette == 3,!finished.header.preserveFriendlySlots,saved.roster.slots.count == 45 else {
            throw EngineError.invalid("Original battle restart has no source36 checkpoint for this battle")
        }
        let named = Set(saved.roster.slots.map(\.person).filter{(0..<384).contains($0)})
        try people.transaction {
            try people.restore(people:named,from:saved.people)
            try vm.restoreRetryContext(saved.vm)
        }
        roster = saved.roster;money = saved.money
        battle = try OriginalBattleSession(definition:finished.definition,roster:&roster,people:people,
            combat:source.combat,movement:source.movement,rng:finished.rng,carryover:nil)
        pendingBattleMap = nil;battleReturnSelection = nil
        controllerInvocationPending = host.controllerInvocationPending;controllerIdle = host.controllerIdle
        currentEventPerson = host.currentEventPerson;waiting = nil
        try pump()
    }
    /// Field menu quit (CF5:F044) sets map-loop flag40 after its question;
    /// the framework then reaches MAIN's retry selector.
    func fieldQuit() throws {
        guard fieldMenuReady else { throw EngineError.invalid("The original field menu is not available now") }
        frameworkReturn = OriginalFrameworkReturn(mask:0x40,producer:"field-menu-quit",recordID:nil,sourceOffset:nil)
        waiting = nil
    }
    func answerRetryPrompt(_ result:Int) throws {
        guard var value = frameworkReturn else { throw EngineError.invalid("No original retry selector is pending") }
        try value.answer(result);frameworkReturn = value
    }
    /// Original MAIN framework texts, exported locally by the campaign producer.
    var retryPromptText:String? { vm.program.framework?.retryPrompt?.text }
    var framework:OriginalFrameworkPrompts? { vm.program.framework }
    /// MAIN's field screen (CF5:C456) outside battle, title and ending: the
    /// PACKGRP frame plus portrait0, player money, person0 level and the name
    /// of player field10's city. Nil when the local data lacks screen facts.
    func fieldScreenState() -> OriginalFieldScreenState? {
        guard let screens = story.screens,ending == nil,stage.mode != "title",stage.palette != 3,
              let frame = story.frameImage(screens.field.frameAsset,palette:stage.palette) else { return nil }
        let portraitID = screens.field.hud["portrait"]?.portraitID ?? 0
        let state = vm.state
        let territory = state.currentCity.flatMap { city in
            exploration.cities.first(where:{$0.chapter == state.chapter && $0.id == city})?.name
        }
        return OriginalFieldScreenState(frameImage:frame,portraitImage:story.portraitImage(portraitID,palette:stage.palette),
            hud:screens.field.hud,money:money,level:try? people.person(0).level,territory:territory)
    }
    /// The title stage precedes MAIN's menu; any source state begins only
    /// after the new-game choice (or a native resume).
    var hasStarted:Bool { started }
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
                if instruction.opcode == 0x11 {
                    battleReturnSelection = CampaignVMMapRequest(packedMap:args[0],battleID:nil,
                        recordID:vm.activeRecord?.id ?? "",sourceOffset:instruction.offset)
                }
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
    /// Outside the battle palette the host RNG is current; a finished battle
    /// session retains only its exit state.
    func snapshot() -> OriginalCampaignCheckpoint {
        let active = stage.palette == 3 ? battle : nil
        return OriginalCampaignCheckpoint(vm:vm.snapshot(),people:people.values.values.sorted{$0.id < $1.id},roster:roster,
            rng:active?.rng ?? rng,money:money,stage:stage.snapshot(),
            liveUnits:active?.units.values.sorted{$0.slot < $1.slot},turns:active?.turns,battleValue24:active.map{Int($0.scriptValue24)})
    }
    /// The field menu (input code23 through DS:3636/36E2) is reachable only
    /// while the field controller is idle and no source script runs.
    var fieldMenuReady:Bool { explorationInputReady && [0,1,2].contains(stage.palette) && saveRequest == nil }
    /// Produces a native resume point at a pending source3D prompt, or at an
    /// idle field where MAIN's field menu offers its save (CF5:F0CE). Either
    /// way the stage is idle outside battle and no other source operation runs.
    func resumeSnapshot() throws -> OriginalCampaignResume {
        guard started,stage.palette != 3,stage.hostWaiting,
              stage.dialogue == nil,stage.batch == nil,failure == nil,choice == nil,partySelection == nil,ending == nil,
              frameworkReturn == nil,interpreterReturn == nil,explorationInput == nil,retirement == nil,
              pendingTurnHook == nil,!turnInvocationPending,invocationReturn == nil,retirementProbe == nil,
              controllerMap == nil,pendingBattleMap == nil,battleReturnSelection == nil,pendingCache.isEmpty else {
            throw EngineError.invalid("Native resume is available only at an idle save point outside battle")
        }
        let offset:Int?
        if let request = saveRequest {
            guard request.opcode == 0x3D,let pending = vm.state.pending,pending.kind == "host",pending.offset == request.offset else {
                throw EngineError.invalid("Native resume save prompt lost its source cursor")
            }
            offset = request.offset
        } else {
            guard fieldMenuReady,vm.state.pending == nil else { throw EngineError.invalid("Native field save requires an idle field controller") }
            offset = nil
        }
        return OriginalCampaignResume(checkpoint:snapshot(),saveOffset:offset,
            controllerInvocationPending:controllerInvocationPending,controllerIdle:controllerIdle,
            controllerAfterInvocationFacings:controllerAfterInvocationFacings,currentEventPerson:currentEventPerson,
            carryover:carryover,retryCheckpoint:checkpoint,retryHost:retryHost,uncertainReturnContext:uncertainReturnContext,
            limitations:["Native engine state, not an original MSAVE slot; MAIN's own load path is not replicated.",
                         "Resume continues the same source cursor after the 3D prompt with the saved native stage."])
    }
    /// Rebuilds the saved native host, then completes the pending 3D prompt as
    /// a performed save so the source cursor continues after it.
    static func resume(data:DataSet,from save:OriginalCampaignResume) throws -> OriginalCampaignHost {
        let saved = save.checkpoint
        let host = try OriginalCampaignHost(data:data,rng:saved.rng,vmState:saved.vm)
        guard saved.stage.palette != 3,saved.liveUnits == nil,saved.turns == nil else {
            throw EngineError.invalid("Native resume file was not taken outside battle")
        }
        var prompt:OriginalCampaignInstruction?
        if let offset = save.saveOffset {
            guard let pending = host.vm.state.pending,pending.kind == "host",pending.opcode == 0x3D,pending.offset == offset,
                  let record = host.vm.program.records.first(where:{$0.id == pending.recordID}),
                  let instruction = record.instructions.first(where:{$0.offset == pending.offset}),instruction.kind == "save-prompt" else {
                throw EngineError.invalid("Native resume file does not stop at a source save prompt")
            }
            prompt = instruction
        } else {
            guard host.vm.state.pending == nil,host.vm.state.currentRecordID == nil,host.vm.state.invocationActive != true,
                  save.controllerIdle,!save.controllerInvocationPending,[0,1,2].contains(saved.stage.palette ?? 0) else {
                throw EngineError.invalid("Native field resume file was not taken at an idle field")
            }
        }
        if let money = saved.money,!(0...10000).contains(money) { throw EngineError.invalid("Native resume money is outside its source range") }
        guard saved.roster.slots.count == 45 else { throw EngineError.invalid("Native resume roster is invalid") }
        try host.people.restore(saved.people)
        host.roster = saved.roster;host.money = saved.money
        host.carryover = save.carryover;host.checkpoint = save.retryCheckpoint;host.retryHost = save.retryHost
        host.uncertainReturnContext = save.uncertainReturnContext;host.currentEventPerson = save.currentEventPerson
        host.controllerInvocationPending = save.controllerInvocationPending;host.controllerIdle = save.controllerIdle
        host.controllerAfterInvocationFacings = save.controllerAfterInvocationFacings
        try host.stage.setPalette(saved.stage.palette ?? 0)
        if let map = saved.stage.map {
            if map>>12 < 2 {
                try host.exploration.configure(stage:host.stage,packed:map,chapter:host.vm.state.chapter,people:host.people)
            } else if map>>12 == 2,let resource = data.resources.maps[String(map)] {
                try host.stage.configureMap(map,resource:resource,actors:nil)
            } else { throw EngineError.invalid("Native resume map is not an exploration map") }
        }
        try host.stage.restoreIdle(saved.stage)
        host.started = true
        if let instruction = prompt { host.saveRequest = instruction;try host.completeSaveRequest() }
        else { host.waiting = host.vm.waitingState() }
        return host
    }
}
