// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func originalScriptBattleSelfTests() throws {
    var checks = 0
    func check(_ test:@autoclosure() throws -> Bool,_ reason:String) throws {
        guard try test() else { throw BattleError.invalid("Original script battle self-test: \(reason)") }; checks += 1
    }
    let combat = OriginalCombatTables(format:1,attackBase:Array(repeating:10,count:19),
        defenseBase:Array(repeating:10,count:19),troopBase:Array(repeating:2,count:19),
        troopGrowth:Array(repeating:3,count:19),physicalSubtypeByClass:Array(repeating:0,count:19),
        terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),
        items:(0..<64).map{OriginalItemEffect(id:$0,category:15,value:0)})
    let catalog = OriginalPersonCatalog(format:1,people:(0..<384).map { id in
        OriginalPersonDefinition(id:id,name:"synthetic \(id)",classID:0,level:1,experience:0,rawTroops:200,
            defenseScalar:50,attackScalar:50,intellectScalar:50,personality:0,personalScalar:0,
            itemIDs:Array(repeating:255,count:8),sourceFlags:id == 0 ? 0 : 1,sourceRole:0,sourceContext2:0,sourceContext3:0)
    })
    let people = try OriginalPeople(catalog:catalog,tables:combat)
    let offsets = [OriginalAIOffset(dx:0,dy:-1),OriginalAIOffset(dx:1,dy:0),OriginalAIOffset(dx:0,dy:1),OriginalAIOffset(dx:-1,dy:0)]
    var modes = Array(repeating:2,count:256);modes[4] = 5;modes[8] = 9
    var costs = Array(repeating:Array(repeating:1,count:256),count:4);costs[0][1] = 255
    let movement = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),
        classMovementBudgets:Array(repeating:3,count:19),attackRangeCodes:Array(repeating:0,count:19),movementCosts:costs,
        cardinalOffsets:offsets,diagonalOffsets:offsets,extendedOffsets:offsets,setupOrderModes:modes)
    var roster = OriginalRoster();roster.header = OriginalBattleHeader(preserveFriendlySlots:false,turnLimit:10,sourceByte2:0,discardedBytes:[],objectives:[])
    roster.slots[0] = OriginalPlacement(ordinal:0,person:0,x:1,y:1,selector:0,flag:0,flags:0,rawMode:0,parameter:0,classID:0,level:1)
    roster.slots[1] = OriginalPlacement(ordinal:1,person:1,x:3,y:1,selector:0,flag:0,flags:1,rawMode:0,parameter:0,classID:0,level:1)
    var terrain = Array(repeating:0,count:25);terrain[4] = 1
    let session = try OriginalBattleSession(definition:BattleDefinition(id:"synthetic-script",width:5,height:5,tiles:terrain),
        roster:&roster,people:people,combat:combat,movement:movement,rng:OriginalRNG(state:1))
    session.units[2] = OriginalLiveUnit(slot:2,person:2,position:GridPoint(x:4,y:4),status:4,mp:0)
    session.units[16] = OriginalLiveUnit(slot:16,person:1,position:GridPoint(x:4,y:3),status:1,mp:0)
    session.units[0]!.scriptFlags |= 4;session.units[0]!.goal = GridPoint(x:0,y:0)
    let manual = try session.applyScriptAttribute(arguments:[0,3,2])
    try check(!manual.modeSetterApplied && manual.targetSetterApplied && session.units[0]!.orderMode == 7,
              "manual affiliation gate suppresses mode only, not the later target setter")
    try check(session.units[0]!.preferredTarget == 2 && session.units[0]!.scriptFlags&4 == 0 && session.units[0]!.goal == GridPoint(x:0,y:0),
              "preferred lookup includes retired slots and retains stored coordinates")
    let goal = try session.applyScriptAttribute(arguments:[1,4,2,3])
    try check(goal.runtimeSlot == 15 && goal.goalSetterApplied && session.units[15]!.goal == GridPoint(x:2,y:3),
              "source person lookup selects first runtime match and applies typed x/y bytes")
    try check(session.units[15]!.orderMode == 5 && session.units[16]!.goal == nil,"script mode table and first-slot ownership")
    session.units[0]!.scriptFlags |= 4
    let blocked = try session.applyScriptAttribute(arguments:[0,4,4,0])
    try check(!blocked.goalSetterApplied && session.units[0]!.scriptFlags&4 == 0 && session.units[0]!.preferredTarget == 2,
              "blocked goal clears flag4 but preserves prior goal and preferred target")
    session.units[0]!.scriptFlags |= 4
    let absentTarget = try session.applyScriptAttribute(arguments:[0,3,999])
    try check(!absentTarget.targetSetterApplied && session.units[0]!.scriptFlags&4 != 0,
              "missing target does not invoke target setter after a declined manual mode setter")
    let ignored = try session.applyScriptAttribute(arguments:[1,0,60000])
    try check(ignored.modeSetterApplied && session.units[15]!.orderMode == 2,"selectors0..2 consume their typed word without treating it as a stat")
    let absent = try session.applyScriptAttribute(arguments:[999,3,2])
    try check(absent.runtimeSlot == nil,"missing source person is a no-op without fabricated live slot")
    _ = try session.applyScriptAttribute(arguments:[1,8])
    try check(session.units[15]!.orderMode == 2,"source mode values above7 leave current mode unchanged")
    let before = session.units
    do {_ = try session.applyScriptAttribute(arguments:[1,4,250,3]);throw EngineError.invalid("out-of-map script goal accepted")}
    catch BattleError.unsupported {try check(session.units == before,"out-of-map source lookup retains uncertainty without partial changes")}
    let item = try people.grantScriptItem(person:0,itemID:5)
    try check(item.insertedSlot == 0 && people.person(0).itemIDs[0] == 5,"script item gift uses first empty inventory slot")
    let duplicate = try people.grantScriptItem(person:0,itemID:5)
    try check(duplicate.insertedSlot == 1,"source insertion does not invent duplicate-item rejection")
    try people.update(0) {$0.itemIDs = [7,7,8,9,10,11,12,13]}
    let full = try people.person(0).itemIDs
    do {_ = try people.grantScriptItem(person:0,itemID:6);throw EngineError.invalid("full inventory silently replaced an item")}
    catch BattleError.unsupported {try check(try people.person(0).itemIDs == full,"full inventory requires explicit replacement input")}
    let cancelled = try people.grantScriptItem(person:0,itemID:6,replacementChoice:255)
    try check(cancelled.cancelled && people.person(0).itemIDs == full,"source replacement cancellation retains inventory")
    let replacement = try people.grantScriptItem(person:0,itemID:6,replacementChoice:1)
    try check(replacement.insertedSlot == 0 && replacement.replacedItemID == 7 && people.person(0).itemIDs[1] == 7,
              "source duplicate replacement selects the first slot matching the chosen old item ID")
    print("Original script battle self-tests passed: \(checks)")
}
