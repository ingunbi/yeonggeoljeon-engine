// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The effect group MAIN2E0E6..2E833 selects from an item id, in source order.
/// Equipment and other ids fall through to the source refusal.
enum OriginalItemUse:Equatable {
    case classChange(target:Int)
    case promotion(required:Int,level:Int)
    case attack(family:Int,power:Int)
    case confuse(raw:Int,splash:Bool)
    case recovery(kind:Int,power:Int)
    case areaRecovery(kind:Int,power:Int)
    case bomb
    case unusable

    static func of(_ id:Int) -> Self {
        switch id {
        case 0...2,0x10...0x12:
            return .classChange(target:[15,18,12,3,6,0][id >= 0x10 ? id-0xD : id])
        case 0x13...0x1A:
            let index = id-0x13
            return .promotion(required:[0,1,3,4,6,7,9,10][index],level:index%2 == 0 ? 15 : 30)
        case 0x22...0x2A:
            // MAIN2E243..2E24D: idiv truncates toward zero, as Swift does.
            return .attack(family:(0x22-id)/3+2,power:(id-0x22)%3)
        case 0x2B...0x2D:
            return .confuse(raw:id == 0x2C ? 1 : 0,splash:id == 0x2D)
        case 0x34...0x36:
            return .recovery(kind:3,power:id-0x34)
        case 0x1B...0x20:
            return .recovery(kind:id >= 0x1E ? 1 : 2,power:id%3)
        case 0x2E...0x33:
            return .areaRecovery(kind:id >= 0x31 ? 2 : 1,power:(id-0x2E)%3)
        case 0x21:
            return .bomb
        default:
            return .unusable
        }
    }
    /// Range code for the target picker, or nil when no unit is picked.
    var rangeCode:Int? {
        switch self {
        case .attack(_,let power),.recovery(_,let power),.areaRecovery(_,let power):return power|0x80
        case .confuse(let raw,_):return raw|0x80
        case .bomb:return 0x81
        default:return nil
        }
    }
    /// Friendly pickers also offer the user's own cell, first (MAIN2F5C6).
    var targetsFriends:Bool {
        switch self {
        case .recovery,.areaRecovery:return true
        default:return false
        }
    }
}

struct OriginalItemExecution:Codable {
    var userSlot:Int
    var item:Int
    var completed:Bool
    /// A key of `OriginalBattleCommands`' item messages, or a selection state.
    var rejection:String?
    var targets:[OriginalStrategyTargetEffect]
    var newClass:Int?
    var rngBefore:UInt32
    var rngAfter:UInt32
}

enum OriginalItemStep {
    case target(OriginalStrategyTargetEffect)
    case retirement(OriginalRetirementNotice)
    case finished(OriginalItemExecution)
}

/// Retained locals of one item use, resumable across retirement dialogue like
/// `OriginalStrategyOperation`. Completion consumes the item and sets acted80.
struct OriginalItemOperation:Codable {
    private enum Continuation:Codable {
        case classChange(target:Int,clamp:Bool)
        case damage(target:Int,subtype:Int)
        case bomb(target:Int)
        case confuse(target:Int,center:GridPoint,splash:Bool)
        case confuseNeighbors(center:GridPoint,next:Int)
        case healing(slots:[Int],next:Int,subtype:Int)
        case completion
        case finished(OriginalItemExecution)
    }
    private var format = 1
    private var battleID:String
    let userSlot:Int
    let item:Int
    private var rngBefore:UInt32
    private var newClass:Int?
    private var continuation:Continuation
    private(set) var effects:[OriginalStrategyTargetEffect] = []
    private(set) var pendingRetirement:OriginalStrategyPendingRetirement?
    var execution:OriginalItemExecution? {
        if case .finished(let value) = continuation {return value};return nil
    }

