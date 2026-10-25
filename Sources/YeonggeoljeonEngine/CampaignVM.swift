// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct OriginalCampaignGroup: Codable, Equatable {
    var base: Int
    var count: Int
    var repeating: Bool
}

struct OriginalCampaignInstruction: Codable {
    var opcode: Int
    var offset: Int
    var kind: String
    var arguments: [Int]
    var commands: [Command]
    var positiveFlags: [Int]?
    var negativeFlags: [Int]?
    var skipTarget: Int?
    var options: [String]?
    var presentationOrder: [Int]?
    var battleID: String?
    var text: String?
    var failure: String?
    var skipFailure: String?
    var interpreterStatus: Int?
    var source: JSONValue?
}

struct OriginalCampaignRecord: Codable {
    var id: String
    var chapter: Int
    var member: Int
    var block: Int
    var ordinal: Int
    var kind: Int
    var inverted: Bool
    var rawKind: Int
    var words: [Int]
    var group: OriginalCampaignGroup
    var instructions: [OriginalCampaignInstruction]
    var framingFailure: String?
    var source: JSONValue?
}

struct OriginalCampaignProgram: Codable {
    var format: Int
    var records: [OriginalCampaignRecord]
    var sourceDigest: String?
    var profile: String?
    var limitations: [String]?

    static func load(from url: URL) throws -> OriginalCampaignProgram {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              size.int64Value > 0, size.int64Value <= 128 * 1024 * 1024 else {
            throw EngineError.invalid("Original campaign program exceeds its input bound")
        }
        struct Container: Decodable { var vmProgram: OriginalCampaignProgram }
        let program = try JSONDecoder().decode(Container.self, from: Data(contentsOf: url)).vmProgram
        try program.validate()
        return program
    }

    func validate() throws {
        guard format == 1, !records.isEmpty, records.count <= 16384 else {
            throw EngineError.invalid("Unsupported original campaign program format or record count")
        }
        var ids = Set<String>(), locations = Set<String>()
        for record in records {
            let location = "\(record.chapter):\(record.member):\(record.block):\(record.ordinal)"
            guard ids.insert(record.id).inserted, locations.insert(location).inserted,
                  record.chapter >= 0, record.member >= 0, record.block >= 0, record.ordinal >= 0,
                  (0...255).contains(record.rawKind), record.kind == record.rawKind & 0x7F,
                  record.inverted == (record.rawKind & 0x80 != 0), record.words.count == 3,
                  record.words.allSatisfy({ (0...65535).contains($0) }),
                  record.group.base >= 0, (1...127).contains(record.group.count),
                  (record.group.base..<(record.group.base + record.group.count)).contains(record.ordinal),
                  !record.instructions.isEmpty else {
                throw EngineError.invalid("Invalid original campaign record or phase identity")
            }
            var offsets = Set<Int>()
            for instruction in record.instructions {
                guard offsets.insert(instruction.offset).inserted,
                      instruction.offset >= 0, (0...255).contains(instruction.opcode),
                      instruction.arguments.allSatisfy({ (0...65535).contains($0) }),
                      (instruction.positiveFlags ?? []).allSatisfy({ (0...255).contains($0) }),
                      (instruction.negativeFlags ?? []).allSatisfy({ (0...255).contains($0) }) else {
                    throw EngineError.invalid("Invalid original campaign instruction facts")
                }
            }
            for instruction in record.instructions {
                if let target = instruction.skipTarget, !offsets.contains(target) {
                    throw EngineError.invalid("Original campaign skip target has no decoded execution entry")
                }
            }
        }
        let phases = Dictionary(grouping: records, by: { "\($0.chapter):\($0.member):\($0.block):\($0.group.base)" })
        for phase in phases.values {
            let record = phase[0]
            guard phase.count == record.group.count, phase.allSatisfy({ $0.group == record.group }),
                  Set(phase.map(\.ordinal)) == Set(record.group.base..<(record.group.base + record.group.count)) else {
                throw EngineError.invalid("Original campaign phase population is inconsistent")
            }
        }
    }
}

