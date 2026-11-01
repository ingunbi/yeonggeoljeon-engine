// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Synthetic checks for the item use routine (MAIN2E0E6..2E833).
func originalItemSelfTests() throws {
    var checks = 0
    func check(_ value:@autoclosure() throws -> Bool,_ reason:String) throws {
        guard try value() else {throw BattleError.invalid("Original item regression: \(reason)")};checks += 1
    }
    // Source id ranges decide the effect group before anything else.
    let groups:[(Int,OriginalItemUse)] = [(0,.classChange(target:15)),(1,.classChange(target:18)),(2,.classChange(target:12)),
        (0x10,.classChange(target:3)),(0x11,.classChange(target:6)),(0x12,.classChange(target:0)),
        (0x13,.promotion(required:0,level:15)),(0x14,.promotion(required:1,level:30)),(0x1A,.promotion(required:10,level:30)),
        (0x22,.attack(family:2,power:0)),(0x24,.attack(family:2,power:2)),(0x25,.attack(family:1,power:0)),
        (0x28,.attack(family:0,power:0)),(0x2A,.attack(family:0,power:2)),
        (0x2B,.confuse(raw:0,splash:false)),(0x2C,.confuse(raw:1,splash:false)),(0x2D,.confuse(raw:0,splash:true)),
        (0x1B,.recovery(kind:2,power:0)),(0x1D,.recovery(kind:2,power:2)),(0x1E,.recovery(kind:1,power:0)),
        (0x20,.recovery(kind:1,power:2)),(0x34,.recovery(kind:3,power:0)),(0x36,.recovery(kind:3,power:2)),
        (0x2E,.areaRecovery(kind:1,power:0)),(0x30,.areaRecovery(kind:1,power:2)),(0x31,.areaRecovery(kind:2,power:0)),
        (0x33,.areaRecovery(kind:2,power:2)),(0x21,.bomb),(3,.unusable),(9,.unusable),(0x37,.unusable),(0x3E,.unusable)]
    for (id,expected) in groups { try check(OriginalItemUse.of(id) == expected,"item \(id) selects its source group") }
    try check(OriginalItemUse.attack(family:1,power:2).rangeCode == 0x82 && OriginalItemUse.bomb.rangeCode == 0x81,"range codes carry the extended bit")
    try check(OriginalItemUse.recovery(kind:1,power:0).targetsFriends && !OriginalItemUse.bomb.targetsFriends,"recovery picks friends")

    func fixture(seed:UInt32 = 2,userClass:Int = 0,userLevel:Int = 20,items:[Int],weatherLookup:Int = 0,
                 impassableClass:Int? = nil) throws -> OriginalBattleSession {
        let tables = OriginalCombatTables(format:1,attackBase:Array(repeating:1,count:19),defenseBase:Array(repeating:1,count:19),
            troopBase:Array(repeating:10,count:19),troopGrowth:Array(repeating:10,count:19),physicalSubtypeByClass:Array(repeating:0,count:19),
            terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:weatherLookup,count:256),
            items:(0..<64).map{OriginalItemEffect(id:$0,category:15,value:0)})
        let people = try OriginalPeople(catalog:OriginalPersonCatalog(format:1,people:(0..<384).map{id in
            let leads = [0,1,5,6]
            return OriginalPersonDefinition(id:id,name:"synthetic \(id)",classID:id == 1 ? userClass : 0,level:id == 1 ? userLevel : 10,experience:0,
                rawTroops:100,defenseScalar:50,attackScalar:50,intellectScalar:50,personality:0,personalScalar:0,
                itemIDs:id == 1 ? items+Array(repeating:255,count:8-items.count) : Array(repeating:255,count:8),
                sourceFlags:leads.prefix(2).contains(id) ? 0 : 1,sourceRole:0,sourceContext2:0,sourceContext3:0)
        }),tables:tables)
        let cardinal = [OriginalAIOffset(dx:0,dy:-1),.init(dx:1,dy:0),.init(dx:0,dy:1),.init(dx:-1,dy:0)]
        let diagonal = [OriginalAIOffset(dx:-1,dy:-1),.init(dx:1,dy:-1),.init(dx:-1,dy:1),.init(dx:1,dy:1)]
        var types = Array(repeating:0,count:19)
        if impassableClass != nil { types[impassableClass!] = 1 }
        var costs = Array(repeating:Array(repeating:1,count:256),count:4)
        costs[1][0] = 255
        let movement = OriginalMovementProfile(format:1,classMovementTypes:types,classMovementBudgets:Array(repeating:3,count:19),
            attackRangeCodes:Array(repeating:0,count:19),movementCosts:costs,cardinalOffsets:cardinal,diagonalOffsets:diagonal,
            extendedOffsets:cardinal,setupOrderModes:Array(repeating:2,count:256),strategyTerrainEligibility:[[0,255,255,255],[1,255,255,255],[0,255,255,255]])
        var roster = OriginalRoster();roster.header = OriginalBattleHeader(preserveFriendlySlots:false,turnLimit:10,sourceByte2:0,discardedBytes:[],objectives:[])
        // Slots are assigned by placement order: person0 lead, person1 user,
        // then the enemy row. Person1 stands between a friend and two enemies.
        let rows:[(Int,Int,Int)] = [(0,2,1),(1,2,2),(5,3,2),(6,4,2)]
        for (ordinal,row) in rows.enumerated() {
            roster.slots[ordinal] = OriginalPlacement(ordinal:ordinal,person:row.0,x:row.1,y:row.2,selector:0,flag:0,flags:row.0 >= 5 ? 1 : 0,
                rawMode:0,parameter:0,classID:0,level:10)
        }
        let session = try OriginalBattleSession(definition:BattleDefinition(id:"synthetic-item",width:7,height:6,tiles:Array(repeating:0,count:42)),
            roster:&roster,people:people,combat:tables,movement:movement,rng:OriginalRNG(state:seed))
        return session
    }
    func finish(_ session:OriginalBattleSession,_ operation:inout OriginalItemOperation) throws -> OriginalItemExecution {
        for _ in 0..<64 {
            switch try operation.advance(in:session) {
            case .target:continue
            case .retirement(let notice):try operation.resumeRetirement(notice)
            case .finished(let result):return result
            }
        }
        throw BattleError.invalid("Synthetic item driver exceeded its bound")
    }
    func use(_ session:OriginalBattleSession,_ item:Int,target:Int? = nil) throws -> OriginalItemExecution {
        var operation = try OriginalItemOperation.begin(in:session,userSlot:1,item:item,target:target)
        return try finish(session,&operation)
    }
    let enemy = 15,neighbor = 16

    // Bomb: one troop draw, one morale draw, no experience.
    let bomb = try fixture(items:[0x21])
    var draws = bomb.rng
    let troopCut = (try draws.next(bound:21)+0x5A)*15,moraleCut = try draws.next(bound:10)+0x1E
    let experienceBefore = try bomb.people.person(1).experience,bombTroops = try bomb.people.person(5).rawTroops
    let blast = try use(bomb,0x21,target:enemy)
    try check(blast.completed && blast.targets.first?.quantity == troopCut,"the bomb removes the drawn troops")
    try check(try bomb.people.person(5).rawTroops == bombTroops-troopCut,"bomb damage reaches the shared person")
    try check(bomb.units[enemy]!.morale == 100-moraleCut,"the bomb cuts morale by its second draw")
    try check(bomb.rng.state == draws.state,"the bomb consumes exactly two draws here")
    try check(try bomb.people.person(1).experience == experienceBefore,"the bomb grants no experience")
    try check(try !bomb.people.person(1).itemIDs.contains(0x21) && bomb.units[1]!.scriptFlags&0x80 != 0,"use consumes the item and ends the action")

    // A lethal bomb stops after the troop draw and retires through a resumable step.
    let lethal = try fixture(items:[0x21])
    try lethal.people.update(5) {$0.rawTroops = 50}
    var lethalDraws = lethal.rng
    _ = try lethalDraws.next(bound:21)
    var lethalOperation = try OriginalItemOperation.begin(in:lethal,userSlot:1,item:0x21,target:enemy)
    guard case .target(let hit) = try lethalOperation.advance(in:lethal) else {throw BattleError.invalid("Expected the bomb effect")}
    try check(hit.quantity == 50 && hit.morale == nil && lethal.rng.state == lethalDraws.state,"a wiped-out target takes no morale draw")
    let encoder = JSONEncoder()
    var restored = try JSONDecoder().decode(OriginalItemOperation.self,from:encoder.encode(lethalOperation))
    guard case .retirement(let notice) = try restored.advance(in:lethal) else {throw BattleError.invalid("Expected a pending retirement")}
    try check(lethal.units[enemy]!.status == 4,"the target retires before the host acknowledges")
    guard case .retirement = try restored.advance(in:lethal) else {throw BattleError.invalid("Expected the same pending retirement")}
    try restored.resumeRetirement(notice)
    try check(try finish(lethal,&restored).completed,"the operation finishes after acknowledgement")

    // Attack scrolls use context kind3, and the experience of a strike.
    let strike = try fixture(items:[0x28])
    var strikeRNG = strike.rng
    let a = try strike.people.stats(1,morale:100),d = try strike.people.stats(5,morale:100)
    let expected = try OriginalCombat.strategyStrike(OriginalStrategyInput(attacker:a,defender:d,terrainID:0,subtype:0,kind:3,weatherCode:Int(strike.turns.weatherIndex)),tables:strike.combat,rng:&strikeRNG)
    let mpBefore = strike.units[1]!.mp
    let scroll = try use(strike,0x28,target:enemy)
    try check(scroll.targets.first?.damage == expected,"an attack item is a kind3 strike with family and tier in its subtype")
    try check(strike.units[1]!.mp == mpBefore,"an item costs no MP")
    try check((scroll.targets.first?.experience?.experience ?? 0) > 0,"an attack item earns strike experience")

    let rain = try fixture(items:[0x28],weatherLookup:2)
    let wet = rain.rng.state,rejected = try use(rain,0x28,target:enemy)
    try check(rejected.rejection == "rainFire" && !rejected.completed && rain.rng.state == wet,"rain refuses fire items without a draw")
    try check(try rain.people.person(1).itemIDs.contains(0x28) && rain.units[1]!.scriptFlags&0x80 == 0,"a refusal keeps the item and the action")
    let rock = try fixture(items:[0x25])
    try check(try use(rock,0x25,target:enemy).rejection == "terrain","a target on the wrong terrain is refused")
    try check(try use(try fixture(items:[0x28]),0x28).rejection == "cancelled","no pick cancels")

    // Confusion has no success roll, and the wide item spreads to enemy neighbours.
    let fog = try fixture(items:[0x2D])
    let fogState = fog.rng.state
    let cloud = try use(fog,0x2D,target:enemy)
    try check(fog.units[enemy]!.scriptFlags&2 != 0 && fog.units[neighbor]!.scriptFlags&2 != 0,"splash confuses the adjacent enemy")
    try check(fog.units[1]!.scriptFlags&2 == 0,"splash spares the user's side")
    try check(fog.rng.state == fogState && cloud.targets.count == 2,"confusion draws nothing")
    let dazed = try fixture(items:[0x2B])
    dazed.units[enemy]!.scriptFlags |= 2
    try check(try use(dazed,0x2B,target:enemy).rejection == "alreadyConfused","a confused target is refused")

    // Recovery uses the caster-less healing path and refuses a full unit.
    let full = try fixture(items:[0x1E])
    let maximum = try OriginalCombat.maxTroops(classID:0,level:20,tables:full.combat)
    try full.people.update(1) {$0.rawTroops = maximum}
    try check(try use(full,0x1E,target:1).rejection == "noRecovery","a full target is refused")
    let hurt = try fixture(items:[0x1E])
    try hurt.people.update(1) {$0.rawTroops = 100}
    let healed = try use(hurt,0x1E,target:1)
    try check(healed.completed && (healed.targets.first?.healing?.troopsDelta ?? 0) > 0,"an item heals without a caster")
    try check(try OriginalItemOperation.targetSlots(in:hurt,userSlot:0,use:.recovery(kind:1,power:0)).first == 0,"the picker offers the user first")
    let area = try fixture(items:[0x2E])
    let spread = try use(area,0x2E)
    try check(spread.targets.map(\.runtimeSlot) == [1,0],"area recovery keeps the user first, then range order")

    // Class changes refuse in source order, then rewrite the person.
    func refusal(_ item:Int,classID:Int = 0,level:Int = 20,impassable:Int? = nil,person0:Bool = false) throws -> String? {
        let session = try fixture(userClass:classID,userLevel:level,items:[item],impassableClass:impassable)
        return try OriginalItemOperation.classRefusal(in:session,userSlot:person0 ? 0 : 1,use:OriginalItemUse.of(item))
    }
    try check(try refusal(0,person0:true) == "playerClass","the player's own unit cannot change class")
    try check(try refusal(0x12,classID:0) == "sameClass","the same class is refused")
    try check(try refusal(0x12,classID:1) == "sameFamily","the same family is refused")
    try check(try refusal(0,classID:0,impassable:15) == "classTerrain","a cell the new class cannot stand on is refused")
    try check(try refusal(0,classID:0) == nil,"a legal change is offered")
    try check(try refusal(0x13,classID:1) == "wrongClass","a promotion needs its source class")
    try check(try refusal(0x13,classID:0,level:14) == "lowLevel","a promotion needs its level")
    try check(try refusal(0x14,classID:1,level:30) == nil,"level thirty promotes the second tier")
    let change = try fixture(items:[0])
    let cap = try OriginalCombat.maxTroops(classID:15,level:20,tables:change.combat)
    try change.people.update(1) {$0.rawTroops = cap+40}
    let changed = try use(change,0)
    try check(try changed.newClass == 15 && change.people.person(1).classID == 15,"a class change rewrites the person")
    try check(try change.people.person(1).rawTroops == cap,"a class change caps troops")
    let promote = try fixture(items:[0x13])
    let high = try OriginalCombat.maxTroops(classID:0,level:20,tables:promote.combat)
    try promote.people.update(1) {$0.rawTroops = high}
    _ = try use(promote,0x13)
    try check(try promote.people.person(1).classID == 1 && promote.people.person(1).rawTroops == high,"a promotion moves one class up and leaves troops alone")
    try check(try use(try fixture(items:[9]),9).rejection == "unusable","equipment refuses use")

    // The flow treats a finished use as the unit's action.
    let flowed = try fixture(items:[0x21,0x1E])
    let flow = OriginalBattleFlow(session:flowed)
    try flow.start()
    try check(flow.acceptsManualInput,"the manual phase accepts items")
    let refusedByFlow = try flow.manualItem(1,item:0x1E,target:enemy,confirmed:false)
    try check(refusedByFlow?.completed == false && flow.acceptsManualInput,"a declined use leaves the turn open")
    let done = try flow.manualItem(1,item:0x21,target:enemy)
    try check(done?.completed == true && flowed.units[1]!.scriptFlags&0x80 != 0 && flow.lastItem != nil,"a use ends the action through the flow")
    let input = OriginalPlayInput(kind:.battleItem,slot:1,target:15,item:0x21)
    try input.validate()
    print("Original item self-tests passed: \(checks)")
}