    /// Units the picker offers: range cells in source order, friendly pickers
    /// beginning with the user's own cell.
    static func targetSlots(in session:OriginalBattleSession,userSlot:Int,use:OriginalItemUse) throws -> [Int] {
        guard let raw = use.rangeCode else {return []}
        let board = try session.board()
        guard let actor = board.actors.first(where:{$0.runtimeSlot == userSlot}) else {throw BattleError.invalid("Original item user is missing from its source board")}
        var cells = try OriginalAI.rangeCells(profile:session.movement,board:board,point:actor.position,raw:raw)
        if use.targetsFriends {cells.insert(actor.position,at:0)}
        return cells.compactMap { cell in
            guard let unit = board.occupant(cell),(unit.sourceFaction == actor.sourceFaction) == use.targetsFriends else {return nil}
            return unit.runtimeSlot
        }
    }
    /// MAIN2E127..2E211 and 2E6DD..2E7F9 in source order. The caller asks the
    /// source yes/no question only after this returns nil.
    static func classRefusal(in session:OriginalBattleSession,userSlot:Int,use:OriginalItemUse) throws -> String? {
        let unit = try session.live(userSlot),person = try session.people.person(unit.person)
        switch use {
        case .classChange(let target):
            if unit.person == 0 {return "playerClass"}
            if person.classID == target {return "sameClass"}
            if person.classID/3*3 == target {return "sameFamily"}
            let terrain = Int(session.terrain[unit.position.y*session.width+unit.position.x])
            let type = session.movement.classMovementTypes[target]
            return session.movement.movementCosts[type][terrain] == 255 ? "classTerrain" : nil
        case .promotion(let required,let level):
            if person.classID != required {return "wrongClass"}
            return person.level < level ? "lowLevel" : nil
        default:return nil
        }
    }
    /// Checks and selection stay here, with no gameplay RNG or mutation.
    /// A cancelled selection or a source refusal finishes without consuming.
    static func begin(in session:OriginalBattleSession,userSlot:Int,item:Int,target:Int? = nil,confirmed:Bool = true) throws -> Self {
        let user = try session.live(userSlot)
        guard (0..<64).contains(item),user.scriptFlags&0x82 == 0,try session.people.person(user.person).itemIDs.contains(item) else {
            throw BattleError.illegalAction("Original item user or item is not eligible")
        }
        var operation = Self(battleID:session.definition.id,userSlot:userSlot,item:item,rngBefore:session.rng.state,continuation:.completion)
        func stopped(_ reason:String) -> Self {
            var value = operation
            value.continuation = .finished(value.summary(in:session,completed:false,reason:reason));return value
        }
        let use = OriginalItemUse.of(item)
        if case .unusable = use {return stopped("unusable")}
        if !confirmed {return stopped("cancelled")}
        func picked() throws -> Int? {
            guard let target else {return nil}
            guard try targetSlots(in:session,userSlot:userSlot,use:use).contains(target),session.units[target] != nil else {
                throw BattleError.illegalAction("Original item target is outside its source range/faction")
            }
            return target
        }
        switch use {
        case .classChange(let value):
            if let refusal = try classRefusal(in:session,userSlot:userSlot,use:use) {return stopped(refusal)}
            operation.newClass = value;operation.continuation = .classChange(target:value,clamp:true)
        case .promotion(let required,_):
            if let refusal = try classRefusal(in:session,userSlot:userSlot,use:use) {return stopped(refusal)}
            operation.newClass = required+1;operation.continuation = .classChange(target:required+1,clamp:false)
        case .attack(let family,let power):
            if family == 0 && session.combat.strategyEnvironmentLookup[Int(session.turns.weatherIndex)] == 2 {return stopped("rainFire")}
            guard let slot = try picked(),let unit = session.units[slot] else {return stopped("cancelled")}
            guard try session.movement.strategyTerrainEligible(family:family,terrain:session.terrain[unit.position.y*session.width+unit.position.x]) else {
                return stopped("terrain")
            }
            operation.continuation = .damage(target:slot,subtype:(family<<4)|power)
        case .confuse(_,let splash):
            guard let slot = try picked(),let unit = session.units[slot] else {return stopped("cancelled")}
            if unit.scriptFlags&2 != 0 {return stopped("alreadyConfused")}
            operation.continuation = .confuse(target:slot,center:unit.position,splash:splash)
        case .recovery(let kind,let power):
            guard let slot = try picked(),let unit = session.units[slot] else {return stopped("cancelled")}
            let stats = try session.people.stats(unit.person,morale:unit.morale)
            guard try OriginalCombat.healingUseful(target:stats,conditionFlags:Int(unit.scriptFlags),recoveryFlags:kind,tables:session.combat) else {
                return stopped("noRecovery")
            }
            operation.continuation = .healing(slots:[slot],next:0,subtype:(power<<4)|kind)
        case .areaRecovery(let kind,let power):
            // BAF6 snapshots the list once; a resume never re-enumerates it.
            let slots = try targetSlots(in:session,userSlot:userSlot,use:use)
            if slots.isEmpty {return stopped("noAllyNearby")}
            operation.continuation = .healing(slots:slots,next:0,subtype:(power<<4)|kind)
        case .bomb:
            guard let slot = try picked() else {return stopped("cancelled")}
            operation.continuation = .bomb(target:slot)
        case .unusable:break
        }
        return operation
    }
    mutating func resumeRetirement(_ notice:OriginalRetirementNotice) throws {
        guard pendingRetirement?.notice == notice else {throw BattleError.illegalAction("Original item retirement acknowledgement is stale")}
        pendingRetirement = nil
    }
    mutating func advance(in session:OriginalBattleSession) throws -> OriginalItemStep {
        guard format == 1,battleID == session.definition.id,(0..<15).contains(userSlot),(0..<64).contains(item),effects.count <= 45 else {
            throw BattleError.invalid("Original item continuation does not match its source session")
        }
        if let pending = pendingRetirement {
            guard effects.indices.contains(pending.effectIndex),effects[pending.effectIndex].retirement == pending.notice else {
                throw BattleError.invalid("Original item checkpoint lost its retirement/effect identity")
            }
            return .retirement(pending.notice)
        }
        while true {
            switch continuation {
            case .finished(let value):return .finished(value)
            case let .classChange(target,clamp):
                guard let unit = session.units[userSlot] else {throw BattleError.unsupported("Original item user slot was removed")}
                try session.people.update(unit.person) {$0.classID = target}
                if clamp {
                    // MAIN2E79F..2E7AB rewrites troops through the capped setter.
                    let person = try session.people.person(unit.person)
                    let maximum = try OriginalCombat.maxTroops(classID:target,level:person.level,tables:session.combat)
                    try session.people.update(unit.person) {$0.rawTroops = min($0.rawTroops,maximum)}
                }
                continuation = .completion
            case let .damage(target,subtype):
                let effect = try session.strategyDamageEffect(casterSlot:userSlot,targetSlot:target,subtype:subtype,kind:3)
                continuation = .completion;return retain(effect)
            case let .bomb(target):
                let effect = try session.itemBombEffect(targetSlot:target)
                continuation = .completion;return retain(effect)
            case let .confuse(target,center,splash):
                let effect = try session.itemConfusionEffect(targetSlot:target)
                continuation = splash ? .confuseNeighbors(center:center,next:0) : .completion
                return retain(effect)
            case let .confuseNeighbors(center,next):
                guard (0...4).contains(next) else {throw BattleError.invalid("Original item neighbor continuation is invalid")}
                if next == 4 {continuation = .completion;continue}
                let offset = session.movement.cardinalOffsets[next],point = GridPoint(x:center.x+offset.dx,y:center.y+offset.dy),board = try session.board()
                continuation = .confuseNeighbors(center:center,next:next+1)
                // MAIN2E419..2E423 compares sides against the item user.
                guard board.contains(point),let target = board.occupant(point),(target.runtimeSlot < 15) != (userSlot < 15) else {continue}
                return retain(try session.itemConfusionEffect(targetSlot:target.runtimeSlot))
            case let .healing(slots,next,subtype):
                guard slots.count <= 45,(0...slots.count).contains(next),slots.allSatisfy({(0..<45).contains($0)}) else {throw BattleError.invalid("Original item healing continuation is invalid")}
                if next == slots.count {continuation = .completion;continue}
                let effect = try session.strategyHealingEffect(casterSlot:nil,targetSlot:slots[next],subtype:subtype)
                continuation = .healing(slots:slots,next:next+1,subtype:subtype);return retain(effect)
            case .completion:
                guard let current = session.units[userSlot] else {throw BattleError.unsupported("Original item user slot was removed before completion")}
                // MAIN2E807..2E82B: a campaign hook may already have taken the item.
                if try session.people.person(current.person).itemIDs.contains(item) {try session.people.discardItem(person:current.person,item:item)}
                session.units[userSlot]!.scriptFlags |= 0x80;session.commitMove(userSlot)
                let result = summary(in:session,completed:true)
                continuation = .finished(result);return .finished(result)
            }
        }
    }
    private mutating func retain(_ effect:OriginalStrategyTargetEffect) -> OriginalItemStep {
        effects.append(effect)
        if let notice = effect.retirement {
            pendingRetirement = OriginalStrategyPendingRetirement(effectIndex:effects.count-1,notice:notice)
        }
        return .target(effect)
    }
    private func summary(in session:OriginalBattleSession,completed:Bool,reason:String? = nil) -> OriginalItemExecution {
        OriginalItemExecution(userSlot:userSlot,item:item,completed:completed,rejection:reason,targets:effects,
            newClass:completed ? newClass : nil,rngBefore:rngBefore,rngAfter:session.rng.state)
    }
}