/// Event numbers and argument order are source identities. Display names such
/// as 'turn start' belong to the host after their original call sites are traced.
struct OriginalCampaignEvent: Codable, Equatable {
    var kind: Int
    var arguments: [Int]
    static let automatic = OriginalCampaignEvent(kind: 0, arguments: [])
    static func townActor(person: Int) -> OriginalCampaignEvent {
        OriginalCampaignEvent(kind: 3, arguments: [person])
    }
    static func townDestination(marker: Int, currentCity: Int) -> OriginalCampaignEvent {
        OriginalCampaignEvent(kind: 4, arguments: [marker, currentCity])
    }
    static func worldDestination(currentCity: Int) -> OriginalCampaignEvent {
        OriginalCampaignEvent(kind: 4, arguments: [255, currentCity])
    }
}

struct CampaignVMChoice: Codable, Equatable {
    var id: String
    var kind: String
    var options: [String]
    var prompt: String
    var expectedIndex: Int?
    var skipTarget: Int?
    var presentationOrder: [Int]?
}

struct CampaignVMPending: Codable, Equatable {
    var kind: String
    var recordID: String
    var offset: Int
    var opcode: Int
    var choice: CampaignVMChoice?
}

struct OriginalCampaignCachedActor: Codable, Equatable {
    var person = 0xFFFF
    // New-game global storage starts at zero; the cache clear constructor
    // changes identity/flags only. Allocating lookup uses FF coordinates.
    var x = 0
    var y = 0
    var flags = 0
    var sourceFacing = 0
}

struct OriginalCampaignPlayerPosition: Codable, Equatable {
    var packedMap: Int
    var x: Int
    var y: Int
}

struct OriginalCampaignState: Codable, Equatable {
    var programDigest: String?
    var chapter = 0
    var member = 0
    var block = 0
    var groupBase = 0
    var packedMap = 0
    var city = 0
    /// Game/player current city is separate from the script map-context city.
    /// Its first established script value is supplied by opcode2E.
    var currentCity: Int?
    var playerPosition: OriginalCampaignPlayerPosition?
    var flags = [UInt8](repeating: 0, count: 32)
    var automatic = false
    var music: Int?
    var objectiveText: String?
    var sourceList: [Int] = []
    var actorCache = [OriginalCampaignCachedActor](repeating: OriginalCampaignCachedActor(), count: 62)
    var actorCacheCity = 0xFFFF
    var actorCacheMap = 0xFFFF
    var actorCacheDirty = false
    var storyPanelActive: Bool? = false
    var currentRecordID: String?
    var instructionIndex = 0
    var event: OriginalCampaignEvent?
    var pending: CampaignVMPending?
    var completedRecords = 0

    func flag(_ id: Int) throws -> Bool {
        guard flags.count == 32, (0...255).contains(id) else {
            throw EngineError.invalid("Original campaign flag identity or bitmap is invalid")
        }
        return flags[id >> 3] & (0x80 >> UInt8(id & 7)) != 0
    }

    mutating func setFlag(_ id: Int, _ enabled: Bool) throws {
        guard flags.count == 32, (0...255).contains(id) else {
            throw EngineError.invalid("Original campaign flag identity or bitmap is invalid")
        }
        let mask: UInt8 = 0x80 >> UInt8(id & 7)
        if enabled { flags[id >> 3] |= mask } else { flags[id >> 3] &= ~mask }
    }
}

struct CampaignVMMapRequest {
    var packedMap: Int
    var battleID: String?
    var recordID: String
    var sourceOffset: Int
}

struct CampaignVMWaiting {
    var chapter: Int
    var member: Int
    var block: Int
    var groupBase: Int
    var eventKinds: [Int]
}

struct CampaignVMFailure {
    var recordID: String?
    var opcode: Int?
    var sourceOffset: Int?
    var reason: String
}

enum CampaignVMYield {
    case commands([Command])
    case loadMap(CampaignVMMapRequest)
    case choice(CampaignVMChoice)
    case sourceAction(OriginalCampaignInstruction)
    case waiting(CampaignVMWaiting)
    case unsupported(CampaignVMFailure)
    case budgetReached
}

