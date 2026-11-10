// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(AppKit)
import AppKit
#endif
import CryptoKit

/// Only explicit player operations are accepted. Original route/person values
/// belong to a caller-owned local input file, never to the public driver.
struct OriginalPlayInput: Codable, Equatable {
    enum Kind: String, Codable {
        case talk, choice
        case saveSkip = "save-skip", saveNative = "save-native", worldCity = "world-city", townMarker = "town-marker", townCell = "town-cell"
        case partyToggle = "party-toggle", partyConfirm = "party-confirm", expectBattle = "expect-battle"
        case battleMove = "battle-move", battleAttack = "battle-attack", battleStrategy = "battle-strategy", battleItem = "battle-item"
        case battleWait = "battle-wait", battleEndTurn = "battle-end-turn"
        case battleCancelMove = "battle-cancel-move", battleGive = "battle-give", battleDiscard = "battle-discard"
        case battleReleaseAmbush = "battle-release-ambush", battleOptions = "battle-options"
        case battleRetreat = "battle-retreat", battleQuit = "battle-quit", fieldQuit = "field-quit"
        case retryChoice = "retry-choice"
        case shopAnswer = "shop-answer", cityEntry = "city-entry", fieldExchange = "field-exchange"
        case itemOffer = "item-offer"
    }
    var kind: Kind
    var person: Int?
    var index: Int?
    var city: Int?
    var marker: Int?
    var battleID: String?
    var slot: Int?
    var x: Int?
    var y: Int?
    var target: Int?
    var ability: Int?
    var item: Int?

    var operandKeys:Set<String> {
        Set([person == nil ? nil : "person", index == nil ? nil : "index",
             city == nil ? nil : "city", marker == nil ? nil : "marker",battleID == nil ? nil : "battleID",
             slot == nil ? nil : "slot",x == nil ? nil : "x",y == nil ? nil : "y",
             target == nil ? nil : "target",ability == nil ? nil : "ability",item == nil ? nil : "item"].compactMap{$0})
    }

    func validate() throws {
        let allowed: Set<String>
        switch kind {
        case .talk,.partyToggle: allowed = ["person"]
        case .choice,.retryChoice,.cityEntry: allowed = ["index"]
        case .shopAnswer: allowed = index == nil ? [] : ["index"]
        case .fieldExchange: allowed = ["person","index","item"]
        case .worldCity: allowed = ["city"]
        case .townMarker: allowed = ["marker"]
        case .expectBattle: allowed = battleID == nil ? [] : ["battleID"]
        case .saveSkip,.saveNative,.partyConfirm,.fieldQuit: allowed = []
        case .itemOffer: allowed = slot == nil ? [] : ["slot"]
        case .battleMove: allowed = ["slot","x","y"]
        case .townCell: allowed = ["x","y"]
        case .battleAttack: allowed = ["slot","target"]
        case .battleStrategy: allowed = target == nil ? ["slot","ability"] : ["slot","ability","target"]
        case .battleItem: allowed = target == nil ? ["slot","item"] : ["slot","item","target"]
        case .battleWait,.battleCancelMove,.battleReleaseAmbush: allowed = ["slot"]
        case .battleGive: allowed = ["slot","target","item"]
        case .battleDiscard: allowed = ["slot","item"]
        case .battleOptions: allowed = ["index"]
        case .battleEndTurn,.battleRetreat,.battleQuit: allowed = []
        }
        guard operandKeys == allowed,
              person.map({ (0..<384).contains($0) }) ?? true,
              index.map({ $0 >= 0 }) ?? true, kind != .battleOptions || (0...65535).contains(index ?? -1), ![.retryChoice,.cityEntry].contains(kind) || [0,1].contains(index ?? -1),
              city.map({ (0...255).contains($0) }) ?? true,
              marker.map({ (0...255).contains($0) }) ?? true,
              battleID.map({ !$0.isEmpty }) ?? true,
              slot.map({(0..<45).contains($0)}) ?? true,target.map({(0..<45).contains($0)}) ?? true,
              x.map({(0...255).contains($0)}) ?? true,y.map({(0...255).contains($0)}) ?? true,
              ability.map({(0..<36).contains($0)}) ?? true,item.map({(0..<64).contains($0)}) ?? true else {
            throw EngineError.invalid("Original play input has missing, extraneous or out-of-domain operands")
        }
    }
    /// This boundary invokes the same source flow as the battle input view.
    /// Coordinates and targets remain caller choices; no state/result setter
    /// or alternative battle policy is exposed by the replay format.
    func performBattle(in flow:OriginalBattleFlow,enabled:Bool)throws {
        try validate()
        guard enabled,flow.acceptsManualInput else {
            throw BattleError.illegalAction("Original play battle input is outside its manual source boundary")
        }
        switch kind {
        case .battleMove:
            _ = try flow.session.requireManualUnit(slot!)
            _ = try flow.session.move(slot!,to:GridPoint(x:x!,y:y!))
        case .battleCancelMove:try flow.session.cancelMove(slot!)
        case .battleGive:
            guard try flow.manualGive(slot!,to:target!,item:item!) else {throw EngineError.invalid("Recorded item transfer was refused")}
        case .battleDiscard:
            let user = try flow.session.requireManualUnit(slot!)
            try flow.session.people.discardItem(person:user.person,item:item!)
        case .battleReleaseAmbush:try flow.manualReleaseAmbush(slot!)
        case .battleOptions:flow.session.sourceOptionsWord = index!
        case .battleAttack:_ = try flow.manualAttack(slot!,target:target!)
        case .battleStrategy:_ = try flow.manualStrategy(slot!,abilityID:ability!,target:target)
        case .battleItem:_ = try flow.manualItem(slot!,item:item!,target:target)
        case .battleWait:try flow.manualWait(slot!)
        case .battleEndTurn:try flow.finishManual()
        case .battleRetreat:try flow.requestRetreat()
        case .battleQuit:try flow.requestQuit()
        default:throw EngineError.invalid("Original play input is not a battle primitive")
        }
    }
}
struct OriginalPlayInputs: Codable {
    static let maximumBytes = 4 * 1024 * 1024
    var format: Int
    var seed: UInt32?
    var fixedStepMicroseconds: Int64?
    var maximumTicksPerInput: Int?
    var inputs: [OriginalPlayInput]

