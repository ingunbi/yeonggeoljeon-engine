// SPDX-License-Identifier: GPL-3.0-only
import AppKit

func battleAssistanceSelfTests() throws {
    var checks = 0
    func check(_ value:@autoclosure() throws -> Bool,_ reason:String) throws {
        guard try value() else {throw EngineError.invalid("Battle assistance regression: "+reason)}
        checks += 1
    }
    func rejected(_ body:() throws->Void)->Bool {do {try body();return false} catch {return true}}
    func makeSession(area:Bool = false) throws -> OriginalBattleSession {
        var items = (0..<64).map {OriginalItemEffect(id:$0,category:15,value:0)}
        items[5] = OriginalItemEffect(id:5,category:4,value:2)
        let tables = OriginalCombatTables(format:1,attackBase:Array(repeating:10,count:19),defenseBase:Array(repeating:10,count:19),
            troopBase:Array(repeating:10,count:19),troopGrowth:Array(repeating:0,count:19),physicalSubtypeByClass:Array(repeating:0,count:19),
            terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),items:items)
        let people = try OriginalPeople(catalog:OriginalPersonCatalog(format:1,people:(0..<384).map { id in
            OriginalPersonDefinition(id:id,name:"검증 장수 \(id)",classID:0,level:10,experience:3,rawTroops:1000,
                defenseScalar:80,attackScalar:70,intellectScalar:60,personality:0,personalScalar:0,
                itemIDs:Array(repeating:255,count:8),sourceFlags:0,sourceRole:0,sourceContext2:0,sourceContext3:0)
        }),tables:tables)
        let cardinal = [OriginalAIOffset(dx:0,dy:-1),.init(dx:1,dy:0),.init(dx:0,dy:1),.init(dx:-1,dy:0)]
        let diagonal = [OriginalAIOffset(dx:-1,dy:-1),.init(dx:1,dy:-1),.init(dx:1,dy:1),.init(dx:-1,dy:1)]
        var costs = Array(repeating:Array(repeating:1,count:256),count:4)
        costs[0][1] = 255;costs[0][2] = 3
        var levels = Array(repeating:Array(repeating:255,count:19),count:36)
        levels[0][0] = 1;levels[24][0] = 1
        var categories = Array(repeating:0,count:36)
        if area {for id in [3,17,30,33] {levels[id][0] = 1};categories[30] = 3;categories[33] = 3}
        let movement = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),
            classMovementBudgets:Array(repeating:3,count:19),attackRangeCodes:Array(repeating:0,count:19),movementCosts:costs,
            cardinalOffsets:cardinal,diagonalOffsets:diagonal,extendedOffsets:cardinal,setupOrderModes:Array(repeating:2,count:256),
            strategyLevelRequirements:levels,strategyMPCosts:Array(repeating:5,count:36),strategyCategories:categories,
            strategyTerrainEligibility:Array(repeating:[0,1,2,3],count:3))
        var roster = OriginalRoster()
        roster.header = OriginalBattleHeader(preserveFriendlySlots:false,turnLimit:20,sourceByte2:0,discardedBytes:[],objectives:[])
        roster.slots[0] = OriginalPlacement(ordinal:0,person:0,x:0,y:2,selector:0,flag:0,flags:0,rawMode:0,parameter:0,classID:0,level:10)
        let session = try OriginalBattleSession(definition:BattleDefinition(id:"synthetic-assistance",width:7,height:5,tiles:Array(repeating:0,count:35)),
            roster:&roster,people:people,combat:tables,movement:movement,rng:OriginalRNG(state:123))
        session.units = [
            0:.init(slot:0,person:0,position:.init(x:0,y:2),status:2,scriptFlags:0x20,orderMode:7,morale:70,mp:10),
            1:.init(slot:1,person:1,position:.init(x:1,y:2),status:2,scriptFlags:0x20,orderMode:7,morale:100,mp:1),
            2:.init(slot:2,person:2,position:.init(x:0,y:0),status:2,scriptFlags:0x20,orderMode:7,morale:100,mp:10),
            15:.init(slot:15,person:3,position:.init(x:6,y:4),status:2,scriptFlags:0x20,orderMode:0,morale:100,mp:10)]
        session.turns.stage = .manualFriendly
        return session
    }
    let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
    func snapshot(_ session:OriginalBattleSession) throws -> [Data] {
        try [encoder.encode(session.people.values),encoder.encode(session.units),encoder.encode(session.rng),
             encoder.encode(session.turns),encoder.encode(session.suspensionState())]
    }

    try check(BattleAssistance.strategyReasons(ability:0,cost:5,mp:2,rain:true) == [.mp(shortfall:3),.rain],"MP and rain reasons coexist")
    try check(BattleAssistance.strategyReasons(ability:5,cost:5,mp:5,rain:true).isEmpty,"rain only disables fire; exact MP cost is usable")
    let session = try makeSession(),before = try snapshot(session)
    let levels = session.movement.strategyLevelRequirements!,costs = session.movement.strategyMPCosts!
    let rows = OriginalBattleCommand.strategyRows(classID:0,level:10,mp:2,rain:true,levels:levels,costs:costs)
    try check(rows.count == 2 && rows.allSatisfy {!$0.enabled},"the source learned list remains visible while unavailable")
    try check(OriginalBattleCommand.strategyRows(classID:19,level:10,mp:2,rain:true,levels:levels,costs:costs).isEmpty,"invalid class cannot index a table")
    try check(OriginalBattleCommand.strategyRows(classID:0,level:10,mp:2,rain:true,levels:[[1]],costs:costs).isEmpty,"incomplete requirements fail without a crash")

    let origin = try BattleAssistance.movement(in:session,slot:0,to:.init(x:0,y:2))
    try check(origin.totalCost == 0 && origin.remaining == 3 && origin.route.count == 1,"origin costs zero rather than its entry terrain")
    let throughAlly = try BattleAssistance.movement(in:session,slot:0,to:.init(x:2,y:2))
    try check(throughAlly.reason == nil && throughAlly.totalCost == 2 && throughAlly.remaining == 1,"friendly occupancy permits passing but not stopping")
    try check(throughAlly.route == session.route(0,to:.init(x:2,y:2)),"preview follows the existing source route exactly")
    try check(try BattleAssistance.movement(in:session,slot:0,to:.init(x:1,y:2)).reason == .occupied,"friendly destination has an explicit reason")
    try check(try BattleAssistance.movement(in:session,slot:0,to:.init(x:-1,y:2)).reason == .outside,"off-board query is bounded")
    try check(try BattleAssistance.movement(in:session,slot:0,to:.init(x:6,y:4)).reason == .enemy,"visible enemy occupancy is explainable")
    try check(try snapshot(session) == before,"basic movement and availability queries preserve full state and RNG")

    session.terrain[1*7+2] = 1;session.terrain[2*7+3] = 2
    try check(try BattleAssistance.movement(in:session,slot:0,to:.init(x:2,y:1)).reason == .terrain,"class-forbidden terrain is distinct")
    try check(try BattleAssistance.movement(in:session,slot:0,to:.init(x:3,y:2)).reason == .budget(required:5,available:3),"source terrain cost explains budget deficiency")
    try session.people.update(0) {$0.itemIDs[0] = 5;$0.itemIDs[1] = 5}
    let equipped = try BattleAssistance.movement(in:session,slot:0,to:.init(x:3,y:2))
    try check(equipped.budget == 5 && equipped.totalCost == 5 && equipped.remaining == 0,"equipment maximum is added once, not duplicated")
    session.units[0]!.scriptFlags |= 0x40
    try check(try BattleAssistance.movement(in:session,slot:0,to:.init(x:2,y:2)).reason == .moved,"pending move cannot be advertised as another move")
    session.units[0]!.scriptFlags = 0xA0
    try check(try BattleAssistance.movement(in:session,slot:0,to:.init(x:2,y:2)).reason == .acted,"acted state has its own refusal")
    session.units[0]!.scriptFlags = 0x22
    try check(try BattleAssistance.movement(in:session,slot:0,to:.init(x:2,y:2)).reason == .confused,"confusion blocks the movement guide")
    let confusedBefore = try snapshot(session)
    let conditions = try BattleAssistance.conditions(in:session,slot:0)
    try check(conditions.first?.title == "혼란" && conditions.first?.facts.first?.value == "50%","condition probability comes from the source threshold")
    session.rng = OriginalRNG(state:98765)
    try check(try BattleAssistance.conditions(in:session,slot:0) == conditions,"guide does not reveal the live next RNG result")
    session.rng = OriginalRNG(state:123)
    try check(try snapshot(session) == confusedBefore,"status reading never applies the private probe's outcome")
    session.units[0]!.status = 4
    let retired = try BattleAssistance.conditions(in:session,slot:0)
    try check(retired.count == 1 && retired[0].title == "전선 이탈","retired unit is not offered a confusion recovery")

    let hidden = try makeSession()
    hidden.units[1] = nil;hidden.units[15]!.position = .init(x:1,y:2);hidden.units[15]!.scriptFlags = 0
    try check(try BattleAssistance.movement(in:hidden,slot:0,to:.init(x:1,y:2)).reason == .unavailable,"hidden occupant is never named as an enemy or a ZOC source")
    try check(rejected {_ = try BattleAssistance.conditions(in:hidden,slot:15)},"hidden enemy status cannot be inspected")
    let corridor = try makeSession();corridor.units[1] = nil;corridor.units[2] = nil
    corridor.terrain = Array(repeating:1,count:35)
    for x in 0..<7 {corridor.terrain[2*7+x] = 0}
    corridor.terrain[1*7+2] = 0;corridor.units[15]!.position = .init(x:2,y:1)
    try check(try BattleAssistance.movement(in:corridor,slot:0,to:.init(x:4,y:2)).reason == .control,"visible ZOC can be distinguished from terrain walls")
    corridor.units[15]!.scriptFlags = 0
    try check(try BattleAssistance.movement(in:corridor,slot:0,to:.init(x:3,y:2)).reason == .unavailable,"hidden ZOC does not gain a public direction or identity")

    let roster = try makeSession()
    try roster.people.update(0) {$0.rawTroops = 400}
    try roster.people.update(1) {$0.rawTroops = 200;$0.level = 11}
    roster.units[2]!.scriptFlags |= 0x80;roster.units[15]!.scriptFlags = 0
    let rosterBefore = try snapshot(roster),slots = [2,1,0,15]
    var options = BattleRosterOptions()
    try check(try BattleAssistance.rosterRows(in:roster,slots:slots,options:options) == [2,1,0],"hidden enemies are removed even from an unfiltered list")
    options.filters = [.ready]
    try check(try BattleAssistance.rosterRows(in:roster,slots:slots,options:options) == [1,0],"ready filter uses real command eligibility")
    options.filters = [.ready,.wounded];options.sort = .troops
    try check(try BattleAssistance.rosterRows(in:roster,slots:slots,options:options) == [1,0],"combined filters and troop sorting use slot identities")
    options.descending = true
    try check(try BattleAssistance.rosterRows(in:roster,slots:slots,options:options) == [0,1],"descending sort affects only presentation")
    options.filters = [.healer]
    try check(try BattleAssistance.rosterRows(in:roster,slots:slots,options:options) == [0],"healer needs learned recovery, enough MP and an unspent action")
    options.filters = [.confused]
    try check(try BattleAssistance.rosterRows(in:roster,slots:slots,options:options).isEmpty,"empty filters have an empty result rather than an unfiltered fallback")
    try check(try JSONDecoder().decode(BattleRosterOptions.self,from:encoder.encode(options)) == options,"roster preferences roundtrip without writing actual defaults")
    try check(try snapshot(roster) == rosterBefore,"filtering and sorting preserve people, original slots, turn and RNG")
    let projectedSession = try makeSession()
    projectedSession.units[1] = nil;projectedSession.units[2] = nil
    projectedSession.units[15]!.position = .init(x:3,y:2)
    try projectedSession.people.update(0) {$0.rawTroops = 100;$0.itemIDs[0] = 30}
    let projectionBefore = try snapshot(projectedSession),projection = try BattleProjection(projectedSession)
    let future = GridPoint(x:2,y:2),preview = try projection.preview(0,at:future)
    try check(preview.attackTargets == [15],"future-position preview finds a newly reachable enemy")
    try check(preview.strategies[0] == [15] && preview.strategies[24] == [0],"future strategy range handles damage and relocated self healing")
    let previewHP = try projection.physical(0,target:15)
    let strategyEffect = try projection.strategyEffect(0,ability:0,target:15)
    try check(strategyEffect.kind == .damage && strategyEffect.troops.lowerBound > 0 && (strategyEffect.successPercent ?? 0) > 0 && (strategyEffect.successPercent ?? 100) < 100,
        "strategy preview separates success-only damage from a non-certain probability")
    let projectedStrategyInput = OriginalStrategyInput(attacker:try projection.unit(0).stats,defender:try projection.unit(15).stats,
        terrainID:0,subtype:0,kind:2,weatherCode:0)
    for seed:UInt32 in [0,1,123,UInt32.max] {
        var actualRNG = OriginalRNG(state:seed),expectedRNG = OriginalRNG(state:seed)
        let kernel = try OriginalCombat.strategyKernel(projectedStrategyInput,tables:projectedSession.combat)
        _ = try expectedRNG.next(bound:kernel.bound);_ = try expectedRNG.next(bound:kernel.jitterBound)
        let result = try OriginalCombat.strategyStrike(projectedStrategyInput,tables:projectedSession.combat,rng:&actualRNG)
        try check((result.success ? strategyEffect.troops.contains(result.damage) : result.damage == 0) && actualRNG == expectedRNG,
            "shared strategy kernel preserves success/failure effect and both source draws")
    }
    try check(try OriginalCombat.rollProbability(bound:0,accepts:{$0 == 0}) == 100 && OriginalCombat.rollProbability(bound:1,accepts:{$0 > 0}) == 0,
        "zero and one bounds have exact probability endpoints")
    let byteProbability = try OriginalCombat.rollProbability(bound:300) {Int(UInt8(truncatingIfNeeded:$0)) > 200}
    let byteReference = Double((0..<32768).filter {Int(UInt8(truncatingIfNeeded:$0%300)) > 200}.count)*100/32768
    try check(byteProbability == byteReference && byteProbability < 20,"success-byte wrapping and modulo bias remain in probability forecasts")
    var strikeRNG = OriginalRNG(state:17)
    let strikeInput = OriginalPhysicalInput(attacker:try projection.unit(0).stats,defender:try projection.unit(15).stats,
        terrainID:0,subtype:0,defenderCounterDisabled:false)
    let actualStrike = try OriginalCombat.physicalStrike(strikeInput,tables:projectedSession.combat,rng:&strikeRNG)
    try check(previewHP.damage == actualStrike.damage && previewHP.adjustedDefense == actualStrike.adjustedDefense && previewHP.counterRoll == nil,
        "pure physical kernel matches execution without producing a sampled counter")
    let threats = try projection.threats()
    try check(threats.sources(.init(x:2,y:2)) == [15] && threats.physical[.init(x:2,y:2)] == [15],"multiple enemy origins count the same source only once")
    projectedSession.units[16] = .init(slot:16,person:4,position:.init(x:4,y:2),status:2,scriptFlags:0x20,orderMode:0,mp:10)
    let overlap = try BattleProjection(projectedSession).threats()
    try check(overlap.sources(.init(x:3,y:1)) == [15,16],"overlapping threats preserve two distinct sources")
    try check(try BattleProjection(projectedSession).threats(only:15).sources(.init(x:3,y:1)) == [15],"pinning limits the source set without guessing an AI target")
    projectedSession.units[16] = nil
    let healing = try projection.recoveries(target:0)
    try check(healing.contains {$0.caster == 0 && $0.action == .strategy(24) && $0.troops.lowerBound > 0},"target-first recovery finds source-valid self strategy")
    try check(healing.contains {$0.action == .item(30) && $0.cost == 0},"target-first recovery includes carried tools separately from MP cost")
    let restored = healing.first {$0.action == .strategy(24)}!
    let healInput = OriginalHealingInput(caster:try projection.unit(0).stats,target:try projection.unit(0).stats,
        targetStatus:2,targetConditionFlags:0x20,encodedSubtype:1)
    for seed:UInt32 in [0,1,123,UInt32.max] {
        var rng = OriginalRNG(state:seed)
        let actual = try OriginalCombat.heal(healInput,tables:projectedSession.combat,rng:&rng)
        try check(restored.troops.contains(actual.troopsDelta),"shared healing range contains execution for independent RNG seeds")
    }
    try check(try snapshot(projectedSession) == projectionBefore,"all public projections leave units, people, movement origins, log and RNG intact")
    projectedSession.rng = OriginalRNG(state:999)
    try check(try BattleProjection(projectedSession).key == projection.key,"live RNG is absent from both the projection and cache identity")
    projectedSession.units[15]!.scriptFlags = 0
    let hiddenProjection = try BattleProjection(projectedSession)
    projectedSession.units[15]!.position = .init(x:6,y:4)
    try check(try BattleProjection(projectedSession).key == hiddenProjection.key,"hidden enemy position does not leak through projection invalidation")
    try check(try hiddenProjection.threats().cells.isEmpty && hiddenProjection.preview(0,at:future).attackTargets.isEmpty,"hidden enemy has no threat or target representation")
    projectedSession.units[0]!.scriptFlags |= 0x80
    try check(try BattleProjection(projectedSession).recoveries(target:0).isEmpty,"an acted healer is not offered another command")
    projectedSession.units[0]!.scriptFlags = 0x60
    try check(try BattleProjection(projectedSession).origins(0).map(\.point) == [projectedSession.units[0]!.position],"a moved actor only offers its current cell")
    let turnSession = try makeSession(),turnBefore = EnemyTurnSnapshot(try makeSession())
    try turnSession.people.update(0) {$0.rawTroops = 400}
    turnSession.units[0]!.mp = 3;turnSession.units[0]!.scriptFlags |= 2
    turnSession.units[15]!.scriptFlags = 0
    let turnState = try snapshot(turnSession),turnAfter = EnemyTurnSnapshot(turnSession)
    let changes = turnBefore.changes(to:turnAfter)
    try check(changes.first(where:{$0.person == 0})?.detail.contains("병력 1000 → 400") == true &&
              changes.first(where:{$0.person == 0})?.detail.contains("책략치 10 → 3") == true &&
              changes.first(where:{$0.person == 0})?.detail.contains("혼란 발생") == true,"enemy-turn summary combines observed HP, MP and confusion changes")
    try check(turnAfter.units[3] == nil && changes.first(where:{$0.person == 3})?.point == nil,"hidden enemy is removed and disappearance supplies no coordinate")
    turnSession.units[15]!.position = .init(x:5,y:3)
    try check(turnAfter.changes(to:EnemyTurnSnapshot(turnSession)).isEmpty,"hidden movement cannot appear in the turn summary")
    turnSession.units[15]!.position = .init(x:6,y:4)
    try check(try snapshot(turnSession) == turnState,"turn comparison does not mutate live state or RNG")
    var favorites = OfficerCommandFavorites()
    try favorites.set(person:0,actions:[.strategy(24),.item(30),.strategy(0)])
    let favoriteData = try encoder.encode(favorites)
    try check(try JSONDecoder().decode(OfficerCommandFavorites.self,from:favoriteData) == favorites,"ordered officer favorites survive value encoding")
    try check(rejected {try favorites.set(person:0,actions:[.strategy(24),.strategy(24)])},"favorite duplicates are rejected transactionally")
    try check(rejected {try favorites.set(person:0,actions:[.item(64)])},"unknown favorite IDs cannot reach command routing")
    try check(favorites.actions(for:0) == [.strategy(24),.item(30),.strategy(0)] && favorites.actions(for:1).isEmpty,"failed changes preserve the owner and order")
    let favoriteSession = try makeSession(),favoriteState = try snapshot(favoriteSession)
    try check(try OfficerCommandFavorites.reasons(.strategy(24),in:favoriteSession,slot:0).isEmpty,"learned affordable favorite uses the current source condition")
    try check(try OfficerCommandFavorites.reasons(.item(30),in:favoriteSession,slot:0).contains("소지품 없음"),"missing favorite tool remains readable with a reason")
    try check(try snapshot(favoriteSession) == favoriteState,"favorite lookup changes no source state")
    let growthSession = try makeSession()
    growthSession.units[1] = nil;growthSession.units[15]!.position = .init(x:1,y:2)
    try growthSession.people.update(0) {$0.experience = 95;$0.rawTroops = 400}
    try growthSession.people.update(3) {$0.rawTroops = 1}
    let growthState = try snapshot(growthSession),growthProjection = try BattleProjection(growthSession)
    let names = (0..<36).map {"검증 책략 \($0)"}
    let physicalGrowth = try growthProjection.growth(0,target:15,ability:nil,names:names)
    try check(physicalGrowth.branches.first?.hit == 6 && physicalGrowth.branches.first?.defeated == 48 && physicalGrowth.branches.first?.level == 11 && physicalGrowth.branches.first?.experience == 49,
        "commander defeat growth uses the source runtime-slot bonus and level remainder")
    let strategyGrowth = try growthProjection.growth(0,target:15,ability:0,names:names)
    try check(strategyGrowth.branches.count == 2 && strategyGrowth.branches.first?.total == 6 && strategyGrowth.branches.last?.total == 54,
        "failed and lethal strategy branches retain the source hit and defeat grants")
    let supportGrowth = try growthProjection.growth(0,target:0,ability:24,names:names)
    try check(supportGrowth.branches.first?.completion == 8 && supportGrowth.branches.first?.level == 11 && supportGrowth.branches.first?.experience == 3,
        "completed recovery uses its one flat command grant")
    try check(try snapshot(growthSession) == growthState,"growth branches and next-learning lookup do not apply their results")
    try growthSession.people.update(0) {$0.rawTroops = 1000}
    try check(try BattleProjection(growthSession).growth(0,target:0,ability:24,names:names).branches.isEmpty,"rejected full-health recovery earns no preview completion grant")
    growthSession.units[0]!.person = 256;try growthSession.people.update(256) {$0.experience = 95}
    let npcGrowth = try BattleProjection(growthSession).growth(0,target:15,ability:nil,names:names)
    try check(npcGrowth.branches.first?.ignoredReason != nil && npcGrowth.branches.first?.experience == 95,"NPC person-word identity keeps experience unchanged")
    let areaSession = try makeSession(area:true)
    areaSession.units[0]!.position = .init(x:1,y:2);areaSession.units[0]!.scriptFlags = 0x60
    areaSession.units[1]!.position = .init(x:0,y:2);areaSession.units[15]!.position = .init(x:2,y:2)
    areaSession.units[16] = .init(slot:16,person:4,position:.init(x:2,y:3),status:2,scriptFlags:0x20,orderMode:0,mp:10)
    try areaSession.people.update(1) {$0.rawTroops = 900}
    let areaState = try snapshot(areaSession),areaProjection = try BattleProjection(areaSession)
    let areaResult = try areaProjection.areaAdvice(0,ability:3)
    let cross = areaResult.candidates.first {$0.center == 15}
    try check(cross?.targets == [15,16] && cross?.usefulTargets == 2,"area advice keeps center then source cardinal order without duplicate targets")
    try check(areaResult.candidates.allSatisfy {$0.origin == GridPoint(x:1,y:2)},"a moved area caster has no second hypothetical move")
    let areaHeal = try areaProjection.areaAdvice(0,ability:33)
    try check(areaHeal.candidates.first?.usefulTargets == 1 && areaHeal.candidates.first?.troops.upperBound ?? 101 <= 100,"area healing ranks actual capped increases and does not count full-health allies")
    try check(try snapshot(areaSession) == areaState,"area candidate queries preserve MP, movement, events and RNG")
    try areaSession.people.update(0) {$0.experience = 99}
    let levelAdvice = try BattleProjection(areaSession).areaAdvice(0,ability:3).candidates.first(where:{$0.center == 15})
    try check(levelAdvice?.effects[1].facts.contains(where:{$0.label == "순차 시전자 레벨" && $0.value == "11~11"}) == true,"area damage propagates intermediate level gain into later source effects")
    areaSession.units[16]!.scriptFlags = 0
    try check(try BattleProjection(areaSession).areaAdvice(0,ability:3).candidates.allSatisfy {!$0.targets.contains(16)},"hidden splash targets do not enter advice counts")
    areaSession.units[0]!.scriptFlags = 0x20
    let boundedArea = try BattleProjection(areaSession).areaAdvice(0,ability:3,limit:1)
    try check(boundedArea.examined == 1 && boundedArea.limited,"area search explicitly reports its candidate cap")
    let cooperativeSession = try makeSession()
    cooperativeSession.units[15]!.position = .init(x:2,y:2)
    cooperativeSession.units[0]!.position = .init(x:1,y:2);cooperativeSession.units[0]!.scriptFlags = 0x60
    cooperativeSession.units[1]!.position = .init(x:2,y:1);cooperativeSession.units[1]!.scriptFlags = 0x60
    cooperativeSession.units[2]!.scriptFlags |= 0x80
    let cooperativeState = try snapshot(cooperativeSession),cooperativeProjection = try BattleProjection(cooperativeSession)
    let coop = try cooperativeProjection.cooperation(target:15)
    let pair = try cooperativeProjection.evaluateCooperation([
        .init(actor:0,origin:.init(x:1,y:2),action:.attack,target:15),.init(actor:1,origin:.init(x:2,y:1),action:.attack,target:15)],target:15)
    try check(pair.steps.count == 2 && pair.exhaustive && pair.counterLoss.lowerBound == 0 && pair.counterLoss.upperBound > 0,"two attacks include both counter and no-counter outcomes")
    try check(try cooperativeProjection.cooperativeChoices(target:15).contains(where:{if case .strategy(0) = $0.action {return true};return false}),"cooperative candidate generation includes learned offensive strategies")
    let capped = try cooperativeProjection.evaluateCooperation([.init(actor:0,origin:.init(x:1,y:2),action:.attack,target:15)],target:15,branchLimit:1)
    try check(!capped.exhaustive && !capped.guaranteed,"truncated branches cannot claim a guaranteed defeat")
    for seed:UInt32 in [0,1,2,123,65535,UInt32.max] {
        let live = try makeSession();live.units = cooperativeSession.units;live.rng = OriginalRNG(state:seed)
        let projected = try BattleProjection(live).projectedStep(.init(actor:0,origin:.init(x:1,y:2),action:.attack,target:15))
        _ = try live.attack(0,target:15)
        let actual = try BattleProjection(live)
        try check(projected.exhaustive && projected.branches.contains(where:{$0.model.key == actual.key}),"physical branch contains actual HP, XP, morale, confusion and counter results without predicting RNG")
        let areaLive = try makeSession(area:true);areaLive.units[0]!.position = .init(x:1,y:2);areaLive.units[0]!.scriptFlags = 0x60
        areaLive.units[1]!.position = .init(x:0,y:2);areaLive.units[15]!.position = .init(x:2,y:2)
        areaLive.units[16] = .init(slot:16,person:4,position:.init(x:2,y:3),status:2,scriptFlags:0x20,orderMode:0,mp:10)
        try areaLive.people.update(0) {$0.experience = 99};areaLive.rng = OriginalRNG(state:seed)
        let areaProjected = try BattleProjection(areaLive).projectedStep(.init(actor:0,origin:.init(x:1,y:2),action:.strategy(3),target:15),branchLimit:1024)
        _ = try areaLive.executeStrategy(0,abilityID:3,target:15)
        let areaActual = try BattleProjection(areaLive)
        try check(areaProjected.exhaustive && areaProjected.branches.contains(where:{$0.model.key == areaActual.key}),"sequential area branches contain actual later-level damage, XP and MP results")
    }
    try check(coop.candidates.allSatisfy {Set($0.steps.map(\.actor)).count == $0.steps.count && Set($0.steps.map(\.origin)).count == $0.steps.count},"cooperation cannot reuse one actor or occupy the same destination")
    try check(try cooperativeProjection.cooperation(target:15,limit:1).limited,"cooperation exposes bounded search rather than claiming a global optimum")
    try check(try snapshot(cooperativeSession) == cooperativeState,"cooperative planning consumes no source state or RNG")
    let collisionSession = try makeSession();collisionSession.units[15]!.position = .init(x:3,y:2)
    let collisionBefore = try snapshot(collisionSession),collisionModel = try BattleProjection(collisionSession)
    let contested = GridPoint(x:2,y:2)
    let collision = try collisionModel.evaluateCooperation([.init(actor:0,origin:contested,action:.attack,target:15),.init(actor:1,origin:contested,action:.attack,target:15)],target:15)
    try check(collision.boundaries.contains(where:{$0.contains("뒤 행동")}) && collision.steps.last?.damageRange == 0...0,"a first mover occupying the second destination stops that hypothetical action")
    try check(try snapshot(collisionSession) == collisionBefore,"collision rejection leaves the real units, movement origins and RNG untouched")
    try collisionSession.people.update(3) {$0.rawTroops = 1}
    let terminal = try BattleProjection(collisionSession).projectedStep(.init(actor:0,origin:contested,action:.attack,target:15))
    try check(terminal.branches.allSatisfy {$0.boundary != nil && (try? $0.model.unit(0).live.scriptFlags&0x80) == 0},"retirement is a hard script boundary before command completion; no event is guessed")
    cooperativeSession.units[15]!.scriptFlags = 0
    try check(rejected {_ = try BattleProjection(cooperativeSession).cooperation(target:15)},"hidden targets cannot be used for cooperative advice")
    for mode in BattleMapViewMode.allCases {
        let layout = BattleMapViewport.layout(source:.source,width:40,height:24,mode:mode)
        for point in [GridPoint(x:0,y:0),.init(x:39,y:0),.init(x:0,y:23),.init(x:39,y:23)] {
            var camera = OriginalBattleCamera(width:40,height:24,layout:layout);camera.center(on:point)
            let box = camera.rect(of:point,in:layout.viewportRect,size:layout.cell)
            try check(camera.cell(at:CGPoint(x:box.midX,y:box.midY),in:layout.viewportRect,size:layout.cell) == point,"map view mode preserves draw/hit inversion at every edge")
            try check(camera.cell(at:CGPoint(x:layout.viewportRect.maxX+1,y:layout.viewportRect.midY),in:layout.viewportRect,size:layout.cell) == nil,"map letterbox and sidebar cannot become cells")
        }
        if mode == .overview {try check(layout.columns == 40 && layout.rows == 24,"overview contains the entire original map")}
    }
    for seed:UInt32 in [0,1,123,UInt32.max] {for requested in [-1,0,10,70,90,100] {for flags in [0x20,0x22] {
        var actualRNG = OriginalRNG(state:seed),expectedRNG = actualRNG
        let stats = try cooperativeProjection.unit(0).stats
        let kernel = try OriginalCombat.moraleKernel(stats:stats,unitStatus:2,conditionFlags:flags,requestedMorale:requested)
        let loss = kernel.lossRequired ? try expectedRNG.next(bound:5) : nil
        let recovery = kernel.recoveryRollRequired ? try expectedRNG.next(bound:100) : nil
        let actual = try OriginalCombat.setMorale(stats:stats,unitStatus:2,conditionFlags:flags,requestedMorale:requested,rng:&actualRNG)
        try check(actual == kernel.result(lossRoll:loss,recoveryRoll:recovery) && actualRNG == expectedRNG,"shared morale producer preserves source draw count and exact flags/results")
    }}}
    var controlPreferences = AppControlPreferences();controlPreferences.battleMapMode = .large
    try check(try JSONDecoder().decode(AppControlPreferences.self,from:encoder.encode(controlPreferences)).battleMapMode == .large,"default map scale persists independently of battle state")
    controlPreferences.battleMapMode = .overview
    try check(try JSONDecoder().decode(AppControlPreferences.self,from:encoder.encode(controlPreferences)).battleMapMode == .standard,"overview is a temporary inspection mode, never a default play scale")
    let identity = String(repeating:"a",count:64),publicObjective = "검증 대상 퇴각"
    let context = ReviewedEventHints.Context(sourceIdentity:identity,battleID:session.definition.id,turn:1)
    var hint = ReviewedEventHints.Hint(id:"synthetic",battleID:session.definition.id,lightText:"확인한 사건",detailedText:"검증용 조건",conditions:[.turnAtLeast(1)],evidence:[.init(relativeFile:"synthetic.bin",byteOffset:4,byteLength:2,reviewNote:"합성 근거")],publicTargetPerson:3,completion:.init(recordID:"test",sourceOffset:4,opcode:1,status:0))
    var catalog = ReviewedEventHints.Catalog(sourceIdentity:identity,reviewed:true,hints:[hint])
    var progress = ReviewedEventHints.Progress(sourceIdentity:identity);progress.recordCompleted("synthetic")
    try check(BattleObjectiveTracker.conditions(catalog:catalog,context:context,progress:progress,publicText:publicObjective).isEmpty,"a completed duel/event cannot implicitly become a victory objective")
    hint.objectiveText = publicObjective;catalog.hints = [hint]
    let tracked = BattleObjectiveTracker.conditions(catalog:catalog,context:context,progress:progress,publicText:publicObjective)
    try check(tracked.first?.state == .confirmed,"exact reviewed objective binding reads committed completion progress")
    try check(BattleObjectiveTracker.conditions(catalog:catalog,context:context,progress:nil,publicText:publicObjective).first?.state == .pending,"condition satisfaction alone never marks objective completion")
    try check(BattleObjectiveTracker.conditions(catalog:catalog,context:context,progress:progress,publicText:"다른 목표").isEmpty,"different objective prose never inherits a similar event")
    session.units[15]!.scriptFlags = 0
    try check(BattleObjectiveTracker.entries(session:session,publicText:publicObjective,conditions:tracked).first?.target == nil,"objective locations never reveal a hidden target")
    try check(BattleObjectiveTracker.entries(session:session,publicText:publicObjective,conditions:[]).first?.state == .unavailable,"unknown mappings explicitly remain unavailable")
    var annotations = BattleAnnotations(battleID:favoriteSession.definition.id,attemptID:favoriteSession.resultLog.attemptID,width:7,height:5)
    let pin = BattleAnnotations.Entry(id:UUID(),kind:.pin,start:.init(x:0,y:0),end:nil,text:"집결",style:.gold)
    try annotations.upsert(pin)
    try check(annotations.matches(favoriteSession) && annotations.entries == [pin],"annotation identity belongs to one battle attempt")
    let annotationsData = try encoder.encode(annotations)
    try check(try JSONDecoder().decode(BattleAnnotations.self,from:annotationsData) == annotations,"annotations round-trip map coordinates and user text")
    var invalidPin = pin;invalidPin.start.x = 7
    try check(rejected {try annotations.upsert(invalidPin)} && annotations.entries == [pin],"out-of-map annotation edits roll back")
    invalidPin = pin;invalidPin.text = String(repeating:"가",count:81)
    try check(rejected {try annotations.upsert(invalidPin)},"annotation length uses the 80-character boundary")
    var wrongAttempt = annotations;wrongAttempt.attemptID = UUID()
    try check(!wrongAttempt.matches(favoriteSession),"retrying the same battle cannot inherit another attempt's marks")
    let line = BattleAnnotations.Entry(id:UUID(),kind:.line,start:.init(x:0,y:0),end:.init(x:6,y:4),text:"방어",style:.blue)
    try annotations.upsert(line);annotations.remove(pin.id)
    try check(annotations.entries == [line],"annotation removal never rewrites another entry")
    try check(try snapshot(favoriteSession) == favoriteState,"map preference and annotation operations leave source gameplay untouched")
    print("Battle assistance self-tests passed: \(checks)")
}