/// Original source phase/condition/flag interpreter, independent of the research
/// catalog. MAIN 1B37A,1BACC,1BB4E,1D934,1D9D8,1D8B8,1DC98 establish the flow.
/// A host operation requires a registered implementation before acknowledgement.
final class CampaignVM {
    let program: OriginalCampaignProgram
    private(set) var state: OriginalCampaignState
    private let recordsByID: [String: OriginalCampaignRecord]
    private let recordsByBlock: [String: [OriginalCampaignRecord]]
    private let supportedHostOpcodes: Set<Int>

    init(program: OriginalCampaignProgram, state: OriginalCampaignState = OriginalCampaignState(),
         supportedHostOpcodes: Set<Int> = []) throws {
        try program.validate()
        self.program = program
        self.state = state
        if let digest = state.programDigest, digest != program.sourceDigest {
            throw EngineError.invalid("Original campaign save belongs to a different source program")
        }
        self.state.programDigest = program.sourceDigest
        self.supportedHostOpcodes = supportedHostOpcodes
        recordsByID = Dictionary(uniqueKeysWithValues: program.records.map { ($0.id, $0) })
        recordsByBlock = Dictionary(grouping: program.records, by: { Self.blockKey($0.chapter, $0.member, $0.block) })
            .mapValues { $0.sorted { $0.ordinal < $1.ordinal } }
        try validateState()
    }

    private static func blockKey(_ chapter: Int, _ member: Int, _ block: Int) -> String {
        "\(chapter):\(member):\(block)"
    }

    func snapshot() -> OriginalCampaignState { state }

    func setCurrentCity(_ city: Int) throws {
        guard (0...255).contains(city) else {
            throw EngineError.invalid("Current source city exceeds its byte field")
        }
        state.currentCity = city
    }

    func setPlayerPosition(packedMap: Int, x: Int, y: Int) throws {
        guard (0...65535).contains(packedMap), (0...255).contains(x), (0...255).contains(y) else {
            throw EngineError.invalid("Source player map/position exceeds its stored field widths")
        }
        state.playerPosition = OriginalCampaignPlayerPosition(packedMap: packedMap, x: x, y: y)
    }

    /// The host completes the source route first. Arrival stores global/player
    /// city and returns its exact kind4 trigger; script context city changes
    /// separately when the destination map is entered (MAIN1C040/1C058).
    func commitWorldArrival(city: Int, x: Int, y: Int) throws -> OriginalCampaignEvent {
        guard state.currentRecordID == nil, state.pending == nil,
              state.packedMap & 0xF000 == 0x1000, (0..<255).contains(city) else {
            throw EngineError.invalid("World destination arrival cannot replace a running script or an unselected world map")
        }
        try setPlayerPosition(packedMap: state.packedMap, x: x, y: y)
        try setCurrentCity(city)
        return .worldDestination(currentCity: city)
    }

    /// Cache updates are distinct from visible actor lifetime. The source uses
    /// first matching identity, otherwise first free cache slot (MAIN1DC02).
    func cacheActor(person: Int, x: Int, y: Int, sourceFacing: Int, completedMovement: Bool = false) throws {
        guard (0..<384).contains(person), (0...255).contains(x), (0...255).contains(y),
              (0...255).contains(sourceFacing) else {
            throw EngineError.invalid("Original campaign actor-cache fields exceed source widths")
        }
        if state.actorCacheCity != state.city || state.actorCacheMap != state.packedMap {
            clearActorCache()
            state.actorCacheCity = state.city; state.actorCacheMap = state.packedMap
        }
        guard let index = state.actorCache.firstIndex(where: { $0.person == person }) ??
                state.actorCache.firstIndex(where: { $0.person == 0xFFFF }) else {
            throw EngineError.invalid("Original campaign actor-cache capacity is exhausted")
        }
        state.actorCache[index] = OriginalCampaignCachedActor(person: person, x: x, y: y,
                                                              flags: state.actorCache[index].flags,
                                                              sourceFacing: sourceFacing)
        if completedMovement { state.actorCache[index].flags &= ~2 }
    }

