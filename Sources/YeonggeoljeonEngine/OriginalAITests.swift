// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func originalAISelfTests() throws {
    var count = 0
    func check(_ condition:@autoclosure()->Bool,_ message:String) throws {
        guard condition() else { throw OriginalAIError.invalid("self-test: \(message)") }; count += 1
    }
    func rejects(_ action:() throws -> Void) throws {
        do { try action() } catch is OriginalAIError { count += 1; return }
        throw OriginalAIError.invalid("self-test: expected source input/route rejection")
    }
    let cardinal = [OriginalAIOffset(dx:0,dy:-1),OriginalAIOffset(dx:1,dy:0),OriginalAIOffset(dx:0,dy:1),OriginalAIOffset(dx:-1,dy:0)]
    let diagonal = [OriginalAIOffset(dx:1,dy:-1),OriginalAIOffset(dx:1,dy:1),OriginalAIOffset(dx:-1,dy:1),OriginalAIOffset(dx:-1,dy:-1)]
    let extended = [OriginalAIOffset(dx:1,dy:0),OriginalAIOffset(dx:-1,dy:0),OriginalAIOffset(dx:0,dy:1),OriginalAIOffset(dx:0,dy:-1)]
    var profile = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),
        classMovementBudgets:Array(repeating:4,count:19),attackRangeCodes:Array(repeating:0,count:19),
        movementCosts:Array(repeating:Array(repeating:1,count:256),count:4),
        cardinalOffsets:cardinal,diagonalOffsets:diagonal,extendedOffsets:extended)
    profile.movementCosts[0][1] = 2; profile.movementCosts[0][2] = 255
    profile.movementCosts[0][255] = 197
    let actor = OriginalMovementActor(runtimeSlot:0,position:GridPoint(x:2,y:2),classID:0,scriptFlags:0,active:true)
    var board = OriginalMovementBoard(width:5,height:5,terrain:Array(repeating:0,count:25),actors:[actor])
    try profile.validate()
    try check(actor.sourceFaction == 1,"source faction belongs to runtime index")
    var enemy = actor; enemy.runtimeSlot = 15; enemy.position = GridPoint(x:4,y:2)
    try check(enemy.sourceFaction == 0,"opposing source index range")
    let budget = try profile.budget(classID:0,equipmentMovementBonuses:[1,3,2])
    try check(budget == 7,"only maximum movement item bonus")
    var wrap = profile; wrap.classMovementBudgets[0] = 254
    let wrapped = try wrap.budget(classID:0,equipmentMovementBonuses:[3])
    try check(wrapped == 1,"movement budget retains source byte wrap")
    try rejects {_ = try profile.budget(classID:19,equipmentMovementBonuses:[])}
    try rejects {_ = try profile.budget(classID:0,equipmentMovementBonuses:Array(repeating:0,count:9))}
    let field = try OriginalMovement.distanceField(profile:profile,board:board,moving:actor,seed:actor.position,limit:2)
    try check(field.value(actor.position) == 0 && field.value(GridPoint(x:4,y:2)) == 2,"source distance layer budget")
    try check(field.value(GridPoint(x:0,y:0)) == 255,"distance sentinel is retained")
    try rejects {_ = try OriginalMovement.distanceField(profile:profile,board:board,moving:actor,
        seed:actor.position,limit:2,stoppingAt:actor.position)}
    let noMove = try OriginalMovement.route(profile:profile,board:board,moving:actor,to:actor.position,budget:2)
    try check(noMove == [actor.position],"no-op player route does not invent a source scratch field")
    let path = try OriginalMovement.route(profile:profile,board:board,moving:actor,to:GridPoint(x:3,y:1),budget:2)
    try check(path == [GridPoint(x:2,y:2),GridPoint(x:3,y:2),GridPoint(x:3,y:1)],"strict source neighbor tie and path inversion")
    board.terrain[board.index(GridPoint(x:3,y:2))] = 1
    let costs = try OriginalMovement.distanceField(profile:profile,board:board,moving:actor,seed:actor.position,limit:1)
    try check(costs.value(GridPoint(x:3,y:2)) == 255,"class terrain cost restricts expansion")
    board.terrain[board.index(GridPoint(x:3,y:2))] = 2
    let walls = try OriginalMovement.distanceField(profile:profile,board:board,moving:actor,seed:actor.position,limit:20)
    try check(walls.value(GridPoint(x:3,y:2)) == 255,"FF cost is impassable")
    board.terrain[board.index(GridPoint(x:3,y:2))] = 255
    let raw = try OriginalMovement.distanceField(profile:profile,board:board,moving:actor,seed:actor.position,limit:200,ignoreZOC:true)
    try check(raw.value(GridPoint(x:3,y:2)) == 197,"raw terrain255 uses its actual lookup window")
    board.terrain = Array(repeating:0,count:25)
    var ally = actor; ally.runtimeSlot = 1; ally.position = GridPoint(x:3,y:2)
    board.actors = [actor,ally,enemy]
    let occupancy = try OriginalMovement.distanceField(profile:profile,board:board,moving:actor,seed:actor.position,limit:4,ignoreZOC:true)
    try check(occupancy.value(ally.position) == 1 && occupancy.value(enemy.position) == 255,"friendly transit versus hostile blocking")
    try rejects {_ = try OriginalMovement.route(profile:profile,board:board,moving:actor,to:ally.position,budget:4)}
    var corridorActor = actor; corridorActor.position = GridPoint(x:0,y:1)
    var corridorEnemy = enemy; corridorEnemy.position = GridPoint(x:3,y:0)
    var corridor = OriginalMovementBoard(width:5,height:3,terrain:Array(repeating:2,count:15),actors:[corridorActor,corridorEnemy])
    for x in 0..<5 { corridor.terrain[corridor.index(GridPoint(x:x,y:1))] = 0 }
    corridor.terrain[corridor.index(corridorEnemy.position)] = 0
    let zoc = try OriginalMovement.distanceField(profile:profile,board:corridor,moving:corridorActor,seed:corridorActor.position,limit:4)
    try check(zoc.value(GridPoint(x:3,y:1)) == 3 && zoc.value(GridPoint(x:4,y:1)) == 255,"hostile ZOC cell is reachable but does not expand")
    var scripted = corridorActor; scripted.scriptFlags = 4
    corridor.actors = [scripted,corridorEnemy]
    let bypass = try OriginalMovement.distanceField(profile:profile,board:corridor,moving:scripted,seed:scripted.position,limit:4)
    try check(bypass.value(GridPoint(x:4,y:1)) == 4,"script flag4 bypasses ZOC, not hostile occupancy")
    try check(bypass.value(corridorEnemy.position) == 255,"script flag does not erase hostile unit blocking")
    board.actors = [actor]
    var center = actor; center.position = GridPoint(x:4,y:4)
    let large = OriginalMovementBoard(width:9,height:9,terrain:Array(repeating:0,count:81),actors:[center])
    let expected = [4,8,8,16,24]
    for code in 0...4 {
        var range = profile; range.attackRangeCodes[0] = code
        let points = try OriginalAI.attackCells(profile:range,board:large,actor:center)
        try check(points.count == expected[code],"source attack pattern cardinality")
        try check(Set(points).count == points.count,"source range pattern has no invented duplicate")
        if code == 2 { try check(!points.contains(GridPoint(x:4,y:3)),"range code2 does not include adjacent cardinal cells") }
    }
    var disabled = profile; disabled.attackRangeCodes[0] = 255
    let none = try OriginalAI.attackCells(profile:disabled,board:large,actor:center)
    try check(none.isEmpty,"source FF range means no candidates")
    var east = enemy; east.position = GridPoint(x:3,y:2)
    var north = enemy; north.runtimeSlot = 16; north.position = GridPoint(x:2,y:1)
    board.actors = [actor,east,north]
    let stats = [OriginalAICombatStats(runtimeSlot:0,attack:100,defense:100,currentTroops:600),
                 OriginalAICombatStats(runtimeSlot:15,attack:100,defense:100,currentTroops:600),
                 OriginalAICombatStats(runtimeSlot:16,attack:100,defense:100,currentTroops:600)]
    let choice = try OriginalAI.physicalAttackChoice(profile:profile,board:board,actor:actor,stats:stats,
        terrainDefensePercent:Array(repeating:0,count:256),preferredTarget:nil)
    try check(choice.targetSlot == 16 && choice.candidates.map(\.runtimeSlot) == [16,15],"equal target weights retain source range order")
    try check(choice.candidates.first?.rawScore == 150,"source predicted term plus own troop component")
    let preference = try OriginalAI.physicalAttackChoice(profile:profile,board:board,actor:actor,stats:stats,
        terrainDefensePercent:Array(repeating:0,count:256),preferredTarget:15)
    try check(preference.targetSlot == 15,"source preferred target bonus")
    let defended = try OriginalAI.targetScore(attacker:actor,attackerStats:stats[0],defender:east,
        defenderStats:stats[1],terrainDefensePercent:30,preferredTarget:nil)
    try check(defended == 135,"source integer terrain reduction")
    try rejects {_ = try OriginalAI.physicalAttackChoice(profile:profile,board:board,actor:actor,stats:[stats[0]],terrainDefensePercent:Array(repeating:0,count:256),preferredTarget:nil)}
    var invalid = profile; invalid.movementCosts[0].removeLast()
    try rejects {try invalid.validate()}
    var controller = profile
    controller.setupOrderModes = Array(repeating:255,count:256)
    controller.setupOrderModes?[7] = 3
    controller.strategyLevelRequirements = Array(repeating:Array(repeating:255,count:19),count:36)
    controller.strategyMPCosts = Array(repeating:255,count:36)
    controller.strategyCategories = Array(repeating:0,count:36)
    try controller.validate()
    let mapped = try controller.orderMode(rawMode:7,currentMode:2)
    let unchanged = try controller.orderMode(rawMode:8,currentMode:2)
    try check(mapped == 3 && unchanged == 2,"source order lookup applies its setter domain")
    let unavailable = try controller.availableStrategies(classID:0,level:2,mp:4)
    try check(unavailable.isEmpty,"no strategy is inferred when original table requirements fail")
    var enabled = controller
    enabled.strategyLevelRequirements?[35][0] = 3; enabled.strategyMPCosts?[35] = 4
    let available = try enabled.availableStrategies(classID:0,level:3,mp:4)
    try check(available == [35],"availability producer includes all36 entries with class/level/MP gates")
    var defenderAI = actor; defenderAI.runtimeSlot = 15; defenderAI.position = GridPoint(x:0,y:2)
    var approaching = actor; approaching.position = GridPoint(x:4,y:2); approaching.scriptFlags = 0x20
    let defensiveBoard = OriginalMovementBoard(width:7,height:5,terrain:Array(repeating:0,count:35),actors:[defenderAI,approaching])
    let defensiveStats = [OriginalAICombatStats(runtimeSlot:15,attack:100,defense:100,currentTroops:600),
                          OriginalAICombatStats(runtimeSlot:0,attack:100,defense:100,currentTroops:600)]
    let stationary = try OriginalAI.decision(profile:controller,board:defensiveBoard,actor:defenderAI,
        mode:2,movementBudget:3,level:2,mp:4,morale:100,maximumTroops:600,stats:defensiveStats,
        terrainDefensePercent:Array(repeating:0,count:256),preferredTarget:nil)
    try check(stationary.path == [defenderAI.position] && stationary.targetSlot == nil,"native mode2 holds its original position")
    let waiting = try OriginalAI.decision(profile:controller,board:defensiveBoard,actor:defenderAI,
        mode:3,movementBudget:2,level:2,mp:4,morale:100,maximumTroops:600,stats:defensiveStats,
        terrainDefensePercent:Array(repeating:0,count:256),preferredTarget:nil)
    try check(!waiting.activatedByInfluence && waiting.path == [defenderAI.position],"native mode3 waits beyond original influence reach")
    let reaction = try OriginalAI.decision(profile:controller,board:defensiveBoard,actor:defenderAI,
        mode:3,movementBudget:3,level:2,mp:4,morale:100,maximumTroops:600,stats:defensiveStats,
        terrainDefensePercent:Array(repeating:0,count:256),preferredTarget:nil)
    try check(reaction.activatedByInfluence && reaction.destination == GridPoint(x:3,y:2) && reaction.targetSlot == 0,
        "native mode3 reacts to source influence then scores the attack position")
    try check(reaction.path == (0...3).map{GridPoint(x:$0,y:2)},"native defensive movement retains source descending route")
    var noTrigger = defensiveBoard; noTrigger.actors[1].scriptFlags = 0
    let unmarked = try OriginalAI.decision(profile:controller,board:noTrigger,actor:defenderAI,
        mode:3,movementBudget:3,level:2,mp:4,morale:100,maximumTroops:600,stats:defensiveStats,
        terrainDefensePercent:Array(repeating:0,count:256),preferredTarget:nil)
    try check(!unmarked.activatedByInfluence,"influence activation preserves the original opponent scriptFlag20 test")
    try rejects {_ = try OriginalAI.decision(profile:controller,board:defensiveBoard,actor:defenderAI,
        mode:5,movementBudget:3,level:2,mp:4,morale:100,maximumTroops:600,stats:defensiveStats,
        terrainDefensePercent:Array(repeating:0,count:256),preferredTarget:nil)}
    try rejects {_ = try OriginalAI.decision(profile:enabled,board:defensiveBoard,actor:defenderAI,
        mode:2,movementBudget:3,level:3,mp:4,morale:100,maximumTroops:600,stats:defensiveStats,
        terrainDefensePercent:Array(repeating:0,count:256),preferredTarget:nil)}
    var distant = approaching; distant.position = GridPoint(x:6,y:2)
    let distantBoard = OriginalMovementBoard(width:9,height:5,terrain:Array(repeating:0,count:45),actors:[defenderAI,distant])
    let advance = try OriginalAI.decision(profile:controller,board:distantBoard,actor:defenderAI,
        mode:1,movementBudget:2,level:2,mp:4,morale:100,maximumTroops:600,stats:defensiveStats,
        terrainDefensePercent:Array(repeating:0,count:256),preferredTarget:nil)
    try check(advance.destination == GridPoint(x:2,y:2) && advance.targetSlot == nil,
        "mode1 follows the first source influence reverse field and partial-route goal bonus")
    let goalAdvance = try OriginalAI.decision(profile:controller,board:distantBoard,actor:defenderAI,
        mode:0,movementBudget:2,level:2,mp:4,morale:100,maximumTroops:600,stats:defensiveStats,
        terrainDefensePercent:Array(repeating:0,count:256),preferredTarget:nil,goal:GridPoint(x:5,y:2))
    try check(goalAdvance.destination == GridPoint(x:2,y:2) && goalAdvance.mode == 0,
        "mode0 preserves its coordinate order while approaching the source goal")
    let goalReached = try OriginalAI.decision(profile:enabled,board:distantBoard,actor:defenderAI,
        mode:4,movementBudget:2,level:3,mp:4,morale:100,maximumTroops:600,stats:defensiveStats,
        terrainDefensePercent:Array(repeating:0,count:256),preferredTarget:nil,goal:GridPoint(x:2,y:2))
    try check(goalReached.destination == GridPoint(x:2,y:2) && goalReached.mode == 3,
        "mode4 skips strategy scoring and becomes mode3 only after reaching the original goal")
    let expiredTarget = try OriginalAI.decision(profile:controller,board:distantBoard,actor:defenderAI,
        mode:3,movementBudget:2,level:2,mp:4,morale:100,maximumTroops:600,stats:defensiveStats,
        terrainDefensePercent:Array(repeating:0,count:256),preferredTarget:44)
    try check(expiredTarget.mode == 1 && expiredTarget.preferredTarget == nil,
        "an inactive source cache target clears the cache and changes to native order1")
    try rejects {_ = try OriginalAI.decision(profile:controller,board:distantBoard,actor:defenderAI,
        mode:0,movementBudget:2,level:2,mp:4,morale:100,maximumTroops:600,stats:defensiveStats,
        terrainDefensePercent:Array(repeating:0,count:256),preferredTarget:nil)}
    board.actors = [actor,east,north]
    let fallback = try OriginalAI.executionTarget(profile:controller,board:board,actor:actor,selected:44)
    try check(fallback == 15,"source execution falls through to the last range candidate when selected target is absent")
    var directed = defenderAI; directed.scriptFlags = 4
    var directedBoard = distantBoard; directedBoard.actors[0] = directed
    let directedMove = try OriginalAI.decision(profile:controller,board:directedBoard,actor:directed,
        mode:4,movementBudget:1,level:2,mp:4,morale:100,maximumTroops:600,stats:defensiveStats,
        terrainDefensePercent:Array(repeating:0,count:256),preferredTarget:nil,goal:GridPoint(x:4,y:2))
    try check(directedMove.destination == GridPoint(x:4,y:2) && directedMove.path.count == 5 && directedMove.targetSlot == nil,
        "scriptFlag4 coordinate order uses its source255 field and bypasses ordinary class budget")
    let blockedDirected = try OriginalAI.decision(profile:controller,board:directedBoard,actor:directed,
        mode:4,movementBudget:1,level:2,mp:4,morale:100,maximumTroops:600,stats:defensiveStats,
        terrainDefensePercent:Array(repeating:0,count:256),preferredTarget:nil,goal:distant.position)
    try check(blockedDirected.destination == directed.position && blockedDirected.changedGoal == directed.position && blockedDirected.mode == 3,
        "unreachable scripted goal resets the original goal to current position and changes coordinate order")
    let scriptedHold = try OriginalAI.decision(profile:enabled,board:directedBoard,actor:directed,
        mode:2,movementBudget:1,level:3,mp:4,morale:100,maximumTroops:600,stats:defensiveStats,
        terrainDefensePercent:Array(repeating:100,count:256),preferredTarget:nil)
    try check(scriptedHold.destination == directed.position && scriptedHold.positionWeight == 0 && scriptedHold.targetSlot == nil,
        "scriptFlag4 hold order skips seed evaluation, terrain, staying and available strategy scores")
    var scriptedRecoveryBoard = directedBoard
    scriptedRecoveryBoard.terrain[scriptedRecoveryBoard.index(GridPoint(x:2,y:2))] = 8
    let scriptedRecovery = try OriginalAI.decision(profile:enabled,board:scriptedRecoveryBoard,actor:directed,
        mode:3,movementBudget:1,level:3,mp:4,morale:20,maximumTroops:600,stats:defensiveStats,
        terrainDefensePercent:Array(repeating:100,count:256),preferredTarget:nil)
    try check(scriptedRecovery.destination == GridPoint(x:2,y:2) && scriptedRecovery.positionWeight == 50 && scriptedRecovery.targetSlot == nil,
        "scriptFlag4 reactive order uses source100 budget and recovery baseline without terrain/attack scoring")
    var strategyProfile = controller
    strategyProfile.strategyTerrainEligibility = Array(repeating:[0,255,4,8],count:3)
    strategyProfile.strategyLevelRequirements?[0][0] = 1; strategyProfile.strategyMPCosts?[0] = 1
    let eligible255 = try strategyProfile.strategyTerrainEligible(family:0,terrain:255)
    try check(eligible255,"source terrain eligibility retains FF as a literal comparison")
    let strategyTables = OriginalCombatTables(format:1,attackBase:Array(repeating:10,count:19),
        defenseBase:Array(repeating:10,count:19),troopBase:Array(repeating:10,count:19),
        troopGrowth:Array(repeating:0,count:19),physicalSubtypeByClass:Array(repeating:1,count:19),
        terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),
        items:(0..<64).map { OriginalItemEffect(id:$0,category:15,value:0) })
    let sourceStats = OriginalPersonStats(classID:0,level:10,troops:1000,attackScalar:100,defenseScalar:100,
        intellectScalar:100,morale:100,itemIDs:Array(repeating:255,count:8))
    let context = OriginalAIStrategyContext(stats:[.init(runtimeSlot:0,stats:sourceStats),.init(runtimeSlot:15,stats:sourceStats),
        .init(runtimeSlot:16,stats:sourceStats)],tables:strategyTables,weatherCode:1,rngState:1)
    var strategyRNG = OriginalRNG(state:1)
    let strategyChoice = try OriginalAI.strategyChoice(profile:strategyProfile,board:board,actor:actor,origin:actor.position,
        available:[0],context:context,preferredTarget:nil,rng:&strategyRNG)
    var twoDraws = OriginalRNG(state:1);_ = try twoDraws.next(bound:10);_ = try twoDraws.next(bound:10)
    try check(strategyChoice.abilityID == 0 && strategyChoice.targetSlot == 16 && strategyChoice.candidates.map(\.targetSlot) == [16,15],
        "strategy targets preserve source range ordering and strict ties")
    try check(strategyChoice.weight == 33 && strategyRNG == twoDraws,"strategy position scoring consumes every source target RNG draw")
    let combatStats = [0,15,16].map {OriginalAICombatStats(runtimeSlot:$0,attack:440,defense:440,currentTroops:1000)}
    let strategyPlan = try OriginalAI.decision(profile:strategyProfile,board:board,actor:actor,
        mode:2,movementBudget:2,level:10,mp:4,morale:100,maximumTroops:1000,stats:combatStats,
        terrainDefensePercent:Array(repeating:0,count:256),preferredTarget:nil,strategyContext:context)
    try check(strategyPlan.strategyID == 0 && strategyPlan.targetSlot == 16 && strategyPlan.positionWeight == 34,
        "native position evaluator compares original physical and strategy utility")
    try check(strategyPlan.rngAfter == twoDraws.state && context.rngState == 1,
        "strategy planning returns shared RNG writeback without consuming caller state during a preview")
    var allyOne = actor;allyOne.runtimeSlot = 1;allyOne.position = east.position
    var allyTwo = actor;allyTwo.runtimeSlot = 2;allyTwo.position = north.position
    let supportBoard = OriginalMovementBoard(width:5,height:5,terrain:Array(repeating:0,count:25),actors:[actor,allyOne,allyTwo])
    var hurt = sourceStats;hurt.morale = 30
    let supportContext = OriginalAIStrategyContext(stats:[.init(runtimeSlot:0,stats:sourceStats),.init(runtimeSlot:1,stats:hurt),
        .init(runtimeSlot:2,stats:hurt)],tables:strategyTables,weatherCode:1,rngState:1)
    strategyProfile.strategyCategories?[30] = 3;strategyRNG = OriginalRNG(state:1)
    let groupSupport = try OriginalAI.strategyChoice(profile:strategyProfile,board:supportBoard,actor:actor,origin:actor.position,
        available:[30],context:supportContext,preferredTarget:1,rng:&strategyRNG)
    try check(groupSupport.abilityID == 30 && groupSupport.targetSlot == nil && groupSupport.weight == 97,
        "aggregate support includes the full caster's RNG before allies, then subtracts100 and shifts")
    let supportOrder = try OriginalAI.strategyTargetSlots(profile:strategyProfile,board:supportBoard,actor:actor,abilityID:30)
    try check(supportOrder == [0,2,1],"source support range enumerates occupied origin before cardinal neighbors")
    let prospectiveTargets = try OriginalAI.strategyTargetSlots(profile:strategyProfile,board:supportBoard,actor:actor,
        abilityID:30,origin:GridPoint(x:0,y:2))
    try check(prospectiveTargets.isEmpty,"source AI prospective origins do not relocate the caster in the occupancy grid")
    var threeDraws = OriginalRNG(state:1)
    for _ in 0..<3 {_ = try threeDraws.next(bound:3)}
    try check(strategyRNG == threeDraws,"full caster consumes aggregate utility RNG even when its utility is zero")
    var largeTables = strategyTables;largeTables.troopBase = Array(repeating:255,count:19)
    var highCaster = sourceStats;highCaster.level = 255
    var depleted = sourceStats;depleted.level = 1;depleted.troops = 1;depleted.morale = 0
    let wrapContext = OriginalAIStrategyContext(stats:[.init(runtimeSlot:0,stats:highCaster),.init(runtimeSlot:1,stats:depleted)],
        tables:largeTables,weatherCode:1,rngState:1)
    var wrapBoard = supportBoard;wrapBoard.actors.removeLast()
    strategyProfile.strategyCategories?[27] = 2;strategyProfile.strategyCategories?[28] = 2
    strategyRNG = OriginalRNG(state:1)
    let byteWrap = try OriginalAI.strategyChoice(profile:strategyProfile,board:wrapBoard,actor:actor,origin:actor.position,
        available:[27,28],context:wrapContext,preferredTarget:1,rng:&strategyRNG)
    let preferredCandidates = byteWrap.candidates.filter{$0.targetSlot == 1}
    try check(preferredCandidates.map(\.comparisonWeight) == [285,285] && preferredCandidates.map(\.storedWeight) == [29,29] && byteWrap.abilityID == 28,
        "source preferred utility compares a word then stores a byte before the next candidate")
    let encoded = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(OriginalMovementProfile.self,from:encoded)
    try decoded.validate(); try check(decoded.movementCosts == profile.movementCosts,"lookup windows retain byte identities through Codable")
    print("Original movement/AI kernel self-tests passed: \(count)")
}