    static func readData(from url:URL)throws->Data {
        let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
        guard let size = attributes[.size] as? NSNumber,size.int64Value >= 0,size.int64Value <= maximumBytes else {
            throw EngineError.invalid("Original play input file exceeds its input bound")
        }
        let handle = try FileHandle(forReadingFrom:url);defer{try? handle.close()}
        var bytes = Data()
        while bytes.count <= maximumBytes {
            guard let chunk = try handle.read(upToCount:min(65536,maximumBytes+1-bytes.count)),!chunk.isEmpty else {break}
            bytes.append(chunk)
        }
        guard bytes.count <= maximumBytes else {throw EngineError.invalid("Original play input file grew beyond its input bound")}
        return bytes
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["format","seed","fixedStepMicroseconds","maximumTicksPerInput","inputs"]),
              let rows = object["inputs"] as? [[String: Any]],
              rows.allSatisfy({ Set($0.keys).isSubset(of: ["kind","person","index","city","marker","battleID","slot","x","y","target","ability","item"]) }) else {
            throw EngineError.invalid("Original play input file has an unsupported shape, field or resource size")
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.format == 1, value.inputs.count <= 4096,
              (1...1_000_000).contains(value.fixedStepMicroseconds ?? 10_000),
              (1...100_000).contains(value.maximumTicksPerInput ?? 20_000) else {
            throw EngineError.invalid("Original play input format or fixed-step work budget is invalid")
        }
        for (row,input) in zip(rows,value.inputs) {
            // Explicit null is not an omitted operand. Reject it instead of
            // silently losing a caller's extraneous or ambiguous field.
            guard Set(row.keys) == input.operandKeys.union(["kind"]) else {
                throw EngineError.invalid("Original play input contains a null or ambiguous operand")
            }
            try input.validate()
        }
        return value
    }
}
struct OriginalPlayObservation: Codable {
    var inputIndex: Int?
    var input: OriginalPlayInput?
    var simulatedTicks: Int
    var status: String
    var packedMap: Int
    var currentCity: Int?
    var recordID: String?
    var chapter: Int
    var member: Int
    var block: Int
    var groupBase: Int
    var choiceID: String?
    var savePending: Bool
    var partyPending: Bool
    var battleID: String?
    var battleStage: OriginalTurnStage?
    var frame: String
    var money: Int?
    var shopText: String?
    /// The live random state (the battle's while one runs), for finding where two runs part.
    var rng: UInt32? = nil
}
struct OriginalPlayVerification: Codable {
    var format = 1
    var kind = "caller-selected original player inputs through native host APIs and fixed simulation steps"
    var status: String
    var inputPath: String
    var resolvedInputPath: String
    var inputSHA256: String
    var seed: UInt32
    var fixedStepMicroseconds: Int64
    var maximumTicksPerInput: Int
    var completedInputs: Int
    var failedInputIndex: Int?
    var failure: String?
    var sourceFailure: CampaignVMFailureRecord?
    var reachedBattles: [String]
    var resumedFrom: String?
    var resumeSHA256: String?
    var nativeSaves: [String]
    var frameworkReturn: OriginalFrameworkReturn?
    var observations: [OriginalPlayObservation]
    var final: OriginalCampaignCheckpoint
    var trace: [TraceEntry]
    var limitations: [String]
}