    func invalidateCachedActor(person: Int) throws {
        guard (0..<384).contains(person) else { throw EngineError.invalid("Invalid cached source person identity") }
        if state.actorCacheCity != state.city || state.actorCacheMap != state.packedMap {
            clearActorCache()
            state.actorCacheCity = state.city; state.actorCacheMap = state.packedMap
        }
        if let index = state.actorCache.firstIndex(where: { $0.person == person }) {
            state.actorCache[index].person = 0xFFFF
        } else if let index = state.actorCache.firstIndex(where: { $0.person == 0xFFFF }) {
            // Source removal uses the same allocating lookup before marking
            // its returned identity free, even if the person was absent.
            state.actorCache[index] = OriginalCampaignCachedActor(person: 0xFFFF, x: 0xFF, y: 0xFF,
                                                                  flags: 0, sourceFacing: 0)
        } else { throw EngineError.invalid("Original campaign actor-cache capacity is exhausted") }
    }

    func clearActorCache() {
        // MAIN1DBDC clears identity/flags only. Coordinates, facing, cache owner
        // and currently visible native actors are deliberately retained.
        for index in state.actorCache.indices {
            state.actorCache[index].person = 0xFFFF
            state.actorCache[index].flags = 0
        }
        state.actorCacheDirty = false
    }

    var activeRecord: OriginalCampaignRecord? {
        state.currentRecordID.flatMap { recordsByID[$0] }
    }

    private func currentBlock() -> [OriginalCampaignRecord] {
        recordsByBlock[Self.blockKey(state.chapter, state.member, state.block)] ?? []
    }

    private func currentGroup() -> [OriginalCampaignRecord] {
        currentBlock().filter { $0.group.base == state.groupBase }
    }

    private func validateState() throws {
        guard state.flags.count == 32, state.chapter >= 0, state.member >= 0,
              state.block >= 0, state.groupBase >= 0, state.instructionIndex >= 0,
              (0...65535).contains(state.packedMap), (0...255).contains(state.city),
              state.sourceList.count <= 32, state.actorCache.count == 62,
              state.actorCache.allSatisfy({ (0..<384).contains($0.person) || $0.person == 0xFFFF }),
              state.actorCache.allSatisfy({ (0...255).contains($0.x) && (0...255).contains($0.y) &&
                                          (0...255).contains($0.flags) && (0...255).contains($0.sourceFacing) }) else {
            throw EngineError.invalid("Invalid original campaign saved context")
        }
        if let city = state.currentCity, !(0...255).contains(city) {
            throw EngineError.invalid("Invalid saved source current-city field")
        }
        if let position = state.playerPosition,
           !(0...65535).contains(position.packedMap) || !(0...255).contains(position.x) || !(0...255).contains(position.y) {
            throw EngineError.invalid("Invalid saved source player position")
        }
        if let id = state.currentRecordID {
            guard let record = recordsByID[id], record.chapter == state.chapter,
                  record.member == state.member, record.block == state.block,
                  state.instructionIndex <= record.instructions.count else {
                throw EngineError.invalid("Original campaign saved cursor has no matching source record")
            }
        } else if state.pending != nil {
            throw EngineError.invalid("Original campaign pending operation lost its source cursor")
        }
        if let pending = state.pending {
            guard pending.recordID == state.currentRecordID,
                  let record = recordsByID[pending.recordID],
                  record.instructions.contains(where: { $0.offset == pending.offset && $0.opcode == pending.opcode }) else {
                throw EngineError.invalid("Original campaign pending operation identity is invalid")
            }
        }
    }

    private func flagsMatch(_ instruction: OriginalCampaignInstruction) throws -> Bool {
        for id in instruction.positiveFlags ?? [] where try !state.flag(id) { return false }
        for id in instruction.negativeFlags ?? [] where try state.flag(id) { return false }
        return true
    }

