// SPDX-License-Identifier: GPL-3.0-only
import AppKit

struct OriginalBattleVerification:Codable {
    var format = 1
    var kind = "isolated original-source kernel integration; synthetic player input driver"
    var sourceBattleID:String
    var sourceProvenance:JSONValue?
    var initialUnits:[OriginalLiveUnit]
    var finalUnits:[OriginalLiveUnit]
    var finalPeople:[OriginalPersonDefinition]
    var turns:OriginalTurnState
    var hooks:[OriginalTurnHook]
    var sourceObjectiveEvents:[OriginalCampaignEvent]
    var exchanges:[OriginalStrikeExchange]
    var strategies:[OriginalStrategyExecution]
    var initialRNG:UInt32
    var finalRNG:UInt32
    var stoppedReason:String
    var limitations:[String]
}

/// A driver generates legal player inputs to exercise restored code. Its
/// path/target preferences are test choices, never the game's enemy AI.
func verifyOriginalBattle(_ id:String,data:DataSet,output:URL) throws {
    let output = try verificationDirectory(output,excluding:data.root)
    let source = try OriginalGameData(root:data.root),seed:UInt32 = 1
    let session = try source.isolatedBattle(id,rng:OriginalRNG(state:seed))
    let initial = session.units.values.sorted(by:{$0.slot < $1.slot})
    var hooks:[OriginalTurnHook] = [],reason = "driver-round-budget",rounds = 0
    let view = try OriginalBattleView(session:session,background:battleBackground(session.definition,root:data.root))
    // Capture is native AppKit offscreen rendering; no keyboard/mouse event is
    // synthesized and original-runtime pixel/AI/RNG parity is not asserted.
    try view.capture(to:output.appendingPathComponent("original-battle-initial.png"))
    outer: while rounds < min(session.header.turnLimit,30),session.turns.result == 0 {
        guard let round = try session.beginRound() else { reason = "source-turn-limit-result";break }
        hooks.append(round);hooks.append(try session.prepareFriendlyRound());try session.enterManualFriendly()
        for slot in (0..<15) {
            guard let unit = try? session.requireManualUnit(slot),unit.scriptFlags&0x80 == 0 else { continue }
            let board = try session.board(),actor = board.actors.first(where:{$0.runtimeSlot == slot})!
            let enemies = board.actors.filter{$0.active && $0.sourceFaction != actor.sourceFaction}.sorted{$0.runtimeSlot < $1.runtimeSlot}
            guard let nearest = enemies.min(by: { abs($0.position.x-unit.position.x)+abs($0.position.y-unit.position.y) < abs($1.position.x-unit.position.x)+abs($1.position.y-unit.position.y) }) else { reason = "no-active-opponent; no-elimination-result-invented";break outer }
            var cells = try OriginalAI.attackCells(profile:session.movement,board:board,actor:actor)
            if !enemies.contains(where:{cells.contains($0.position)}) {
                let points = try session.reachable(slot)
                if let destination = points.sorted(by: { a,b in
                    let da = abs(a.x-nearest.position.x)+abs(a.y-nearest.position.y),db = abs(b.x-nearest.position.x)+abs(b.y-nearest.position.y)
                    return da == db ? (a.y == b.y ? a.x < b.x : a.y < b.y) : da < db
                }).first,destination != unit.position { _ = try session.move(slot,to:destination) }
                let movedBoard = try session.board(),movedActor = movedBoard.actors.first(where:{$0.runtimeSlot == slot})!
                cells = try OriginalAI.attackCells(profile:session.movement,board:movedBoard,actor:movedActor)
            }
            if let enemy = enemies.first(where:{cells.contains($0.position)}) { _ = try session.attack(slot,target:enemy.runtimeSlot) }
            else { _ = try session.waitManually(slot) }
            hooks.append(session.sourceUnitHook(slot))
            if !session.objectiveEvents.isEmpty { reason = "source-objective-event-awaits-campaign";break outer }
        }
        try session.finishManualFriendly()
        for phase in 0..<2 {
            if phase == 1 { try session.prepareEnemyPhase() }
            while let slot = session.turns.pendingAI.first {
                guard let unit = session.units[slot],unit.status == 2,unit.orderMode != 7,unit.scriptFlags&0x80 == 0 else { try session.skipNativeUnit(slot);continue }
                let decision:OriginalAIDecision
                do { decision = try session.aiDecision(slot) }
                catch OriginalAIError.unsupported(let detail) { reason = "unsupported-original-ai: \(detail)";break outer }
                try session.applyAIMovement(slot,decision)
                if let strategy = decision.strategyID { _ = try session.executeStrategy(slot,abilityID:strategy,target:decision.targetSlot) }
                else if let target = decision.targetSlot { _ = try session.attack(slot,target:target) }
                if let hook = try session.completeNativeUnit(slot) { hooks.append(hook) }
                if !session.objectiveEvents.isEmpty { reason = "source-objective-event-awaits-campaign";break outer }
            }
        }
        try session.completeRound();rounds += 1
    }
    try view.capture(to:output.appendingPathComponent("original-battle-final.png"))
    let activeIDs = Set(initial.map(\.person))
    let report = OriginalBattleVerification(sourceBattleID:id,sourceProvenance:session.definition.source,
        initialUnits:initial,finalUnits:session.units.values.sorted(by:{$0.slot < $1.slot}),
        finalPeople:session.people.values.values.filter{activeIDs.contains($0.id)}.sorted{$0.id < $1.id},
        turns:session.turns,hooks:hooks,sourceObjectiveEvents:session.objectiveEvents,exchanges:session.exchanges,strategies:session.strategyExecutions,
        initialRNG:seed,finalRNG:session.rng.state,stoppedReason:reason,
        limitations:["Initial clear flags and lexical placement producers define an isolated research state; campaign reachability was not established.",
                     "The scripted player input policy is only a test driver; supported enemy decisions use source-derived controllers.",
                     "Campaign hooks are retained but not executed by this isolated check. A source goal event is not an asserted campaign victory.",
                     "Seed1 is explicit test input; source clock packing and implemented call order do not establish whole-DOS RNG timeline parity.",
                     "Markers are native diagnostic geometry over the original map; original combat sprites and animation are not reproduced.",
                     "No original DOS executable or existing save was run or modified; OS input delivery is not tested."])
    let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
    try encoder.encode(report).write(to:output.appendingPathComponent("original-battle-verification.json"),options:.atomic)
    print("Original kernel integration: \(id), \(session.exchanges.count) exchanges, \(session.turns.roundIndex) rounds, \(reason)")
}
