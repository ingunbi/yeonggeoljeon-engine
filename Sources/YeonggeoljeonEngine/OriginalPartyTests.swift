// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func originalPartySelfTests() throws {
    var checks = 0
    func check(_ test:@autoclosure() throws -> Bool,_ reason:String) throws {
        guard try test() else {throw BattleError.invalid("Original party self-test: \(reason)")};checks += 1
    }
    func rejects(_ action:()throws->Void) throws {
        do {try action()} catch is BattleError {checks += 1;return}
        throw BattleError.invalid("Original party self-test expected an explicit rejection")
    }
    let combat = OriginalCombatTables(format:1,attackBase:Array(repeating:10,count:19),defenseBase:Array(repeating:10,count:19),
        troopBase:Array(repeating:10,count:19),troopGrowth:Array(repeating:0,count:19),physicalSubtypeByClass:Array(repeating:0,count:19),
        terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),
        items:(0..<64).map{OriginalItemEffect(id:$0,category:15,value:0)})
    let people = try OriginalPeople(catalog:OriginalPersonCatalog(format:1,people:(0..<384).map {id in
        let classes = [0,1,2,1,2,0],levels = [10,5,9,10,9,2]
        return OriginalPersonDefinition(id:id,name:"synthetic \(id)",classID:id < 6 ? classes[id] : 0,
            level:id < 6 ? levels[id] : 1,experience:0,rawTroops:50,defenseScalar:50,attackScalar:50,intellectScalar:50,
            personality:0,personalScalar:0,itemIDs:Array(repeating:255,count:8),sourceFlags:id < 6 ? 0x80 : id == 6 ? 0x81 : 0,
            sourceRole:0,sourceContext2:0,sourceContext3:0)
    }),tables:combat)
    var ranks = Array(repeating:2,count:256);ranks[1] = 1;ranks[2] = 1
    let profile = OriginalPartyProfile(format:1,classSortRanks:ranks,personZeroDefaultWord:1)
    func row(_ person:Int,_ x:Int,_ y:Int,_ flags:Int = 0)->OriginalPlacement {
        OriginalPlacement(ordinal:0,person:person,x:x,y:y,selector:0,flag:0,flags:flags,rawMode:0,parameter:0,classID:0,level:1)
    }
    var roster = OriginalRoster();roster.header = OriginalBattleHeader(preserveFriendlySlots:false,turnLimit:10,sourceByte2:0,discardedBytes:[],objectives:[])
    roster.slots[0] = row(0,1,1);roster.slots[1] = row(0x400,2,1);roster.slots[2] = row(0x400,3,1)
    roster.slots[3] = row(6,4,4,1)
    var selection = try OriginalParty.prepareSelection(people:people,roster:roster,profile:profile,combat:combat)
    try check(selection.capacity == 3 && selection.fixedCount == 1 && selection.remaining == 2,"named manual friend and placeholder source capacity")
    try check(selection.candidates == [0,3,2,4,1,5],"source class-rank then descending-level nested swap order")
    try check(try people.person(5).rawTroops == 1000 && people.person(6).rawTroops == 1000 && people.person(7).rawTroops == 50,
              "party preparation heals eligible unselected people and named enemy rows, not unrelated inactive people")
    try check(try OriginalParty.orderedCandidates([1,2,3],people:people,profile:profile) == [1,3,2],"source fixes first candidate even when person0 is absent")
    try selection.toggle(person:3);try selection.toggle(person:2);try selection.toggle(person:3);try selection.toggle(person:4)
    try check(Array(selection.selectedSlots.prefix(3)) == [0,4,2] && selection.remaining == 0,"selection holes refill before later slots")
    try rejects {try selection.toggle(person:0)}
    try rejects {try selection.toggle(person:5)}
    let confirmed = try selection.confirm()
    try check(confirmed.selectedPeople == [0,4,2] && confirmed.assignments.map(\.setupSlot) == [1,2],"source confirmation preserves selected-slot order")
    try check(confirmed.roster.slots[1].person == 4 && confirmed.roster.slots[1].x == 2 && confirmed.roster.slots[2].person == 2,
              "party application changes only placeholder person words")
    var trailing = selection;trailing.preparedRoster.slots[44] = row(0x400,4,0,1)
    try check(try trailing.confirm().roster.slots[44].person == 0x400,"source cleanup is bounded by45-lastScan instead of clearing all later placeholders")
    var disabled = profile;disabled.personZeroDefaultWord = 0
    let withoutZero = try OriginalParty.prepareSelection(people:people,roster:roster,profile:disabled,combat:combat)
    try check(withoutZero.preparedRoster.slots[0].person == 65535 && withoutZero.preparedRoster.slots[0].x == 1,
              "source default-person0 removal retains cleared-row coordinates")
    for id in 0..<100 {try people.update(id) {$0.sourceFlags = 0x80;$0.rawTroops = 50}}
    let capped = try OriginalParty.prepareSelection(people:people,roster:roster,profile:profile,combat:combat)
    try check(capped.candidates.count == 66 && people.person(65).rawTroops == 1000 && people.person(66).rawTroops == 50,
              "source candidate count66 stops its ascending scan and HP resets")
    let cardinal = [OriginalAIOffset(dx:0,dy:-1),OriginalAIOffset(dx:1,dy:0),OriginalAIOffset(dx:0,dy:1),OriginalAIOffset(dx:-1,dy:0)]
    var costs = Array(repeating:Array(repeating:1,count:256),count:4);costs[0][1] = 255
    let movement = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),classMovementBudgets:Array(repeating:3,count:19),
        attackRangeCodes:Array(repeating:0,count:19),movementCosts:costs,cardinalOffsets:cardinal,diagonalOffsets:cardinal,extendedOffsets:cardinal,
        setupOrderModes:Array(repeating:1,count:256))
    var terrain = Array(repeating:UInt8(0),count:25)
    for y in 1...3 {terrain[y*5+2] = 1}
    let spawn = try OriginalParty.spawnPoint(requested:GridPoint(x:2,y:4),classID:0,movement:movement,width:5,height:5,
        terrain:terrain,occupancy:[GridPoint(x:2,y:4):15])
    try check(spawn == GridPoint(x:2,y:0),"source depth-first marker crosses blocked nodes before a nearer east cell")
    var inactive = OriginalLiveUnit(slot:0,person:0,position:GridPoint(x:1,y:1),status:1,mp:7,aiPriority:9)
    var occupancy:[GridPoint:Int] = [:]
    let rejected = try OriginalParty.activate(unit:&inactive,classID:0,requested:GridPoint(x:255,y:255),flipped:true,
        movement:movement,width:5,height:5,terrain:terrain,occupancy:&occupancy)
    try check(!rejected && inactive.status == 1 && inactive.aiPriority == 9 && inactive.scriptFlags&0x10 == 0,"out-of-board activation changes neither status nor priority/flip")
    let activated = try OriginalParty.activate(unit:&inactive,classID:0,requested:GridPoint(x:1,y:1),flipped:true,
        movement:movement,width:5,height:5,terrain:terrain,occupancy:&occupancy)
    try check(activated && inactive.status == 2 && inactive.scriptFlags&0x10 != 0 && inactive.aiPriority == 9,
              "activation flip shares scriptFlags10 and never aliases AIpriority byte8")
    var carryUnit = inactive;carryUnit.status = 1;carryUnit.scriptFlags = 0xF6;carryUnit.morale = 20
    var carrySecond = OriginalLiveUnit(slot:1,person:1,position:GridPoint(x:4,y:4),status:1,mp:12);carrySecond.morale = 90
    let carry = OriginalPartyCarryover(liveSlots:[carryUnit,carrySecond],roundIndex:3,weatherIndex:4)
    var next = OriginalRoster();next.header = OriginalBattleHeader(preserveFriendlySlots:true,turnLimit:10,sourceByte2:0,discardedBytes:[],objectives:[])
    next.slots[0] = row(0,1,1);next.slots[1] = row(0x400,2,1,4);next.slots[2] = row(0,3,1,4)
    let deployed = try OriginalParty.deploy(carryover:carry,roster:next,people:people,movement:movement,width:5,height:5,
        terrain:Array(repeating:0,count:25))
    try check(deployed.units[0]!.position == GridPoint(x:3,y:1) && deployed.units[0]!.scriptFlags == 0x30,
              "every named match executes; later direct relocation retains first activation flip")
    try check(deployed.units[1]!.position == GridPoint(x:2,y:1) && deployed.units[1]!.scriptFlags&0x10 == 0 && deployed.roster.slots[1].person == 1,
              "fallback writes person word and uses inverted source setup-flip flag")
    try check(deployed.units[0]!.mp == 7 && deployed.units[0]!.morale == 20 && deployed.units[1]!.mp == 12 && deployed.units[1]!.morale == 90,
              "preserved friendly deployment retains MP and morale")
    try check(deployed.roundIndex == 3 && deployed.weatherIndex == 4,"source preserved round and weather state")
    next.header!.sourceByte2 = 1
    let resetRound = try OriginalParty.deploy(carryover:carry,roster:next,people:people,movement:movement,width:5,height:5,terrain:Array(repeating:0,count:25))
    try check(resetRound.roundIndex == 0 && resetRound.weatherIndex == 4,"sourceByte2 resets preserved round only")
    var empty = OriginalRoster();empty.header = next.header
    let noCoordinates = try OriginalParty.deploy(carryover:OriginalPartyCarryover(liveSlots:[carryUnit],roundIndex:3,weatherIndex:4),
        roster:empty,people:people,movement:movement,width:5,height:5,terrain:Array(repeating:0,count:25))
    try check(noCoordinates.units[0]!.status == 1 && noCoordinates.roster.slots[0].person == 0 && !noCoordinates.attempts[0].applied,
              "unsigned FFFF fallback consumes an all-FF row while its255 coordinate rejects activation")
    var nativeRoster = OriginalRoster();nativeRoster.header = roster.header
    nativeRoster.slots[0] = row(0,1,1);nativeRoster.slots[1] = row(1,2,1)
    let native = try OriginalBattleSession(definition:BattleDefinition(id:"synthetic-party",width:5,height:5,tiles:Array(repeating:0,count:25)),
        roster:&nativeRoster,people:people,combat:combat,movement:movement,rng:OriginalRNG(state:7))
    try people.update(0) {$0.level = 10;$0.experience = 90;$0.rawTroops = 300}
    native.turns.result = 2;native.turns.roundIndex = 3;native.turns.weatherIndex = 4;native.scriptValue24 = 50
    native.units[0]!.mp = 7;native.units[0]!.morale = 20
    let victory = try native.finishBattleForCarryover()
    try check(try people.person(0).level == 11 && people.person(0).experience == 40 && people.person(0).rawTroops == 300,
              "source victory byte24 bonus levels a person without healing troops")
    try check(victory.liveSlots.allSatisfy{$0.status == 1} && victory.liveSlots[0].mp == 7 && victory.liveSlots[0].morale == 20,
              "victory converts active slots to reserves while preserving live-unit quantities")
    _ = try native.finishBattleForCarryover()
    try check(try people.person(0).experience == 40,"repeated source finish does not award inactive reserves again")
    native.units[0]!.status = 2;native.turns.result = 3
    let defeat = try native.finishBattleForCarryover()
    try check(defeat.liveSlots[0].status == 2 && people.person(0).experience == 40,"nonvictory result skips bonus and status conversion")
    print("Original party self-tests passed: \(checks)")
}