    private func predicate(_ record: OriginalCampaignRecord, event: OriginalCampaignEvent) throws -> Bool {
        if record.rawKind == 1 { return true } // Source wrapper's fallback descriptor.
        let words = record.words, args = event.arguments
        var matched = false
        switch (event.kind, record.kind) {
        case (0, 0):
            matched = true
            if record.group.repeating, let first = record.instructions.first, first.kind == "conditional-skip" {
                matched = try flagsMatch(first)
            }
        case (2, 2), (4, 4): matched = args.count >= 2 && words[0] == args[0] && words[1] == args[1]
        case (2, 5): matched = state.packedMap & 0xF000 == 0x1000 && args.count >= 2 && words[0] == args[1]
        case (3, 3), (9, 9), (12, 12): matched = args.count >= 1 && words[0] == args[0]
        case (6, 6):
            matched = args.count >= 3 && words[0] == args[0] && words[1] == ((args[2] & 255) << 8 | args[1] & 255)
        case (7, 7), (8, 8): matched = true
        case (11, 11):
            matched = args.count >= 3 && words[0] == args[0] &&
                args[1] >= words[1] & 255 && args[1] <= words[2] & 255 &&
                args[2] >= words[1] >> 8 && args[2] <= words[2] >> 8
        default: matched = false
        }
        return record.inverted ? !matched : matched
    }

    /// Selects only within the source phase, preserving source ordinal order.
    /// Events may not abandon a running script, pending map, battle or choice.
    @discardableResult
    func dispatch(event: OriginalCampaignEvent) throws -> Bool {
        guard state.currentRecordID == nil, state.pending == nil,
              [0, 2, 3, 4, 6, 7, 8, 9, 11, 12].contains(event.kind) else {
            throw EngineError.invalid("Original campaign event cannot replace a running operation or has an unsupported source kind")
        }
        state.event = event
        for record in currentGroup() where try predicate(record, event: event) {
            state.currentRecordID = record.id
            state.instructionIndex = 0
            if event.kind == 0, record.kind == 0, record.group.repeating,
               record.instructions.first?.kind == "conditional-skip" {
                // The source event predicate runs the first 21 in predicate-only
                // interpreter mode; its cursor remains after that instruction.
                state.instructionIndex = 1
            }
            return true
        }
        return false
    }

    func start() throws -> CampaignVMYield {
        if state.currentRecordID == nil { _ = try dispatch(event: .automatic) }
        return try advance()
    }

    private func waiting() -> CampaignVMYield {
        .waiting(CampaignVMWaiting(chapter: state.chapter, member: state.member, block: state.block,
            groupBase: state.groupBase, eventKinds: Array(Set(currentGroup().map(\.kind))).sorted()))
    }

    private func failure(_ reason: String, instruction: OriginalCampaignInstruction? = nil) -> CampaignVMYield {
        .unsupported(CampaignVMFailure(recordID: state.currentRecordID, opcode: instruction?.opcode,
            sourceOffset: instruction?.offset, reason: reason))
    }

    private func finishRecord(advanceGroup: Bool) throws {
        guard state.currentRecordID != nil, let group = currentGroup().first?.group else {
            throw EngineError.invalid("Original campaign phase advance lost its source record")
        }
        state.completedRecords += 1
        state.currentRecordID = nil
        state.instructionIndex = 0
        if advanceGroup {
            state.groupBase += group.count
            if !currentBlock().contains(where: { $0.ordinal == state.groupBase }) {
                state.groupBase = 0
                state.block += 1
                if currentBlock().isEmpty {
                    state.block = 0
                    state.member += 1
                }
            }
        }
    }

    private func jump(to offset: Int, in record: OriginalCampaignRecord) throws {
        guard let index = record.instructions.firstIndex(where: { $0.offset == offset }) else {
            throw EngineError.invalid("Original campaign source skip cursor has no execution entry")
        }
        state.instructionIndex = index
    }

