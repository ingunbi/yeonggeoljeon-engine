// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private func scriptActionFixture() throws -> OriginalBattleSession {
    let tables = OriginalCombatTables(format:1,attackBase:Array(repeating:10,count:19),defenseBase:Array(repeating:10,count:19),
        troopBase:Array(repeating:10,count:19),troopGrowth:Array(repeating:0,count:19),physicalSubtypeByClass:Array(repeating:1,count:19),
        terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),
        items:(0..<64).map{OriginalItemEffect(id:$0,category:15,value:0)})
    let cardinal = [OriginalAIOffset(dx:0,dy:-1),.init(dx:1,dy:0),.init(dx:0,dy:1),.init(dx:-1,dy:0)]
    var profile = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),classMovementBudgets:Array(repeating:3,count:19),
        attackRangeCodes:Array(repeating:0,count:19),movementCosts:Array(repeating:Array(repeating:1,count:256),count:4),
        cardinalOffsets:cardinal,diagonalOffsets:[.init(dx:1,dy:-1),.init(dx:1,dy:1),.init(dx:-1,dy:1),.init(dx:-1,dy:-1)],
        extendedOffsets:cardinal,setupOrderModes:Array(repeating:3,count:256))
    var environment = OriginalScriptEnvironmentTables(markerTerrain:Array(repeating:7,count:256),toggleTerrain:Array(repeating:9,count:256),
        pictureDeltas:[Array(repeating:1,count:128),Array(repeating:5,count:128)],remapFrom:[1,2,17,18,19,20,21,22,23],
        remapTo:[2,0xD3,117,118,119,120,121,122,123],specialMapIndices:Array(repeating:33,count:19))
    environment.toggleTerrain[0] = 1;environment.toggleTerrain[1] = 2;environment.toggleTerrain[2] = 3;environment.toggleTerrain[3] = 4
    profile.scriptEnvironment = environment
    let catalog = OriginalPersonCatalog(format:1,people:(0..<384).map { id in
        OriginalPersonDefinition(id:id,name:"synthetic\(id)",classID:0,level:1,experience:0,rawTroops:1000,
            defenseScalar:50,attackScalar:50,intellectScalar:50,personality:0,personalScalar:0,itemIDs:Array(repeating:255,count:8),
            sourceFlags:id == 5 ? 1 : 0,sourceRole:0,sourceContext2:0,sourceContext3:0)
    })
    let people = try OriginalPeople(catalog:catalog,tables:tables)
    var roster = OriginalRoster();roster.header = OriginalBattleHeader(preserveFriendlySlots:false,turnLimit:1,sourceByte2:0,discardedBytes:[],objectives:[])
    roster.slots[0] = OriginalPlacement(ordinal:0,person:0,x:1,y:1,selector:0,flag:0,flags:0,rawMode:0,parameter:0,classID:0,level:1)
    roster.slots[1] = OriginalPlacement(ordinal:1,person:0,x:1,y:2,selector:0,flag:0,flags:0,rawMode:0,parameter:0,classID:0,level:1)
    roster.slots[2] = OriginalPlacement(ordinal:2,person:5,x:3,y:1,selector:0,flag:0,flags:1,rawMode:0,parameter:0,classID:0,level:1)
    var terrain = Array(repeating:0,count:25);terrain[12] = 1
    var pictures = Array(repeating:10,count:100)
    for (index,value) in zip([44,45,54,55],[0xC5,0xC6,254,0]) { pictures[index] = value }
    let definition = BattleDefinition(id:"synthetic-actions",width:5,height:5,tiles:terrain,
        pictureColumns:10,pictureRows:10,pictureTiles:pictures)
    return try OriginalBattleSession(definition:definition,roster:&roster,people:people,combat:tables,movement:profile,rng:OriginalRNG(state:4))
}

