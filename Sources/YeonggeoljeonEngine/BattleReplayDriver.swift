// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Re-executes accepted inputs on a separately restored campaign host. Source
/// hooks and retirement scripts run normally; no recorded damage is reapplied.
final class BattleReplayDriver {
    let archive:BattleReplayArchive
    let data:DataSet
    private(set) var host:OriginalCampaignHost
    private(set) var flow:OriginalBattleFlow
    private(set) var cursor = 0
    private(set) var stopped:Error?
    private var cancellation:BattleArchiveCancellation?
    var finished:Bool {cursor == archive.inputs.count && archive.complete && stopped == nil}
    convenience init(data:DataSet,archive:BattleReplayArchive,expectedDataDigest:String,cancellation:BattleArchiveCancellation? = nil) throws {
        try self.init(data:data,archive:archive,expectedDataDigest:expectedDataDigest,ownedHost:nil,cancellation:cancellation)
    }
    /// Verification can drive the actual isolated practice context through the
    /// same accepted input stream, including all source hooks and retirements.
    convenience init(practice:PracticeHostContext) throws {
        try self.init(data:practice.host.data,archive:practice.archive,expectedDataDigest:practice.archive.dataDigest,ownedHost:practice.host,cancellation:nil)
    }
    private init(data:DataSet,archive:BattleReplayArchive,expectedDataDigest:String,ownedHost:OriginalCampaignHost?,cancellation:BattleArchiveCancellation?) throws {
        self.cancellation = cancellation;try cancellation?.check()
        try archive.validate()
        guard archive.complete,archive.dataDigest == expectedDataDigest else {throw EngineError.invalid("Replay is incomplete or needs different local data")}
        self.data = data;self.archive = archive
        let source = try OriginalGameData(root:data.root)
        host = try ownedHost ?? OriginalCampaignHost.resume(data:data,from:try archive.start.restore(source:source,attemptID:archive.attemptID))
        guard let battle = host.battle,battle.definition.id == archive.battleID,
              try BattleReplayIdentity.state(host) == archive.initialDigest else {throw EngineError.invalid("Replay initial state does not match")}
        try cancellation?.check()
        flow = OriginalBattleFlow(session:battle)
        connect()
        try settle();try checkBoundary()
    }
    private func connect() {
        let independent = host
        flow.onHook = {try independent.beginTurnHook($0)}
        flow.onRetirement = {try independent.beginRetirement($0)}
    }
    private func settle() throws {
        for _ in 0..<20000 {
            try cancellation?.check()
            guard host.battle === flow.session,host.stage.palette == 3 else {throw EngineError.invalid("Replay left its recorded battle context")}
            if let failure = host.failure {throw EngineError.invalid("Replay reached unsupported source operation: \(failure.reason)")}
            if host.frameworkReturn != nil || host.interpreterReturn != nil {throw EngineError.invalid("Replay encountered an unsupported framework boundary")}
            if host.choice != nil || host.itemOffer != nil || host.saveRequest != nil {return}
            if host.partySelection != nil || host.shop != nil || host.cityEntry != nil {throw EngineError.invalid("Replay reached an unrecorded selection kind")}
            if host.itemMessage != nil {try host.acknowledgeItemMessage();continue}
            if host.retirementPresentation != nil {try host.acknowledgeRetirement();continue}
            if host.stage.dialogue != nil {try host.acknowledge();continue}
            if host.battleInputReady {
                if flow.session.turns.stage == .unstarted {try flow.start()}
                else if flow.suspended {try flow.resumeSourceFlow()}
                if flow.canLeaveBattle || flow.acceptsManualInput {return}
            }
            try host.advance(microseconds:10_000)
        }
        throw EngineError.invalid("Replay simulation limit reached at input \(cursor+1)")
    }
    private func checkBoundary() throws {
        if let expected = archive.checkpoints.first(where:{$0.cursor == cursor}) {
            guard try BattleReplayIdentity.state(host) == expected.digest else {
                throw EngineError.invalid("Replay state or RNG differs after input \(cursor); playback stopped")
            }
        }
        if cursor == archive.inputs.count {
            guard flow.canLeaveBattle,Int(flow.session.turns.result) == archive.result,
                  try BattleReplayIdentity.state(host) == archive.finalDigest else {
                throw EngineError.invalid("Replay final state or RNG does not match")
            }
        }
    }
    @discardableResult func step() throws -> Bool {
        try cancellation?.check()
        if let stopped {throw stopped}
        guard cursor < archive.inputs.count else {return false}
        do {
            let input = archive.inputs[cursor]
            switch input.kind {
            case .choice:try host.choose(input.index!)
            case .itemOffer:try host.answerItemOffer(slot:input.slot)
            case .saveSkip:
                guard host.saveRequest != nil else {throw EngineError.invalid("Replay save acknowledgement has no source prompt")}
                try host.completeSaveRequest()
            default:try input.performBattle(in:flow,enabled:host.battleInputReady)
            }
            cursor += 1;try settle();try checkBoundary();return true
        } catch {stopped = error;throw error}
    }
    func runToEnd() throws {while try step() {}}
    /// Rebuild from the first-turn checkpoint. No arbitrary mid-animation snapshot is loaded.
    func seek(to requested:Int) throws {
        guard (0...archive.inputs.count).contains(requested) else {throw EngineError.invalid("Replay seek cursor is outside its input range")}
        let fresh = try Self(data:data,archive:archive,expectedDataDigest:archive.dataDigest,cancellation:cancellation)
        while fresh.cursor < requested {_ = try fresh.step()}
        host = fresh.host;flow = fresh.flow;cursor = fresh.cursor;stopped = nil
    }
    /// The completed worker transfers exclusive ownership to the UI. Its old
    /// cancellation token must not affect later playback commands.
    func finishBackgroundPreparation() {cancellation = nil}
    var turnStops:[Int] {
        var seen = Set<Int>()
        return archive.checkpoints.filter {seen.insert($0.round).inserted}.map(\.cursor)
    }
}

