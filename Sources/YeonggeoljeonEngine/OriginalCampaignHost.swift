// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct OriginalCampaignCheckpoint:Codable {
    var format = 1
    var vm:OriginalCampaignState
    var people:[OriginalPersonDefinition]
    var roster:OriginalRoster
    var rng:OriginalRNG
    var money:Int?
    var stage:Snapshot
    var liveUnits:[OriginalLiveUnit]?
    var turns:OriginalTurnState?
    var battleValue24:Int?
}

/// Owns native state effects for registered source operations. A VM instruction
/// is acknowledged only after its handler completed; unregistered effects stop
/// at the exact original record/offset. The record browser never advances this.
final class OriginalCampaignHost {
    let data:DataSet
    let source:OriginalGameData
    let vm:CampaignVM
    let stage:Runtime
    let exploration:OriginalExplorationCatalog
    let story:OriginalStoryCatalog
    let people:OriginalPeople
    private(set) var roster = OriginalRoster()
    private(set) var rng:OriginalRNG
    // MAIN1276F..12779 clears DS6390..<E6D0, including7A80+0. The
    // new-game BAK actor loader does not deserialize player/save money.
    private(set) var money:Int? = 0
    private(set) var battle:OriginalBattleSession?
    private(set) var checkpoint:OriginalCampaignCheckpoint?
    private(set) var waiting:CampaignVMWaiting?
    private(set) var choice:CampaignVMChoice?
    private(set) var saveRequest:OriginalCampaignInstruction?
    private(set) var failure:CampaignVMFailure?
    private var pendingCache:[Command] = []
    private var currentEventPerson:Int?
    private var started = false
    var status:String {
        if let failure = failure { return "미복원: \(failure.recordID ?? "") @\(failure.sourceOffset ?? 0) · \(failure.reason)" }
        if choice != nil { return "원작 선택지 입력 대기" }
        if saveRequest != nil { return "자체 엔진 형식의 저장 여부를 선택하세요." }
        if let waiting = waiting { return "\(waiting.chapter):\(waiting.member):\(waiting.block):\(waiting.groupBase) · 원작 이벤트 대기 \(waiting.eventKinds)" }
        return "\(vm.state.chapter):\(vm.state.member):\(vm.state.block):\(vm.state.groupBase)"
    }
    init(data:DataSet,rng:OriginalRNG) throws {
        self.data = data;self.rng = rng;source = try OriginalGameData(root:data.root)
        people = try OriginalPeople(catalog:source.people,tables:source.combat)
        exploration = try OriginalExplorationCatalog.load(from:data.root.appendingPathComponent("exploration.json"))
        story = try OriginalStoryCatalog.load(from:data.root.appendingPathComponent("story.json"))
        let program = try OriginalCampaignProgram.load(from:data.root.appendingPathComponent("campaign.json"))
        vm = try CampaignVM(program:program,supportedHostOpcodes:[3,7,0x11,0x1B,0x1C,0x22,0x24,0x29,0x2F,0x37,0x39,0x3A,0x2B,0x36,0x38,0x3B,0x3C,0x3D])
        stage = Runtime(data,hostDriven:true)
    }
    func acknowledge() throws {
        guard failure == nil,choice == nil,saveRequest == nil else { return }
        stage.acknowledge()
        if !started { started = true }
        try pump()
    }
    func advance(microseconds:Int64) throws {
        guard started,failure == nil else { return }
        stage.advance(microseconds:microseconds);try pump()
    }
    func choose(_ index:Int) throws {
        guard choice != nil else { throw EngineError.invalid("No original campaign choice is pending") }
        try vm.choose(index:index);choice = nil;try pump()
    }
    func completeSaveRequest() throws {
        guard let request = saveRequest else { throw EngineError.invalid("No original save request is pending") }
        try vm.resumeHostAction(opcode:request.opcode,sourceOffset:request.offset);saveRequest = nil;try pump()
    }
    @discardableResult
    func dispatch(_ event:OriginalCampaignEvent,currentPerson:Int? = nil) throws -> Bool {
        guard waiting != nil,stage.hostWaiting,choice == nil,saveRequest == nil,failure == nil else {
            throw EngineError.invalid("Original campaign cannot accept an event while a source operation is running")
        }
        if let currentPerson = currentPerson { currentEventPerson = currentPerson }
        let matched = try vm.dispatch(event:event)
        if matched { waiting = nil;try pump() }
        return matched
    }
    private func cacheCompletedCommands() throws {
        for c in pendingCache {
            if c.op == "remove",let person = c.person { try vm.invalidateCachedActor(person:person) }
            else if c.op == "place" || c.op == "move",let person = c.person,let x = c.x,let y = c.y,let facing = c.facing {
                try vm.cacheActor(person:person,x:x,y:y,sourceFacing:facing*2,completedMovement:c.op == "move")
            }
        }
        pendingCache.removeAll()
    }
    func pump() throws {
        guard started,stage.hostWaiting,choice == nil,saveRequest == nil,failure == nil,waiting == nil else {
            if let termination = stage.termination,termination != .sourceBoundary {
                let record = vm.activeRecord
                let source = stage.trace.last?.source
                let instruction = source.flatMap { origin in record?.instructions.first(where:{$0.commands.contains(where:{$0.source == origin})}) }
                failure = CampaignVMFailure(recordID:record?.id,opcode:instruction?.opcode,sourceOffset:instruction?.offset,reason:stage.endReason ?? "Native stage failed")
            }
            return
        }
        try cacheCompletedCommands()
        // A work bound stops pathological script cycles without declaring EOF
        // or inventing a phase transition. Caller can explicitly continue.
        for _ in 0..<4096 {
            let result = try vm.advance()
            switch result {
            case .commands(let commands):
                pendingCache = commands;try stage.enqueue(commands)
                if !stage.hostWaiting { return };try cacheCompletedCommands()
            case .loadMap(let request):
                try stage.setPalette(request.packedMap>>12)
                if request.packedMap>>12 == 3 {
                    guard let id = request.battleID,let definition = source.battles.battles.first(where:{$0.id == id}) else {
                        throw EngineError.invalid("Reached source battle map has no source load-site identity")
                    }
                    battle = try OriginalBattleSession(definition:definition,roster:roster,people:people,
                        combat:source.combat,movement:source.movement,rng:rng)
                } else {
                    if request.packedMap>>12 < 2 {
                        try exploration.configure(stage:stage,packed:request.packedMap,chapter:vm.state.chapter,people:people)
                    } else if request.packedMap>>12 == 2,let map = data.resources.maps[String(request.packedMap)] {
                        try stage.configureMap(request.packedMap,resource:map,actors:nil)
                    } else { throw EngineError.invalid("Reached original map is unavailable") }
                    try stage.enqueue([Command("map",map:request.packedMap)])
                }
                try vm.resumeMap(packedMap:request.packedMap)
            case .sourceAction(let instruction):
                if instruction.kind == "save-prompt" { saveRequest = instruction;return }
                do { try apply(instruction) }
                catch {
                    failure = CampaignVMFailure(recordID:vm.activeRecord?.id,opcode:instruction.opcode,
                        sourceOffset:instruction.offset,reason:"\(error)")
                    return
                }
                try vm.resumeHostAction(opcode:instruction.opcode,sourceOffset:instruction.offset)
                if instruction.kind == "checkpoint-capture" { checkpoint = snapshot() }
            case .choice(let value):choice = value;return
            case .waiting(let value):waiting = value;return
            case .unsupported(let value):failure = value;return
            case .budgetReached:
                failure = CampaignVMFailure(recordID:vm.activeRecord?.id,opcode:nil,sourceOffset:nil,reason:"Original VM instruction work budget reached")
                return
            }
        }
        failure = CampaignVMFailure(recordID:vm.activeRecord?.id,opcode:nil,sourceOffset:nil,reason:"Original host work budget reached")
    }
    private func apply(_ instruction:OriginalCampaignInstruction) throws {
        let args = instruction.arguments
        let expected:[Int:Int] = [3:0,7:2,0x11:2,0x1B:1,0x22:0,0x24:2,0x29:1,0x2F:2,0x37:2,0x39:2,0x3A:2,0x2B:2,0x36:0,0x38:1,0x3B:2,0x3C:1]
        guard instruction.opcode == 0x1C || expected[instruction.opcode] == args.count else { throw EngineError.invalid("Original host operands do not match their registered contract") }
        switch instruction.opcode {
        case 3,0x22:
            try roster.apply(source.rosters.program(chapter:vm.state.chapter,member:vm.state.member,offset:instruction.offset),flags:vm.state)
        case 7:
            try stage.beginStory(image:story.picture(args[0],mode:args[1],palette:stage.palette),mode:args[1],source:instruction.source)
        case 0x38: break // VM owns the source music selection; audio output remains unimplemented.
        case 0x36: break // Full native snapshot is captured after host acknowledgement below.
        case 0x11,0x29:
            let mode = instruction.opcode == 0x11 ? args[1] : args[0]
            guard [0,1,3].contains(mode) else { throw EngineError.invalid("Original map return mode is invalid") }
            // MAIN336FA only changes battle state under the battle palette.
            if stage.palette == 3,let battle = battle {
                try battle.acceptSourceResult(mode == 0 ? 2 : 3);rng = battle.rng
            }
        case 0x3B:try stage.worldCamera(x:args[0],y:args[1],source:instruction.source)
        case 0x3C:try stage.worldFollow(person:args[0],source:instruction.source)
        case 0x1C:
            guard let battle = battle else { throw BattleError.unsupported("Original AI-order effect requires its battle context") }
            _ = try battle.applyScriptAttribute(arguments:args)
        case 0x1B:
            let recipient:Int
            if vm.state.packedMap>>12 == 3 {
                guard let person = currentEventPerson else { throw BattleError.unsupported("Original battle item recipient has no source event-person identity") }
                recipient = person
            } else { recipient = 0 }
            _ = try people.grantScriptItem(person:recipient,itemID:args[0])
        case 0x24:try people.setAffiliation(person:args[0],value:args[1])
        case 0x2F:
            try people.update(args[0]) { $0.sourceRole = args[1] }
            if stage.currentMap?.geometry == "world" {
                try exploration.configure(stage:stage,packed:vm.state.packedMap,chapter:vm.state.chapter,people:people)
            }
        case 0x37:try people.update(args[0]) { $0.sourceFlags = args[1] == 0 ? ($0.sourceFlags & ~0x40) : ($0.sourceFlags|0x40) }
        case 0x39:try people.update(args[0]) { $0.level = min(99,$0.level+args[1]) }
        case 0x3A:try people.update(args[0]) { $0.classID = args[1] }
        case 0x2B:
            if args[0] == 2 {
                guard let current = money else { throw EngineError.invalid("Original initial player money has not been established") }
                money = min(10000,Int(UInt16(truncatingIfNeeded:current+args[1])))
            }
            else if args[0] == 4,let battle = battle { battle.scriptValue24 = UInt8(truncatingIfNeeded:args[1]) }
            else { throw EngineError.invalid("Reached campaign value selector has no restored host effect") }
        default:throw EngineError.invalid("Unregistered original host effect")
        }
    }
    func snapshot() -> OriginalCampaignCheckpoint {
        OriginalCampaignCheckpoint(vm:vm.snapshot(),people:people.values.values.sorted{$0.id < $1.id},roster:roster,
            rng:battle?.rng ?? rng,money:money,stage:stage.snapshot(),
            liveUnits:battle?.units.values.sorted{$0.slot < $1.slot},turns:battle?.turns,battleValue24:battle.map{Int($0.scriptValue24)})
    }
}
