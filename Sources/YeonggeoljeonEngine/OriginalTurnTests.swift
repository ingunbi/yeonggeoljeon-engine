// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func originalTurnSelfTests() throws {
    var checks = 0
    func check(_ value:@autoclosure() throws -> Bool,_ message:String) throws {
        guard try value() else { throw BattleError.invalid("Original turn self-test: \(message)") }; checks += 1
    }
    func rejects(_ action:() throws -> Void) throws {
        do { try action() } catch is BattleError { checks += 1; return }
        throw BattleError.invalid("Original turn self-test: expected source stage/input rejection")
    }
    try check(try OriginalTurnRules.weather(current:1,draw:0) == 5,"source zero endpoint remaps to5")
    try check(try OriginalTurnRules.weather(current:4,draw:5) == 0,"source five endpoint remaps to0")
    try check(try OriginalTurnRules.weather(current:2,draw:5) == 3,"weather moves one source step")
    try check(try OriginalTurnRules.weather(current:2,draw:2) == 2,"equal source weather index stays unchanged")
    try rejects {_ = try OriginalTurnRules.weather(current:6,draw:0)}
    try check(OriginalTurnRules.priorityTier(terrain:8,troops:999,maximumTroops:1000,morale:100) == 0,"recovery terrain precedes healthy units")
    try check(OriginalTurnRules.priorityTier(terrain:0,troops:400,maximumTroops:1004,morale:100) == 1,"low troop threshold divides before doubling")
    try check(OriginalTurnRules.priorityTier(terrain:0,troops:401,maximumTroops:1004,morale:40) == 2,"priority threshold is inclusive and morale40 is healthy")
    try check(OriginalTurnRules.permitsManual(slot:0,status:2,mode:7,flags:0x20),"manual native mode7 gate")
    try check(!OriginalTurnRules.permitsManual(slot:15,status:2,mode:7,flags:0x20),"enemy input cannot enter manual friendly gate")
    try check(!OriginalTurnRules.permitsManual(slot:0,status:2,mode:1,flags:0x20),"automatic friendly order stays outside manual input")
    try check(!OriginalTurnRules.permitsManual(slot:0,status:2,mode:7,flags:2),"source condition2 prevents manual movement selector")
    let tables = OriginalCombatTables(format:1,attackBase:Array(repeating:10,count:19),
        defenseBase:Array(repeating:10,count:19),troopBase:Array(repeating:2,count:19),
        troopGrowth:Array(repeating:3,count:19),physicalSubtypeByClass:Array(repeating:1,count:19),
        terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),
        items:(0..<64).map { OriginalItemEffect(id:$0,category:15,value:0) })
    let definitions = (0..<384).map { id in
        OriginalPersonDefinition(id:id,name:"synthetic \(id)",classID:0,level:1,experience:0,rawTroops:200,
            defenseScalar:50,attackScalar:50,intellectScalar:50,personality:0,personalScalar:0,
            itemIDs:Array(repeating:255,count:8),sourceFlags:id == 0 ? 0 : 1,sourceRole:0,sourceContext2:0,sourceContext3:0)
    }
    let people = try OriginalPeople(catalog:OriginalPersonCatalog(format:1,people:definitions),tables:tables)
    var movement = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),
        classMovementBudgets:Array(repeating:3,count:19),attackRangeCodes:Array(repeating:0,count:19),
        movementCosts:Array(repeating:Array(repeating:1,count:256),count:4),
        cardinalOffsets:[.init(dx:0,dy:-1),.init(dx:1,dy:0),.init(dx:0,dy:1),.init(dx:-1,dy:0)],
        diagonalOffsets:[.init(dx:1,dy:-1),.init(dx:1,dy:1),.init(dx:-1,dy:1),.init(dx:-1,dy:-1)],
        extendedOffsets:[.init(dx:1,dy:0),.init(dx:-1,dy:0),.init(dx:0,dy:1),.init(dx:0,dy:-1)])
    movement.setupOrderModes = Array(repeating:3,count:256)
    movement.strategyLevelRequirements = Array(repeating:Array(repeating:255,count:19),count:36)
    movement.strategyMPCosts = Array(repeating:255,count:36);movement.strategyCategories = Array(repeating:0,count:36)
    let header = OriginalBattleHeader(preserveFriendlySlots:false,turnLimit:1,sourceByte2:0,discardedBytes:[],objectives:[])
    let friendly = OriginalPlacement(ordinal:0,person:0,x:1,y:1,selector:0,flag:0,flags:0,rawMode:0,parameter:0,classID:0,level:1)
    let enemy = OriginalPlacement(ordinal:1,person:1,x:4,y:1,selector:0,flag:0,flags:1,rawMode:0,parameter:0,classID:0,level:1)
    var roster = OriginalRoster();roster.header = header;roster.slots[0] = friendly;roster.slots[1] = enemy
    var tiles = Array(repeating:0,count:35);tiles[5] = 14
    let definition = BattleDefinition(id:"synthetic-turn",width:7,height:5,tiles:tiles)
    let session = try OriginalBattleSession(definition:definition,roster:roster,people:people,combat:tables,movement:movement,rng:OriginalRNG(state:7))
    session.units[16] = OriginalLiveUnit(slot:16,person:2,position:GridPoint(x:6,y:2),status:2,orderMode:3,mp:0)
    session.units[17] = OriginalLiveUnit(slot:17,person:3,position:GridPoint(x:5,y:0),status:2,orderMode:3,mp:0)
    try people.update(2) {$0.rawTroops = 40}
    let priority = try session.sourceAIOrder(enemy:true)
    try check(priority == [17,16,15],"native AI priority is terrain then recovery need then runtime order")
    try people.update(2) {$0.rawTroops = 0}
    try check(try session.sourceAIOrder(enemy:true).contains(16),"source AI selection preserves status2 independently of shared troop count")
    let zeroTroopBoard = try session.board()
    try check(zeroTroopBoard.occupant(session.units[16]!.position)?.runtimeSlot == 16,
        "source occupancy retains a status2 slot whose shared person troops are zero")
    try people.update(2) {$0.rawTroops = 40}
    try rejects {try session.enterManualFriendly()}
    var expected = OriginalRNG(state:7)
    let weatherDraw = try expected.next(bound:6)
    let numbered = try session.beginRound()
    try check(numbered?.kind == .numberedRound && numbered?.round == 1,"round event uses source1-based round")
    try check(try numbered?.campaignEvent() == OriginalCampaignEvent(kind:9,arguments:[1]),"round hook maps to original event9")
    try check(session.turns.weatherIndex == OriginalTurnRules.weather(current:1,draw:weatherDraw),"weather uses the first shared source RNG draw")
    for _ in 0..<15 { _ = try expected.next(bound:11);_ = try expected.next(bound:5) }
    let global = try session.prepareFriendlyRound()
    try check(session.rng == expected,"all15 friendly slots consume upkeep draws, including14 absent slots")
    try check(try global.campaignEvent() == OriginalCampaignEvent(kind:0,arguments:[]),"global hook maps to original event0")
    try session.enterManualFriendly()
    let morale = session.units[0]!.morale
    let wait = try session.waitManually(0)
    try check(session.units[0]!.scriptFlags&0x80 != 0 && session.units[0]!.morale == morale,"wait sets acted flag without morale effect")
    try check(wait.kind == .unitConditions && wait.runtimeSlot == 0,"wait emits source unit condition wrapper hook")
    try rejects {_ = try session.waitManually(0)}
    let coordinate = try session.sourceUnitProbe(0,kind:6)
    try check(coordinate?.primary == OriginalCampaignEvent(kind:6,arguments:[0,1,1]) &&
        coordinate?.friendlyFallback == OriginalCampaignEvent(kind:6,arguments:[0x400,1,1]),"unit coordinate probe preserves source friendly wildcard fallback")
    try session.finishManualFriendly()
    try check(session.turns.pendingAI.isEmpty,"manual mode7 is excluded from friendly automatic actions")
    for _ in 15..<45 { _ = try expected.next(bound:11);_ = try expected.next(bound:5) }
    try session.prepareEnemyPhase()
    try check(session.rng == expected,"enemy upkeep includes every30 source slots in source RNG order")
    try check(session.turns.pendingAI == [17,16,15],"enemy phase uses source recovery priority")
    try rejects {_ = try session.completeNativeUnit(15)}
    session.units[17]!.status = 0;session.units[17]!.scriptFlags |= 0x80
    try session.skipNativeUnit(17)
    try check(session.turns.pendingAI == [16,15],"script-retired native unit skips without emitting an acted-bit hook")
    try rejects {try session.skipNativeUnit(16)}
    for slot in [16,15] { _ = try session.completeNativeUnit(slot) }
    try session.completeRound()
    let state = session.rng
    try check(try session.beginRound() == nil && session.turns.result == 3 && session.turns.stage == .finished,
        "source round limit returns native result3 without invented defeat condition")
    try check(session.rng == state,"turn-limit result consumes no extra weather or upkeep draws")
    print("Original turn lifecycle self-tests passed: \(checks)")
}