/// The mutable host and every save path are owned by this practice instance.
/// The caller keeps the original view/host alive and never copies state back.
struct PracticeHostContext {
    let host:OriginalCampaignHost
    let saveRoot:URL
    let scenario:BattleArchiveReference
    let archive:BattleReplayArchive
    var title:String {"연습 · "+scenario.title+" · 본편에 반영되지 않음"}
    static func open(_ reference:BattleArchiveReference,coordinator:BattleArchiveCoordinator,cancellation:BattleArchiveCancellation? = nil,
                     progress:((BattleArchiveVerificationProgress)->Void)? = nil) throws -> Self {
        guard reference.result == 2 else {throw EngineError.invalid("Only a completed victory can open a practice battle")}
        let archive = try coordinator.verifiedArchive(reference,cancellation:cancellation,progress:progress)
        try cancellation?.check()
        let source = try OriginalGameData(root:coordinator.data.root)
        let restored = try archive.start.restore(source:source,attemptID:UUID())
        let host = try OriginalCampaignHost.resume(data:coordinator.data,from:restored)
        // A scenario's battle scripts stay intact. Only native helper state is separate.
        host.extras = CampaignExtras();try cancellation?.check()
        let saveRoot = coordinator.store.root.appendingPathComponent("practice",isDirectory:true).appendingPathComponent(reference.recordingID.uuidString.lowercased(),isDirectory:true)
        return Self(host:host,saveRoot:saveRoot,scenario:reference,archive:archive)
    }
    func retry() throws -> Self {
        try Self.restarting(data:host.data,archive:archive,saveRoot:saveRoot,scenario:scenario)
    }
    static func restarting(data:DataSet,archive:BattleReplayArchive,saveRoot:URL,scenario:BattleArchiveReference,
                           cancellation:BattleArchiveCancellation? = nil,progress:((BattleArchiveVerificationProgress)->Void)? = nil) throws -> Self {
        try cancellation?.check()
        guard try BattleReplayIdentity.data(at:data.root,cancellation:{try cancellation?.check()},
            progress:{progress?(.init(phase:.identity,completed:$0,total:$1))}) == archive.dataDigest else {
            throw EngineError.invalid("Practice requires its original local data version")
        }
        let source = try OriginalGameData(root:data.root)
        let restored = try archive.start.restore(source:source,attemptID:UUID())
        let fresh = try OriginalCampaignHost.resume(data:data,from:restored);fresh.extras = CampaignExtras()
        try cancellation?.check()
        return Self(host:fresh,saveRoot:saveRoot,scenario:scenario,archive:archive)
    }
}
