// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct OriginalScriptEnvironmentTables:Codable {
    var markerTerrain:[Int]
    var toggleTerrain:[Int]
    var pictureDeltas:[[Int]]
    var remapFrom:[Int]
    var remapTo:[Int]
    var specialMapIndices:[Int]
    func validate() throws {
        guard markerTerrain.count == 256,toggleTerrain.count == 256,
              (markerTerrain+toggleTerrain+remapFrom+remapTo).allSatisfy({(0...255).contains($0)}),
              pictureDeltas.count == 2,pictureDeltas.allSatisfy({$0.count == 128 && $0.allSatisfy({(-32768...32767).contains($0)})}),
              remapFrom.count == 9,remapTo.count == 9,specialMapIndices.count == 19,
              specialMapIndices.allSatisfy({(0...65535).contains($0)}) else {
            throw BattleError.invalid("Original script environment table domain/cardinality")
        }
    }
}
struct OriginalScriptEnvironmentRecord:Codable,Equatable {
    var point:GridPoint
    var encodedType:UInt8
    var priorTerrain:UInt8
}
struct OriginalScriptDuel:Codable,Equatable {
    var people:[Int]
    var positions:[Int16] = [4,16]
    var rows:[Int16] = [3,3]
    var frames:[UInt8] = [0,0]
    // Source3431C graphics buffers are replaced by death/flee loaders. The
    // same pose index must retain its current native graphic-load identity.
    var loadModes:[UInt8] = [0,1]
    var camera:UInt8 = 0
    var active = true
}
struct OriginalScriptActionState:Codable,Equatable {
    // MAIN335A2 initializes the source action-manager's byte0 toFF.
    var contextByte0:UInt8 = 255
    var duel:OriginalScriptDuel?
    var environment:[OriginalScriptEnvironmentRecord] = []
    var markers:[GridPoint:UInt8] = [:]
}
struct OriginalScriptActionResult:Codable,Equatable {
    var opcode:Int
    var sourceReturn:Int?
    var changedSlots:[Int] = []
    var changedPeople:[Int] = []
    var changedCells:[GridPoint] = []
    var presentationOnly = false
    var presentationTimingRestored = false
    var rngBounds:[Int] = []
    var movementPath:[GridPoint]?
    var rngBefore:UInt32
    var rngAfter:UInt32
}