extension OriginalBattleSession {
    /// MAIN2E5DA..2E6D3. The troop draw comes first; a wiped-out target takes
    /// no morale loss and consumes no second draw.
    func itemBombEffect(targetSlot:Int) throws -> OriginalStrategyTargetEffect {
        guard let target = units[targetSlot],target.status == 2 else {throw BattleError.unsupported("Original bomb target changed before its producer")}
        let stats = try people.stats(target.person,morale:target.morale)
        let amount = (try rng.next(bound:21)+0x5A)*15,damage = min(amount,stats.troops)
        try people.update(target.person) {$0.rawTroops = stats.troops-damage}
        var morale:OriginalMoraleMutation?
        if stats.troops != damage {
            let loss = min(try rng.next(bound:10)+0x1E,stats.morale)
            var after = stats;after.troops = stats.troops-damage
            morale = try OriginalCombat.setMorale(stats:after,unitStatus:target.status,conditionFlags:Int(target.scriptFlags),requestedMorale:stats.morale-loss,rng:&rng)
            units[targetSlot]!.morale = morale!.remainingMorale;units[targetSlot]!.scriptFlags = UInt8(morale!.remainingFlags)
        }
        let retirement = try strategyRetirement(targetSlot)
        return OriginalStrategyTargetEffect(runtimeSlot:targetSlot,person:target.person,kind:"bomb",morale:morale,
            quantity:damage,retiredPerson:retirement.person,retirement:retirement.notice)
    }
    /// MAIN2E3B6..2E3CF: confusion items have no success roll.
    func itemConfusionEffect(targetSlot:Int) throws -> OriginalStrategyTargetEffect {
        guard let target = units[targetSlot] else {throw BattleError.unsupported("Original confusion target changed before its producer")}
        units[targetSlot]!.scriptFlags |= 2
        let retirement = try strategyRetirement(targetSlot)
        return OriginalStrategyTargetEffect(runtimeSlot:targetSlot,person:target.person,kind:"condition2",
            retiredPerson:retirement.person,retirement:retirement.notice)
    }
}