#if canImport(AppKit)
func verifyOriginalPlay(_ data: DataSet, inputs inputURL: URL, output: URL, resume resumeURL: URL? = nil, archiveRoot:URL? = nil, omitRendering:Bool = false) throws {
    let bytes = try OriginalPlayInputs.readData(from:inputURL)
    let selected = try OriginalPlayInputs.decode(bytes)
    guard resumeURL == nil || selected.seed == nil else {
        throw EngineError.invalid("A resumed replay takes its RNG from the native save; remove the input seed")
    }
    let output = try verificationDirectory(output, excluding: data.root)
    let seed = selected.seed ?? 1, fixedStep = selected.fixedStepMicroseconds ?? 10_000
    let budget = selected.maximumTicksPerInput ?? 20_000
    var resumeDigest: String?
    let host: OriginalCampaignHost
    if let url = resumeURL {
        let saveBytes = try Data(contentsOf: url)
        resumeDigest = SHA256.hash(data: saveBytes).map { String(format: "%02x", $0) }.joined()
        host = try OriginalCampaignHost.resume(data: data, from: OriginalCampaignResume.read(from: url))
    } else { host = try OriginalCampaignHost(data: data, rng: OriginalRNG(state: seed)) }
    var nativeSaves: [String] = []
    let renderer = try Renderer(data)
    var battleView: OriginalBattleView?, reachedBattles: [String] = []
    var observations: [OriginalPlayObservation] = [], totalTicks = 0
    var completed = 0, failedIndex: Int?, failure: String?
    let recorder = archiveRoot.map {BattleArchiveCoordinator(data:data,root:$0)}
    var recording = BattleArchiveProgress();recording.recordingEnabled = recorder != nil
    var archiveChecks:[String] = []

    func synchronizeBattle() throws {
        guard host.stage.palette == 3, let session = host.battle else { return }
        if battleView?.session !== session {
            let view = try OriginalBattleView(session: session,
                background: battleBackground(session.definition, root: data.root),
                sprites: OriginalBattleSpriteRenderer(root: data.root),
                style: OriginalBattleStyle.load(definition: session.definition, root: data.root, story: host.story))
            view.showsSlotNumbers = true
            view.onHook = { try host.beginTurnHook($0) }
            view.onRetirement = { try host.beginRetirement($0) }
            view.inputReady = { host.battleInputReady }
            view.menuTexts = host.framework?.battleMenu
            battleView = view
            if !reachedBattles.contains(session.definition.id) { reachedBattles.append(session.definition.id) }
        }
        if host.battleInputReady, let view = battleView {
            if session.turns.stage == .unstarted {
                if let recorder,let start = try host.battleStartSnapshot() {try recorder.begin(start:start,progress:&recording)}
                try view.start()
            }
            else if view.suspended { try view.resumeSourceFlow() }
            if view.flow.canLeaveBattle {
                if let recorder,recording.active != nil {
                    try recorder.finish(host:host,progress:&recording)
                    if let reference = recording.completed.last {
                        _ = try recorder.verifiedArchive(reference)
                        recording.completed[recording.completed.count-1].verified = true
                        archiveChecks.append(reference.battleID)
                    }
                }
                try host.finishBattleLoop()
            }
        }
    }
    /// Dialogue acknowledgement is explicit native input. Choices, save and
    /// deployment remain caller-selected steps and are never auto-selected.
    @discardableResult func settle() throws -> Int {
        let started = totalTicks
        for _ in 0..<budget {
            try synchronizeBattle()
            if let source = host.failure { throw EngineError.invalid("Reached unrestored source operation: \(source.reason)") }
            if host.interpreterReturn != nil || host.frameworkReturn != nil { return totalTicks - started }
            if host.choice != nil || host.saveRequest != nil || host.itemOffer != nil || host.partySelection != nil || host.shop != nil || host.cityEntry != nil { return totalTicks - started }
            if host.retirementPresentation != nil { try host.acknowledgeRetirement(); continue }
            if host.stage.dialogue != nil { try host.acknowledge(); continue }
            if host.explorationInputReady || (host.stage.palette == 3 && host.battleInputReady) { return totalTicks - started }
            try host.advance(microseconds: fixedStep)
            totalTicks += 1
        }
        throw EngineError.invalid("Original play fixed-step work budget reached before input readiness")
    }
    func capture(index: Int?, input: OriginalPlayInput?, ticks: Int) throws {
        let name = "\(observations.count)-\(input?.kind.rawValue ?? "initial").png"
        if !omitRendering {
            if host.stage.palette == 3, let view = battleView { try view.capture(to: output.appendingPathComponent(name)) }
            else { try renderer.render(host.stage, evidence: true, screen: host.fieldScreenState()).writePNG(output.appendingPathComponent(name)) }
        }
        if let recorder,let view = battleView,host.battleInputReady,view.flow.canSuspendCheckpoint {try recorder.checkpoint(host:host,progress:&recording)}
        let state = host.vm.state
        observations.append(.init(inputIndex: index, input: input, simulatedTicks: ticks, status: host.status,
            packedMap: state.packedMap, currentCity: state.currentCity, recordID: state.currentRecordID,
            chapter: state.chapter, member: state.member, block: state.block, groupBase: state.groupBase,
            choiceID: host.choice?.id, savePending: host.saveRequest != nil, partyPending: host.partySelection != nil,
            battleID: host.stage.palette == 3 ? host.battle?.definition.id : nil,
            battleStage: host.stage.palette == 3 ? host.battle?.turns.stage : nil, frame: omitRendering ? "not-rendered" : name,
            money: host.money, shopText: host.shopPrompt?.text,
            rng: (host.stage.palette == 3 ? (host.battle?.rng ?? host.rng) : host.rng).state))
    }
    do {
        if resumeURL == nil { try host.acknowledge() }
        let initialTicks = try settle()
        try capture(index: nil, input: nil, ticks: initialTicks)
        for (index, input) in selected.inputs.enumerated() {
            failedIndex = index
            if let value = host.frameworkReturn, value.outcome != .pending {
                throw EngineError.invalid("Original MAIN \(value.outcome.rawValue) ended this replay host; later inputs need a new run")
            }
            switch input.kind {
            case .retryChoice: try host.answerRetryPrompt(input.index!)
            case .talk: _ = try host.talk(to: input.person!)
            case .shopAnswer: try host.answerShop(input.index)
            case .cityEntry: try host.answerCityEntry(input.index == 1)
            case .fieldExchange:
                guard try host.exchangeItem(from:input.person!,to:input.index!,item:input.item!) else {
                    throw EngineError.invalid("Original item exchange receiver has no empty slot")
                }
            case .choice: try host.choose(input.index!)
            case .saveSkip:
                guard host.saveRequest != nil else { throw EngineError.invalid("Play save-skip has no matching source save request") }
                try host.completeSaveRequest()
            case .saveNative:
                guard host.saveRequest != nil || host.fieldMenuReady else {
                    throw EngineError.invalid("Play save-native has no source save prompt or idle field menu")
                }
                let name = "native-save-\(nativeSaves.count).json"
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
                try encoder.encode(try host.resumeSnapshot()).write(to: output.appendingPathComponent(name), options: .atomic)
                nativeSaves.append(name)
                if host.saveRequest != nil { try host.completeSaveRequest() }
            case .fieldQuit: try host.fieldQuit()
            case .worldCity: _ = try host.travel(toCity: input.city!)
            case .townMarker: _ = try host.townDestination(marker: input.marker!)
            case .townCell: try host.walk(to: GridPoint(x: input.x!, y: input.y!))
            case .partyToggle: try host.toggleParty(person: input.person!)
            case .partyConfirm: try host.confirmParty()
            case .itemOffer:
                guard host.itemOffer != nil else { throw EngineError.invalid("Play item-offer has no pending full-inventory offer") }
                try host.answerItemOffer(slot:input.slot)
            case .expectBattle:
                guard host.stage.palette == 3, let battle = host.battle,
                      input.battleID.map({ $0 == battle.definition.id }) ?? true else {
                    throw EngineError.invalid("Play expectation did not reach its selected source battle")
                }
            case .battleMove,.battleAttack,.battleStrategy,.battleItem,.battleWait,.battleEndTurn,.battleRetreat,.battleQuit,.battleCancelMove,.battleGive,.battleDiscard,.battleReleaseAmbush,.battleOptions:
                guard host.stage.palette == 3,let view = battleView,let session = host.battle,view.session === session else {
                    throw EngineError.invalid("Original play battle primitive has no current native battle")
                }
                try input.performBattle(in:view.flow,enabled:host.battleInputReady)
            }
            if let recorder,BattleReplayArchive.supports(input.kind) {try recorder.accepted(input:input,progress:&recording)}
            let ticks = try settle()
            try capture(index: index, input: input, ticks: ticks)
            completed += 1
            failedIndex = nil
        }
    } catch { failure = "\(error)" }
    if failure != nil {
        do { try capture(index: failedIndex, input: failedIndex.map { selected.inputs[$0] }, ticks: 0) }
        catch { failure = "\(failure ?? "Verification stopped"); frame capture failed: \(error)" }
    }
    if (try? OriginalPlayInputs.readData(from:inputURL)) != bytes { failure = "Caller-selected input file changed during verification" }
    let sourceFailure = host.failure.map { CampaignVMFailureRecord(recordID: $0.recordID, opcode: $0.opcode,
        sourceOffset: $0.sourceOffset, reason: $0.reason) }
    let report = OriginalPlayVerification(status: failure == nil ? "input-list-completed" : "stopped-at-input-or-source-boundary",
        inputPath: inputURL.path, resolvedInputPath: inputURL.standardizedFileURL.resolvingSymlinksInPath().path,
        inputSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), seed: seed,
        fixedStepMicroseconds: fixedStep, maximumTicksPerInput: budget, completedInputs: completed,
        failedInputIndex: failedIndex, failure: failure, sourceFailure: sourceFailure, reachedBattles: reachedBattles,
        resumedFrom: resumeURL?.path, resumeSHA256: resumeDigest, nativeSaves: nativeSaves,
        frameworkReturn: host.frameworkReturn,
        observations: observations, final: host.snapshot(), trace: host.stage.trace,
        limitations: ["Only caller-selected native inputs are replayed; no campaign state, flags, result or unit is injected.",
                      "Dialogue and retirement text are acknowledged; choices, save requests, party selection and the MAIN retry selector require explicit input steps.",
                      "A retry answer records MAIN's restart/exit outcome; this driver does not start a second MAIN host.",
                      "Manual battle primitives are caller-selected and use restored source flow; the driver has no win, teleport or autoplay policy. Enemy decisions belong to the restored engine.",
                      "Completing an input list or reaching a battle does not establish a complete campaign or original-runtime parity.",
                      "Seed1 is the default explicit test input; the driver does not establish the original DOS wall-clock RNG timeline.",
                      "Frames use native AppKit offscreen rendering. Real macOS keyboard/mouse delivery is not verified."])
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
    try encoder.encode(report).write(to: output.appendingPathComponent("original-play-verification.json"), options: .atomic)
    if recorder != nil {
        try encoder.encode(recording).write(to:output.appendingPathComponent("battle-archive-verification.json"),options:.atomic)
        if let recorder {
            var practiceChecks:[String] = []
            for reference in recording.completed where reference.result == 2 && reference.verified {
                let before = try BattleReplayIdentity.state(host)
                let helpers = try BattleReplayIdentity.encode(host.extras)
                let practice = try PracticeHostContext.open(reference,coordinator:recorder)
                guard practice.host !== host,practice.host.people !== host.people,practice.host.battle !== host.battle else {
                    throw EngineError.invalid("Practice context shares mutable campaign state")
                }
                let player = try BattleReplayDriver(practice:practice);try player.runToEnd()
                let retry = try practice.retry()
                guard try BattleReplayIdentity.state(retry.host) == practice.archive.initialDigest,
                      try BattleReplayIdentity.state(host) == before,
                      try BattleReplayIdentity.encode(host.extras) == helpers else {
                    throw EngineError.invalid("Practice execution/retry changed the original campaign or helper state")
                }
                practiceChecks.append(reference.battleID)
            }
            try encoder.encode(["verifiedPracticeBattles":practiceChecks]).write(to:output.appendingPathComponent("practice-isolation-verification.json"),options:.atomic)
            print("Practice contexts independently completed and isolated: \(practiceChecks.count)")
        }
        print("Battle archives independently verified: \(archiveChecks.count); \(archiveChecks.joined(separator:", "))")
    }
    print("Original play: \(completed)/\(selected.inputs.count) inputs, battles \(reachedBattles.count), \(report.status)")
    if let failure = failure { throw EngineError.invalid(failure) }
}
#endif
