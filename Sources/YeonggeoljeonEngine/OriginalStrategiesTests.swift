// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func originalStrategiesSelfTests() throws {
    var checks = 0
    func check(_ test:@autoclosure() throws -> Bool,_ reason:String) throws {
        guard try test() else { throw BattleError.invalid("Original strategy command self-test: \(reason)") };checks += 1
    }
    func makeSession(environment:Int = 0) throws -> OriginalBattleSession {
        var table = OriginalCombatTables(format:1,attackBase:Array(repeating:10,count:19),
            defenseBase:Array(repeating:10,count:19),troopBase:Array(repeating:10,count:19),troopGrowth:Array(repeating:0,count:19),
            physicalSubtypeByClass:Array(repeating:0,count:19),terrainDefensePercent:Array(repeating:0,count:256),
            strategyEnvironmentLookup:Array(repeating:0,count:256),items:(0..<64).map{OriginalItemEffect(id:$0,category:15,value:0)})
        table.strategyEnvironmentLookup[1] = environment
        let people = try OriginalPeople(catalog:OriginalPersonCatalog(format:1,people:(0..<384).map{id in
            OriginalPersonDefinition(id:id,name:"synthetic \(id)",classID:0,level:10,experience:0,rawTroops:1000,
                defenseScalar:100,attackScalar:100,intellectScalar:id == 0 ? 100 : 0,personality:0,personalScalar:0,
                itemIDs:Array(repeating:255,count:8),sourceFlags:id == 0 ? 0 : 1,sourceRole:0,sourceContext2:0,sourceContext3:0)
        }),tables:table)
        let cardinal = [OriginalAIOffset(dx:0,dy:-1),OriginalAIOffset(dx:1,dy:0),OriginalAIOffset(dx:0,dy:1),OriginalAIOffset(dx:-1,dy:0)]
        let diagonal = [OriginalAIOffset(dx:-1,dy:-1),OriginalAIOffset(dx:1,dy:-1),OriginalAIOffset(dx:1,dy:1),OriginalAIOffset(dx:-1,dy:1)]
        var categories = Array(repeating:0,count:36);for id in 30..<36 {categories[id] = 3}
        let movement = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),
            classMovementBudgets:Array(repeating:3,count:19),attackRangeCodes:Array(repeating:0,count:19),
            movementCosts:Array(repeating:Array(repeating:1,count:256),count:4),cardinalOffsets:cardinal,
            diagonalOffsets:diagonal,extendedOffsets:cardinal,setupOrderModes:Array(repeating:2,count:256),
            strategyLevelRequirements:Array(repeating:Array(repeating:0,count:19),count:36),
            strategyMPCosts:Array(repeating:1,count:36),strategyCategories:categories,
            strategyTerrainEligibility:Array(repeating:[0,1,255,255],count:3))
        var roster = OriginalRoster();roster.header = OriginalBattleHeader(preserveFriendlySlots:false,turnLimit:10,sourceByte2:0,discardedBytes:[],objectives:[])
        let coordinates = [(1,1),(1,0),(2,1),(2,0),(3,1),(2,2)]
        for (id,coordinate) in coordinates.enumerated() {
            roster.slots[id] = OriginalPlacement(ordinal:id,person:id,x:coordinate.0,y:coordinate.1,selector:0,flag:0,
                flags:id >= 2 ? 1 : 0,rawMode:0,parameter:0,classID:0,level:10)
        }
        return try OriginalBattleSession(definition:BattleDefinition(id:"synthetic-strategies",width:5,height:5,tiles:Array(repeating:0,count:25)),
            roster:roster,people:people,combat:table,movement:movement,rng:OriginalRNG(state:2))
    }
    let damage = try makeSession()
    let hit = try damage.castStrategy(0,abilityID:3,target:15)
    try check(hit.completed && hit.targets.map(\.runtimeSlot) == [15,16,17,18],"damage strategy visits primary then source N/E/S/W enemy splash")
    try check(hit.targets[0].damage?.damage == 441 && damage.people.person(2).rawTroops == 559,"actual damage producer writes shared troops")
    try check(hit.completionExperience == nil && hit.targets.allSatisfy{$0.experience != nil},"damage strategies receive context EXP without extra flat EXP setter")
    try check(damage.units[0]!.mp == 49 && damage.units[0]!.scriptFlags&0x80 != 0,"completed strategy consumes MP and marks actor acted")
    let weather = try makeSession(environment:2),weatherRNG = weather.rng
    let blocked = try weather.castStrategy(0,abilityID:0,target:15)
    try check(!blocked.completed && weather.rng == weatherRNG && weather.units[0]!.mp == 50 && weather.units[0]!.scriptFlags&0x80 == 0,
              "source weather rejection consumes no RNG, MP or action")
    let status = try makeSession()
    let confused = try status.castStrategy(0,abilityID:17,target:15)
    try check(confused.targets.map(\.runtimeSlot) == [15,16,17,18] && confused.targets.allSatisfy{$0.success?.success == true},
              "source status strategy applies denominator2 attempts in primary/cardinal order")
    try check(status.units[15]!.scriptFlags&2 != 0 && confused.completion?.flatExperience == 8,"status2 mutation and common completion EXP")
    let morale = try makeSession()
    let lowered = try morale.castStrategy(0,abilityID:18,target:15)
    try check(lowered.targets[0].success?.success == true && morale.units[15]!.morale == 80,"actual morale strategy has no AI random damage multiplier")
    let healing = try makeSession();healing.units[0]!.morale = 80
    try healing.people.update(0) {$0.classID = 12}
    let restored = try healing.castStrategy(0,abilityID:21,target:0)
    try check(restored.completed && healing.units[0]!.morale == 100 && restored.completion?.flatExperience == 12,
              "support range includes caster and single-target healer class gains12 EXP")
    let full = try makeSession(),fullRNG = full.rng
    let noHeal = try full.castStrategy(0,abilityID:21,target:0)
    try check(!noHeal.completed && full.rng == fullRNG && full.units[0]!.mp == 50,"already-restored single target cancels without costs")
    let area = try makeSession()
    let areaResult = try area.castStrategy(0,abilityID:30)
    try check(areaResult.targets.map(\.runtimeSlot) == [0,1] && areaResult.completion?.flatExperience == 8,
              "area support retains source center-first friendly target list and flat EXP")
    var expected = OriginalRNG(state:2);_ = try expected.next(bound:3);_ = try expected.next(bound:3)
    try check(area.rng == expected,"full-morale area targets still consume each healing jitter draw")
    let cancel = try makeSession(),cancelRNG = cancel.rng
    let cancelled = try cancel.castStrategy(0,abilityID:30,confirmed:false)
    try check(!cancelled.completed && cancel.rng == cancelRNG && cancel.units[0]!.mp == 50,"area confirmation cancellation retains source state")
    let interleaved = try makeSession();try interleaved.people.update(2) {$0.rawTroops = 1}
    let changed = try interleaved.castStrategy(0,abilityID:3,target:15,afterRetirement:{slot in
        if slot == 15 {
            interleaved.units[16]!.status = 4
            interleaved.units[19] = OriginalLiveUnit(slot:19,person:6,position:GridPoint(x:2,y:0),status:2,mp:0)
        }
    })
    try check(changed.targets.map(\.runtimeSlot) == [15,19,17,18] && interleaved.units[15]!.status == 4,
              "retirement hook completes before splash re-reads neighboring occupancy")
    print("Original strategy command self-tests passed: \(checks)")
}
