// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func combatPresentationPolicySelfTests() throws {
    var checks = 0
    func check(_ value:Bool,_ reason:String) throws {
        guard value else { throw EngineError.invalid("Combat presentation regression: \(reason)") };checks += 1
    }
    var snapshot = OriginalCombatSnapshot(kind:1,subtype:0,attackerSlot:0,targetSlot:15,attackerPerson:0,targetPerson:1,
        attackerClass:3,targetClass:0,attackerLevel:1,targetLevel:1,attackerTroops:1000,targetTroops:1000,
        attackerMaxTroops:1000,targetMaxTroops:1000,attackerMorale:100,targetMorale:100,attackValue:60,defenseValue:40,
        terrain:0,terrainPercent:0,damage:100,moraleLoss:10,experience:0,experienceGain:2,counter:false)
    let ordinary = snapshot
    let all = CombatPresentationPolicy(mode:.all),none = CombatPresentationPolicy(mode:.none)
    let first = CombatPresentationPolicy(mode:.first),important = CombatPresentationPolicy(mode:.important)
    try check(all.showsCombat(snapshot,hasPresentedCombat:true) && !none.showsCombat(snapshot,hasPresentedCombat:false),"all and none select only pictures")
    try check(first.showsCombat(snapshot,hasPresentedCombat:false) && !first.showsCombat(snapshot,hasPresentedCombat:true),"first is a local display cursor")
    try check(!important.showsCombat(snapshot,hasPresentedCombat:false),"an ordinary healthy encounter is abbreviated")
    for person in [snapshot.attackerPerson,snapshot.targetPerson] {
        try check(CombatPresentationPolicy(mode:.important,importantPersonIDs:[person]).showsCombat(snapshot,hasPresentedCombat:true),"either participating favorite keeps its scene")
    }
    try check(CombatPresentationPolicy(mode:.important,importantPersonIDs:[-1,384,999]).importantPersonIDs.isEmpty,"invalid person identities are excluded")
    snapshot.damage = 1000
    try check(important.showsCombat(snapshot,hasPresentedCombat:true),"a committed lethal hit is important")
    snapshot = ordinary;snapshot.attackerTroops = 250
    try check(important.showsCombat(snapshot,hasPresentedCombat:true),"friendly health includes the exact quarter boundary")
    snapshot.attackerTroops = 251
    try check(!important.showsCombat(snapshot,hasPresentedCombat:true),"healthy friendly units do not trigger the quarter threshold")
    snapshot = ordinary;snapshot.targetSlot = 1;snapshot.damage = 750
    try check(important.showsCombat(snapshot,hasPresentedCombat:true),"a committed hit leaving an ally at a quarter is important")
    snapshot.targetSlot = 15
    try check(!important.showsCombat(snapshot,hasPresentedCombat:true),"enemy low health alone does not trigger an allied warning")
    snapshot = ordinary;snapshot.attackerTroops = 0;snapshot.targetTroops = 0;snapshot.damage = 0
    try check(!important.showsCombat(snapshot,hasPresentedCombat:true),"absent zero-health participants are not manufactured lethal or critical events")
    snapshot = ordinary;snapshot.damage = -300
    try check(!important.showsCombat(snapshot,hasPresentedCombat:true),"healing is not treated as a lethal result")
    snapshot.kind = 99
    try check(none.showsCombat(snapshot,hasPresentedCombat:true),"unknown scenes retain the established presentation path")
    try check(none.showsDuels && !CombatPresentationPolicy(mode:.all,showsDuels:false).showsDuels,"duels have an independent default-on presentation choice")
    try check(none.abbreviatedCues(for:ordinary) == [.number(slot:15,value:100,color:7,passes:3)],"abbreviated damage uses the existing map result cue exactly once")
    snapshot = ordinary;snapshot.kind = 2;snapshot.damage = 0
    try check(none.abbreviatedCues(for:snapshot) == [.number(slot:15,value:0,color:7,passes:3),.notice(.strategyFailed(person:0))],"failed strategy retains its source failure notice")

    let decoder = JSONDecoder(),encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
    for sourceChoice in [0,1] {
        let old = try decoder.decode(OriginalSettings.self,from:Data("{\"unitCombat\":\(sourceChoice),\"revision\":1,\"enemyMove\":false}".utf8))
        try check(old.combatPresentationMode == (sourceChoice == 0 ? .all : .none) && old.showDuelPresentation,"legacy visibility becomes a display policy")
        for mode in CombatPresentationPolicy.Mode.allCases {
            var changed = old;changed.combatPresentationMode = mode;changed.showDuelPresentation = false
            try check(changed.unitCombat == sourceChoice && changed.battleWord == old.battleWord,"new display choices preserve the source option word")
            try check(try decoder.decode(OriginalSettings.self,from:encoder.encode(changed)) == changed,"new policy round trips with legacy bits intact")
        }
    }
    let unknown = try decoder.decode(OriginalSettings.self,from:Data(#"{"unitCombat":1,"combatPresentationMode":"future","showDuelPresentation":false}"#.utf8))
    try check(unknown.combatPresentationMode == .none && !unknown.showDuelPresentation && unknown.unitCombat == 1,"unknown display mode falls back without changing original options")

    func makeSession(word:Int) throws -> OriginalBattleSession {
        let table = OriginalCombatTables(format:1,attackBase:Array(repeating:10,count:19),defenseBase:Array(repeating:10,count:19),
            troopBase:Array(repeating:10,count:19),troopGrowth:Array(repeating:2,count:19),physicalSubtypeByClass:Array(repeating:0,count:19),
            terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),
            items:(0..<64).map { OriginalItemEffect(id:$0,category:0,value:0) })
        let cardinal = [OriginalAIOffset(dx:0,dy:-1),OriginalAIOffset(dx:1,dy:0),OriginalAIOffset(dx:0,dy:1),OriginalAIOffset(dx:-1,dy:0)]
        let diagonal = [OriginalAIOffset(dx:-1,dy:-1),OriginalAIOffset(dx:1,dy:-1),OriginalAIOffset(dx:1,dy:1),OriginalAIOffset(dx:-1,dy:1)]
        let movement = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),classMovementBudgets:Array(repeating:3,count:19),
            attackRangeCodes:Array(repeating:0,count:19),movementCosts:Array(repeating:Array(repeating:1,count:256),count:4),
            cardinalOffsets:cardinal,diagonalOffsets:diagonal,extendedOffsets:cardinal,setupOrderModes:Array(repeating:2,count:256),
            strategyLevelRequirements:Array(repeating:Array(repeating:255,count:19),count:36),strategyMPCosts:Array(repeating:255,count:36),strategyCategories:Array(repeating:0,count:36))
        let people = try OriginalPeople(catalog:OriginalPersonCatalog(format:1,people:(0..<384).map { id in
            OriginalPersonDefinition(id:id,name:"synthetic \(id)",classID:id == 0 ? 3 : 0,level:1,experience:0,rawTroops:1000,
                defenseScalar:40,attackScalar:60,intellectScalar:50,personality:0,personalScalar:25,itemIDs:Array(repeating:255,count:8),
                sourceFlags:0,sourceRole:0,sourceContext2:0,sourceContext3:0)
        }),tables:table)
        var roster = OriginalRoster();roster.header = OriginalBattleHeader(preserveFriendlySlots:false,turnLimit:20,sourceByte2:0,discardedBytes:[0,0],objectives:[])
        roster.slots[0] = OriginalPlacement(ordinal:0,person:0,x:1,y:1,selector:0,flag:0,flags:0,rawMode:255,parameter:65535,classID:255,level:255)
        roster.slots[1] = OriginalPlacement(ordinal:1,person:1,x:2,y:1,selector:0,flag:0,flags:1,rawMode:0,parameter:0,classID:0,level:1)
        let session = try OriginalBattleSession(definition:BattleDefinition(id:"synthetic-presentation",width:5,height:5,coordinateSystem:"orthogonal",tiles:Array(repeating:0,count:25)),
            roster:&roster,people:people,combat:table,movement:movement,rng:OriginalRNG(state:4))
        session.sourceOptionsWord = word
        session.resultLog.attemptID = UUID(uuidString:"11111111-2222-3333-4444-555555555555")!
        return session
    }
    func state(_ session:OriginalBattleSession) throws -> [Data] {
        try [encoder.encode(session.people.values.values.sorted { $0.id < $1.id }),encoder.encode(session.units.values.sorted { $0.slot < $1.slot }),
             encoder.encode(session.turns),encoder.encode(session.rng),encoder.encode(session.suspensionState())]
    }
    func play(word:Int,emit:Bool,mode:CombatPresentationPolicy.Mode) throws -> (state:[Data],snapshots:[OriginalCombatSnapshot],shown:Int) {
        let session = try makeSession(word:word),flow = OriginalBattleFlow(session:session),policy = CombatPresentationPolicy(mode:mode)
        flow.presentsNativeActions = true;flow.emitsCombatPresentationCues = emit
        var seen = false,shown = 0,snapshots:[OriginalCombatSnapshot] = []
        func drain() throws {
            for _ in 0..<100 where flow.suspended {
                let before = try state(session)
                for cue in flow.takeCues() {
                    guard case .combat(let snapshot) = cue else { continue }
                    snapshots.append(snapshot)
                    if policy.showsCombat(snapshot,hasPresentedCombat:seen) { seen = true;shown += 1 }
                    else { _ = policy.abbreviatedCues(for:snapshot) }
                }
                try check(try state(session) == before,"display selection never mutates committed state or RNG")
                try flow.resumeSourceFlow()
            }
            try check(!flow.suspended,"display cues drain without a suspended operation")
        }
        try flow.start();try drain()
        _ = try flow.beginManualAttack(0,target:15);_ = try flow.finishManualOperation();try drain()
        try check(flow.canSuspendCheckpoint,"resolved attack leaves a resumable player boundary")
        try check(session.exchanges.first?.preludeDraws.count == (word&0xF0 == 0 ? 8 : 16),"class-three attack keeps the original option-dependent RNG prelude")
        let beforeReplay = try state(session)
        for snapshot in snapshots {
            // A newly entered view resets first-picture state, but replays only
            // the captured presentation and cannot re-execute the source hit.
            _ = first.showsCombat(snapshot,hasPresentedCombat:false)
            _ = first.showsCombat(snapshot,hasPresentedCombat:true)
        }
        try check(try state(session) == beforeReplay,"resetting the local first-picture cursor cannot alter resumed RNG or results")
        return (try state(session),snapshots,shown)
    }
    for word in [0,0x10] {
        let baseline = try play(word:word,emit:false,mode:.all)
        for mode in CombatPresentationPolicy.Mode.allCases {
            let result = try play(word:word,emit:true,mode:mode)
            try check(result.state == baseline.state,"each presentation policy matches its own original-word baseline including result log and RNG")
            try check(!result.snapshots.isEmpty,"independent snapshots are available even with the legacy enlarged view disabled")
            if mode == .none { try check(result.shown == 0,"none suppresses all supported combat pictures") }
            if mode == .first { try check(result.shown == 1,"first shows exactly the first committed combat picture") }
        }
    }

    let phaseSession = try makeSession(word:0),phaseFlow = OriginalBattleFlow(session:phaseSession)
    phaseFlow.presentsNativeActions = true;phaseFlow.emitsCombatPresentationCues = true
    var starts = 0,startsBeforeAI = true
    phaseFlow.onEnemyTurnStart = {
        starts += 1
        startsBeforeAI = startsBeforeAI && phaseSession.turns.stage == .enemyAI && !phaseSession.turns.pendingAI.isEmpty && phaseSession.exchanges.isEmpty
    }
    func drainPhase() throws {
        for _ in 0..<200 where phaseFlow.suspended { _ = phaseFlow.takeCues();try phaseFlow.resumeSourceFlow() }
        try check(!phaseFlow.suspended,"enemy phase presentation drains")
    }
    try phaseFlow.start();try drainPhase();try phaseFlow.finishManual();try drainPhase()
    try check(starts == 1 && startsBeforeAI,"enemy start is captured once at the phase boundary before the first AI decision")
    try phaseFlow.resumeSourceFlow();try phaseFlow.start()
    try check(starts == 1,"idle source resumption does not recapture the same enemy turn")
    print("Combat presentation policy self-tests: \(checks) assertions passed")
}
