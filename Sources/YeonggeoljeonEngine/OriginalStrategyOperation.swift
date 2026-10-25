// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Operation-local effect cursor and the session owner's retirement identity
/// are separate checkpoint facts. The global notice is the host's ack token.
struct OriginalStrategyPendingRetirement:Codable,Equatable {
    var effectIndex:Int
    var notice:OriginalRetirementNotice
}

enum OriginalStrategyStep {
    case target(OriginalStrategyTargetEffect)
    case retirement(OriginalRetirementNotice)
    case finished(OriginalStrategyExecution)
}

/// The source dispatcher's retained locals and program counter. No native
/// closure, session reference or re-parsed raw source belongs in a checkpoint.
struct OriginalStrategyOperation:Codable {
    private enum Continuation:Codable {
        case damage(target:Int,subtype:Int,family:Int,splash:Bool)
        case damageCenter(target:Int,subtype:Int,family:Int)
        case damageNeighbors(center:GridPoint,subtype:Int,family:Int,next:Int)
        case condition(target:Int,center:GridPoint,splash:Bool)
        case conditionNeighbors(center:GridPoint,next:Int)
        case morale(target:Int)
        case healing(slots:[Int],next:Int,subtype:Int)
        case completion
        case finished(OriginalStrategyExecution)
    }
    private var format = 1
    private var battleID:String
    private var width:Int
    private var height:Int
    let casterSlot:Int
    let abilityID:Int
    private var category:Int
    private var mpCost:Int
    private var sourceFaction:Int
    private var rngBefore:UInt32
    private var continuation:Continuation
    private(set) var effects:[OriginalStrategyTargetEffect] = []
    private(set) var pendingRetirement:OriginalStrategyPendingRetirement?
    var execution:OriginalStrategyExecution? {
        if case .finished(let value) = continuation {return value};return nil
    }

    /// MAIN2E836..2EE1C: selection/availability and the branch's source locals
    /// are captured before the first effect. This consumes no gameplay RNG.
    static func begin(in session:OriginalBattleSession,casterSlot:Int,abilityID:Int,target:Int? = nil,confirmed:Bool = true) throws -> Self {
        let caster = try session.live(casterSlot)
        guard (0..<36).contains(abilityID),caster.scriptFlags&0x82 == 0 else {throw BattleError.illegalAction("Original strategy actor/ability is not eligible")}
        let stats = try session.people.stats(caster.person,morale:caster.morale)
        guard try session.movement.availableStrategies(classID:stats.classID,level:stats.level,mp:caster.mp).contains(abilityID),
              let categories = session.movement.strategyCategories,let costs = session.movement.strategyMPCosts,
              categories.count == 36,costs.count == 36 else {throw BattleError.illegalAction("Original strategy level/MP availability rejects this ability")}
        try session.combat.validate()
        let category = categories[abilityID]
        var operation = Self(battleID:session.definition.id,width:session.width,height:session.height,casterSlot:casterSlot,
            abilityID:abilityID,category:category,mpCost:costs[abilityID],sourceFaction:casterSlot < 15 ? 1 : 0,
            rngBefore:session.rng.state,continuation:.completion)
        func stopped(_ reason:String)->Self {
            var value = operation
            value.continuation = .finished(value.summary(in:session,completed:false,reason:reason));return value
        }
        if abilityID < 15 && abilityID/5 == 0 && session.combat.strategyEnvironmentLookup[Int(session.turns.weatherIndex)] == 2 {
            return stopped("source weather rejection")
        }
        let board = try session.board()
        guard let actor = board.actors.first(where:{$0.runtimeSlot == casterSlot}) else {throw BattleError.invalid("Original strategy caster is missing from its source board")}
        let candidates = try OriginalAI.strategyTargetSlots(profile:session.movement,board:board,actor:actor,abilityID:abilityID)
        if abilityID < 30 {
            guard let target else {return stopped("source target selection cancelled")}
            guard candidates.contains(target),let unit = session.units[target] else {throw BattleError.illegalAction("Original strategy target is outside its source range/faction")}
            if abilityID < 15 {
                let family = abilityID/5
                guard try session.movement.strategyTerrainEligible(family:family,terrain:session.terrain[unit.position.y*session.width+unit.position.x]) else {return stopped("source target terrain rejection")}
                operation.continuation = .damage(target:target,subtype:((family<<4)|category)&255,family:family,splash:abilityID%5 >= 3)
            } else if abilityID <= 17 {
                // Source status AoE copies the center before its first context.
                operation.continuation = .condition(target:target,center:unit.position,splash:abilityID == 17)
            } else if abilityID <= 20 {operation.continuation = .morale(target:target)}
            else {
                let flags = abilityID >= 27 ? 3 : abilityID >= 24 ? 1 : 2
                let targetStats = try session.people.stats(unit.person,morale:unit.morale)
                guard try OriginalCombat.healingUseful(target:targetStats,conditionFlags:Int(unit.scriptFlags),recoveryFlags:flags,tables:session.combat) else {return stopped("source healing target is already restored")}
                operation.continuation = .healing(slots:[target],next:0,subtype:((category<<4)|flags)&255)
            }
        } else {
            if candidates.isEmpty {return stopped("source area target list is empty")}
            if !confirmed {return stopped("source area confirmation declined")}
            // BAF6 snapshots slot order once; resuming never re-enumerates it.
            operation.continuation = .healing(slots:candidates,next:0,subtype:(((abilityID-30)%3)<<4)|(abilityID > 32 ? 1 : 2))
        }
        return operation
    }