    private func pending(_ instruction: OriginalCampaignInstruction, kind: String,
                         choice: CampaignVMChoice? = nil) {
        state.pending = CampaignVMPending(kind: kind, recordID: state.currentRecordID!,
            offset: instruction.offset, opcode: instruction.opcode, choice: choice)
    }

    func resumeMap(packedMap: Int) throws {
        guard let pending = state.pending, pending.kind == "map", state.packedMap == packedMap else {
            throw EngineError.invalid("Original campaign map completion does not match its pending source selection")
        }
        guard let city = state.currentCity else {
            throw EngineError.invalid("Source map entry has no established current city")
        }
        state.city = city
        state.pending = nil
    }

    func resumeHostAction(opcode: Int, sourceOffset: Int) throws {
        guard let pending = state.pending, pending.kind == "host", pending.opcode == opcode,
              pending.offset == sourceOffset, supportedHostOpcodes.contains(opcode) else {
            throw EngineError.invalid("Original campaign host action has no matching registered implementation")
        }
        if opcode == 7 { state.storyPanelActive = true }
        state.pending = nil
    }

    func choose(index: Int) throws {
        guard let pending = state.pending, pending.kind == "choice", let choice = pending.choice,
              let record = recordsByID[pending.recordID], index >= 0 else {
            throw EngineError.invalid("Original campaign has no matching pending choice")
        }
        if choice.kind == "choice-record" {
            guard index < choice.options.count,
                  let target = currentBlock().first(where: { $0.ordinal == state.groupBase + index + 1 }) else {
                throw EngineError.invalid("Original campaign menu selection has no source descriptor")
            }
            state.currentRecordID = target.id
            state.instructionIndex = 0
        } else {
            // Original source selector returns an integer. Its display labels
            // are deliberately not invented by the VM.
            guard index <= 1 else { throw EngineError.invalid("Original source selector index is outside its two-entry result") }
            if index == choice.expectedIndex {
                guard let target = choice.skipTarget else {
                    throw EngineError.invalid("Original source choice skip has no supported execution target")
                }
                try jump(to: target, in: record)
            }
        }
        state.pending = nil
    }

