// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func originalPartyIntegrationSelfTests() throws {
    var checks = 0
    func check(_ test:@autoclosure() throws -> Bool,_ reason:String) throws {
        guard try test() else {throw BattleError.invalid("Original party integration: \(reason)")};checks += 1
    }
    func rejects(_ action:() throws -> Void) throws {
        do {try action()} catch {checks += 1;return}
        throw BattleError.invalid("Original party integration expected rejection")
    }
    var bases = Array(repeating:2,count:19),growth = Array(repeating:3,count:19);bases[1] = 8;growth[1] = 4
    let combat = OriginalCombatTables(format:1,attackBase:Array(repeating:10,count:19),defenseBase:Array(repeating:10,count:19),
        troopBase:bases,troopGrowth:growth,physicalSubtypeByClass:Array(repeating:0,count:19),
        terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),
        items:(0..<64).map{OriginalItemEffect(id:$0,category:15,value:0)})
    let people = try OriginalPeople(catalog:OriginalPersonCatalog(format:1,people:(0..<384).map{id in
        OriginalPersonDefinition(id:id,name:"synthetic \(id)",classID:0,level:1,experience:0,rawTroops:50,
            defenseScalar:50,attackScalar:50,intellectScalar:80,personality:0,personalScalar:0,itemIDs:Array(repeating:255,count:8),
            sourceFlags:id < 5 ? 0 : 1,sourceRole:0,sourceContext2:0,sourceContext3:0)
    }),tables:combat)
    let cardinal = [OriginalAIOffset(dx:0,dy:-1),.init(dx:1,dy:0),.init(dx:0,dy:1),.init(dx:-1,dy:0)]
    var costs = Array(repeating:Array(repeating:1,count:256),count:4);costs[0][1] = 255
    let movement = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),classMovementBudgets:Array(repeating:3,count:19),
        attackRangeCodes:Array(repeating:0,count:19),movementCosts:costs,cardinalOffsets:cardinal,diagonalOffsets:cardinal,
        extendedOffsets:cardinal,setupOrderModes:Array(repeating:3,count:256))
    func row(_ person:Int,_ x:Int,_ y:Int,_ flags:Int = 0,_ cls:Int = 0,_ level:Int = 1,_ mode:Int = 0,_ parameter:Int = 0)->OriginalPlacement {
        OriginalPlacement(ordinal:0,person:person,x:x,y:y,selector:0,flag:0,flags:flags,rawMode:mode,parameter:parameter,classID:cls,level:level)
    }
    func roster(_ preserve:Bool = false,_ resetRound:Int = 0)->OriginalRoster {
        var value = OriginalRoster();value.header = OriginalBattleHeader(preserveFriendlySlots:preserve,turnLimit:10,
            sourceByte2:resetRound,discardedBytes:[],objectives:[]);return value
    }
    let plain = BattleDefinition(id:"synthetic-party-integration",width:5,height:5,tiles:Array(repeating:0,count:25))
    var terrain = Array(repeating:0,count:25);for y in 1...3 {terrain[y*5+2] = 1}
    let blocked = BattleDefinition(id:"synthetic-party-dfs",width:5,height:5,tiles:terrain)
    var fresh = roster();fresh.slots[0] = row(0,2,4);fresh.slots[1] = row(1,2,4)
    fresh.slots[2] = row(2,3,3,2);fresh.slots[3] = row(3,255,255)
    fresh.slots[4] = row(6,4,4,5,1,3)
    let initial = try OriginalBattleSession(definition:blocked,roster:&fresh,people:people,combat:combat,movement:movement,rng:OriginalRNG(state:4))
    try check(initial.units[0]!.position == GridPoint(x:2,y:4) && initial.units[1]!.position == GridPoint(x:2,y:0),
        "fresh setup uses the shared depth-first activation producer in source row order")
    try check(initial.units[0]!.scriptFlags == 0x30 && initial.units[15]!.scriptFlags == 0x20,
        "fresh activation sets inverted source flip without changing reserved flags20")
    try check(initial.units[2]!.status == 1 && initial.units[2]!.position == GridPoint(x:255,y:255) && initial.units[2]!.scriptFlags == 0x20,
        "hidden setup retains source FF coordinates and unflipped flags20")
    try check(initial.units[3]!.status == 1 && initial.units[3]!.position == GridPoint(x:255,y:255) && people.person(3).rawTroops == 200,
        "out-of-board activation rejects placement while the later friendly HP producer still runs")
    try check(try people.person(6).classID == 1 && people.person(6).level == 3 && people.person(6).rawTroops == 880 && initial.units[15]!.mp == 26,
        "enemy class and level precede its MP and HP production")

    var carried = OriginalLiveUnit(slot:0,person:0,position:GridPoint(x:1,y:1),status:1,scriptFlags:0xF6,mp:7,aiPriority:9)
    carried.morale = 20
    let retired = OriginalLiveUnit(slot:2,person:2,position:GridPoint(x:4,y:0),status:4,mp:3)
    let staleEnemy = OriginalLiveUnit(slot:16,person:8,position:GridPoint(x:4,y:4),status:1,mp:9)
    let carry = OriginalPartyCarryover(liveSlots:[carried,retired,staleEnemy],roundIndex:3,weatherIndex:4)
    try people.update(0) {$0.rawTroops = 77}
    var preserved = roster(true);preserved.slots[0] = row(0x400,2,2,4);preserved.slots[1] = row(99,4,0)
    preserved.slots[20] = row(7,2,2,1,1,4,3,8)
    let next = try OriginalBattleSession(definition:plain,roster:&preserved,people:people,combat:combat,movement:movement,
        rng:OriginalRNG(state:5),carryover:carry)
    try check(next.units[0]!.position == GridPoint(x:2,y:1) && next.units[15]!.position == GridPoint(x:2,y:2),
        "preserved friendly activation searches around the newly spawned enemy")
    try check(next.units[0]!.morale == 20 && next.units[0]!.mp == 7 && next.units[0]!.aiPriority == 9 && people.person(0).rawTroops == 77,
        "preserved original slot retains live values and shared HP")
    try check(preserved.slots[0].person == 0 && preserved.slots[0].x == 2 && preserved.slots[0].flags == 4,
        "fallback person mutation commits to the caller's canonical setup row")
    try check(next.units[2]!.status == 4 && next.units[1] == nil && people.person(99).rawTroops == 50,
        "preserved friendly setup does not create named replacements or heal unrelated people")
    try check(next.turns.roundIndex == 3 && next.turns.weatherIndex == 4,
        "preserved source round and weather reach the native session")
    try check(next.units[15]!.preferredTarget == 16 && next.units[16] == nil,
        "source enemy target lookup sees the old slot before unused enemy reset clears its identity")
    var reset = roster(true,1);reset.slots[0] = row(0,1,1)
    let resetSession = try OriginalBattleSession(definition:plain,roster:&reset,people:people,combat:combat,movement:movement,
        rng:OriginalRNG(state:5),carryover:carry)
    try check(resetSession.turns.roundIndex == 0 && resetSession.turns.weatherIndex == 4,
        "header third byte resets only the preserved source round")

    let encode = JSONEncoder();encode.outputFormatting = [.sortedKeys]
    func peopleBytes() throws -> Data {try encode.encode(people.values.values.sorted{$0.id < $1.id})}
    let before = try peopleBytes()
    var missing = roster(true);missing.slots[0] = row(0x400,1,1);let missingBefore = missing
    try rejects {_ = try OriginalBattleSession(definition:plain,roster:&missing,people:people,combat:combat,movement:movement,rng:OriginalRNG(state:5))}
    try check(try peopleBytes() == before && missing == missingBefore,"missing carryover fails before any shared state commits")
    var late = roster();late.slots[0] = row(0,1,1);late.slots[1] = row(10,3,3,1,1,3);late.slots[2] = row(11,4,4,1,255,1)
    let lateBefore = late
    try rejects {_ = try OriginalBattleSession(definition:plain,roster:&late,people:people,combat:combat,movement:movement,rng:OriginalRNG(state:5))}
    try check(try peopleBytes() == before && late == lateBefore,"late enemy failure rolls back previous friendly HP and enemy class/level/HP writes")

    var second = carried;second.slot = 1;second.person = 1
    let two = OriginalPartyCarryover(liveSlots:[carried,second],roundIndex:3,weatherIndex:4)
    var overlap = roster(true);overlap.slots[0] = row(0,1,1);overlap.slots[1] = row(0x400,2,1)
    overlap.slots[2] = row(0,4,4);overlap.slots[20] = row(12,4,4,1,1,3)
    let overlapBefore = overlap
    try rejects {_ = try OriginalBattleSession(definition:plain,roster:&overlap,people:people,combat:combat,movement:movement,rng:OriginalRNG(state:5),carryover:two)}
    try check(try peopleBytes() == before && overlap == overlapBefore,"board rejection rolls back class/HP writes and does not commit fallback roster mutations")

    var retainedError = false
    try people.transaction {
        try people.update(3) {$0.rawTroops = 111}
        do {try people.transaction {try people.update(3) {$0.rawTroops = 123};throw BattleError.invalid("synthetic nested abort")}}
        catch {retainedError = true}
        try check(try people.person(3).rawTroops == 111,"inner transaction rolls back to its own savepoint")
    }
    try check(retainedError && people.person(3).rawTroops == 111,"outer transaction commits after a handled nested rejection")
    print("Original party integration self-tests passed: \(checks)")
}