    /// Acknowledgement alone does not execute another target. Repeated advance
    /// while waiting returns the same notice and does not repeat RNG/writeback.
    mutating func resumeRetirement(_ notice:OriginalRetirementNotice) throws {
        guard pendingRetirement?.notice == notice else {throw BattleError.illegalAction("Original strategy retirement acknowledgement is stale")}
        pendingRetirement = nil
    }
    mutating func advance(in session:OriginalBattleSession) throws -> OriginalStrategyStep {
        guard format == 1,battleID == session.definition.id,width == session.width,height == session.height,
              (0..<45).contains(casterSlot),(0..<36).contains(abilityID),(0...255).contains(category),
              (0...255).contains(mpCost),[0,1].contains(sourceFaction),effects.count <= 45 else {
            throw BattleError.invalid("Original strategy continuation does not match its source session")
        }
        if let pending = pendingRetirement {
            guard effects.indices.contains(pending.effectIndex),effects[pending.effectIndex].retirement == pending.notice else {
                throw BattleError.invalid("Original strategy checkpoint lost its retirement/effect identity")
            }
            return .retirement(pending.notice)
        }
        while true {
            switch continuation {
            case .finished(let value):return .finished(value)
            case let .damage(target,subtype,family,splash):
                let effect = try session.strategyDamageEffect(casterSlot:casterSlot,targetSlot:target,subtype:subtype)
                continuation = splash ? .damageCenter(target:target,subtype:subtype,family:family) : .completion
                return retain(effect)
            case let .damageCenter(target,subtype,family):
                // Deliberately after retirement acknowledgement: the script
                // may move the primary, change terrain, or replace neighbors.
                guard let center = session.units[target]?.position else {throw BattleError.unsupported("Original splash center was removed by a campaign hook")}
                continuation = .damageNeighbors(center:center,subtype:subtype,family:family,next:0)
            case let .damageNeighbors(center,subtype,family,next):
                guard (0...4).contains(next) else {throw BattleError.invalid("Original strategy neighbor continuation is invalid")}
                if next == 4 {continuation = .completion;continue}
                let offset = session.movement.cardinalOffsets[next],point = GridPoint(x:center.x+offset.dx,y:center.y+offset.dy)
                let board = try session.board()
                guard board.contains(point),try session.movement.strategyTerrainEligible(family:family,terrain:board.terrain[board.index(point)]),
                      let target = board.occupant(point),target.sourceFaction != sourceFaction else {
                    continuation = .damageNeighbors(center:center,subtype:subtype,family:family,next:next+1);continue
                }
                let effect = try session.strategyDamageEffect(casterSlot:casterSlot,targetSlot:target.runtimeSlot,subtype:subtype)
                continuation = .damageNeighbors(center:center,subtype:subtype,family:family,next:next+1)
                return retain(effect)
            case let .condition(target,center,splash):
                let effect = try session.strategyConditionEffect(casterSlot:casterSlot,targetSlot:target)
                continuation = splash ? .conditionNeighbors(center:center,next:0) : .completion
                return retain(effect)
            case let .conditionNeighbors(center,next):
                guard (0...4).contains(next) else {throw BattleError.invalid("Original strategy neighbor continuation is invalid")}
                if next == 4 {continuation = .completion;continue}
                let offset = session.movement.cardinalOffsets[next],point = GridPoint(x:center.x+offset.dx,y:center.y+offset.dy),board = try session.board()
                guard board.contains(point),let target = board.occupant(point),target.sourceFaction != sourceFaction else {
                    continuation = .conditionNeighbors(center:center,next:next+1);continue
                }
                let effect = try session.strategyConditionEffect(casterSlot:casterSlot,targetSlot:target.runtimeSlot)
                continuation = .conditionNeighbors(center:center,next:next+1)
                return retain(effect)
            case let .morale(target):
                let effect = try session.strategyMoraleEffect(casterSlot:casterSlot,targetSlot:target,category:category)
                continuation = .completion;return retain(effect)
            case let .healing(slots,next,subtype):
                guard slots.count <= 45,(0...slots.count).contains(next),slots.allSatisfy({(0..<45).contains($0)}) else {throw BattleError.invalid("Original healing continuation is invalid")}
                if next == slots.count {continuation = .completion;continue}
                let effect = try session.strategyHealingEffect(casterSlot:casterSlot,targetSlot:slots[next],subtype:subtype)
                continuation = .healing(slots:slots,next:next+1,subtype:subtype);return retain(effect)
            case .completion:
                guard let current = session.units[casterSlot] else {throw BattleError.unsupported("Original caster slot was removed before command completion")}
                let casterClass = try session.people.person(current.person).classID
                let completion = try OriginalCombat.completeStrategy(abilityID:abilityID,casterClassID:casterClass,currentMP:Int(current.mp),mpCost:mpCost)
                let experience = completion.flatExperience == 0 ? nil : try session.people.applyExperience(person:current.person,gain:completion.flatExperience)
                session.units[casterSlot]!.mp = UInt8(completion.remainingMP);session.units[casterSlot]!.scriptFlags |= 0x80;session.commitMove(casterSlot)
                let result = summary(in:session,completed:true,completion:completion,experience:experience)
                continuation = .finished(result);return .finished(result)
            }
        }
    }
    private mutating func retain(_ effect:OriginalStrategyTargetEffect)->OriginalStrategyStep {
        effects.append(effect)
        if let notice = effect.retirement {
            pendingRetirement = OriginalStrategyPendingRetirement(effectIndex:effects.count-1,notice:notice)
        }
        return .target(effect)
    }
    private func summary(in session:OriginalBattleSession,completed:Bool,reason:String? = nil,
                         completion:OriginalStrategyCompletion? = nil,experience:OriginalExperienceMutation? = nil)->OriginalStrategyExecution {
        OriginalStrategyExecution(casterSlot:casterSlot,abilityID:abilityID,completed:completed,rejectionReason:reason,
            targets:effects,completion:completion,completionExperience:experience,rngBefore:rngBefore,rngAfter:session.rng.state)
    }
}