func originalScriptActionSelfTests() throws {
    var checks = 0
    func check(_ value:@autoclosure() throws -> Bool,_ message:String) throws {
        guard try value() else { throw BattleError.invalid("Original script action self-test: \(message)") };checks += 1
    }
    let duel = try scriptActionFixture()
    let quantity = try duel.people.person(0).rawTroops
    _ = try duel.applyScriptAction(opcode:2,arguments:[6])
    try check(duel.scriptActions.contextByte0 == 6 && duel.turns.result == 0,"source action-manager byte0 is distinct from battle result")
    let begin = try duel.applyScriptAction(opcode:0x10,arguments:[0,5])
    try check(begin.sourceReturn == 1 && duel.scriptActions.duel?.people == [0,5],"duel setup resolves source person identities")
    try check(duel.scriptActions.duel?.positions == [4,16],"source duel entry ends at native presentation coordinates")
    try check(duel.scriptActions.duel?.loadModes == [0,1],"source duel setup initializes both graphic load identities")
    let clash = try duel.applyScriptAction(opcode:0x34,arguments:[])
    try check(clash.rngBounds == [3,3,2,2,3,3,3,3,3,3,2,2,3,3,2,2] && duel.rng.state == 3806687796,
        "duel presentation consumes source random poses and conditional sound draws")
    try check(try duel.people.person(0).rawTroops == quantity && duel.units[15]!.status == 2,
        "duel presentation does not invent physical damage or retirement")
    for motion in [0,1,0,10] { _ = try duel.applyScriptAction(opcode:0x35,arguments:[0,motion]) }
    _ = try duel.applyScriptAction(opcode:0x35,arguments:[5,3])
    try check(duel.scriptActions.duel?.loadModes == [0,2],"death motion replaces the second graphic buffer before its final pose")
    _ = try duel.applyScriptAction(opcode:0x35,arguments:[0,9])
    _ = try duel.applyScriptAction(opcode:0x35,arguments:[0,2])
    try check(duel.scriptActions.duel?.positions == [10,1] && duel.scriptActions.duel?.camera == 14,
        "scripted duel attack and camera mutations preserve source word/byte coordinates")
    try check(duel.scriptActions.duel?.frames == [9,4],"source duel motion frames remain separate from gameplay stats")
    let finish = try duel.applyScriptAction(opcode:0x33,arguments:[])
    try check(duel.scriptActions.duel?.active == false && finish.presentationOnly && !finish.presentationTimingRestored,
        "duel completion records missing native render timing without inventing game effects")
    let flight = try scriptActionFixture()
    _ = try flight.applyScriptAction(opcode:0x10,arguments:[0,5])
    _ = try flight.applyScriptAction(opcode:0x35,arguments:[0,4])
    try check(flight.scriptActions.duel?.loadModes == [0,3] && flight.scriptActions.duel?.positions == [4,30],
        "flee motion reloads and moves participant1 even when the named person is participant0")
    let restoredDuel = try JSONDecoder().decode(OriginalScriptDuel.self,from:JSONEncoder().encode(flight.scriptActions.duel!))
    try check(restoredDuel.loadModes == [0,3],"saved native duel state retains its reloaded graphic identity")
    _ = try flight.applyScriptAction(opcode:0x10,arguments:[5,0])
    try check(flight.scriptActions.duel?.loadModes == [0,1],"fresh source duel context resets graphic load identities")
    let side = try scriptActionFixture()
    side.units[0]!.morale = 59;side.units[1]!.morale = 80
    var expected = side.rng;_ = try expected.next(bound:5)
    _ = try side.applyScriptAction(opcode:0x2D,arguments:[0,0])
    try check(side.units[0]!.morale == 29 && side.units[1]!.morale == 40 && side.rng == expected,
        "side morale halving uses the source morale setter and its low-morale RNG")
    let halved = try side.applyScriptAction(opcode:0x2D,arguments:[0,1])
    try check(try side.people.person(0).rawTroops == 250 && halved.changedPeople == [0,0],
        "side troop halving visits aliased live slots rather than deduplicating shared people")
    try check(side.units[0]!.status == 2 && side.units[1]!.status == 2,"halving does not add an unobserved retirement effect")
    let transfer = try side.applyScriptAction(opcode:0x28,arguments:[5,0])
    try check(transfer.changedSlots == [15,2] && side.units[15]!.status == 0 && side.units[2]!.status == 2,
        "source side transfer copies to the first opposite inactive runtime slot")
    try check(side.units[2]!.person == 5 && side.units[2]!.orderMode == 7 && side.units[2]!.goal == side.units[15]!.position,
        "source transfer resets cache/goal and applies the friendly affiliation order gate")
    try check(try side.people.person(5).sourceFlags&31 == 0,"source transfer updates shared affiliation")
    let environment = try scriptActionFixture()
    _ = try environment.applyScriptAction(opcode:0x26,arguments:[2,2,0],mapIndex:0)
    try check(environment.terrain[12] == 2 && [44,45,54,55].map{environment.pictureTiles![$0]} == [0xC7,0xE6,255,1],
        "source tile toggle preserves exceptional picture IDs and byte delta wrapping")
    _ = try environment.applyScriptAction(opcode:0x26,arguments:[2,2,1],mapIndex:33)
    try check(environment.terrain[12] == 1 && environment.pictureTiles![54] == 4,"source map variant selects its original signed picture delta")
    _ = try environment.applyScriptAction(opcode:0x27,arguments:[2,2,0])
    try check(environment.terrain[12] == 7 && environment.scriptActions.markers[GridPoint(x:2,y:2)] == 45,
        "environment marker changes terrain separately from active unit occupancy")
    _ = try environment.applyScriptAction(opcode:0x27,arguments:[2,2,2])
    try check(environment.terrain[12] == 1 && environment.scriptActions.environment.count == 2,
        "source marker restoration removes the first matching backup even across action kinds")
    let blocked = try environment.applyScriptAction(opcode:0x27,arguments:[1,1,0])
    try check(blocked.changedCells.isEmpty && environment.terrain[6] == 0,"active unit occupancy prevents source marker mutation")
    for index in [66,67,76,77] { environment.pictureTiles![index] = 1 }
    _ = try environment.applyScriptAction(opcode:0x26,arguments:[3,3,2])
    try check([66,67,76,77].allSatisfy{environment.pictureTiles![$0] == 0xD3} && environment.terrain[18] == 4,
        "source special picture remap cascades across records before testing terrain mutation")
    let backups = environment.scriptActions.environment.count
    _ = try environment.applyScriptAction(opcode:0x26,arguments:[3,3,130])
    try check(environment.scriptActions.environment.count == backups,"source high bit suppresses environment backup insertion")
    let map = try scriptActionFixture()
    var setup = OriginalRoster()
    setup.slots[0] = OriginalPlacement(ordinal:0,person:5,x:2,y:3,selector:0,flag:0,flags:0,rawMode:0,parameter:0,classID:0,level:1)
    map.units[15]!.status = 1;map.units[15]!.aiPriority = 29
    let placed = try map.applyScriptMapCommand(Command("place",person:5,x:4,y:4,facing:0),roster:setup)
    try check(placed.sourceReturn == 1 && map.units[15]!.status == 2 && map.units[15]!.position == GridPoint(x:2,y:3),
        "battle place activates from setup coordinates rather than the independent VM actor cache")
    try check(map.units[15]!.scriptFlags&0x10 != 0 && map.units[15]!.aiPriority == 29,
        "source activation flip uses flag10 and preserves the separate AI priority byte")
    let moved = try map.applyScriptMapCommand(Command("move",person:5,x:4,y:3,facing:6),roster:setup)
    try check(map.units[15]!.position == GridPoint(x:4,y:3) && map.units[15]!.orderMode == 3 && moved.movementPath?.count == 3,
        "battle move executes the source flag4 goal controller and arrival order transition")
    try check(map.units[15]!.scriptFlags&0xC4 == 0 && moved.rngBefore == moved.rngAfter,
        "scripted movement clears C4 after suppressing attack and retains the exact no-RNG branch")
    map.units[0]!.preferredTarget = 15;map.units[0]!.orderMode = 0
    map.units[1]!.preferredTarget = 15;map.units[1]!.orderMode = 4
    let beforeHP = try map.people.person(5).rawTroops
    _ = try map.applyScriptMapCommand(Command("remove",person:5),roster:setup)
    try check(map.units[15]!.status == 4 && map.units[15]!.scriptFlags&4 == 0 && map.objectiveEvents.isEmpty,
        "scripted removal retires an active slot while suppressing its native objective/death effects")
    try check(map.units[0]!.preferredTarget == nil && map.units[0]!.orderMode == 1 && map.units[1]!.preferredTarget == 15,
        "scripted retirement clears cached references only for source order0")
    try check(try map.people.person(5).rawTroops == beforeHP,"scripted removal does not invent troop damage")
    map.units[0]!.status = 1;map.units[1]!.status = 2
    let firstAlias = try map.applyScriptMapCommand(Command("move",person:0,x:4,y:4,facing:3),roster:setup)
    try check(firstAlias.movementPath == nil && map.units[0]!.goal == GridPoint(x:4,y:4) && map.units[1]!.position == GridPoint(x:1,y:2),
        "native person lookup preserves the first reserved alias rather than selecting an active alias")
    let generic = try scriptActionFixture()
    generic.units[15]!.status = 1;generic.units[15]!.scriptFlags = 0xE4
    let genericPlace = try generic.applyScriptMapCommand(Command("place",person:5,x:0,y:0,sourcePlacementFacing:0),roster:setup)
    try check(genericPlace.sourceReturn == 1 && generic.units[15]!.position == GridPoint(x:2,y:3) && generic.units[15]!.scriptFlags == 0xF4,
        "opcode1A raw8 zero uses setup placement/flip and preserves action-condition flags after activation")
    generic.units[15]!.status = 1;generic.units[15]!.scriptFlags = 0xE4
    let omitted = try generic.applyScriptMapCommand(Command("place",person:5,x:0,y:0),roster:setup)
    try check(omitted.sourceReturn == 1 && generic.units[15]!.position == GridPoint(x:2,y:3) && generic.units[15]!.scriptFlags == 0xF4 && omitted.rngBefore == omitted.rngAfter,
        "native battle placement never invents a facing read or extra random effect for an omitted ignored operand")
    print("Original scripted action self-tests passed: \(checks)")
}
