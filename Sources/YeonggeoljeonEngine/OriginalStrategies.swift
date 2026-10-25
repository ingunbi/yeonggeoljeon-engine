// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct OriginalStrategyTargetEffect: Codable {
    var runtimeSlot: Int
    var person: Int
    var kind: String
    var damage: OriginalStrategyResult?
    var healing: OriginalHealingResult?
    var success: OriginalStrategySuccess?
    var morale: OriginalMoraleMutation?
    var experience: OriginalExperienceMutation?
    var retiredPerson: Int?
}

struct OriginalStrategyExecution: Codable {
    var casterSlot: Int
    var abilityID: Int
    var completed: Bool
    var rejectionReason: String?
    var targets: [OriginalStrategyTargetEffect]
    var completion: OriginalStrategyCompletion?
    var completionExperience: OriginalExperienceMutation?
    var rngBefore: UInt32
    var rngAfter: UInt32
}

extension OriginalBattleSession {
    /// MAIN2E836..2EE1C. The caller's chosen target replaces source UI input;
    /// area confirmation is explicit. Profile-owned availability/range facts
    /// are consumed once. A retirement callback can execute campaign hooks
    /// before the next splash target, preserving source interleaving.
    func castStrategy(_ slot:Int,abilityID:Int,target:Int? = nil,confirmed:Bool = true,
                      afterRetirement:((Int)throws->Void)? = nil) throws -> OriginalStrategyExecution {
        let caster = try live(slot)
        guard (0..<36).contains(abilityID),caster.scriptFlags&0x82 == 0 else {
            throw BattleError.illegalAction("Original strategy actor/ability is not eligible")
        }
        let initial = try people.stats(caster.person,morale:caster.morale)
        guard try movement.availableStrategies(classID:initial.classID,level:initial.level,mp:caster.mp).contains(abilityID),
              let categories = movement.strategyCategories,let costs = movement.strategyMPCosts,
              categories.count == 36,costs.count == 36 else {
            throw BattleError.illegalAction("Original strategy level/MP availability rejects this ability")
        }
        let category = categories[abilityID],cost = costs[abilityID],before = rng.state
        var effects:[OriginalStrategyTargetEffect] = []
        func stopped(_ reason:String) -> OriginalStrategyExecution {
            OriginalStrategyExecution(casterSlot:slot,abilityID:abilityID,completed:false,rejectionReason:reason,
                targets:effects,completion:nil,completionExperience:nil,rngBefore:before,rngAfter:rng.state)
        }
        if abilityID < 15 && abilityID/5 == 0 && combat.strategyEnvironmentLookup[Int(turns.weatherIndex)] == 2 {
            return stopped("source weather rejection")
        }
        let sourceBoard = try board()
        guard let actor = sourceBoard.actors.first(where:{$0.runtimeSlot == slot}) else {
            throw BattleError.invalid("Original strategy caster is missing from its source board")
        }
        let candidates = try OriginalAI.strategyTargetSlots(profile:movement,board:sourceBoard,actor:actor,abilityID:abilityID)
        let selected:Int?
        if abilityID < 30 {
            guard let target else { return stopped("source target selection cancelled") }
            guard candidates.contains(target) else { throw BattleError.illegalAction("Original strategy target is outside its source range/faction") }
            selected = target
        } else {
            if candidates.isEmpty { return stopped("source area target list is empty") }
            if !confirmed { return stopped("source area confirmation declined") }
            selected = nil
        }
        func retire(_ targetSlot:Int) throws -> Int? {
            let retired = try retireContextTarget(targetSlot)
            if retired != nil { try afterRetirement?(targetSlot) }
            return retired
        }
        func damage(_ targetSlot:Int,subtype:Int) throws {
            guard let source = units[slot],let targetUnit = units[targetSlot],targetUnit.status == 2 else {
                throw BattleError.unsupported("Original strategy context slot changed before its producer")
            }
            let a = try people.stats(source.person,morale:source.morale)
            let d = try people.stats(targetUnit.person,morale:targetUnit.morale)
            let value = try OriginalCombat.strategyStrike(OriginalStrategyInput(attacker:a,defender:d,
                terrainID:Int(terrain[targetUnit.position.y*width+targetUnit.position.x]),subtype:subtype,kind:2,
                weatherCode:Int(turns.weatherIndex)),tables:combat,rng:&rng)
            let gain = try OriginalCombat.experienceGain(attackerLevel:a.level,defenderLevel:d.level,
                attackerRuntimeSlot:slot,defenderRuntimeSlot:targetSlot,damage:value.damage,defenderTroops:d.troops)
            try people.update(targetUnit.person) {$0.rawTroops = value.remainingTroops}
            var mutation:OriginalMoraleMutation?
            if value.damage != d.troops {
                mutation = try OriginalCombat.setMorale(stats:d,unitStatus:targetUnit.status,
                    conditionFlags:Int(targetUnit.scriptFlags),requestedMorale:value.remainingMorale,rng:&rng)
                units[targetSlot]!.morale = mutation!.remainingMorale
                units[targetSlot]!.scriptFlags = UInt8(mutation!.remainingFlags)
            }
            let experience = try people.applyExperience(person:source.person,gain:gain.total)
            let retired = try retire(targetSlot)
            effects.append(OriginalStrategyTargetEffect(runtimeSlot:targetSlot,person:targetUnit.person,kind:"damage",
                damage:value,morale:mutation,experience:experience,retiredPerson:retired))
        }
        func condition(_ targetSlot:Int) throws {
            guard let source = units[slot],let targetUnit = units[targetSlot] else {
                throw BattleError.unsupported("Original status strategy slot changed before its producer")
            }
            let a = try people.stats(source.person,morale:source.morale),d = try people.stats(targetUnit.person,morale:targetUnit.morale)
            let success = try OriginalCombat.strategySuccess(caster:a,target:d,denominatorByte:2,rng:&rng)
            var retired:Int?
            if success.success { units[targetSlot]!.scriptFlags |= 2;retired = try retire(targetSlot) }
            effects.append(OriginalStrategyTargetEffect(runtimeSlot:targetSlot,person:targetUnit.person,kind:"condition2",
                success:success,retiredPerson:retired))
        }
        func heal(_ targetSlot:Int,subtype:Int) throws {
            guard let source = units[slot],let targetUnit = units[targetSlot] else {
                throw BattleError.unsupported("Original healing strategy slot changed before its producer")
            }
            let a = try people.stats(source.person,morale:source.morale),d = try people.stats(targetUnit.person,morale:targetUnit.morale)
            let value = try OriginalCombat.heal(OriginalHealingInput(caster:a,target:d,targetStatus:targetUnit.status,
                targetConditionFlags:Int(targetUnit.scriptFlags),encodedSubtype:subtype),tables:combat,rng:&rng)
            try people.update(targetUnit.person) {$0.rawTroops = value.remainingTroops}
            units[targetSlot]!.morale = value.remainingMorale;units[targetSlot]!.scriptFlags = UInt8(value.remainingFlags)
            effects.append(OriginalStrategyTargetEffect(runtimeSlot:targetSlot,person:targetUnit.person,kind:"healing",healing:value))
        }
        if abilityID < 15,let chosen = selected {
            let family = abilityID/5
            let position = units[chosen]!.position
            guard try movement.strategyTerrainEligible(family:family,terrain:terrain[position.y*width+position.x]) else {
                return stopped("source target terrain rejection")
            }
            let subtype = ((family<<4)|category)&255
            try damage(chosen,subtype:subtype)
            if abilityID%5 >= 3 {
                // Source copies the primary target position after its context.
                guard let center = units[chosen]?.position else { throw BattleError.unsupported("Original splash center was removed by a campaign hook") }
                for offset in movement.cardinalOffsets {
                    let point = GridPoint(x:center.x+offset.dx,y:center.y+offset.dy)
                    let current = try board()
                    guard current.contains(point),try movement.strategyTerrainEligible(family:family,terrain:current.terrain[current.index(point)]),
                          let other = current.occupant(point),other.sourceFaction != actor.sourceFaction else { continue }
                    try damage(other.runtimeSlot,subtype:subtype)
                }
            }
        } else if abilityID <= 17,let chosen = selected {
            // The status branch copies this position before its first effect.
            let center = units[chosen]!.position
            try condition(chosen)
            if abilityID == 17 {
                for offset in movement.cardinalOffsets {
                    let point = GridPoint(x:center.x+offset.dx,y:center.y+offset.dy),current = try board()
                    guard current.contains(point),let other = current.occupant(point),other.sourceFaction != actor.sourceFaction else { continue }
                    try condition(other.runtimeSlot)
                }
            }
        } else if abilityID <= 20,let chosen = selected {
            let source = units[slot]!,targetUnit = units[chosen]!
            let a = try people.stats(source.person,morale:source.morale),d = try people.stats(targetUnit.person,morale:targetUnit.morale)
            let success = try OriginalCombat.strategySuccess(caster:a,target:d,denominatorByte:4,rng:&rng)
            var mutation:OriginalMoraleMutation?,retired:Int?
            if success.success {
                let amount = try OriginalCombat.moraleStrategyAmount(casterLevel:a.level,targetLevel:d.level,category:category,targetMorale:d.morale)
                mutation = try OriginalCombat.setMorale(stats:d,unitStatus:targetUnit.status,
                    conditionFlags:Int(targetUnit.scriptFlags),requestedMorale:d.morale-amount,rng:&rng)
                units[chosen]!.morale = mutation!.remainingMorale;units[chosen]!.scriptFlags = UInt8(mutation!.remainingFlags)
                retired = try retire(chosen)
            }
            effects.append(OriginalStrategyTargetEffect(runtimeSlot:chosen,person:targetUnit.person,kind:"morale",
                success:success,morale:mutation,retiredPerson:retired))
        } else if abilityID <= 29,let chosen = selected {
            let flags = abilityID >= 27 ? 3 : abilityID >= 24 ? 1 : 2,targetUnit = units[chosen]!
            let d = try people.stats(targetUnit.person,morale:targetUnit.morale)
            guard try OriginalCombat.healingUseful(target:d,conditionFlags:Int(targetUnit.scriptFlags),recoveryFlags:flags,tables:combat) else {
                return stopped("source healing target is already restored")
            }
            try heal(chosen,subtype:((category<<4)|flags)&255)
        } else {
            let subtype = (((abilityID-30)%3)<<4)|(abilityID > 32 ? 1 : 2)
            // BAF6 snapshots the source target list, then visits each slot in
            // that retained order; it does not re-enumerate after every heal.
            for candidate in candidates { try heal(candidate,subtype:subtype) }
        }
        guard let current = units[slot] else { throw BattleError.unsupported("Original caster slot was removed before command completion") }
        let casterClass = try people.person(current.person).classID
        let completion = try OriginalCombat.completeStrategy(abilityID:abilityID,casterClassID:casterClass,currentMP:Int(current.mp),mpCost:cost)
        let experience = completion.flatExperience == 0 ? nil : try people.applyExperience(person:current.person,gain:completion.flatExperience)
        units[slot]!.mp = UInt8(completion.remainingMP);units[slot]!.scriptFlags |= 0x80;commitMove(slot)
        return OriginalStrategyExecution(casterSlot:slot,abilityID:abilityID,completed:true,rejectionReason:nil,
            targets:effects,completion:completion,completionExperience:experience,rngBefore:before,rngAfter:rng.state)
    }
}