extension OriginalBattleSession {
    /// MAIN1D2D4/1D3D8/1D60C dispatch these generic campaign commands to the
    /// native battle action manager for map kind3. VM actor-cache writes remain
    /// owned by the campaign VM; its typed operands are not decoded again here.
    @discardableResult
    func applyScriptMapCommand(_ command:Command,roster:OriginalRoster) throws -> OriginalScriptActionResult {
        let opcodes = ["place":0x0A,"move":0x01,"remove":0x18]
        guard let opcode = opcodes[command.op],let person = command.person,(0...65535).contains(person),roster.slots.count == 45 else {
            throw BattleError.invalid("Original native map command identity/shape")
        }
        if command.op != "remove" {
            guard let x = command.x,let y = command.y,[x,y].allSatisfy({(0...255).contains($0)}) else {
                throw BattleError.invalid("Original native map position operands are not bytes")
            }
            // Generic facing/cache interpretation belongs to Command's
            // genericPlacementDirection consumer in the host/runtime. The
            // native battle placement/movement never reads that operand; raw8,
            // script-quarter and omitted facing therefore share this adapter.
        }
        var result = OriginalScriptActionResult(opcode:opcode,sourceReturn:-1,rngBefore:rng.state,rngAfter:rng.state)
        // MAIN3356A returns the first person match, including inactive/reserved
        // slots. In particular, do not prefer an active alias of that person.
        guard let slot = units.keys.sorted().first(where:{units[$0]!.person == person}) else {return result}
        let prior = units[slot]!
        switch command.op {
        case "place":
            // MAIN335BE ignores the command's position after the VM cache write.
            // Activation instead reads the first matching native setup row.
            guard prior.status == 1,let row = roster.slots.first(where:{$0.person == person}) else {return result}
            var unit = prior,occupancy:[GridPoint:Int] = [:]
            for live in units.values.sorted(by:{$0.slot < $1.slot}) where live.status == 2 {occupancy[live.position] = live.slot}
            let classID = try people.person(person).classID
            // The wrapper returns1 once it calls8422, even if8422 rejects an
            // out-of-map setup coordinate. Preserve that wrapper return value.
            _ = try OriginalParty.activate(unit:&unit,classID:classID,requested:GridPoint(x:row.x,y:row.y),
                flipped:row.flags&4 == 0,movement:movement,width:width,height:height,terrain:terrain,occupancy:&occupancy)
            // MAIN33652..3366C has no action/condition-bit clear after8422.
            units[slot] = unit;result.sourceReturn = 1
        case "move":
            let goal = GridPoint(x:command.x!,y:command.y!)
            guard (0..<width).contains(goal.x),(0..<height).contains(goal.y) else {return result}
            units[slot]!.scriptFlags |= 4;units[slot]!.orderMode = 0
            if try movement.cost(classID:people.person(person).classID,terrain:Int(terrain[goal.y*width+goal.x])) != 255 {
                units[slot]!.goal = goal;units[slot]!.preferredTarget = nil
            }
            if let cached = units[slot]!.preferredTarget,units[cached]?.status != 2 {
                units[slot]!.preferredTarget = nil;units[slot]!.orderMode = 1
            }
            if prior.status == 2,prior.scriptFlags&0x82 == 0 {
                let decision = try aiDecision(slot)
                guard decision.targetSlot == nil,decision.strategyID == nil else {
                    throw BattleError.invalid("Original scripted movement unexpectedly selected an attack")
                }
                try applyAIMovement(slot,decision);result.movementPath = decision.path
            }
            // Native CE50 skips condition2/already-acted movement and suppresses
            // attack/event probes under flag4. Its caller then clears C4 only.
            units[slot]!.scriptFlags &= ~UInt8(0xC4);result.sourceReturn = 1
        case "remove":
            units[slot]!.scriptFlags |= 4
            let referenced = units.keys.sorted().filter{units[$0]!.orderMode == 0 && units[$0]!.preferredTarget == slot}
            _ = retireUnit(slot)
            if prior.status == 2 { result.changedSlots.append(contentsOf:referenced) }
            units[slot]!.scriptFlags &= ~UInt8(4);result.sourceReturn = 1
        default:throw BattleError.invalid("Original native map command producer")
        }
        if units[slot] != prior,!result.changedSlots.contains(slot) {result.changedSlots.insert(slot,at:0)}
        result.rngAfter = rng.state
        return result
    }
}

private enum OriginalDuelActions {
    static func adjust(_ value:inout OriginalScriptDuel,encoded:Int) {
        let count = encoded&127,delta = encoded&128 == 0 ? count : -count
        value.positions[0] = Int16(truncatingIfNeeded:Int(value.positions[0])+delta)
        value.positions[1] = Int16(truncatingIfNeeded:Int(value.positions[1])-delta)
        value.frames = [0,0]
    }
    static func approach(_ value:inout OriginalScriptDuel,side:Int,extra:Int?) throws {
        let other = side^1,direction = side == 0 ? 1 : -1
        let target = Int16(truncatingIfNeeded:Int(value.positions[other])+(side == 0 ? -4 : 4))
        if let extra = extra {
            let difference = Int16(truncatingIfNeeded:Int(value.positions[1])-Int(value.positions[0]))
            let magnitude = difference < 0 ? Int16(truncatingIfNeeded:-Int(difference)) : difference
            let bound = Int16(truncatingIfNeeded:Int(magnitude)+extra)
            guard bound < 255 else { throw BattleError.unsupported("Original duel's byte animation counter cannot terminate for this position span") }
            let steps = bound < 0 ? 1 : Int(bound)+1
            value.positions[side] = Int16(truncatingIfNeeded:Int(value.positions[side])+direction*steps)
        } else { value.positions[side] = target }
        value.frames[side] = 0
    }
    static func motion(_ value:inout OriginalScriptDuel,person:Int,code:Int) throws {
        let side = person == value.people[0] ? 0 : 1
        switch code {
        case 0,1,6,7:
            try approach(&value,side:side,extra:nil)
            value.frames[side] = UInt8(code < 3 ? (code+2)*2+1 : (code-4)*2+1)
        case 2:value.frames[side] = 9
        case 3:
            value.loadModes[1] = 2
            value.frames[side] = 4
        case 4:
            // The source fleeing sequence always moves duel participant1.
            value.loadModes[1] = 3
            value.positions[1] = Int16(truncatingIfNeeded:Int(value.positions[1])+14)
            value.frames[1] = 1
        case 5:value.frames[side] = 0
        case 8:adjust(&value,encoded:10)
        case 9:
            let target = max(0,Int(Int16(truncatingIfNeeded:Int(value.positions[side])-10)))
            guard target <= 255 else { throw BattleError.unsupported("Original duel camera byte loop cannot reach this target") }
            let initial = Int(value.camera),direction = initial > target ? -1 : 1,steps = abs(initial-target)
            if steps > 0 {
                for index in 0..<2 { value.positions[index] = Int16(truncatingIfNeeded:Int(value.positions[index])-direction*steps) }
                value.camera = UInt8(target-direction)
            }
        case 10:try approach(&value,side:side,extra:8)
        default:throw BattleError.unsupported("Original duel motion reads an uninitialized source frame for code\(code)")
        }
    }
}

