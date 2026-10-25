// SPDX-License-Identifier: GPL-3.0-only
import AppKit

func verificationDirectory(_ destination:URL,excluding input:URL) throws -> URL {
    let output = destination.standardizedFileURL.resolvingSymlinksInPath()
    let source = input.standardizedFileURL.resolvingSymlinksInPath()
    guard output != source, !source.path.hasPrefix(output.path+"/"), !output.path.hasPrefix(source.path+"/") else {
        throw EngineError.invalid("Verification output must be separate from the input data directory")
    }
    let fm = FileManager.default
    if fm.fileExists(atPath:output.path), !(try fm.contentsOfDirectory(atPath:output.path)).isEmpty {
        throw EngineError.invalid("Verification output is not empty; existing evidence is preserved")
    }
    try fm.createDirectory(at:output,withIntermediateDirectories:true)
    return output
}

func writeReport<T:Encodable>(_ value:T,to url:URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
    try encoder.encode(value).write(to:url,options:.atomic)
}

struct BattleVerification:Codable {
    var format = 1
    var status:String
    var policy:BattlePolicy
    var definition:BattleDefinition
    var turns:Int
    var replayDeterministic:Bool
    var first:BattleSnapshot
    var final:BattleSnapshot
    var events:[BattleEvent]
    var limitations:[String]
}

func verifyBattle(_ definition:BattleDefinition,policy:BattlePolicy,input:URL,output:URL) throws {
    let output = try verificationDirectory(output,excluding:input)
    let session = try BattleSession(definition:definition,policy:policy)
    let replay = try BattleSession(definition:definition,policy:policy)
    let initial = session.snapshot(), board = BattleBoardView(session:session,background:try battleBackground(definition,root:input))
    try board.capture(to:output.appendingPathComponent("00-initial.png"))
    let budget = 2*(session.width+session.height)+definition.units.count*10
    var turns = 0, attacked = false, moved = false
    while session.outcome == .ongoing && turns < budget {
        try session.performAutomaticTurn(); try replay.performAutomaticTurn(); turns += 1
        guard session.snapshot() == replay.snapshot(), session.events == replay.events else {
            throw EngineError.invalid("Battle replay diverged at turn \(turns)")
        }
        if !moved, session.events.contains(where:{$0.operation == "move"}) {
            try board.capture(to:output.appendingPathComponent("01-movement.png")); moved = true
        }
        if !attacked, session.events.contains(where:{$0.operation == "attack"}) {
            try board.capture(to:output.appendingPathComponent("02-attack.png")); attacked = true
        }
    }
    try board.capture(to:output.appendingPathComponent("03-final.png"))
    let result = BattleVerification(status:session.outcome == .ongoing ? "incomplete-turn-budget" : "completed-experimental-battle",
        policy:policy,definition:definition,turns:turns,replayDeterministic:session.snapshot() == replay.snapshot(),
        first:initial,final:session.snapshot(),events:session.events,
        limitations:["This explicitly selected policy is not original damage, class movement, AI or battle objectives.",
                     "Uniform experimental stats are separate from preserved original/unknown values.",
                     "Grid circles are generated research marks; original battle sprite rendering is not implemented.",
                     "Both sides were driven by deterministic engine decisions; no OS input was sent.",
                     "An experimental outcome is not an original campaign flag update."])
    try writeReport(result,to:output.appendingPathComponent("battle-verification.json"))
    guard session.outcome != .ongoing else { throw EngineError.invalid("Battle did not complete within its diagnostic turn budget") }
    print("Verified experimental battle \(definition.id): \(turns) side turns, \(session.outcome.rawValue), deterministic replay")
}

struct CampaignRecordVerification:Codable {
    var id:String; var conditionStatus:String; var executionStatus:String
    var nativeStatus:String; var reason:String?; var commands:Int
}
struct CampaignVerification:Codable {
    var format = 1
    var status = "catalog inspected; full campaign playback not established"
    var records:[CampaignRecordVerification]
    var supportedRecordBoundaries:Int
    var unsupportedBoundaries:Int
    var runtimeFailures:Int
    var conditionalOrDataOnly:Int
    var limitations = ["Each eligible record is probed independently, not through original campaign dispatch.",
                       "Conditional records are not automatically selected and earlier source state is not invented.",
                       "Declared unsupported boundaries are retained as partial coverage, never full campaign completion."]
}

func verifyCampaign(_ catalog:CampaignCatalog,data:DataSet,output:URL) throws {
    let output = try verificationDirectory(output,excluding:data.root)
    var records:[CampaignRecordVerification] = [], completed = 0, unsupported = 0, failed = 0, skipped = 0
    for record in catalog.records {
        guard record.conditionUnconditional, let scene = record.scene else {
            records.append(CampaignRecordVerification(id:record.id,conditionStatus:record.conditionStatus,
                executionStatus:record.executionStatus,nativeStatus:"not-automatically-selected",reason:nil,commands:0)); skipped += 1; continue
        }
        do {
            let runtime = Runtime(try data.replacingScene(scene)); runtime.acknowledge()
            var steps = 0
            let budget = max(1,scene.commands.count)*(31*20+2)
            while runtime.mode != "ended" && steps < budget {
                steps += 1
                if runtime.dialogue != nil { runtime.acknowledge() }
                else if let batch = runtime.batch { runtime.advance(microseconds:batch.duration-batch.elapsed) }
                else { runtime.advance(microseconds:500_000) }
            }
            let status = runtime.termination?.rawValue ?? "diagnostic-work-limit"
            if runtime.termination == .sourceBoundary { completed += 1 }
            else if runtime.termination == .unsupportedBoundary { unsupported += 1 }
            else { failed += 1 }
            records.append(CampaignRecordVerification(id:record.id,conditionStatus:record.conditionStatus,
                executionStatus:record.executionStatus,nativeStatus:status,reason:runtime.endReason,commands:runtime.cursor))
        } catch {
            failed += 1
            records.append(CampaignRecordVerification(id:record.id,conditionStatus:record.conditionStatus,
                executionStatus:record.executionStatus,nativeStatus:"invalid-native-data",reason:"\(error)",commands:0))
        }
    }
    try writeReport(CampaignVerification(records:records,supportedRecordBoundaries:completed,
        unsupportedBoundaries:unsupported,runtimeFailures:failed,conditionalOrDataOnly:skipped),
        to:output.appendingPathComponent("campaign-verification.json"))
    print("Inspected \(catalog.records.count) campaign records: \(completed) source boundaries, \(unsupported) declared unsupported, \(failed) native failures, \(skipped) not automatically selected")
    guard failed == 0 else { throw EngineError.invalid("Campaign record probes encountered \(failed) native failures; see the retained report") }
}