    /// Commands yield before subsequent control effects execute. A pending host
    /// boundary is stable across calls and save/restore until its exact completion.
    func advance(instructionBudget: Int = 4096) throws -> CampaignVMYield {
        guard instructionBudget > 0 else { throw EngineError.invalid("Campaign instruction budget must be positive") }
        if let pending = state.pending {
            guard let record = recordsByID[pending.recordID],
                  let instruction = record.instructions.first(where: { $0.offset == pending.offset }) else {
                return failure("Pending source instruction is missing")
            }
            if let choice = pending.choice { return .choice(choice) }
            if pending.kind == "map" {
                return .loadMap(CampaignVMMapRequest(packedMap: state.packedMap, battleID: instruction.battleID,
                    recordID: record.id, sourceOffset: instruction.offset))
            }
            return .sourceAction(instruction)
        }
        for _ in 0..<instructionBudget {
            if state.currentRecordID == nil {
                if currentBlock().isEmpty { return failure("Source script member has no next block; chapter or ending transition is not invented") }
                if !(try dispatch(event: .automatic)) { return waiting() }
            }
            guard let id = state.currentRecordID, let record = recordsByID[id],
                  state.instructionIndex < record.instructions.count else {
                return failure("Source record reached its decoded end without an executed FF")
            }
            let instruction = record.instructions[state.instructionIndex]
            if state.storyPanelActive == true, instruction.opcode != 8 {
                // MAIN1C1CF..1C1DF owns this check before dispatch, including
                // hidden flag effects and FF. Do not consume that instruction.
                state.storyPanelActive = false
                var command = Command("close-story")
                command.source = instruction.source
                return .commands([command])
            }
            if let reason = instruction.failure { return failure(reason, instruction: instruction) }
            if let reason = record.framingFailure { return failure(reason, instruction: instruction) }
            switch instruction.kind {
            case "unsupported":
                return failure("Original host opcode 0x\(String(instruction.opcode, radix: 16)) is not implemented", instruction: instruction)
            case "commands":
                state.instructionIndex += 1
                var commands = instruction.commands
                if instruction.opcode == 1 {
                    // Source queues consecutive 01 actors before entering its
                    // movement wait. Preserve that batch across VM yields.
                    while state.instructionIndex < record.instructions.count {
                        let next = record.instructions[state.instructionIndex]
                        guard next.opcode == 1, next.kind == "commands", next.failure == nil else { break }
                        commands.append(contentsOf: next.commands)
                        state.instructionIndex += 1
                    }
                }
                if !commands.isEmpty { return .commands(commands) }
            case "flag":
                guard instruction.arguments.count == 2 else { return failure("Invalid source flag operands", instruction: instruction) }
                try state.setFlag(instruction.arguments[0], instruction.arguments[1] == 0)
                state.instructionIndex += 1
            case "conditional-skip":
                if try flagsMatch(instruction) { state.instructionIndex += 1 }
                else if let target = instruction.skipTarget { try jump(to: target, in: record) }
                else { return failure(instruction.skipFailure ?? "Original conditional skip target is unsupported", instruction: instruction) }
            case "jump-block":
                guard let block = instruction.arguments.first else { return failure("Missing original block selector", instruction: instruction) }
                state.block = block; state.groupBase = 0; state.currentRecordID = nil; state.instructionIndex = 0
            case "next-chapter":
                state.chapter += 1; state.member = 0; state.block = 0; state.groupBase = 0
                state.currentRecordID = nil; state.instructionIndex = 0
            case "next-phase": try finishRecord(advanceGroup: true)
            case "end-record":
                let repeatGroup = currentGroup().first?.group.repeating ?? record.group.repeating
                try finishRecord(advanceGroup: !repeatGroup)
                if repeatGroup { return waiting() }
            case "load-map":
                guard let map = instruction.arguments.first else { return failure("Missing source map selector", instruction: instruction) }
                state.packedMap = map; state.instructionIndex += 1
                pending(instruction, kind: "map")
                return .loadMap(CampaignVMMapRequest(packedMap: map, battleID: instruction.battleID,
                    recordID: record.id, sourceOffset: instruction.offset))
            case "city":
                guard let city = instruction.arguments.first else { return failure("Missing source city selector", instruction: instruction) }
                try setCurrentCity(city); state.instructionIndex += 1
            case "automatic":
                guard let value = instruction.arguments.first else { return failure("Missing source automatic-mode selector", instruction: instruction) }
                state.automatic = value == 0; state.instructionIndex += 1
            case "objective-text": state.objectiveText = instruction.text; state.instructionIndex += 1
            case "source-list":
                guard instruction.arguments.count <= 32 else { return failure("Source list exceeds its source context capacity", instruction: instruction) }
                state.sourceList = instruction.arguments; state.instructionIndex += 1
            case "clear-actor-cache": clearActorCache(); state.instructionIndex += 1
            case "choice-record", "choice-skip":
                let choice = CampaignVMChoice(id: "\(record.id)@\(instruction.offset)", kind: instruction.kind,
                    options: instruction.options ?? [], prompt: instruction.commands.compactMap(\.text).joined(separator: "\n"),
                    expectedIndex: instruction.kind == "choice-skip" ? instruction.arguments.first : nil,
                    skipTarget: instruction.skipTarget, presentationOrder: instruction.presentationOrder)
                state.instructionIndex += 1; pending(instruction, kind: "choice", choice: choice)
                return .choice(choice)
            case "no-op", "deferred-dialogue": state.instructionIndex += 1
            default:
                guard supportedHostOpcodes.contains(instruction.opcode) else {
                    return failure("Original \(instruction.kind) host effect has no registered implementation", instruction: instruction)
                }
                if instruction.kind == "music" { state.music = instruction.arguments.first }
                if instruction.kind == "resume-map", let map = instruction.arguments.first { state.packedMap = map }
                state.instructionIndex += 1; pending(instruction, kind: "host")
                return .sourceAction(instruction)
            }
        }
        return .budgetReached
    }
}
