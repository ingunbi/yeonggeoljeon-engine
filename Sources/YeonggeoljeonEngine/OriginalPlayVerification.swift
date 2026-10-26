// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit

/// Only explicit player operations are accepted. Original route/person values
/// belong to a caller-owned local input file, never to the public driver.
struct OriginalPlayInput: Codable, Equatable {
    enum Kind: String, Codable {
        case talk, choice
        case saveSkip = "save-skip", worldCity = "world-city", townMarker = "town-marker", townCell = "town-cell"
        case partyToggle = "party-toggle", partyConfirm = "party-confirm", expectBattle = "expect-battle"
        case battleMove = "battle-move", battleAttack = "battle-attack", battleStrategy = "battle-strategy"
        case battleWait = "battle-wait", battleEndTurn = "battle-end-turn"
        case retryChoice = "retry-choice"
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

    var operandKeys:Set<String> {
        Set([person == nil ? nil : "person", index == nil ? nil : "index",
             city == nil ? nil : "city", marker == nil ? nil : "marker",battleID == nil ? nil : "battleID",
             slot == nil ? nil : "slot",x == nil ? nil : "x",y == nil ? nil : "y",
             target == nil ? nil : "target",ability == nil ? nil : "ability"].compactMap{$0})
    }

    func validate() throws {
        let allowed: Set<String>
        switch kind {
        case .talk,.partyToggle: allowed = ["person"]
        case .choice,.retryChoice: allowed = ["index"]
        case .worldCity: allowed = ["city"]
        case .townMarker: allowed = ["marker"]
        case .expectBattle: allowed = battleID == nil ? [] : ["battleID"]
        case .saveSkip,.partyConfirm: allowed = []
        case .battleMove: allowed = ["slot","x","y"]
        case .townCell: allowed = ["x","y"]
        case .battleAttack: allowed = ["slot","target"]
        case .battleStrategy: allowed = target == nil ? ["slot","ability"] : ["slot","ability","target"]
        case .battleWait: allowed = ["slot"]
        case .battleEndTurn: allowed = []
        }
        guard operandKeys == allowed,
              person.map({ (0..<384).contains($0) }) ?? true,
              index.map({ $0 >= 0 }) ?? true, kind != .retryChoice || [0,1].contains(index ?? -1),
              city.map({ (0...255).contains($0) }) ?? true,
              marker.map({ (0...255).contains($0) }) ?? true,
              battleID.map({ !$0.isEmpty }) ?? true,
              slot.map({(0..<45).contains($0)}) ?? true,target.map({(0..<45).contains($0)}) ?? true,
              x.map({(0...255).contains($0)}) ?? true,y.map({(0...255).contains($0)}) ?? true,
              ability.map({(0..<36).contains($0)}) ?? true else {
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
        case .battleAttack:_ = try flow.manualAttack(slot!,target:target!)
        case .battleStrategy:_ = try flow.manualStrategy(slot!,abilityID:ability!,target:target)
        case .battleWait:try flow.manualWait(slot!)
        case .battleEndTurn:try flow.finishManual()
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
              rows.allSatisfy({ Set($0.keys).isSubset(of: ["kind","person","index","city","marker","battleID","slot","x","y","target","ability"]) }) else {
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
    var frameworkReturn: OriginalFrameworkReturn?
    var observations: [OriginalPlayObservation]
    var final: OriginalCampaignCheckpoint
    var trace: [TraceEntry]
    var limitations: [String]
}

func verifyOriginalPlay(_ data: DataSet, inputs inputURL: URL, output: URL) throws {
    let bytes = try OriginalPlayInputs.readData(from:inputURL)
    let selected = try OriginalPlayInputs.decode(bytes)
    let output = try verificationDirectory(output, excluding: data.root)
    let seed = selected.seed ?? 1, fixedStep = selected.fixedStepMicroseconds ?? 10_000
    let budget = selected.maximumTicksPerInput ?? 20_000
    let host = try OriginalCampaignHost(data: data, rng: OriginalRNG(state: seed))
    let renderer = try Renderer(data)
    var battleView: OriginalBattleView?, reachedBattles: [String] = []
    var observations: [OriginalPlayObservation] = [], totalTicks = 0
    var completed = 0, failedIndex: Int?, failure: String?

    func synchronizeBattle() throws {
        guard host.stage.palette == 3, let session = host.battle else { return }
        if battleView?.session !== session {
            let view = try OriginalBattleView(session: session,
                background: battleBackground(session.definition, root: data.root),
                sprites: OriginalBattleSpriteRenderer(root: data.root))
            view.onHook = { try host.beginTurnHook($0) }
            view.onRetirement = { try host.beginRetirement($0) }
            view.inputReady = { host.battleInputReady }
            battleView = view
            if !reachedBattles.contains(session.definition.id) { reachedBattles.append(session.definition.id) }
        }
        if host.battleInputReady, let view = battleView {
            if session.turns.stage == .unstarted { try view.start() }
            else if view.suspended { try view.resumeSourceFlow() }
            if view.flow.canLeaveBattle { try host.finishBattleLoop() }
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
            if host.choice != nil || host.saveRequest != nil || host.partySelection != nil { return totalTicks - started }
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
        if host.stage.palette == 3, let view = battleView { try view.capture(to: output.appendingPathComponent(name)) }
        else { try renderer.render(host.stage, evidence: true).writePNG(output.appendingPathComponent(name)) }
        let state = host.vm.state
        observations.append(.init(inputIndex: index, input: input, simulatedTicks: ticks, status: host.status,
            packedMap: state.packedMap, currentCity: state.currentCity, recordID: state.currentRecordID,
            chapter: state.chapter, member: state.member, block: state.block, groupBase: state.groupBase,
            choiceID: host.choice?.id, savePending: host.saveRequest != nil, partyPending: host.partySelection != nil,
            battleID: host.stage.palette == 3 ? host.battle?.definition.id : nil,
            battleStage: host.stage.palette == 3 ? host.battle?.turns.stage : nil, frame: name))
    }
    do {
        try host.acknowledge()
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
            case .choice: try host.choose(input.index!)
            case .saveSkip:
                guard host.saveRequest != nil else { throw EngineError.invalid("Play save-skip has no matching source save request") }
                try host.completeSaveRequest()
            case .worldCity: _ = try host.travel(toCity: input.city!)
            case .townMarker: _ = try host.townDestination(marker: input.marker!)
            case .townCell: try host.walk(to: GridPoint(x: input.x!, y: input.y!))
            case .partyToggle: try host.toggleParty(person: input.person!)
            case .partyConfirm: try host.confirmParty()
            case .expectBattle:
                guard host.stage.palette == 3, let battle = host.battle,
                      input.battleID.map({ $0 == battle.definition.id }) ?? true else {
                    throw EngineError.invalid("Play expectation did not reach its selected source battle")
                }
            case .battleMove,.battleAttack,.battleStrategy,.battleWait,.battleEndTurn:
                guard host.stage.palette == 3,let view = battleView,let session = host.battle,view.session === session else {
                    throw EngineError.invalid("Original play battle primitive has no current native battle")
                }
                try input.performBattle(in:view.flow,enabled:host.battleInputReady)
            }
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
    print("Original play: \(completed)/\(selected.inputs.count) inputs, battles \(reachedBattles.count), \(report.status)")
    if let failure = failure { throw EngineError.invalid(failure) }
}
