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

/// Native engine resume point at a source3D prompt, idle field, or the
/// engine's first-turn checkpoint or separate suspension. This is not an original MSAVE slot:
/// MAIN's own save/load (CF5:B58C, title item one) is not replicated.
/// Host-owned continuation state identifies the exact supported boundary.
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
    /// Engine-only first-turn boundary, absent in legacy field saves.
    var battleStart:OriginalBattleStartResume? = nil
    /// Separate single-use suspension. Absent from all earlier save files.
    var suspension:OriginalCampaignSuspension? = nil
    /// Player assistance state belongs to this exact saved campaign.
    var extras:CampaignExtras? = nil

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

/// A battle whose opening scripts have finished, before the turn flow starts.
/// This deliberately does not serialize suspended attacks, movement undo state
/// or AI continuations. Mid-battle suspension uses its own guarded payload.
struct OriginalBattleStartResume:Codable {
    var battleID:String
    var terrain:[UInt8]
    var pictureTiles:[UInt8]?
    var scriptActions:OriginalScriptActionState
    var resultLog:BattleResultLog? = nil
    var sourceOptionsWord:Int? = nil

    /// Bind the ID to a decoded load instruction in this campaign block,
    /// not merely to a map that happens to exist in the battle catalogue.
    func matchesSource(program:OriginalCampaignProgram,state:OriginalCampaignState) -> Bool {
        program.records.contains { record in
            record.chapter == state.chapter && record.member == state.member && record.block == state.block &&
            record.instructions.contains { instruction in
                [9,0x11].contains(instruction.opcode) && instruction.battleID == battleID && instruction.arguments.first == state.packedMap
            }
        }
    }

    static func capture(_ battle:OriginalBattleSession) throws -> Self {
        guard battle.turns.stage == .unstarted,battle.turns.result == 0,battle.turns.pendingAI.isEmpty,
              battle.exchanges.isEmpty,battle.strategyExecutions.isEmpty,battle.retirements.isEmpty,
              battle.objectiveEvents.isEmpty,battle.upkeepNotices.isEmpty,
              battle.scriptActions.duel?.active != true else {
            throw EngineError.invalid("Battle-start resume requires a completed opening before the first turn")
        }
        return Self(battleID:battle.definition.id,terrain:battle.terrain,pictureTiles:battle.pictureTiles,scriptActions:battle.scriptActions,resultLog:battle.resultLog,sourceOptionsWord:battle.sourceOptionsWord)
    }
    /// Replaces only the explicitly serialized starting state of a fresh session.
    func restore(_ saved:OriginalCampaignCheckpoint,in battle:OriginalBattleSession) throws {
        try restoreState(saved,in:battle,beforeFirstTurn:true)
    }
    func restoreState(_ saved:OriginalCampaignCheckpoint,in battle:OriginalBattleSession,beforeFirstTurn:Bool) throws {
        try resultLog?.validate()
        if let options = sourceOptionsWord,!(0...65535).contains(options) { throw EngineError.invalid("Saved battle options are invalid") }
        func point(_ p:GridPoint) -> Bool { (0..<battle.width).contains(p.x) && (0..<battle.height).contains(p.y) }
        guard battleID == battle.definition.id,let turns = saved.turns,let units = saved.liveUnits,
              (beforeFirstTurn ? turns.stage == .unstarted : [.unstarted,.manualFriendly].contains(turns.stage)),turns.result == 0,turns.pendingAI.isEmpty,
              (0...65535).contains(turns.roundIndex),turns.weatherIndex <= 5,
              terrain.count == battle.width*battle.height,
              pictureTiles == nil || pictureTiles!.count == terrain.count*4,
              units.count <= 45,Set(units.map(\.slot)).count == units.count,
              units.allSatisfy({ unit in
                  (0..<45).contains(unit.slot) && (0..<384).contains(unit.person) && (0...4).contains(unit.status) &&
                  (0...100).contains(unit.morale) && (0...255).contains(unit.position.x) && (0...255).contains(unit.position.y) &&
                  (unit.status != 2 || point(unit.position)) && (unit.goal.map { (0...255).contains($0.x) && (0...255).contains($0.y) } ?? true) &&
                  (unit.preferredTarget.map { (0..<45).contains($0) } ?? true)
              }),let value24 = saved.battleValue24,(0...255).contains(value24),
              scriptActions.duel?.active != true,
              scriptActions.environment.count <= terrain.count,scriptActions.environment.allSatisfy({point($0.point)}),
              scriptActions.markers.count <= terrain.count,scriptActions.markers.keys.allSatisfy(point) else {
            throw EngineError.invalid("Battle-start resume has an invalid starting state")
        }
        if let resultLog = resultLog { battle.resultLog = resultLog }
        if let options = sourceOptionsWord { battle.sourceOptionsWord = options }
        battle.restoredSourceOptions = true
        battle.units = Dictionary(uniqueKeysWithValues:units.map { ($0.slot,$0) })
        battle.turns = turns;battle.terrain = terrain;battle.pictureTiles = pictureTiles
        battle.scriptActions = scriptActions;battle.scriptValue24 = UInt8(value24);battle.rng = saved.rng
        _ = try battle.board()
    }
}

/// Owns native state effects for registered source operations. A VM instruction
/// is acknowledged only after its handler completed; unregistered effects stop
/// at the exact original record/offset. The record browser never advances this.
enum OriginalItemMessage:Equatable {
    case gained(item:Int),declined(item:Int),gaveUp(item:Int),discarded(item:Int)
}

