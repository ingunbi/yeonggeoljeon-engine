// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func originalIntegrationSelfTests() throws {
    var checks = 0
    func check(_ value:Bool,_ reason:String) throws { checks += 1;if !value { throw EngineError.invalid("Original integration regression: \(reason)") } }
    let tables = OriginalCombatTables(format:1,attackBase:Array(repeating:10,count:19),defenseBase:Array(repeating:10,count:19),
        troopBase:Array(repeating:10,count:19),troopGrowth:Array(repeating:2,count:19),physicalSubtypeByClass:Array(repeating:0,count:19),
        terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),
        items:(0..<64).map{OriginalItemEffect(id:$0,category:0,value:0)})
    let offsets = [OriginalAIOffset(dx:0,dy:-1),OriginalAIOffset(dx:1,dy:0),OriginalAIOffset(dx:0,dy:1),OriginalAIOffset(dx:-1,dy:0)]
    let diagonals = [OriginalAIOffset(dx:-1,dy:-1),OriginalAIOffset(dx:1,dy:-1),OriginalAIOffset(dx:1,dy:1),OriginalAIOffset(dx:-1,dy:1)]
    let profile = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),classMovementBudgets:Array(repeating:3,count:19),
        attackRangeCodes:Array(repeating:0,count:19),movementCosts:Array(repeating:Array(repeating:1,count:256),count:4),
        cardinalOffsets:offsets,diagonalOffsets:diagonals,extendedOffsets:offsets,setupOrderModes:Array(repeating:2,count:256),
        strategyLevelRequirements:Array(repeating:Array(repeating:255,count:19),count:36),strategyMPCosts:Array(repeating:255,count:36),strategyCategories:Array(repeating:0,count:36))
    let catalog = OriginalPersonCatalog(format:1,people:(0..<384).map { id in
        OriginalPersonDefinition(id:id,name:"synthetic\(id)",classID:0,level:1,experience:99,rawTroops:65535,
            defenseScalar:40,attackScalar:60,intellectScalar:50,personality:0,personalScalar:25,itemIDs:Array(repeating:255,count:8),
            sourceFlags:0,sourceRole:0,sourceContext2:0,sourceContext3:0)
    })
    let people = try OriginalPeople(catalog:catalog,tables:tables)
    try check(try people.person(0).rawTroops == 1000,"source constructor clamps once")
    let header = OriginalBattleHeader(preserveFriendlySlots:false,turnLimit:2,sourceByte2:0,discardedBytes:[0,0],objectives:[])
    let placements = [OriginalPlacement(ordinal:0,person:0,x:1,y:1,selector:0,flag:0,flags:0,rawMode:255,parameter:65535,classID:255,level:255),
        OriginalPlacement(ordinal:1,person:0,x:1,y:2,selector:0,flag:0,flags:0,rawMode:255,parameter:65535,classID:255,level:255),
        OriginalPlacement(ordinal:2,person:1,x:2,y:1,selector:0,flag:0,flags:1,rawMode:0,parameter:0,classID:0,level:1)]
    var roster = OriginalRoster();roster.header = header
    for (index,placement) in placements.enumerated() { roster.slots[index] = placement }
    let definition = BattleDefinition(id:"synthetic",width:5,height:5,coordinateSystem:"orthogonal",tiles:Array(repeating:0,count:25))
    let session = try OriginalBattleSession(definition:definition,roster:&roster,people:people,combat:tables,movement:profile,rng:OriginalRNG(state:4))
    try check(Set(session.units.keys) == Set([0,1,15]),"source runtime slot partition")
    try check(session.units[0]!.orderMode == 7 && session.units[0]!.scriptFlags == 0x30,"manual gate and source activation orientation bit")
    try people.update(0) { $0.rawTroops = 777 }
    try check(try people.stats(session.units[1]!.person,morale:100).troops == 777,"unit aliases share one person object")
    try people.update(0) { $0.rawTroops = 0 }
    try check(try session.board().occupant(GridPoint(x:1,y:2))?.runtimeSlot == 1 && session.live(1).status == 2,"zero-troop aliases retain independent active status and occupancy")
    try people.update(0) { $0.rawTroops = 777 }
    _ = try session.beginRound();_ = try session.prepareFriendlyRound();try session.enterManualFriendly()
    _ = try session.move(1,to:GridPoint(x:0,y:2));try session.cancelMove(1)
    try check(session.units[1]!.position == GridPoint(x:1,y:2) && session.units[1]!.scriptFlags&0x40 == 0,"source menu cancellation restores position and move flag")
    let hp = try people.person(0).rawTroops
    let result = try session.attack(0,target:15)
    try check(result.strike.damage > 0,"restored producer used in session")
    try check(try people.person(0).level == 2 && people.person(0).rawTroops <= hp,"EXP level-up does not heal current troops")
    try check(try people.person(1).rawTroops == 1000-result.strike.damage,"target writeback belongs to shared person")
    do { _ = try session.move(0,to:GridPoint(x:0,y:1));throw EngineError.invalid("attack allowed a subsequent move") }
    catch BattleError.illegalAction { checks += 1 }
    try people.setAffiliation(person:2,value:255)
    try check(try people.person(2).sourceFlags == 31,"source affiliation mask preserves separate high bits")
    var resumedRoster = roster
    resumedRoster.header!.objectives = [OriginalObjective(eventKind:7,enabled:true,person:1)]
    let resumedPeople = try OriginalPeople(catalog:catalog,tables:tables)
    let resumed = try OriginalBattleSession(definition:definition,roster:&resumedRoster,people:resumedPeople,
        combat:tables,movement:profile,rng:OriginalRNG(state:7))
    let flow = OriginalBattleFlow(session:resumed)
    var hookCalls = 0,objectiveCalls = 0
    flow.onHook = {_ in hookCalls += 1;return false}
    try flow.start()
    try check(flow.suspended && resumed.turns.stage == .roundEvent,"numbered-turn script suspends before upkeep")
    try flow.resumeSourceFlow()
    try check(flow.suspended && resumed.turns.stage == .globalEvent && hookCalls == 2,"global script resumes after one upkeep without repeating the numbered hook")
    try flow.resumeSourceFlow()
    try check(flow.acceptsManualInput && hookCalls == 2,"manual input begins after source hook completion")
    flow.onHook = {_ in hookCalls += 1;return true}
    flow.onRetirement = {notice in
        guard notice.runtimeSlot == 15,notice.person == 1 else { throw EngineError.invalid("Wrong original retirement identity") }
        objectiveCalls += 1;return false
    }
    try resumedPeople.update(1) {$0.rawTroops = 1}
    _ = try flow.manualAttack(0,target:15)
    let afterAttackRNG = resumed.rng.state
    try check(flow.suspended && objectiveCalls == 1 && resumed.units[15]?.status == 4,"objective script suspends after its committed strike")
    try flow.resumeSourceFlow()
    try check(flow.acceptsManualInput && objectiveCalls == 1 && resumed.rng.state == afterAttackRNG && hookCalls == 3,"objective continuation does not repeat combat, RNG or delivery")
    print("Original integration self-tests: \(checks) assertions passed")
}