extension OriginalBattleSession {
    /// Typed campaign operands are consumed once here. Duel actions preserve
    /// their native state and RNG without claiming restored bitmap timing.
    @discardableResult
    func applyScriptAction(opcode:Int,arguments:[Int],mapIndex:Int? = nil) throws -> OriginalScriptActionResult {
        let shapes:[Int:Int] = [2:1,0x10:2,0x26:3,0x27:3,0x28:2,0x2D:2,0x33:0,0x34:0,0x35:2]
        guard shapes[opcode] == arguments.count,arguments.allSatisfy({(0...65535).contains($0)}) else {
            throw BattleError.invalid("Original script action opcode/typed operand shape")
        }
        let byteArguments:[Int]
        switch opcode {
        case 2,0x26,0x27,0x2D:byteArguments = arguments
        case 0x28,0x35:byteArguments = [arguments[1]]
        default:byteArguments = []
        }
        guard byteArguments.allSatisfy({(0...255).contains($0)}) else { throw BattleError.invalid("Original script action byte operand") }
        var result = OriginalScriptActionResult(opcode:opcode,sourceReturn:nil,rngBefore:rng.state,rngAfter:rng.state)
        func slot(_ person:Int)->Int? { units.keys.sorted().first { units[$0]?.person == person } }
        switch opcode {
        case 2:scriptActions.contextByte0 = UInt8(arguments[0])
        case 0x10:
            result.presentationOnly = true
            guard slot(arguments[0]) != nil,slot(arguments[1]) != nil else { result.sourceReturn = -1;return result }
            scriptActions.duel = OriginalScriptDuel(people:arguments)
            result.sourceReturn = 1
        case 0x33:
            result.presentationOnly = true
            scriptActions.duel?.active = false
        case 0x34:
            guard var duel = scriptActions.duel else { throw BattleError.unsupported("Original duel setup context is absent") }
            result.presentationOnly = true
            OriginalDuelActions.adjust(&duel,encoded:4)
            for _ in 0..<5 {
                result.rngBounds += [3,3]
                let first = try rng.next(bound:3),second = try rng.next(bound:3)
                if first != 2 || second != 2 {
                    for _ in 0..<2 { result.rngBounds.append(2);_ = try rng.next(bound:2) }
                }
            }
            OriginalDuelActions.adjust(&duel,encoded:0x84)
            scriptActions.duel = duel
        case 0x35:
            result.presentationOnly = true
            guard slot(arguments[0]) != nil else { return result }
            guard var duel = scriptActions.duel else { throw BattleError.unsupported("Original duel motion context is absent") }
            try OriginalDuelActions.motion(&duel,person:arguments[0],code:arguments[1])
            scriptActions.duel = duel
        case 0x2D:
            let enemy = arguments[0] != 0
            for id in units.keys.sorted() where units[id]!.enemy == enemy && units[id]!.status == 2 {
                let unit = units[id]!
                if arguments[1] == 0 {
                    let stats = try people.stats(unit.person,morale:unit.morale)
                    let mutation = try OriginalCombat.setMorale(stats:stats,unitStatus:unit.status,
                        conditionFlags:Int(unit.scriptFlags),requestedMorale:unit.morale/2,rng:&rng)
                    units[id]!.morale = mutation.remainingMorale;units[id]!.scriptFlags = UInt8(mutation.remainingFlags)
                    result.changedSlots.append(id)
                } else {
                    let quantity = try people.person(unit.person).rawTroops/2
                    try people.update(unit.person) { $0.rawTroops = quantity }
                    result.changedPeople.append(unit.person)
                }
            }
        case 0x28:
            guard let oldSlot = slot(arguments[0]),let old = units[oldSlot] else { result.sourceReturn = -1;return result }
            let destinationRange = old.enemy ? 0..<15 : 15..<45
            guard let newSlot = destinationRange.first(where:{(units[$0]?.status ?? 0) == 0}) else { result.sourceReturn = -1;return result }
            try people.setAffiliation(person:old.person,value:arguments[1])
            var copied = old;copied.slot = newSlot;copied.preferredTarget = nil;copied.goal = old.position
            let affiliation = try people.person(old.person).sourceFlags
            copied.orderMode = newSlot < 15 && affiliation&31 == 0 ? 7 : 3
            units[newSlot] = copied;units[oldSlot]!.status = 0
            result.changedSlots = [oldSlot,newSlot];result.changedPeople = [old.person];result.sourceReturn = 1
        case 0x26,0x27:
            result.changedCells = try applyScriptEnvironment(opcode:opcode,arguments:arguments,mapIndex:mapIndex)
        default:throw BattleError.unsupported("Original script action producing boundary")
        }
        result.rngAfter = rng.state
        return result
    }
}

