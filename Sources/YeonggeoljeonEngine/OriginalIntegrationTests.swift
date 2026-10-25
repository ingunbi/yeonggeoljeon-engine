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
    let session = try OriginalBattleSession(definition:definition,roster:roster,people:people,combat:tables,movement:profile,rng:OriginalRNG(state:4))
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
    print("Original integration self-tests: \(checks) assertions passed")
}