private extension OriginalBattleSession {
    func strategyDamageEffect(casterSlot:Int,targetSlot:Int,subtype:Int) throws -> OriginalStrategyTargetEffect {
        guard let source = units[casterSlot],let target = units[targetSlot],target.status == 2 else {throw BattleError.unsupported("Original strategy context slot changed before its producer")}
        let a = try people.stats(source.person,morale:source.morale),d = try people.stats(target.person,morale:target.morale)
        guard (0..<width).contains(target.position.x),(0..<height).contains(target.position.y) else {throw BattleError.unsupported("Original strategy context coordinate leaves its source map")}
        let value = try OriginalCombat.strategyStrike(OriginalStrategyInput(attacker:a,defender:d,
            terrainID:Int(terrain[target.position.y*width+target.position.x]),subtype:subtype,kind:2,weatherCode:Int(turns.weatherIndex)),tables:combat,rng:&rng)
        let gain = try OriginalCombat.experienceGain(attackerLevel:a.level,defenderLevel:d.level,
            attackerRuntimeSlot:casterSlot,defenderRuntimeSlot:targetSlot,damage:value.damage,defenderTroops:d.troops)
        try people.update(target.person) {$0.rawTroops = value.remainingTroops}
        var morale:OriginalMoraleMutation?
        if value.damage != d.troops {
            morale = try OriginalCombat.setMorale(stats:d,unitStatus:target.status,conditionFlags:Int(target.scriptFlags),requestedMorale:value.remainingMorale,rng:&rng)
            units[targetSlot]!.morale = morale!.remainingMorale;units[targetSlot]!.scriptFlags = UInt8(morale!.remainingFlags)
        }
        let experience = try people.applyExperience(person:source.person,gain:gain.total)
        let retirement = try strategyRetirement(targetSlot)
        return OriginalStrategyTargetEffect(runtimeSlot:targetSlot,person:target.person,kind:"damage",damage:value,morale:morale,
            experience:experience,retiredPerson:retirement.person,retirement:retirement.notice)
    }
    func strategyConditionEffect(casterSlot:Int,targetSlot:Int) throws -> OriginalStrategyTargetEffect {
        guard let source = units[casterSlot],let target = units[targetSlot] else {throw BattleError.unsupported("Original status strategy slot changed before its producer")}
        let a = try people.stats(source.person,morale:source.morale),d = try people.stats(target.person,morale:target.morale)
        let success = try OriginalCombat.strategySuccess(caster:a,target:d,denominatorByte:2,rng:&rng)
        var retirement:(person:Int?,notice:OriginalRetirementNotice?) = (nil,nil)
        if success.success {units[targetSlot]!.scriptFlags |= 2;retirement = try strategyRetirement(targetSlot)}
        return OriginalStrategyTargetEffect(runtimeSlot:targetSlot,person:target.person,kind:"condition2",success:success,
            retiredPerson:retirement.person,retirement:retirement.notice)
    }
    func strategyMoraleEffect(casterSlot:Int,targetSlot:Int,category:Int) throws -> OriginalStrategyTargetEffect {
        guard let source = units[casterSlot],let target = units[targetSlot] else {throw BattleError.unsupported("Original morale strategy slot changed before its producer")}
        let a = try people.stats(source.person,morale:source.morale),d = try people.stats(target.person,morale:target.morale)
        let success = try OriginalCombat.strategySuccess(caster:a,target:d,denominatorByte:4,rng:&rng)
        var morale:OriginalMoraleMutation?,retirement:(person:Int?,notice:OriginalRetirementNotice?) = (nil,nil)
        if success.success {
            let amount = try OriginalCombat.moraleStrategyAmount(casterLevel:a.level,targetLevel:d.level,category:category,targetMorale:d.morale)
            morale = try OriginalCombat.setMorale(stats:d,unitStatus:target.status,conditionFlags:Int(target.scriptFlags),requestedMorale:d.morale-amount,rng:&rng)
            units[targetSlot]!.morale = morale!.remainingMorale;units[targetSlot]!.scriptFlags = UInt8(morale!.remainingFlags)
            retirement = try strategyRetirement(targetSlot)
        }
        return OriginalStrategyTargetEffect(runtimeSlot:targetSlot,person:target.person,kind:"morale",success:success,morale:morale,
            retiredPerson:retirement.person,retirement:retirement.notice)
    }
    func strategyHealingEffect(casterSlot:Int,targetSlot:Int,subtype:Int) throws -> OriginalStrategyTargetEffect {
        guard let source = units[casterSlot],let target = units[targetSlot] else {throw BattleError.unsupported("Original healing strategy slot changed before its producer")}
        let a = try people.stats(source.person,morale:source.morale),d = try people.stats(target.person,morale:target.morale)
        let value = try OriginalCombat.heal(OriginalHealingInput(caster:a,target:d,targetStatus:target.status,
            targetConditionFlags:Int(target.scriptFlags),encodedSubtype:subtype),tables:combat,rng:&rng)
        try people.update(target.person) {$0.rawTroops = value.remainingTroops}
        units[targetSlot]!.morale = value.remainingMorale;units[targetSlot]!.scriptFlags = UInt8(value.remainingFlags)
        return OriginalStrategyTargetEffect(runtimeSlot:targetSlot,person:target.person,kind:"healing",healing:value)
    }
    func strategyRetirement(_ slot:Int) throws -> (person:Int?,notice:OriginalRetirementNotice?) {
        let cursor = retirements.count,person = try retireContextTarget(slot)
        return (person,retirements.dropFirst(cursor).first)
    }
}
