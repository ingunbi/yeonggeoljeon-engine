// SPDX-License-Identifier: GPL-3.0-only
import AppKit

struct OriginalCampaignHostVerification:Codable {
    var format = 1
    var kind = "original-source phase interpreter and persistent native stage; offscreen input driver"
    var status:String
    var completedRecords:Int
    var sourceFailure:CampaignVMFailureRecord?
    var waitingEvents:[Int]?
    var choiceID:String?
    var frames:[String]
    var final:OriginalCampaignCheckpoint
    var trace:[TraceEntry]
    var limitations:[String]
}
struct CampaignVMFailureRecord:Codable {
    var recordID:String?;var opcode:Int?;var sourceOffset:Int?;var reason:String
}
func verifyOriginalCampaignHost(_ data:DataSet,output:URL) throws {
    let output = try verificationDirectory(output,excluding:data.root)
    let host = try OriginalCampaignHost(data:data,rng:OriginalRNG(state:1)),renderer = try Renderer(data)
    var frames:[String] = [],captured = Set<String>()
    func capture(_ event:String) throws {
        guard captured.insert(event).inserted else { return }
        let name = "\(frames.count)-\(event).png"
        try renderer.render(host.stage,evidence:true,screen:host.fieldScreenState()).writePNG(output.appendingPathComponent(name));frames.append(name)
    }
    try capture("title");try host.acknowledge()
    var steps = 0
    while steps < 100_000,host.failure == nil,!host.explorationInputReady,
          !(host.stage.palette == 3 && host.battleInputReady),host.choice == nil,host.saveRequest == nil,
          host.partySelection == nil,host.interpreterReturn == nil,host.frameworkReturn == nil {
        steps += 1
        if host.stage.storyPanel != nil { try capture("original-story-figure") }
        if let map = host.stage.mapID,host.stage.visible { try capture("source-map-\(map)") }
        if let batch = host.stage.batch { try host.advance(microseconds:batch.duration-batch.elapsed) }
        else if host.stage.dialogue != nil { try host.acknowledge() }
        else { try host.advance(microseconds:1_000_000) }
    }
    try capture("last-source-state")
    let failure = host.failure.map { CampaignVMFailureRecord(recordID:$0.recordID,opcode:$0.opcode,sourceOffset:$0.sourceOffset,reason:$0.reason) }
    let status = failure != nil ? "stopped-at-unrestored-source-operation" : host.waiting != nil ? "waiting-for-original-event" : host.choice != nil ? "waiting-for-original-choice" : host.saveRequest != nil ? "waiting-for-native-save-request" : host.frameworkReturn != nil ? "original-framework-return" : host.interpreterReturn != nil ? "source-interpreter-return" : "work-budget-reached"
    let report = OriginalCampaignHostVerification(status:status,completedRecords:host.vm.state.completedRecords,sourceFailure:failure,
        waitingEvents:host.waiting?.eventKinds,choiceID:host.choice?.id,frames:frames,final:host.snapshot(),trace:host.stage.trace,
        limitations:["The driver acknowledges text and completes source movement; it does not choose branches, inject battle wins or skip unsupported effects.",
                     "Waiting, a source failure or a catalog ending is not asserted full-campaign completion.",
                     "Native text and panel framing differ from original UI; TF-DCE uses an explicit zero-plane drawing base and preserves that limitation in local metadata.",
                     "No original DOS executable or original save was executed/modified. Offscreen capture does not verify OS input delivery."])
    let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
    try encoder.encode(report).write(to:output.appendingPathComponent("original-campaign-verification.json"),options:.atomic)
    print("Original campaign host: \(report.completedRecords) records, \(frames.count) frames, \(status)\(failure.map { "; \($0.recordID ?? "") opcode \($0.opcode ?? -1): \($0.reason)" } ?? "")")
    guard steps < 100_000 else { throw EngineError.invalid("Original campaign host verification exhausted its work bound") }
}