extension OriginalBattleSession {
    private func applyScriptEnvironment(opcode:Int,arguments:[Int],mapIndex:Int?) throws -> [GridPoint] {
        guard let tables = movement.scriptEnvironment else { throw BattleError.unsupported("Original script environment tables are absent") }
        try tables.validate()
        let point = GridPoint(x:arguments[0],y:arguments[1]),rawType = arguments[2]
        guard (0..<width).contains(point.x),(0..<height).contains(point.y) else {
            throw BattleError.unsupported("Original environment action reads outside the interpreted source map")
        }
        let index = point.y*width+point.x,prior = terrain[index]
        if opcode == 0x27 {
            guard !units.values.contains(where:{$0.status == 2 && $0.position == point}) else { return [] }
            if rawType == 2 {
                guard let record = scriptActions.environment.firstIndex(where:{$0.point == point}) else { return [] }
                terrain[index] = scriptActions.environment[record].priorTerrain
                scriptActions.environment.remove(at:record);scriptActions.markers.removeValue(forKey:point)
            } else {
                scriptActions.environment.append(.init(point:point,encodedType:UInt8(rawType),priorTerrain:prior))
                terrain[index] = UInt8(tables.markerTerrain[rawType])
                scriptActions.markers[point] = UInt8(truncatingIfNeeded:45+rawType)
            }
            return [point]
        }
        guard opcode == 0x26 else { throw BattleError.invalid("Original environment producer opcode") }
        let type = rawType&127
        // The ordinary source branch returns before any graphic lookup when
        // the terrain predicate fails; preserve that no-op without new inputs.
        if type != 2 && Int(prior) != tables.toggleTerrain[type] { return [] }
        guard let columns = definition.pictureColumns,let rows = definition.pictureRows,
              columns == width*2,rows == height*2,var pictures = pictureTiles,pictures.count == columns*rows else {
            throw BattleError.unsupported("Original environment picture grid is absent or inconsistent")
        }
        let positions = [point.y*2*columns+point.x*2,point.y*2*columns+point.x*2+1,
                         (point.y*2+1)*columns+point.x*2,(point.y*2+1)*columns+point.x*2+1]
        let oldPictures = positions.map { pictures[$0] }
        var updateTerrain = true
        if type == 2 {
            for position in positions {
                // Source scans all nine records after each write: remapping
                // can cascade and cannot be normalized to a dictionary lookup.
                for pair in 0..<9 where pictures[position] == UInt8(tables.remapFrom[pair]) {
                    pictures[position] = UInt8(tables.remapTo[pair])
                }
            }
            updateTerrain = positions.contains { pictures[$0] == 0xD3 }
        } else {
            guard let mapIndex = mapIndex,(0...255).contains(mapIndex) else {
                throw BattleError.unsupported("Original environment tile variant requires the source map byte")
            }
            let variant = tables.specialMapIndices.contains(mapIndex) ? 1 : 0
            let delta = tables.pictureDeltas[variant][type]
            for position in positions {
                if pictures[position] == 0xC5 { pictures[position] = 0xC7 }
                else if pictures[position] == 0xC6 { pictures[position] = 0xE6 }
                else { pictures[position] = UInt8(truncatingIfNeeded:Int(pictures[position])+delta) }
            }
        }
        pictureTiles = pictures
        if updateTerrain {
            let paired = type+(type&1 == 0 ? 1 : -1)
            terrain[index] = UInt8(tables.toggleTerrain[paired])
            if rawType&128 == 0 {
                scriptActions.environment.append(.init(point:point,encodedType:UInt8(type|128),priorTerrain:prior))
            }
        }
        return updateTerrain || positions.map({pictures[$0]}) != oldPictures ? [point] : []
    }
}
