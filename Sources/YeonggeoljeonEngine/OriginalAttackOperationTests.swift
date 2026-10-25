// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func originalAttackOperationSelfTests() throws {
    var checks = 0
    func check(_ value:@autoclosure() throws -> Bool,_ reason:String) throws {
        guard try value() else {throw BattleError.invalid("Original attack operation: \(reason)")};checks += 1
    }
    let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
    func checkpoint(_ value:OriginalAttackOperation) throws -> OriginalAttackOperation {
        try JSONDecoder().decode(OriginalAttackOperation.self,from:encoder.encode(value))
    }
    func fixture(classID:Int = 0,seed:UInt32 = 2) throws -> OriginalBattleSession {
        let tables = OriginalCombatTables(format:1,attackBase:Array(repeating:1,count:19),defenseBase:Array(repeating:1,count:19),
            troopBase:Array(repeating:10,count:19),troopGrowth:Array(repeating:0,count:19),physicalSubtypeByClass:Array(repeating:0,count:19),
            terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),
            items:(0..<64).map{OriginalItemEffect(id:$0,category:15,value:0)})
        let people = try OriginalPeople(catalog:OriginalPersonCatalog(format:1,people:(0..<384).map{id in
            OriginalPersonDefinition(id:id,name:"synthetic \(id)",classID:id == 0 ? classID : 0,level:10,experience:99,rawTroops:1000,
                defenseScalar:id == 0 ? 0 : 100,attackScalar:id == 0 ? 0 : 100,intellectScalar:50,personality:0,personalScalar:0,
                itemIDs:Array(repeating:255,count:8),sourceFlags:id == 0 ? 0 : 1,sourceRole:0,sourceContext2:0,sourceContext3:0)
        }),tables:tables)
        let cardinal = [OriginalAIOffset(dx:0,dy:-1),.init(dx:1,dy:0),.init(dx:0,dy:1),.init(dx:-1,dy:0)]
        let movement = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),classMovementBudgets:Array(repeating:3,count:19),
            attackRangeCodes:Array(repeating:0,count:19),movementCosts:Array(repeating:Array(repeating:1,count:256),count:4),
            cardinalOffsets:cardinal,diagonalOffsets:cardinal,extendedOffsets:cardinal,setupOrderModes:Array(repeating:2,count:256))
        var roster = OriginalRoster();roster.header = OriginalBattleHeader(preserveFriendlySlots:false,turnLimit:10,sourceByte2:0,discardedBytes:[],objectives:[])
        for (id,point) in [GridPoint(x:1,y:1),GridPoint(x:2,y:1)].enumerated() {
            roster.slots[id] = OriginalPlacement(ordinal:id,person:id,x:point.x,y:point.y,selector:0,flag:0,flags:id == 0 ? 0 : 1,
                rawMode:0,parameter:0,classID:0,level:10)
        }
        return try OriginalBattleSession(definition:BattleDefinition(id:"synthetic-attack-operation",width:5,height:5,tiles:Array(repeating:0,count:25)),
            roster:&roster,people:people,combat:tables,movement:movement,rng:OriginalRNG(state:seed))
    }
    func finish(_ operation:inout OriginalAttackOperation,_ session:OriginalBattleSession,
                retirement:((OriginalRetirementNotice)throws->Void)? = nil) throws -> OriginalStrikeExchange {
        for _ in 0..<16 {
            switch try operation.advance(in:session) {
            case .context:continue
            case .retirement(let notice):try retirement?(notice);try operation.resumeRetirement(notice)
            case .finished(let result):return result
            }
        }
        throw BattleError.invalid("Synthetic physical driver exceeded the source recursion bound")
    }
    let session = try fixture(classID:3);try session.people.update(0) {$0.rawTroops = 1}
    let before = session.rng,flagsBefore = session.units[0]!.scriptFlags
    var operation = try OriginalAttackOperation.begin(in:session,attackerSlot:0,targetSlot:15)
    try check(session.rng == before && session.units[0]!.scriptFlags == flagsBefore && operation.contexts.isEmpty,
        "begin validates source range without consuming presentation RNG or changing facing")
    guard case .context(let primary) = try operation.advance(in:session) else {throw BattleError.invalid("Expected primary physical context")}
    try check(primary.preludeDraws == [12,1,15,2,13,7,8,9] && primary.strike.counterRoll == 52 && primary.strike.counterEligible,
        "source class3 prelude and first counter roll retain their order")
    try check(try session.people.person(0).level == 11 && session.units[0]!.scriptFlags&0x90 == 0,
        "primary EXP levels the shared person and horizontal facing changes before acted80")
    operation = try checkpoint(operation)
    guard case .context(let counter) = try operation.advance(in:session) else {throw BattleError.invalid("Expected recursive physical context")}
    try check(counter.subtype == 7 && counter.attackerSlot == 15 && counter.targetSlot == 0 && counter.preludeDraws.isEmpty && counter.strike.defense == 273,
        "subtype7 re-reads updated level and skips another presentation prelude")
    try check(operation.contextAttackerSlot == 15 && operation.contextTargetSlot == 0,
        "recursive E91A overwrites the shared context orientation")
    guard case .retirement(let notice) = try operation.advance(in:session) else {throw BattleError.invalid("Expected counter target retirement")}
    var expected = OriginalRNG(state:2);for _ in 0..<8 {_ = try expected.next(bound:16)}
    _ = try expected.next(bound:150);_ = try expected.next(bound:150)
    try check(session.rng == expected && notice.runtimeSlot == 0 && notice.person == 0 && session.units[0]!.status == 4,
        "counter target retirement follows exactly the two contexts' source draws")
    let waitingRNG = session.rng,waitingEXP = try session.people.person(0).experience
    operation = try checkpoint(operation)
    for _ in 0..<3 {
        guard case .retirement(let repeated) = try operation.advance(in:session),repeated == notice else {throw BattleError.invalid("Pending physical retirement changed")}
    }
    try check(session.rng == waitingRNG && session.people.person(0).experience == waitingEXP && session.units[0]!.scriptFlags&0x80 == 0 && operation.retirementChecks.count == 1,
        "serialized source wait blocks the outer tail and final acted flag without replaying RNG/EXP")
    var wrong = notice;wrong.sequence += 1
    do {try operation.resumeRetirement(wrong);throw BattleError.invalid("Wrong physical acknowledgement accepted")}
    catch BattleError.illegalAction {checks += 1}
    // Synthetic source-hook mutation: a new map/setup can replace a live slot.
    // This tests a fresh slot read; it is not a claimed reachable campaign path.
    func replaceCounterTarget(_ s:OriginalBattleSession) throws {
        s.units[0]!.person = 2;s.units[0]!.status = 2
        try s.people.update(2) {$0.rawTroops = 0}
        _ = try s.rng.next(bound:7)
    }
    try replaceCounterTarget(session)
    try operation.resumeRetirement(notice)
    operation = try checkpoint(operation)
    guard case .retirement(let secondNotice) = try operation.advance(in:session) else {throw BattleError.invalid("Expected fresh outer-tail retirement")}
    try check(secondNotice.sequence == 1 && secondNotice.runtimeSlot == 0 && secondNotice.person == 2 && operation.retirementChecks.map(\.queriedPerson) == [0,2],
        "outer tail reads the overwritten context slot's current person after the first script finishes")
    try check(session.units[15]!.status == 2 && session.units[0]!.scriptFlags&0x80 == 0,
        "old logical target is not substituted for the shared context's current target")
    try operation.resumeRetirement(secondNotice)
    let result = try finish(&operation,session)
    try check(result.fallenPeople == [0,2] && session.units[0]!.scriptFlags&0x80 != 0 && operation.contexts.count == 2,
        "physical command completes only after both source retirement returns")
    let after = session.rng,afterEXP = try session.people.person(0).experience
    let repeatedResult = try finish(&operation,session)
    try check(try encoder.encode(repeatedResult) == encoder.encode(result) && session.rng == after && session.people.person(0).experience == afterEXP,
        "finished physical continuation does not repeat damage, draws, EXP or completion")
    let synchronous = try fixture(classID:3);try synchronous.people.update(0) {$0.rawTroops = 1}
    let synchronousResult = try synchronous.attack(0,target:15,afterRetirement:{notice in
        if notice.sequence == 0 {try replaceCounterTarget(synchronous)}
    })
    try check(try encoder.encode(result) == encoder.encode(synchronousResult) && synchronous.exchanges.count == 1,
        "synchronous attack uses the identical operation and records its result once")

    let changedOther = try fixture();try changedOther.people.update(0) {$0.rawTroops = 1}
    var changedOperation = try OriginalAttackOperation.begin(in:changedOther,attackerSlot:0,targetSlot:15)
    let changedResult = try finish(&changedOperation,changedOther,retirement:{_ in try changedOther.people.update(1) {$0.rawTroops = 0}})
    try check(changedOperation.retirementChecks.map(\.runtimeSlot) == [0,0] && changedResult.fallenPeople == [0] && changedOther.units[15]!.status == 2 && changedOther.people.person(1).rawTroops == 0,
        "recursive return never restores and scans a different logical target, even when its HP changed in the script")

    let lethal = try fixture();try lethal.people.update(1) {$0.rawTroops = 1}
    var lethalOperation = try OriginalAttackOperation.begin(in:lethal,attackerSlot:0,targetSlot:15)
    guard case .context(let lethalHit) = try lethalOperation.advance(in:lethal),
          case .retirement(let lethalNotice) = try lethalOperation.advance(in:lethal) else {throw BattleError.invalid("Expected lethal outer target notice")}
    try check(!lethalHit.strike.counterEligible && lethalNotice.runtimeSlot == 15 && lethalOperation.contexts.count == 1 && lethal.units[0]!.scriptFlags&0x80 == 0,
        "a lethal primary skips recursion but still waits before the caller's acted flag")
    try lethalOperation.resumeRetirement(lethalNotice);_ = try finish(&lethalOperation,lethal)
    try check(lethalOperation.retirementChecks.map(\.runtimeSlot) == [15],"non-counter exchange has only its source outer retirement check")

    let disabled = try fixture();disabled.units[15]!.morale = 1
    var disabledOperation = try OriginalAttackOperation.begin(in:disabled,attackerSlot:0,targetSlot:15)
    guard case .context(let eligible) = try disabledOperation.advance(in:disabled),
          case .retirement(let disabledNotice) = try disabledOperation.advance(in:disabled) else {throw BattleError.invalid("Expected low-morale retirement")}
    try check(eligible.strike.counterEligible && disabled.units[15]!.scriptFlags&2 != 0 && disabledOperation.contexts.count == 1 && disabledNotice.runtimeSlot == 15,
        "post-writeback condition2 suppresses a previously eligible counter before retiring the morale-zero target")

    let aliases = try fixture();aliases.units[15]!.person = 0
    try aliases.people.update(0) {$0.attackScalar = 100}
    var aliasOperation = try OriginalAttackOperation.begin(in:aliases,attackerSlot:0,targetSlot:15)
    let aliasResult = try finish(&aliasOperation,aliases)
    try check(aliasOperation.contexts.count == 2 && aliasOperation.contexts[1].attackerPerson == 0 && aliasOperation.contexts[1].targetPerson == 0,
        "distinct opposing live slots retain one shared person through recursive contexts")
    try check(try aliases.people.person(0).rawTroops == aliasResult.strike.remainingTroops-aliasResult.counter!.damage && aliases.units[0]!.status == 2 && aliases.units[15]!.status == 2,
        "aliased troop writeback remains shared while source live status stays per slot")

    let silent = try fixture();silent.units[15]!.scriptFlags |= 4;try silent.people.update(1) {$0.rawTroops = 1}
    var silentOperation = try OriginalAttackOperation.begin(in:silent,attackerSlot:0,targetSlot:15)
    let silentResult = try finish(&silentOperation,silent)
    try check(silentResult.fallenPeople == [1] && silent.retirements.isEmpty && silentOperation.pendingRetirement == nil,
        "suppressed source retirement changes status without inventing a campaign wait")
    let invalid = try fixture(),invalidRNG = invalid.rng,invalidFlags = invalid.units[0]!.scriptFlags
    do {_ = try OriginalAttackOperation.begin(in:invalid,attackerSlot:0,targetSlot:0);throw BattleError.invalid("Invalid physical target accepted")}
    catch BattleError.illegalAction {try check(invalid.rng == invalidRNG && invalid.units[0]!.scriptFlags == invalidFlags,"rejected physical selection changes neither RNG nor facing")}
    let hosted = try fixture(classID:3);hosted.turns.stage = .manualFriendly
    try hosted.people.update(0) {$0.rawTroops = 1}
    let flow = OriginalBattleFlow(session:hosted)
    var notices = 0
    flow.onRetirement = {_ in notices += 1;return false}
    let pending = try flow.manualAttack(0,target:15)
    let hostedRNG = hosted.rng
    try check(pending == nil && flow.suspended && !flow.acceptsManualInput && hosted.exchanges.isEmpty && hosted.units[0]!.scriptFlags&0x80 == 0,
        "native physical flow retains an unfinished exchange while retirement dialogue is pending")
    hosted.turns.result = 3
    try check(!flow.canLeaveBattle,"a source loss result cannot discard the pending recursive return")
    try flow.resumeSourceFlow()
    try check(flow.canLeaveBattle && flow.lastAttack?.counter != nil && hosted.exchanges.count == 1 && hosted.units[0]!.scriptFlags&0x80 != 0 && notices == 1,
        "source-finished battle still completes its physical caller once after retirement returns")
    try flow.resumeSourceFlow()
    try check(hosted.rng == hostedRNG && hosted.exchanges.count == 1 && notices == 1,
        "repeated host-ready delivery cannot replay the completed physical exchange")
    print("Original attack operation self-tests passed: \(checks)")
}