final class OriginalCampaignHost {
    let data:DataSet
    let source:OriginalGameData
    let vm:CampaignVM
    let stage:Runtime
    let exploration:OriginalExplorationCatalog
    let story:OriginalStoryCatalog
    let retirementCatalog:OriginalRetirementCatalog
    let shopCatalog:OriginalShopCatalog
    let citizens:OriginalCitizenCatalog
    let people:OriginalPeople
    var extras = CampaignExtras()
    var eventHintCatalog:ReviewedEventHints.Catalog?
    var eventHintCatalogError:String?
    /// Immutable source tables, not mutable campaign progress or file paths.
    lazy var currentAssistanceSourceIdentity:String? = {
        struct Facts:Encodable {var campaign:String;var people:OriginalPersonCatalog;var combat:OriginalCombatTables;var movement:OriginalMovementProfile;var party:OriginalPartyProfile}
        guard let digest = vm.program.sourceDigest,SourceCatalogIdentity.valid(digest) else {return nil}
        return try? SourceCatalogIdentity.digest(Facts(campaign:digest,people:source.people,combat:source.combat,movement:source.movement,party:source.party))
    }()
    var resumedFrom:String?
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
    private var controllerEvent:Int?
    private var controllerIdle = false
    private var controllerAfterInvocationFacings:[OriginalExplorationFacing] = []
    private(set) var shop:OriginalShopOperation?
    /// A world arrival waiting for the source yes/no question.
    private(set) var cityEntry:(city:Int,question:String)?
    private(set) var retirementPresentation:OriginalRetirementPresentation?
    private(set) var retirementText:String?
    /// MAIN1A6EC: an item offered to a person with eight full slots.
    private(set) var itemOffer:(person:Int,item:Int)?
    private(set) var itemMessage:OriginalItemMessage?
    private var itemInstruction:OriginalCampaignInstruction?
    /// The window turns this on; verification grants items silently.
    var announcesItems = false
    /// The window plays duels step by step; verification applies them at once.
    var presentsDuels = false
    /// The duel window, kept for drawing between opcodes. Never saved.
    private(set) var duelStage:OriginalDuelStage?
    /// Steps the window has yet to play. The script waits for them, as the
    /// source's duel routines hold it until they return.
    private(set) var duelSteps:[OriginalDuelStep]?
    func finishDuelSteps() { duelSteps = nil }
    /// Scripted battle walks the window has yet to play.
    private(set) var battleCues:[OriginalBattleCue]?
    func finishBattleCues() { battleCues = nil }
    private var pendingBattleCommands:[Command] = []
    private var closingNotices:[OriginalBattleNotice] = []
    func takeClosingNotice() -> OriginalBattleNotice? { closingNotices.isEmpty ? nil : closingNotices.removeFirst() }
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
    /// Source sound numbers the window has yet to play.
    private var sounds:[Int] = []
    func takeSounds() -> [Int] {
        defer { sounds = [];battle?.scriptSounds = [] }
        return sounds+(battle?.scriptSounds ?? [])
    }
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
        shop == nil && cityEntry == nil && controllerIdle && !controllerInvocationPending && vm.state.currentRecordID == nil
    }
    /// What a player needs to read. Script progress stays in `status`.
    var playerStatus:String? {
        if let ending = ending,case .unsupported = ending.output { return status }
        return frameworkReturn?.outcome == .quit || interpreterReturn != nil || failure != nil ? status : nil
    }
    var status:String {
        if let ending = ending {
            if case .unsupported(let frontier) = ending.output { return "엔딩 미복원 경계: \(frontier.resource) @\(frontier.offset) · \(frontier.reason)" }
            return "원작 엔딩 재생"
        }
        if let value = frameworkReturn {
            switch value.outcome {
            case .restart: return "원작 재시작 선택 · MAIN 다시 실행"
            case .quit: return "원작 종료 선택 · 입력하면 창을 닫습니다"
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
        shopCatalog = try OriginalShopCatalog.load(from:data.root.appendingPathComponent("shop.json"))
        citizens = try OriginalCitizenCatalog.load(from:data.root.appendingPathComponent("citizens.json"))
        let program = try OriginalCampaignProgram.load(from:data.root.appendingPathComponent("campaign.json"))
        vm = try CampaignVM(program:program,state:vmState ?? OriginalCampaignState(),supportedHostOpcodes:[2,3,7,0x10,0x11,0x1B,0x1C,0x1F,0x20,0x22,0x23,0x24,0x26,0x27,0x28,0x29,0x2A,0x2D,0x2F,0x33,0x34,0x35,0x37,0x39,0x3A,0x2B,0x36,0x38,0x3B,0x3C,0x3D])
        stage = Runtime(data,hostDriven:true)
        stage.extraActors = citizens.actors(sprites:exploration.townSprites ?? [])
        loadDefaultEventHints()
    }
    func acknowledge() throws {
        guard failure == nil,choice == nil,saveRequest == nil,itemInstruction == nil else { return }
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
        wanderCitizens(microseconds:microseconds)
        if explorationInput != nil,stage.hostWaiting { try completeExplorationInput() }
        if retirement != nil { _ = try continueRetirement() }
        if pendingTurnHook != nil { _ = try continueTurnHook() }
        try controllerAutomaticTick()
    }
    /// Engine input: look around an idle world map (MAIN's scroll unit steps).
    @discardableResult func scrollWorld(dx:Int,dy:Int,step:Int) -> Bool {
        guard explorationInputReady,vm.state.packedMap>>12 == 1 else { return false }
        return stage.scrollWorld(dx:dx,dy:dy,step:step)
    }
    func choose(_ index:Int) throws {
        guard let selected = choice,selected.options.indices.contains(index) else { throw EngineError.invalid("No original campaign choice is pending") }
        try vm.choose(index:index)
        recordJourney(kind:"선택",text:selected.options[index])
        choice = nil;try pump()
    }
    private func itemRecipient() throws -> Int {
        guard vm.state.packedMap>>12 == 3 else { return 0 }
        guard let person = currentEventPerson else { throw BattleError.unsupported("Original battle item recipient has no source event-person identity") }
        return person
    }
    /// True while the grant owns the script: a full person answers first, and
    /// the window shows the result before the next instruction runs.
    private func beginItemGrant(_ instruction:OriginalCampaignInstruction) throws -> Bool {
        guard let item = instruction.arguments.first else { throw EngineError.invalid("Original item grant has no item operand") }
        let person = try itemRecipient()
        if try people.person(person).itemIDs.contains(255) {
            guard announcesItems else { return false }
            recordBattleGrant(try people.grantScriptItem(person:person,itemID:item))
            itemMessage = .gained(item:item)
        } else { itemOffer = (person,item) }
        itemInstruction = instruction
        return true
    }
    /// A slot replaces that item. Nil keeps the inventory: `declined` is the
    /// No answer and the other is a cancelled list (MAIN1A86B, MAIN1A81A).
    func answerItemOffer(slot:Int?,declined:Bool = false) throws {
        guard let offer = itemOffer else { throw EngineError.invalid("No original item offer is pending") }
        if let slot = slot {
            let inventory = try people.person(offer.person).itemIDs
            guard inventory.indices.contains(slot) else { throw EngineError.invalid("Item replacement slot is invalid") }
            guard !extras.protects(personID:offer.person,itemID:inventory[slot],operation:.discard) else {
                throw EngineError.invalid("보호된 도구입니다. 도구 관리에서 보호를 해제한 뒤 버릴 수 있습니다.")
            }
        }
        let grant = try people.grantScriptItem(person:offer.person,itemID:offer.item,replacementChoice:slot ?? 255)
        recordBattleGrant(grant)
        itemOffer = nil
        guard announcesItems else { try finishItemGrant();return }
        itemMessage = grant.replacedItemID.map { .discarded(item:$0) } ?? (declined ? .declined(item:offer.item) : .gaveUp(item:offer.item))
    }
    func acknowledgeItemMessage() throws {
        guard itemMessage != nil else { throw EngineError.invalid("No original item message is pending") }
        itemMessage = nil
        try finishItemGrant()
    }
    private func finishItemGrant() throws {
        guard let instruction = itemInstruction else { throw EngineError.invalid("No original item grant is pending") }
        itemInstruction = nil
        try vm.resumeHostAction(opcode:instruction.opcode,sourceOffset:instruction.offset);try pump()
    }
    func completeSaveRequest() throws {
        guard let request = saveRequest else { throw EngineError.invalid("No original save request is pending") }
        try vm.resumeHostAction(opcode:request.opcode,sourceOffset:request.offset);saveRequest = nil;try pump()
    }
    func toggleParty(person:Int) throws {
        guard var selection = partySelection else { throw EngineError.invalid("No original party selection is pending") }
        try selection.toggle(person:person);partySelection = selection
    }
    func applyPartyPreset(_ preset:CampaignExtras.PartyPreset) throws {
        guard let selection = partySelection else { throw EngineError.invalid("No party selection is pending") }
        if let issue = preset.sourceIssue(for:currentAssistanceSourceIdentity) {throw EngineError.invalid(issue)}
        partySelection = try PartyPreparation.applying(preset:preset,to:selection).selection
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
        if arrival.opensShop { try openShop(facings:arrival.afterInvocationFacings);return }
        if let citizen = arrival.citizen {
            if let line = citizens.say(group:cityGroup,citizen:citizen) { try stage.enqueue([line]) }
            return
        }
        if let event = event {
            controllerAfterInvocationFacings = arrival.afterInvocationFacings
            let matched = try dispatch(event,currentPerson:plan.targetPerson)
            if !matched { try restoreInputFacings() }
            // MAIN26A8D..26A9C: an unmatched talk makes the person say the
            // DS:397A line. Its bytes are a Shift-JIS string left in the Korean
            // build, so the native host states the omission instead.
            if !matched,plan.kind == .townActor {
                notice = "지금은 나눌 이야기가 없습니다."
            }
            if !matched,plan.kind == .worldCity { try offerCityEntry(arrival.currentCity) }
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
    /// MAIN238AF..238F3 gives the receiver's first empty slot, then clears
    /// the giver's first match. False means the receiver is full (MAIN23896).
    func exchangeItem(from giver:Int,to receiver:Int,item:Int) throws -> Bool {
        guard fieldMenuReady else { throw EngineError.invalid("Item exchange is available only at an idle field") }
        let companions = try people.companions()
        guard giver != receiver,companions.contains(giver),companions.contains(receiver) else { throw EngineError.invalid("현재 동료 사이에서만 도구를 전달할 수 있습니다.") }
        var nextExtras = extras
        try nextExtras.transferProtection(from:giver,to:receiver,item:item)
        let given = try people.giveItem(from:giver,to:receiver,item:item)
        if given { extras = nextExtras }
        if !given { sounds.append(2) }                     // MAIN2386F
        return given
    }
    private var cityGroup:Int { exploration.chapterMappings.first{$0.chapter == vm.state.chapter}?.cityGroup ?? 0 }
    /// The window turns this on. Verification keeps citizens where they stand.
    var citizensWander = false
    private var wanderers:[Int:OriginalCitizenWander] = [:]
    private var wanderDice = OriginalRNG(state:0x1234)
    private var wanderTime:Int64 = 0
    /// MAIN257AC runs per loop frame, six ticks at the normal speed.
    private func wanderCitizens(microseconds:Int64) {
        guard citizensWander,explorationInputReady || explorationInput != nil else { return }
        wanderTime += microseconds
        guard wanderTime >= 99_488 else { return }
        wanderTime = 0
        let present = stage.actors.keys.filter { $0 >= OriginalCitizenCatalog.firstActor }
        wanderers = wanderers.filter { present.contains($0.key) }
        let goal = explorationInput?.route.last?.position
        for person in present.sorted() {
            guard person != explorationInput?.targetPerson,let actor = stage.actors[person] else { continue }
            var state = wanderers[person] ?? OriginalCitizenWander(home:actor.position)
            var dice = wanderDice
            let walks = state.tick { (try? dice.next(bound:$0)) ?? 0 }
            wanderDice = dice
            if walks {
                var allowed = false
                stage.wander(person:person,direction:state.direction) { allowed = $0 != goal && state.allows($0);return allowed }
                if !allowed { state.blocked() }
            }
            wanderers[person] = state
        }
    }
    /// MAIN26298 places the city's citizens once per map: 18E8 finds any class
    /// 0x400 actor already there. The key is the room, or 7D for the town.
    private func placeCitizens() throws {
        guard !stage.actors.keys.contains(where:{$0 >= OriginalCitizenCatalog.firstActor}),let city = vm.state.gameCity,
              let map = stage.currentMap,let width = map.walkWidth,let walk = map.walkBytes else { return }
        let packed = vm.state.packedMap
        try stage.enqueue(citizens.placements(group:cityGroup,city:city,key:packed>>12 == 2 ? packed&0xFF : 0x7D,width:width,walk:walk,rng:&rng))
    }
    /// MAIN23F96..23FE9: an unmatched arrival at a town asks before entering.
    /// The source also skips the question while the cursor is disabled (player
    /// field 0C); a native arrival always comes from a pointer input.
    private func offerCityEntry(_ id:Int) throws {
        guard let facts = exploration.cityEntry,let city = exploration.cities.first(where:{$0.chapter == vm.state.chapter && $0.id == id}) else {
            throw EngineError.invalid("Original world arrival has no city entry facts")
        }
        if let question = facts.question(city:city) { cityEntry = (id,question) }
    }
    /// MAIN23FF3..2402B selects the town map with native entry byte7=1.
    func answerCityEntry(_ enter:Bool) throws {
        guard let pending = cityEntry,let facts = exploration.cityEntry else { throw EngineError.invalid("No original city entry question is pending") }
        cityEntry = nil
        guard enter else { return }
        do { try enterNativeMap(packedMap:pending.city,spawn:GridPoint(x:facts.x,y:facts.y),sourceFacing:0) }
        catch {
            failure = CampaignVMFailure(recordID:vm.activeRecord?.id,opcode:nil,sourceOffset:nil,reason:"\(error)")
            throw error
        }
    }
    /// MAIN36B47..36B7B picks the stock row before the greeting.
    private func openShop(facings:[OriginalExplorationFacing]) throws {
        guard let city = vm.state.currentCity,let mapping = exploration.chapterMappings.first(where:{$0.chapter == vm.state.chapter}),money != nil else {
            throw EngineError.invalid("Original shop has no player city, chapter mapping or money")
        }
        let names = source.combat.items
        shop = OriginalShopOperation(catalog:shopCatalog,stock:try shopCatalog.stock(cityBase:mapping.cityBase,city:city),
            itemName:{ item in names.first{$0.id == item}?.name ?? "" })
        controllerAfterInvocationFacings = facings
    }
    struct ShoppingTransactionResult { var completed:Int;var failure:String? }
    func performShopPurchase(item:Int,person:Int,count:Int) throws -> ShoppingTransactionResult {
        try performShopTransaction(item:item,person:person,count:count,buying:true)
    }
    func performShopSale(person:Int,item:Int,count:Int) throws -> ShoppingTransactionResult {
        try performShopTransaction(item:item,person:person,count:count,buying:false)
    }
    /// Each item follows the original shop dialogue transitions on a private
    /// people copy. Commit only a complete transaction; earlier completed
    /// items survive a later refusal, and there is no partial item/money write.
    private func performShopTransaction(item:Int,person:Int,count:Int,buying:Bool) throws -> ShoppingTransactionResult {
        guard (0..<64).contains(item),(0..<384).contains(person),(1...8).contains(count),
              let active = shop,let current = money else { throw EngineError.invalid("상점 거래 요청이 올바르지 않습니다.") }
        switch active.phase {
        case .top,.buying,.selling:break
        default:throw EngineError.invalid("진행 중인 상점 선택을 마친 뒤 다시 시도해 주세요.")
        }
        let original = people.values.values.sorted {$0.id < $1.id}
        let scratch = try OriginalPeople(catalog:.init(format:1,people:original),tables:source.combat)
        try scratch.restore(original)
        var completed = 0,available = current
        for _ in 0..<count {
            let customers = try OriginalShopOperation.customers(scratch)
            guard let customer = customers.firstIndex(of:person) else { return .init(completed:completed,failure:"거래할 수 있는 장수가 아닙니다.") }
            var transaction = OriginalShopOperation(catalog:active.catalog,stock:active.stock,itemName:active.itemName)
            try transaction.answer(nil,people:scratch,money:&available)
            try transaction.answer(buying ? 0 : 1,people:scratch,money:&available)
            if buying {
                guard let row = active.stock.firstIndex(of:item) else { return .init(completed:completed,failure:"현재 상점에서 판매하지 않는 도구입니다.") }
                guard available >= active.catalog.buyingPrice(item) else { return .init(completed:completed,failure:"돈이 부족합니다.") }
                guard try scratch.person(person).itemIDs.contains(255) else { return .init(completed:completed,failure:"장수의 도구 칸이 가득 찼습니다.") }
                try transaction.answer(row,people:scratch,money:&available)
                try transaction.answer(1,people:scratch,money:&available)
                try transaction.answer(customer,people:scratch,money:&available)
                try transaction.answer(1,people:scratch,money:&available)
            } else {
                guard !extras.protects(personID:person,itemID:item,operation:.sell) else { return .init(completed:completed,failure:"보호된 도구는 팔 수 없습니다.") }
                let held = try scratch.person(person).itemIDs.filter {$0 != 255}
                guard let row = held.firstIndex(of:item) else { return .init(completed:completed,failure:"선택한 도구를 더 이상 가지고 있지 않습니다.") }
                try transaction.answer(customer,people:scratch,money:&available)
                try transaction.answer(row,people:scratch,money:&available)
                try transaction.answer(1,people:scratch,money:&available)
            }
            try transaction.answer(0,people:scratch,money:&available)
            try people.restore(scratch.values.values.sorted {$0.id < $1.id})
            money = available;shop = transaction;completed += 1;sounds.append(buying ? 3 : 4)
        }
        return .init(completed:completed,failure:nil)
    }
    var shopPrompt:OriginalShopPrompt? { try? shop?.prompt(people:people) }
    /// Answers the routine's current blocking call. The end restores the
    /// merchant's facing (MAIN26AA1..26AAD).
    func answerShop(_ value:Int?) throws {
        guard var operation = shop,var current = money else { throw EngineError.invalid("No original shop is open") }
        if case .sellConfirm(let person,let slot) = operation.phase,value == 1 {
            let item = try people.person(person).itemIDs[slot]
            guard !extras.protects(personID:person,itemID:item,operation:.sell) else {
                throw EngineError.invalid("보호된 도구는 팔 수 없습니다. 도구 관리에서 보호를 해제해 주세요.")
            }
        }
        if case .receiverConfirm(let item,let person) = operation.phase,value == 1 {
            guard try OriginalShopOperation.customers(people).contains(person),
                  try people.person(person).itemIDs.contains(255),current >= shopCatalog.buyingPrice(item) else {
                throw EngineError.invalid("장수의 도구 칸이나 소지금이 바뀌었습니다. 수령인을 다시 선택해 주세요.")
            }
        }
        let before = current
        try operation.answer(value,people:people,money:&current)
        // MAIN3677D and 36AEA: a purchase sounds three, a sale four.
        if current != before { sounds.append(current < before ? 3 : 4) }
        money = current;shop = operation.finished ? nil : operation
        // MAIN35787.. warn with sound two before a refusal line.
        let texts = shopCatalog.texts
        if let line = shopPrompt?.text,[texts.shortMoney,texts.receiverFull,texts.noItems,texts.sellEmpty].contains(line) { sounds.append(2) }
        if operation.finished { try restoreInputFacings() }
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
    /// (MAIN24C6A). Between them MAIN24BD6..24C1A selects the entry music and
    /// puts the merchant in a palace whose type is seven (DS:3838, rooms 10 and 11).
    private func enterNativeMap(packedMap:Int,spawn:GridPoint?,sourceFacing:Int) throws {
        let kind = packedMap>>12
        guard [0,1,2].contains(kind),(0...0xFFFF).contains(packedMap) else {
            throw EngineError.invalid("Original native entry selected a non-exploration map")
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
            if let music = shopCatalog.worldMusic { try vm.setSourceMusic(selection:music) }
            let boot = try OriginalExplorationInput.worldBootstrap(catalog:exploration,state:vm.state,entry:.nativeCityDefault,rng:rng)
            try stage.enqueue(boot.commands);rng = boot.rngAfter
        } else {
            guard let spawn = spawn else { throw EngineError.invalid("Original settlement native entry has no game position") }
            var after = rng
            _ = try OriginalExplorationInput.placementEffects(packedMap:packedMap,person:0,rng:&after)
            try stage.enqueue([Command("place",person:0,x:spawn.x,y:spawn.y,sourcePlacementFacing:sourceFacing)]);rng = after
            if kind == 0 {
                let music = shopCatalog.townMusic
                try vm.setSourceMusic(selection:vm.state.chapter == music.chapter && vm.state.currentCity == music.city ? music.special : music.normal)
            } else if shopCatalog.merchant.hosts(palaceIndex:packedMap&0xFF) {
                let merchant = shopCatalog.merchant
                try vm.setSourceMusic(selection:merchant.music)
                if try people.person(merchant.person).sourceFlags&0x80 != 0 {
                    try OriginalExplorationInput.merchantPlacement(rng:&rng)
                    try stage.enqueue([Command("place",person:merchant.person,x:merchant.x,y:merchant.y,sourcePlacementFacing:merchant.sourceFacing)])
                }
            }
            try placeCitizens()
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
              failure == nil,interpreterReturn == nil,explorationInput == nil,retirement == nil,shop == nil,cityEntry == nil,
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
            } else { primary = try hook.campaignEvent();fallback = [.numberedRound,.enemiesDefeated].contains(hook.kind) ? .automatic : nil }
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
        if matched { controllerEvent = event.kind;controllerIdle = false;controllerInvocationPending = true;waiting = nil;try pump() }
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
    private func runPendingBattleCommands() -> Bool {
        guard stage.palette == 3,let battle = battle else { pendingBattleCommands.removeAll();return true }
        while !pendingBattleCommands.isEmpty {
            let command = pendingBattleCommands.removeFirst()
            do {
                if ["place","move","remove"].contains(command.op) {
                    let action = try battle.applyScriptMapCommand(command,roster:roster)
                    if presentsDuels,let path = action.movementPath,path.count > 1,let slot = action.changedSlots.first {
                        battleCues = (battleCues ?? [])+[.walk(slot:slot,path:path,sound:try? battle.walkSound(slot))]
                    }
                } else { try stage.enqueue([command]) }
            } catch {
                pendingBattleCommands.removeAll()
                failCommand(command,error:error)
                return false
            }
            if !stage.hostWaiting || battleCues != nil { return false }
        }
        return true
    }
    func pump() throws {
        guard started,stage.hostWaiting,choice == nil,saveRequest == nil,partySelection == nil,failure == nil,waiting == nil,
              itemInstruction == nil,interpreterReturn == nil,frameworkReturn == nil,duelSteps == nil,battleCues == nil else {
            if let termination = stage.termination,termination != .sourceBoundary {
                let record = vm.activeRecord
                let source = stage.trace.last?.source
                let instruction = source.flatMap { origin in record?.instructions.first(where:{$0.commands.contains(where:{$0.source == origin})}) }
                failure = CampaignVMFailure(recordID:record?.id,opcode:instruction?.opcode,sourceOffset:instruction?.offset,reason:stage.endReason ?? "Native stage failed")
            }
            return
        }
        if !pendingBattleCommands.isEmpty {
            if !runPendingBattleCommands() { return }
        }
        try cacheCompletedCommands()
        // A work bound stops pathological script cycles without declaring EOF
        // or inventing a phase transition. Caller can explicitly continue.
        for _ in 0..<4096 {
            let result = try vm.advance()
            switch result {
            case .commands(let commands):
                pendingCache = commands
                if stage.palette == 3,battle != nil {
                    pendingBattleCommands = commands
                    if !runPendingBattleCommands() { return }
                } else {
                    for command in commands where command.op == "place" {
                        do {
                            guard let person = command.person else { throw EngineError.invalid("Original placement has no person identity") }
                            _ = try OriginalExplorationInput.placementEffects(packedMap:vm.state.packedMap,person:person,rng:&rng)
                        } catch { failCommand(command,error:error);return }
                    }
                    try stage.enqueue(commands)
                }
                if !stage.hostWaiting || battleCues != nil { return };try cacheCompletedCommands()
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
                if instruction.opcode == 0x1B,try beginItemGrant(instruction) { return }
                do { try apply(instruction) }
                catch {
                    failure = CampaignVMFailure(recordID:vm.activeRecord?.id,opcode:instruction.opcode,
                        sourceOffset:instruction.offset,reason:"\(error)")
                    return
                }
                try vm.resumeHostAction(opcode:instruction.opcode,sourceOffset:instruction.offset)
                if instruction.kind == "checkpoint-capture" {
                    checkpoint = snapshot()
                    extras.retryJourney = stage.palette == 3 ? CampaignJourneyCheckpoint(journal:extras.journal,dialogueHistory:extras.dialogueHistory,eventHints:extras.eventHints) : nil
                    retryHost = stage.palette == 3 ? battle.map { OriginalRetryHostState(battleID:$0.definition.id,
                        controllerInvocationPending:controllerInvocationPending,controllerIdle:controllerIdle,
                        currentEventPerson:currentEventPerson) } : nil
                }
                if duelSteps != nil { return }
            case .choice(let value):choice = value;return
            case .waiting(let value):waiting = value;return
            case .unsupported(let value):failure = value;return
            case .interpreterReturn(let value):
                recordReviewedEventCompletion(value)
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
                recordReviewedEventCompletion(returned)
                if controllerInvocationPending {
                    controllerInvocationPending = false;controllerIdle = false;try restoreInputFacings()
                    // MAIN264A6: a destination script ending normally peoples its map.
                    if returned.status == 1,controllerEvent == 2,[0,2].contains(vm.state.packedMap>>12) { try placeCitizens() }
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
            extras.journal.finish(battle)
            do { try restartBattleFromCheckpoint(battle) }
            catch { failure = CampaignVMFailure(recordID:nil,opcode:nil,sourceOffset:nil,reason:"\(error)") }
        case .framework(let mask):
            extras.journal.finish(battle)
            frameworkReturn = OriginalFrameworkReturn(mask:mask,producer:"battle-result-\(battle.turns.result)",recordID:nil,sourceOffset:nil)
            pendingBattleMap = nil;battleReturnSelection = nil;waiting = nil
        case .unsupported(let reason):
            failure = CampaignVMFailure(recordID:nil,opcode:nil,sourceOffset:nil,reason:reason)
        case .enterMap(let index):
            if battle.turns.result == 2 {
                carryover = try battle.finishBattleForCarryover()
                closingNotices += battle.closingNotices
            }
            extras.journal.finish(battle)
            guard completeSelectedMap(selections[index]) else { return }
            pendingBattleMap = nil;battleReturnSelection = nil;controllerIdle = false;waiting = vm.waitingState()
            // The next battle of a chain runs its opening records like a source09 entry.
            if selections[index].packedMap>>12 == 3 { waiting = nil;try pump() }
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
        extras.annotations = nil
        if let savedJourney = extras.retryJourney {
            extras.journal.restoreJourney(savedJourney);extras.dialogueHistory = savedJourney.dialogueHistory
            extras.eventHints = savedJourney.eventHints
        }
        pendingBattleMap = nil;battleReturnSelection = nil;pendingBattleCommands.removeAll();battleCues = nil
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
        do {
            try loadSelectedMap(request)
            let name = request.packedMap>>12 == 3 ? battle?.definition.name : fieldScreenState()?.territory
            if let name = name,!name.isEmpty { extras.journal.record(chapter:vm.state.chapter,map:request.packedMap,kind:"방문",text:name) }
            return true
        }
        catch {
            failure = CampaignVMFailure(recordID:request.recordID,opcode:9,sourceOffset:request.sourceOffset,reason:"\(error)")
            return false
        }
    }
    private func loadSelectedMap(_ request:CampaignVMMapRequest) throws {
        try constructCitiesIfNeeded()
        // After a battle C456 fades the battle screen out first (0x1E36A), so the
        // field map the stage kept from before the battle never shows again.
        if stage.palette == 3,request.packedMap>>12 != 3 { stage.cutToBlack() }
        try vm.selectScriptMap(packedMap:request.packedMap)
        try vm.enterMapContext(packedMap:request.packedMap)
        try stage.setPalette(request.packedMap>>12)
        pendingBattleCommands.removeAll();battleCues = nil
        if request.packedMap>>12 == 3 {
            guard let id = request.battleID,let definition = source.battles.battles.first(where:{$0.id == id}) else {
                throw EngineError.invalid("Reached source battle map has no source load-site identity")
            }
            battle = try OriginalBattleSession(definition:definition,roster:&roster,people:people,
                combat:source.combat,movement:source.movement,rng:rng,carryover:carryover)
            extras.annotations = nil
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
    /// Builds the steps of a duel opcode the session has already applied.
    /// The session's result decides whether the source ran anything at all.
    private func presentDuel(opcode:Int,arguments args:[Int],result:OriginalScriptActionResult,battle:OriginalBattleSession) throws {
        func unit(_ person:Int) -> OriginalLiveUnit? { battle.units.keys.sorted().lazy.compactMap { battle.units[$0] }.first { $0.person == person } }
        switch opcode {
        case 0x10:
            guard result.sourceReturn == 1,let second = unit(args[1]) else { return }
            let terrain = Int(battle.terrain[second.position.y*battle.width+second.position.x])
            let panels = try args.map { id -> OriginalDuelPanel in
                let person = try battle.people.person(id)
                return OriginalDuelPanel(person:id,level:person.level,classID:person.classID,strength:person.attackScalar,troops:person.rawTroops,
                    maxTroops:try OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:battle.combat),experience:person.experience)
            }
            var scene = OriginalDuelStage(people:args,terrain:terrain,panels:panels)
            duelSteps = scene.setup();duelStage = scene
        case 0x33:duelStage = nil
        case 0x34:
            guard var scene = duelStage else { return }
            var rng = OriginalRNG(state:result.rngBefore)
            duelSteps = try scene.clash(rng:&rng);duelStage = scene
        case 0x35:
            guard var scene = duelStage,unit(args[0]) != nil else { return }
            duelSteps = try scene.motion(person:args[0],code:args[1]);duelStage = scene
        default:break
        }
    }
    private func apply(_ instruction:OriginalCampaignInstruction) throws {
        let args = instruction.arguments
        let scriptActions:Set<Int> = [2,0x10,0x26,0x27,0x28,0x2D,0x33,0x34,0x35]
        let expected:[Int:Int] = [3:0,7:2,0x11:2,0x1B:1,0x1F:0,0x22:0,0x24:2,0x29:1,0x2A:1,0x2F:2,0x37:2,0x39:2,0x3A:2,0x2B:2,0x36:0,0x38:1,0x3B:2,0x3C:1]
        guard scriptActions.contains(instruction.opcode) || instruction.opcode == 0x1C || instruction.opcode == 0x20 || expected[instruction.opcode] == args.count else { throw EngineError.invalid("Original host operands do not match their registered contract") }
        if scriptActions.contains(instruction.opcode) {
            guard let battle = battle else { throw BattleError.unsupported("Original battle action has no native battle context") }
            let result = try battle.applyScriptAction(opcode:instruction.opcode,arguments:args,mapIndex:vm.state.packedMap&255)
            if presentsDuels { try presentDuel(opcode:instruction.opcode,arguments:args,result:result,battle:battle) }
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
        case 0x38: break // VM owns the source music selection; OriginalAudio follows it.
        case 0x1F:try placeCitizens()
        case 0x36: break // Full native snapshot is captured after host acknowledgement below.
        case 0x2A:
            let catalog = try OriginalEndingCatalog.load(from:data.root.appendingPathComponent("ending.json"))
            ending = try OriginalEndingSession(catalog:catalog,selection:args[0])
            recordJourney(kind:"사건",text:"결말에 도달했습니다.",sourceOffset:instruction.offset)
        case 0x11,0x29:
            let mode = instruction.opcode == 0x11 ? args[1] : args[0]
            guard [0,1,3].contains(mode) else { throw EngineError.invalid("Original map return mode is invalid") }
            // MAIN336FA only changes battle state under the battle palette.
            if stage.palette == 3,let battle = battle {
                try battle.acceptSourceResult(mode == 0 ? 2 : 3)
                if mode == 3 { try vm.setSourceMusic(selection:4) }
                if instruction.opcode == 0x11 {
                    battleReturnSelection = CampaignVMMapRequest(packedMap:args[0],battleID:instruction.battleID,
                        recordID:vm.activeRecord?.id ?? "",sourceOffset:instruction.offset)
                }
            }
        case 0x3B:try stage.worldCamera(x:args[0],y:args[1],source:instruction.source)
        case 0x3C:try stage.worldFollow(person:args[0],source:instruction.source)
        case 0x1C:
            guard let battle = battle else { throw BattleError.unsupported("Original AI-order effect requires its battle context") }
            _ = try battle.applyScriptAttribute(arguments:args)
        case 0x1B:recordBattleGrant(try people.grantScriptItem(person:itemRecipient(),itemID:args[0]))
        case 0x24:
            let previous = Set(try people.companions())
            try people.setAffiliation(person:args[0],value:args[1])
            for id in try people.companions() where !previous.contains(id) {
                recordJourney(kind:"합류",text:"\(try people.person(id).name) 합류",person:id,sourceOffset:instruction.offset)
            }
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
                if stage.palette == 3,let battle = battle {
                    var rewards = battle.resultLog.totals.sourceRewards ?? ConfirmedBattleRewards()
                    rewards.moneyChange += (money ?? current)-current;battle.resultLog.totals.sourceRewards = rewards
                }
            }
            else if args[0] == 4,let battle = battle { battle.scriptValue24 = UInt8(truncatingIfNeeded:args[1]) }
            else { throw EngineError.invalid("Reached campaign value selector has no restored host effect") }
        default:throw EngineError.invalid("Unregistered original host effect")
        }
    }
    /// Append only after a source effect or an input choice has committed.
    /// A reference can point only to a line already presented in this scene.
    private func recordJourney(kind:String,text:String,person:Int? = nil,sourceOffset:Int? = nil) {
        let dialogue = extras.dialogueHistory.entries.last { $0.chapter == vm.state.chapter && $0.map == vm.state.packedMap }
        extras.journal.record(chapter:vm.state.chapter,map:vm.state.packedMap,kind:kind,text:text,person:person,
            record:vm.activeRecord?.id,sourceOffset:sourceOffset,dialogueID:dialogue?.id)
    }
    private func recordBattleGrant(_ receipt:OriginalScriptInventoryGrant) {
        guard stage.palette == 3,let battle = battle,!receipt.cancelled else { return }
        var rewards = battle.resultLog.totals.sourceRewards ?? ConfirmedBattleRewards()
        rewards.grant(receipt);battle.resultLog.totals.sourceRewards = rewards
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
              frameworkReturn == nil,interpreterReturn == nil,explorationInput == nil,retirement == nil,shop == nil,cityEntry == nil,
              pendingTurnHook == nil,!turnInvocationPending,invocationReturn == nil,retirementProbe == nil,
              controllerMap == nil,pendingBattleMap == nil,battleReturnSelection == nil,pendingCache.isEmpty,pendingBattleCommands.isEmpty else {
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
                         "Resume continues the same source cursor after the 3D prompt with the saved native stage."],extras:extras)
    }
    /// Engine checkpoint after all opening scripts and before the first turn.
    /// An unavailable boundary is normal while dialogue or a source call runs.
    func battleStartSnapshot() throws -> OriginalCampaignResume? {
        guard battleInputReady,let battle = battle,battle.turns.stage == .unstarted,
              stage.palette == 3,stage.hostWaiting,stage.dialogue == nil,stage.batch == nil,
              vm.state.currentRecordID == nil,vm.state.pending == nil,vm.state.invocationActive != true,
              controllerIdle,!controllerInvocationPending,controllerAfterInvocationFacings.isEmpty,
              pendingTurnHook == nil,!turnInvocationPending,invocationReturn == nil,retirementProbe == nil,
              controllerMap == nil,pendingBattleMap == nil,battleReturnSelection == nil,
              pendingCache.isEmpty,pendingBattleCommands.isEmpty,duelSteps == nil,battleCues == nil,
              itemInstruction == nil,itemOffer == nil,itemMessage == nil,ending == nil else { return nil }
        let save = OriginalCampaignResume(checkpoint:snapshot(),saveOffset:nil,
            controllerInvocationPending:false,controllerIdle:true,controllerAfterInvocationFacings:[],
            currentEventPerson:currentEventPerson,carryover:carryover,retryCheckpoint:checkpoint,retryHost:retryHost,
            uncertainReturnContext:uncertainReturnContext,
            limitations:["Native engine battle-start checkpoint, not an original MSAVE slot.",
                         "Resumes after opening scripts and before the first turn; later battle actions are not saved."],
            battleStart:try OriginalBattleStartResume.capture(battle),extras:extras)
        // Verify construction can rebuild this exact source setup before the
        // window is allowed to describe the checkpoint as resumable.
        let restored = try Self.resume(data:data,from:save)
        var before = save.checkpoint,after = restored.snapshot()
        // restoreIdle discards already-consumed presentation commands. Their
        // diagnostic cursor is not a gameplay state or a resumable command.
        before.stage.nextCommand = 0;after.stage.nextCommand = 0
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(before) == encoder.encode(after),
              restored.battle?.terrain == battle.terrain,restored.battle?.pictureTiles == battle.pictureTiles,
              restored.battle?.scriptActions == battle.scriptActions else {
            throw EngineError.invalid("Battle-start reconstruction does not preserve its captured native state")
        }
        return save
    }
    /// Captures an engine suspension at a stable player/presentation boundary.
    /// Nil asks the window to retain the request while the current action runs.
    /// The flow parameter prevents private combat continuations being omitted.
    func suspendSnapshot(battleFlow:OriginalBattleFlow? = nil) throws -> OriginalCampaignResume? {
        guard started,failure == nil,partySelection == nil,ending == nil,
              vm.state.interpreterReturn == nil,vm.state.invocationReturn == nil,
              frameworkReturn == nil,interpreterReturn == nil,explorationInput == nil,retirement == nil,shop == nil,cityEntry == nil,
              pendingTurnHook == nil,!turnInvocationPending,invocationReturn == nil,retirementProbe == nil,
              controllerMap == nil,pendingBattleMap == nil,battleReturnSelection == nil,
              duelSteps == nil,battleCues == nil,itemInstruction == nil,itemOffer == nil,itemMessage == nil,closingNotices.isEmpty,
              let presentation = stage.suspension() else { return nil }
        if waiting != nil,!OriginalCampaignSuspension.canResumeWaiting(vm.state) { return nil }
        if let pending = vm.state.pending,
           pending.kind != "choice" && !(pending.kind == "host" && pending.opcode == 0x3D && saveRequest?.offset == pending.offset) { return nil }
        let active = stage.palette == 3 ? battle : nil
        if let active = active {
            guard let flow = battleFlow,flow.session === active,flow.canSuspendCheckpoint,
                  active.upkeepNotices.isEmpty,active.closingNotices.isEmpty,
                  active.scriptActions.duel?.active != true else { return nil }
        } else if stage.palette == 3 { return nil }
        let continuation = OriginalCampaignSuspension(presentation:presentation,battle:active?.suspensionState(),
            wasWaiting:waiting != nil,controllerEvent:controllerEvent,pendingCache:pendingCache,pendingBattleCommands:pendingBattleCommands,
            wanderers:wanderers.keys.sorted().map { key in
                let w = wanderers[key]!
                return OriginalSuspendedCitizen(person:key,home:w.home,direction:w.direction,counter:w.counter,standing:w.standing)
            },wanderDice:wanderDice,wanderTime:wanderTime,sounds:sounds)
        let save = OriginalCampaignResume(checkpoint:snapshot(),saveOffset:saveRequest?.offset,
            controllerInvocationPending:controllerInvocationPending,controllerIdle:controllerIdle,
            controllerAfterInvocationFacings:controllerAfterInvocationFacings,currentEventPerson:currentEventPerson,
            carryover:carryover,retryCheckpoint:checkpoint,retryHost:retryHost,uncertainReturnContext:uncertainReturnContext,
            limitations:["Native engine single-use suspension, separate from original and regular saves.",
                         "Captures dialogue/choice or a stable player-input boundary; in-flight actions finish before capture."],
            suspension:continuation,extras:extras)
        let restored = try Self.resume(data:data,from:save)
        var before = save.checkpoint,after = restored.snapshot()
        before.stage.nextCommand = 0;after.stage.nextCommand = 0
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(before) == encoder.encode(after),
              restored.battle?.terrain == active?.terrain,restored.battle?.pictureTiles == active?.pictureTiles,
              restored.battle?.scriptActions == active?.scriptActions,
              restored.battle?.pendingMovementSlots == active?.pendingMovementSlots else {
            throw EngineError.invalid("Native suspension reconstruction changed its captured state")
        }
        return save
    }
    /// Rebuilds the saved native host, then completes the pending 3D prompt as
    /// a performed save so the source cursor continues after it.
    static func resume(data:DataSet,from save:OriginalCampaignResume,allowPractice:Bool = false) throws -> OriginalCampaignHost {
        let saved = save.checkpoint
        let host = try OriginalCampaignHost(data:data,rng:saved.rng,vmState:saved.vm)
        let battleStart = save.battleStart
        let suspension = save.suspension
        guard save.format == 1,(save.kind == "native-engine-resume" || (allowPractice && save.kind == "native-engine-practice")),saved.format == 1 else {
            throw EngineError.invalid("Native resume file has an unsupported format")
        }
        var prompt:OriginalCampaignInstruction?
        if let suspended = suspension {
            guard suspended.format == 1,battleStart == nil,saved.stage.mode == "scene",
                  saved.stage.termination == nil,saved.stage.endReason == nil,
                  saved.vm.interpreterReturn == nil,saved.vm.invocationReturn == nil,
                  suspended.pendingCache.count <= 1_000_000,suspended.pendingBattleCommands.count <= 1_000_000,
                  suspended.wanderers.count <= 256,Set(suspended.wanderers.map(\.person)).count == suspended.wanderers.count,
                  suspended.wanderers.allSatisfy({ (1024..<1280).contains($0.person) && (0..<4).contains($0.direction) && (0...17).contains($0.counter) }),
                  (0..<99_488).contains(suspended.wanderTime),suspended.sounds.allSatisfy({(0...255).contains($0)}) else {
                throw EngineError.invalid("Native suspension has an invalid host continuation")
            }
            if suspended.wasWaiting {
                // A bounded move/show invocation can return while retaining
                // its record cursor; the next controller query resumes it.
                guard OriginalCampaignSuspension.canResumeWaiting(saved.vm) else {
                    throw EngineError.invalid("Native suspension waiting state has a running source cursor")
                }
            }
            if let pending = saved.vm.pending {
                guard pending.kind == "choice" || (pending.kind == "host" && pending.opcode == 0x3D && save.saveOffset == pending.offset) else {
                    throw EngineError.invalid("Native suspension contains an unsupported pending source operation")
                }
                if pending.kind == "host" {
                    guard let record = host.vm.program.records.first(where:{$0.id == pending.recordID}),
                          let instruction = record.instructions.first(where:{$0.offset == pending.offset}),instruction.kind == "save-prompt" else {
                        throw EngineError.invalid("Native suspension lost its source save prompt")
                    }
                    prompt = instruction
                }
            } else if save.saveOffset != nil { throw EngineError.invalid("Native suspension lost its pending save cursor") }
            if let battle = suspended.battle {
                guard saved.stage.palette == 3,saved.vm.packedMap>>12 == 3,
                      [.unstarted,.manualFriendly].contains(saved.turns?.stage ?? .finished),saved.liveUnits != nil,
                      battle.matchesSource(program:host.vm.program,state:saved.vm),
                      host.source.battles.battles.contains(where:{$0.id == battle.battleID}) else {
                    throw EngineError.invalid("Native suspension has no matching source battle")
                }
            } else if saved.stage.palette == 3 || saved.liveUnits != nil || saved.turns != nil {
                throw EngineError.invalid("Native suspension is missing its battle state")
            }
        } else if let start = battleStart {
            guard save.saveOffset == nil,saved.stage.palette == 3,saved.vm.packedMap>>12 == 3,
                  saved.liveUnits != nil,saved.turns?.stage == .unstarted,
                  host.vm.state.pending == nil,host.vm.state.currentRecordID == nil,host.vm.state.invocationActive != true,
                  save.controllerIdle,!save.controllerInvocationPending,save.controllerAfterInvocationFacings.isEmpty,
                  host.source.battles.battles.contains(where:{$0.id == start.battleID}),
                  start.matchesSource(program:host.vm.program,state:host.vm.state) else {
                throw EngineError.invalid("Native battle-start resume was not taken before the first turn")
            }
        } else if saved.stage.palette == 3 || saved.liveUnits != nil || saved.turns != nil {
            throw EngineError.invalid("Native resume file was not taken outside battle")
        } else if let offset = save.saveOffset {
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
        let extras = save.extras ?? CampaignExtras()
        try extras.validate()
        host.extras = extras
        host.resumedFrom = suspension != nil ? "중단한 지점부터 이어합니다." : battleStart != nil ? "전투 시작 저장 · 첫 턴부터 재개합니다." : "일반 저장 지점부터 재개합니다."
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
        if let suspended = suspension { try host.stage.restoreSuspension(saved.stage,state:suspended.presentation) }
        else { try host.stage.restoreIdle(saved.stage) }
        if let battleID = suspension?.battle?.battleID ?? battleStart?.battleID,
           let definition = host.source.battles.battles.first(where:{$0.id == battleID}) {
            var setup = saved.roster
            let battle = try OriginalBattleSession(definition:definition,roster:&setup,people:host.people,
                combat:host.source.combat,movement:host.source.movement,rng:saved.rng,carryover:save.carryover)
            // Construction initializes HP/class/MP. Opening scripts may have
            // changed them, so the saved canonical people must win afterwards.
            try host.people.restore(saved.people)
            if let suspended = suspension?.battle { try battle.restoreSuspension(saved,state:suspended) }
            else if let start = battleStart { try start.restore(saved,in:battle) }
            host.battle = battle;host.roster = saved.roster
        }
        host.started = true
        if let suspended = suspension {
            host.waiting = suspended.wasWaiting ? host.vm.waitingState() : nil
            host.choice = host.vm.state.pending?.choice;host.saveRequest = prompt
            host.controllerEvent = suspended.controllerEvent;host.pendingCache = suspended.pendingCache
            host.pendingBattleCommands = suspended.pendingBattleCommands
            host.wanderers = Dictionary(uniqueKeysWithValues:suspended.wanderers.map { ($0.person,
                OriginalCitizenWander(home:$0.home,direction:$0.direction,counter:$0.counter,standing:$0.standing)) })
            host.wanderDice = suspended.wanderDice;host.wanderTime = suspended.wanderTime
            host.sounds = suspended.sounds
        } else if let instruction = prompt { host.saveRequest = instruction;try host.completeSaveRequest() }
        else { host.waiting = host.vm.waitingState() }
        return host
    }
    /// Read-only import of an exported original slot (research/original-saves.md).
    static func importOriginal(data:DataSet,slot:OriginalSaveCatalog.Slot,rng:OriginalRNG) throws -> OriginalCampaignHost {
        let blank = try OriginalCampaignHost(data:data,rng:rng)
        let chapter = slot.script.chapter,packed = slot.game.packedMap
        guard let mapping = blank.exploration.chapterMappings.first(where:{$0.chapter == chapter}) else {
            throw EngineError.invalid("Original slot chapter has no city table")
        }
        var firstActorSlot = 0,worldCells:(width:Int,height:Int)?
        switch slot.game.kind {
        case 0:firstActorSlot = try blank.exploration.map(packed:packed,chapter:chapter).objects.count+1
        case 1:
            let map = try blank.exploration.map(packed:packed,chapter:chapter)
            worldCells = (map.width/16,map.height/16)
        case 2:
            guard let map = data.resources.maps[String(packed)] else { throw EngineError.invalid("Original slot palace map is unavailable") }
            firstActorSlot = (map.objects?.count ?? 0)+1
        default:break
        }
        let combat = blank.source.combat
        let facts = OriginalSaveFacts(program:blank.vm.program,people:blank.source.people.people,
            maxTroops:{ try OriginalCombat.maxTroops(classID:$0,level:$1,tables:combat) },
            cityCount:mapping.cityCount,firstActorSlot:firstActorSlot,worldCells:worldCells,rng:rng)
        return try resume(data:data,from:try slot.resume(facts:facts))
    }
}