/// The same typed manual-input route used by OriginalBattleView, without an
/// AppKit event loop. This verifies flow suspension, not OS key delivery.
func originalStrategyFlowInputSelfTests() throws {
    var checks = 0
    func check(_ value:@autoclosure() throws -> Bool,_ reason:String) throws {
        guard try value() else {throw EngineError.invalid("Original strategy input flow: \(reason)")};checks += 1
    }
    func rejects(_ action:() throws -> Void) throws {
        do {try action()} catch BattleError.illegalAction {checks += 1;return}
        throw EngineError.invalid("Original strategy input flow expected input rejection")
    }
    let combat = OriginalCombatTables(format:1,attackBase:Array(repeating:10,count:19),defenseBase:Array(repeating:10,count:19),
        troopBase:Array(repeating:10,count:19),troopGrowth:Array(repeating:0,count:19),physicalSubtypeByClass:Array(repeating:0,count:19),
        terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),
        items:(0..<64).map{OriginalItemEffect(id:$0,category:15,value:0)})
    let catalog = OriginalPersonCatalog(format:1,people:(0..<384).map {id in
        OriginalPersonDefinition(id:id,name:"synthetic \(id)",classID:0,level:10,experience:0,rawTroops:1000,
            defenseScalar:100,attackScalar:100,intellectScalar:id == 0 ? 100 : 0,personality:0,personalScalar:0,
            itemIDs:Array(repeating:255,count:8),sourceFlags:id == 0 ? 0 : 1,sourceRole:0,sourceContext2:0,sourceContext3:0)
    })
    let people = try OriginalPeople(catalog:catalog,tables:combat)
    let cardinal = [OriginalAIOffset(dx:0,dy:-1),.init(dx:1,dy:0),.init(dx:0,dy:1),.init(dx:-1,dy:0)]
    var requirements = Array(repeating:Array(repeating:255,count:19),count:36);requirements[3][0] = 0
    var costs = Array(repeating:255,count:36);costs[3] = 2
    let movement = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),classMovementBudgets:Array(repeating:3,count:19),
        attackRangeCodes:Array(repeating:0,count:19),movementCosts:Array(repeating:Array(repeating:1,count:256),count:4),
        cardinalOffsets:cardinal,diagonalOffsets:cardinal,extendedOffsets:cardinal,setupOrderModes:Array(repeating:2,count:256),
        strategyLevelRequirements:requirements,strategyMPCosts:costs,strategyCategories:Array(repeating:0,count:36),
        strategyTerrainEligibility:Array(repeating:[0,1,255,255],count:3))
    var roster = OriginalRoster();roster.header = OriginalBattleHeader(preserveFriendlySlots:false,turnLimit:10,sourceByte2:0,discardedBytes:[],objectives:[])
    for (id,point) in [GridPoint(x:1,y:1),GridPoint(x:2,y:1),GridPoint(x:2,y:0),GridPoint(x:3,y:1)].enumerated() {
        roster.slots[id] = OriginalPlacement(ordinal:id,person:id,x:point.x,y:point.y,selector:0,flag:0,flags:id == 0 ? 0 : 1,
            rawMode:0,parameter:0,classID:0,level:10)
    }
    let session = try OriginalBattleSession(definition:BattleDefinition(id:"synthetic-strategy-input",width:5,height:5,tiles:Array(repeating:0,count:25)),
        roster:&roster,people:people,combat:combat,movement:movement,rng:OriginalRNG(state:2))
    session.turns.stage = .manualFriendly
    let flow = OriginalBattleFlow(session:session)
    try check(try movement.availableStrategies(classID:0,level:10,mp:50) == [3] && movement.availableStrategies(classID:0,level:10,mp:1).isEmpty,
        "source class/level/MP facts own the native ability list")
    let before = session.rng
    try rejects {_ = try flow.manualStrategy(0,abilityID:3,target:999)}
    try check(flow.acceptsManualInput && session.rng == before && session.units[0]!.mp == 50,
        "illegal target input leaves the source command and its costs unstarted")
    let cancelled = try flow.manualStrategy(0,abilityID:3,target:nil)
    try check(cancelled?.completed == false && flow.acceptsManualInput && session.rng == before && session.units[0]!.mp == 50 && session.units[0]!.scriptFlags&0x80 == 0,
        "cancelled source target selection keeps movement/action input available without charging MP")
    let priorExecutions = session.strategyExecutions.count
    var delivered:[OriginalRetirementNotice] = []
    flow.onRetirement = {notice in delivered.append(notice);return false}
    try people.update(1) {$0.rawTroops = 1}
    let result = try flow.manualStrategy(0,abilityID:3,target:15)
    let waitingRNG = session.rng
    try check(result == nil && flow.suspended && !flow.acceptsManualInput && delivered.count == 1,
        "manual target input returns a pending operation while the source retirement script waits")
    try check(try people.person(2).rawTroops == 1000 && session.units[0]!.mp == 50 && session.units[0]!.scriptFlags&0x80 == 0 && session.strategyExecutions.count == priorExecutions,
        "remaining targets and final command costs stay untouched during the source wait")
    try rejects {try flow.manualWait(0)}
    try rejects {try flow.finishManual()}
    try rejects {_ = try flow.manualStrategy(0,abilityID:3,target:16)}
    try check(session.rng == waitingRNG && delivered.count == 1,"rejected input cannot repeat RNG or retirement delivery")
    session.units[16]!.status = 4
    session.units[19] = OriginalLiveUnit(slot:19,person:4,position:GridPoint(x:2,y:0),status:2,mp:0)
    try flow.resumeSourceFlow()
    try check(flow.acceptsManualInput && !flow.suspended && flow.lastStrategy?.targets.map(\.runtimeSlot) == [15,19,17],
        "resumed source operation re-reads target occupancy before completing the remaining AoE")
    try check(session.units[0]!.mp == 48 && session.units[0]!.scriptFlags&0x80 != 0 && session.strategyExecutions.count == priorExecutions+1 && delivered.count == 1,
        "resumed manual command records and charges its completion exactly once")
    let finalRNG = session.rng,finalEXP = try people.person(0).experience
    try flow.resumeSourceFlow()
    try check(try session.rng == finalRNG && people.person(0).experience == finalEXP && session.units[0]!.mp == 48 && session.strategyExecutions.count == priorExecutions+1,
        "repeated source-ready notification does not re-execute the finished manual command")
    print("Original strategy input flow self-tests passed: \(checks)")
}
