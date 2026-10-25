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
            roster:&roster,people:people,combat:table,movement:movement,rng:OriginalRNG(state:2))
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
    let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
    func checkpoint(_ operation:OriginalStrategyOperation) throws -> OriginalStrategyOperation {
        try JSONDecoder().decode(OriginalStrategyOperation.self,from:encoder.encode(operation))
    }
    func finish(_ operation:inout OriginalStrategyOperation,_ session:OriginalBattleSession,
                retirement:((OriginalRetirementNotice)throws->Void)? = nil) throws -> OriginalStrategyExecution {
        for _ in 0..<128 {
            switch try operation.advance(in:session) {
            case .target:continue
            case .retirement(let notice):try retirement?(notice);try operation.resumeRetirement(notice)
            case .finished(let value):return value
            }
        }
        throw BattleError.invalid("Original strategy synthetic driver exceeded source target bound")
    }
    let paused = try makeSession();try paused.people.update(2) {$0.rawTroops = 1}
    var operation = try OriginalStrategyOperation.begin(in:paused,casterSlot:0,abilityID:3,target:15)
    let beginRNG = paused.rng
    try check(operation.effects.isEmpty && paused.rng == beginRNG && paused.units[0]!.mp == 50,
        "begin captures typed source locals without consuming effects or costs")
    guard case .target(let first) = try operation.advance(in:paused) else {throw BattleError.invalid("Expected first strategy target")}
    try check(first.retiredPerson == 2 && paused.units[15]!.status == 4 && operation.effects.count == 1,
        "one advance commits exactly one target context before yielding its retirement")
    guard case .retirement(let notice) = try operation.advance(in:paused) else {throw BattleError.invalid("Expected strategy retirement notice")}
    let waitingRNG = paused.rng,waitingEXP = try paused.people.person(0).experience,waitingTroops = try paused.people.person(3).rawTroops
    operation = try checkpoint(operation)
    for _ in 0..<3 {
        guard case .retirement(let repeated) = try operation.advance(in:paused),repeated == notice else {throw BattleError.invalid("Pending retirement identity changed")}
    }
    try check(paused.rng == waitingRNG && paused.people.person(0).experience == waitingEXP && paused.people.person(3).rawTroops == waitingTroops && paused.units[0]!.mp == 50 && paused.units[0]!.scriptFlags&0x80 == 0,
        "serialized pending dialogue blocks remaining AoE, RNG, EXP, MP and acted completion")
    var wrong = notice;wrong.sequence += 1
    do {try operation.resumeRetirement(wrong);throw BattleError.invalid("Wrong retirement acknowledgement was accepted")}
    catch BattleError.illegalAction {try check(operation.pendingRetirement?.notice == notice,"wrong global sequence cannot acknowledge a pending effect")}
    func moveDamageCenter(_ session:OriginalBattleSession) throws {
        session.units[15]!.position = GridPoint(x:3,y:3)
        session.units[18]!.position = GridPoint(x:2,y:3)
        session.units[19] = OriginalLiveUnit(slot:19,person:6,position:GridPoint(x:3,y:2),status:2,mp:0)
        session.units[0]!.mp = 0
        _ = try session.rng.next(bound:7)
    }
    try moveDamageCenter(paused)
    let afterScript = paused.rng
    try operation.resumeRetirement(notice)
    try check(paused.rng == afterScript && paused.units[0]!.mp == 0 && operation.effects.count == 1,
        "acknowledgement alone neither executes a neighbor nor repeats the committed primary")
    operation = try checkpoint(operation)
    let resumed = try finish(&operation,paused)
    try check(resumed.targets.map(\.runtimeSlot) == [15,19,18] && paused.units[0]!.mp == 255,
        "damage center is read after source script and completion uses changed byte MP")
    let synchronous = try makeSession();try synchronous.people.update(2) {$0.rawTroops = 1}
    let expectedResumed = try synchronous.castStrategy(0,abilityID:3,target:15,afterRetirement:{slot in
        if slot == 15 {try moveDamageCenter(synchronous)}
    })
    try check(try encoder.encode(resumed) == encoder.encode(expectedResumed) && paused.rng == synchronous.rng,
        "pause/checkpoint/resume preserves the synchronous source result and interleaved RNG order")
    let finishedRNG = paused.rng,finishedEXP = try paused.people.person(0).experience
    let repeatedResult = try finish(&operation,paused)
    try check(try encoder.encode(repeatedResult) == encoder.encode(resumed) && paused.rng == finishedRNG && paused.people.person(0).experience == finishedEXP && paused.units[0]!.mp == 255,
        "repeated finished advance returns retained output without applying completion twice")

    let statusPaused = try makeSession();statusPaused.units[15]!.morale = 0
    var statusOperation = try OriginalStrategyOperation.begin(in:statusPaused,casterSlot:0,abilityID:17,target:15)
    guard case .target = try statusOperation.advance(in:statusPaused),
          case .retirement(let statusNotice) = try statusOperation.advance(in:statusPaused) else {throw BattleError.invalid("Expected status strategy retirement")}
    try check(try statusPaused.people.person(0).experience == 0 && statusPaused.units[0]!.mp == 50,
        "flat EXP and command MP are deferred while a status retirement script waits")
    statusPaused.units[15]!.position = GridPoint(x:3,y:3)
    try statusOperation.resumeRetirement(statusNotice)
    statusOperation = try checkpoint(statusOperation)
    let statusResult = try finish(&statusOperation,statusPaused)
    try check(statusResult.targets.map(\.runtimeSlot) == [15,16,17,18] && statusResult.completion?.flatExperience == 8,
        "condition AoE retains its pre-context center across source retirement scripts")
    let statusEXP = try statusPaused.people.person(0).experience,statusRNG = statusPaused.rng
    _ = try finish(&statusOperation,statusPaused)
    try check(try statusPaused.people.person(0).experience == statusEXP && statusPaused.rng == statusRNG && statusPaused.units[0]!.mp == 49,
        "non-damage flat EXP and MP completion also execute only once")

    let retainedHealing = try makeSession()
    var healingOperation = try OriginalStrategyOperation.begin(in:retainedHealing,casterSlot:0,abilityID:30)
    guard case .target(let casterHeal) = try healingOperation.advance(in:retainedHealing) else {throw BattleError.invalid("Expected retained area-healing target")}
    try check(casterHeal.runtimeSlot == 0 && retainedHealing.units[0]!.mp == 50,"area healing yields each retained target before command completion")
    retainedHealing.units[1]!.position = GridPoint(x:4,y:4)
    retainedHealing.units[2] = OriginalLiveUnit(slot:2,person:7,position:GridPoint(x:0,y:1),status:2,mp:0)
    healingOperation = try checkpoint(healingOperation)
    let retainedResult = try finish(&healingOperation,retainedHealing)
    try check(retainedResult.targets.map(\.runtimeSlot) == [0,1],"area healing resumes its retained slot list without re-enumerating the changed board")
    let suppressed = try makeSession();suppressed.units[15]!.scriptFlags |= 4
    try suppressed.people.update(2) {$0.rawTroops = 1}
    var suppressedOperation = try OriginalStrategyOperation.begin(in:suppressed,casterSlot:0,abilityID:0,target:15)
    guard case .target(let silentRetirement) = try suppressedOperation.advance(in:suppressed) else {throw BattleError.invalid("Expected suppressed strategy target")}
    try check(silentRetirement.retiredPerson == 2 && silentRetirement.retirement == nil && suppressed.retirements.isEmpty && suppressedOperation.pendingRetirement == nil,
        "flag4 suppression keeps source status retirement distinct from a campaign notice")
    _ = try finish(&suppressedOperation,suppressed)
    try check(suppressed.units[0]!.mp == 49,"suppressed retirement continues directly to its one completion")
    let priorRetirement = try makeSession()
    priorRetirement.units[20] = OriginalLiveUnit(slot:20,person:8,position:GridPoint(x:4,y:4),status:2,mp:0)
    _ = priorRetirement.retireUnit(20)
    try priorRetirement.people.update(2) {$0.rawTroops = 1}
    var indexed = try OriginalStrategyOperation.begin(in:priorRetirement,casterSlot:0,abilityID:0,target:15)
    guard case .target = try indexed.advance(in:priorRetirement),case .retirement(let indexedNotice) = try indexed.advance(in:priorRetirement) else {throw BattleError.invalid("Expected indexed strategy retirement")}
    try check(indexedNotice.sequence == 1 && indexed.pendingRetirement?.effectIndex == 0 && indexedNotice.runtimeSlot == 15,
        "session global retirement sequence stays separate from operation-local effect order")
    print("Original strategy command self-tests passed: \(checks)")
}
