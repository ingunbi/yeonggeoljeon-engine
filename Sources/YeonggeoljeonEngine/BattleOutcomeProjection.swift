// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Finite conservative outcome sets: every individual source draw is covered,
/// but joint probabilities of successive LCG draws are deliberately not invented.
/// No live RNG or mutable session is accepted. Script retirement is a hard boundary.
extension BattleProjection {
    enum PlannedAction:Equatable {case attack,strategy(Int)}
    struct PlannedStep:Equatable {var actor:Int;var origin:GridPoint;var action:PlannedAction;var target:Int?}
    struct OutcomeHit:Equatable {
        var target:Int;var kind:String;var success:Bool;var troops:Int;var morale:Int;var casterLevel:Int
        var successPercent:Double? = nil
    }
    struct OutcomeBranch {
        var model:BattleProjection;var hits:[OutcomeHit] = [];var boundary:String?
    }
    struct OutcomeSet {
        var branches:[OutcomeBranch];var exhaustive:Bool;var work:Int
        var limitation:String? {exhaustive ? nil : "분기 탐색 한도에 도달했습니다. 표시 결과만으로 확정 결과를 보장하지 않습니다."}
    }
    final class OutcomeBudget {
        let branchLimit:Int;let workLimit:Int
        var work = 0;var exhaustive = true
        init(branches:Int,work:Int) {branchLimit = max(1,branches);workLimit = max(1,work)}
        func admit(_ branch:OutcomeBranch,to values:inout [OutcomeBranch],countWork:Bool = true)->Bool {
            if countWork {work += 1;if work > workLimit {exhaustive = false;return false}}
            if values.contains(where:{$0.model.key == branch.model.key && $0.boundary == branch.boundary && $0.hits == branch.hits}) {return true}
            if values.count >= branchLimit {exhaustive = false;return false}
            values.append(branch);return true
        }
    }
    static func drawValues(_ bound:Int)->Range<Int> {0..<max(1,min(32768,bound))}
    mutating func projectedHP(_ slot:Int,_ hp:Int) throws {
        let person = try unit(slot).live.person
        for index in key.units.indices where key.units[index].live.person == person {key.units[index].stats.troops = hp}
    }
    mutating func projectedExperience(_ slot:Int,_ gain:Int) throws {
        let value = try unit(slot)
        let result = try OriginalCombat.applyExperience(sourcePersonWord:value.live.person|0x200,level:value.stats.level,experience:value.experience,gain:gain)
        for index in key.units.indices where key.units[index].live.person == value.live.person {
            key.units[index].stats.level = result.level;key.units[index].experience = result.experience
        }
    }
    mutating func projectedMorale(_ slot:Int,_ result:OriginalMoraleMutation) {
        guard let index = key.units.firstIndex(where:{$0.live.slot == slot}) else {return}
        key.units[index].stats.morale = result.remainingMorale;key.units[index].live.morale = result.remainingMorale
        key.units[index].live.scriptFlags = UInt8(result.remainingFlags)
    }
    static func moraleOutcomes(_ unit:Unit,requested:Int) throws -> [OriginalMoraleMutation] {
        let kernel = try OriginalCombat.moraleKernel(stats:unit.stats,unitStatus:unit.live.status,conditionFlags:Int(unit.live.scriptFlags),requestedMorale:requested)
        let loss:[Int?] = kernel.lossRequired ? [0,4] : [nil],recovery:[Int?] = kernel.recoveryRollRequired ? [0,99] : [nil]
        var values:[OriginalMoraleMutation] = []
        for l in loss {for r in recovery {
            let value = kernel.result(lossRoll:l,recoveryRoll:r)
            if !values.contains(where:{$0.remainingMorale == value.remainingMorale && $0.remainingFlags == value.remainingFlags}) {values.append(value)}
        }}
        return values
    }
    static func stopAtRetirement(_ slot:Int,_ branch:inout OutcomeBranch) throws {
        let target = try branch.model.unit(slot)
        if try OriginalCombat.shouldRetire(troops:target.stats.troops,morale:target.stats.morale,conditionFlags:Int(target.live.scriptFlags)) {
            branch.boundary = "\(target.name) 퇴각 처리 이후의 캠페인 이벤트는 예측하지 않습니다."
        }
    }
    func projectedStep(_ step:PlannedStep,branchLimit:Int = 128,workLimit:Int = 8192) throws -> OutcomeSet {
        let budget = OutcomeBudget(branches:branchLimit,work:workLimit)
        var initial = self
        let actor = try unit(step.actor)
        guard actor.live.scriptFlags&0x20 != 0,OriginalBattleCommand.denial(actor.live) == nil,
              try origins(step.actor).contains(where:{$0.point == step.origin}) else {
            throw BattleError.illegalAction("현재 분기에서 행동자나 이동 위치를 사용할 수 없습니다.")
        }
        let index = initial.key.units.firstIndex(where:{$0.live.slot == step.actor})!
        if step.origin != actor.live.position {initial.key.units[index].live.scriptFlags |= 0x40}
        initial.key.units[index].live.position = step.origin
        var start = OutcomeBranch(model:initial)
        let branches:[OutcomeBranch]
        switch step.action {
        case .attack:
            guard let target = step.target,try initial.preview(step.actor,at:step.origin).attackTargets.contains(target) else {throw BattleError.illegalAction("현재 분기에서 공격 대상이 사거리 밖입니다.")}
            let defender = try initial.unit(target)
            if defender.live.position.x > step.origin.x {start.model.key.units[index].live.scriptFlags &= ~UInt8(0x10)}
            else if defender.live.position.x < step.origin.x {start.model.key.units[index].live.scriptFlags |= 0x10}
            branches = try Self.physicalOutcomes(start,attacker:step.actor,target:target,budget:budget)
        case .strategy(let ability):
            guard try initial.availableStrategies(step.actor).contains(ability) else {throw BattleError.illegalAction("현재 분기에서 책략을 사용할 수 없습니다.")}
            let preview = try initial.preview(step.actor,at:step.origin),eligible = preview.strategies[ability] ?? []
            var targets:[Int]
            if ability >= 30 {targets = eligible}
            else {
                guard let target = step.target,eligible.contains(target) else {throw BattleError.illegalAction("현재 분기에서 책략 대상이 유효하지 않습니다.")}
                targets = [target]
                if Self.isAreaStrategy(ability) {
                    let center = try initial.unit(target).live.position
                    for offset in movement.cardinalOffsets {
                        let point = GridPoint(x:center.x+offset.dx,y:center.y+offset.dy)
                        guard let other = initial.key.units.first(where:{$0.live.position == point && $0.live.enemy != actor.live.enemy}) else {continue}
                        if ability < 15,try !movement.strategyTerrainEligible(family:ability/5,terrain:key.terrain[point.y*key.width+point.x]) {continue}
                        if !targets.contains(other.live.slot) {targets.append(other.live.slot)}
                    }
                }
            }
            guard !targets.isEmpty else {throw BattleError.illegalAction("책략을 적용할 공개 대상이 없습니다.")}
            var active = [start]
            for (targetIndex,target) in targets.enumerated() {
                var next:[OutcomeBranch] = []
                for branch in active {
                    if branch.boundary != nil {_ = budget.admit(branch,to:&next,countWork:false);continue}
                    for result in try Self.strategyTargetOutcomes(branch,caster:step.actor,ability:ability,target:target,budget:budget) {
                        if !budget.admit(result,to:&next,countWork:false) {break}
                    }
                    if budget.work > budget.workLimit {break}
                }
                active = next
                if active.isEmpty || budget.work > budget.workLimit {
                    if targetIndex+1 < targets.count {for index in active.indices where active[index].boundary == nil {active[index].boundary = "분기 한도로 뒤 대상 효과는 미확정입니다."}}
                    break
                }
            }
            branches = try active.map { branch in
                guard branch.boundary == nil else {return branch}
                var value = branch;let caster = try value.model.unit(step.actor)
                let completion = try OriginalCombat.completeStrategy(abilityID:ability,casterClassID:caster.stats.classID,currentMP:Int(caster.live.mp),mpCost:movement.strategyMPCosts![ability])
                try value.model.projectedExperience(step.actor,completion.flatExperience)
                let index = value.model.key.units.firstIndex(where:{$0.live.slot == step.actor})!
                value.model.key.units[index].live.mp = UInt8(completion.remainingMP)
                return value
            }
        }
        return .init(branches:branches.map {branch in
            var value = branch
            if value.boundary == nil,let index = value.model.key.units.firstIndex(where:{$0.live.slot == step.actor}) {value.model.key.units[index].live.scriptFlags |= 0x80}
            return value
        },exhaustive:budget.exhaustive,work:budget.work)
    }
    private static func physicalHit(_ branch:OutcomeBranch,attacker:Int,target:Int,subtype:Int,budget:OutcomeBudget) throws -> [(OutcomeBranch,OriginalPhysicalInput,OriginalPhysicalResult)] {
        let model = branch.model,a = try model.unit(attacker),d = try model.unit(target)
        let input = OriginalPhysicalInput(attacker:a.stats,defender:d.stats,terrainID:Int(model.key.terrain[d.live.position.y*model.key.width+d.live.position.x]),subtype:subtype,defenderCounterDisabled:d.live.scriptFlags&2 != 0)
        let hit = try OriginalCombat.physicalImpact(input,tables:model.combat)
        let gain = try OriginalCombat.experienceGain(attackerLevel:a.stats.level,defenderLevel:d.stats.level,attackerRuntimeSlot:attacker,defenderRuntimeSlot:target,damage:hit.damage,defenderTroops:d.stats.troops)
        var base = branch;try base.model.projectedHP(target,hit.remainingTroops)
        try base.model.projectedExperience(attacker,gain.total)
        base.hits.append(.init(target:target,kind:subtype == 7 ? "반격" : "공격",success:true,troops:hit.damage,morale:hit.moraleLoss,casterLevel:a.stats.level))
        if hit.damage == d.stats.troops {return [(base,input,hit)]}
        return try moraleOutcomes(d,requested:hit.remainingMorale).map {result in
            var value = base;value.model.projectedMorale(target,result);return (value,input,hit)
        }
    }
    private static func physicalOutcomes(_ branch:OutcomeBranch,attacker:Int,target:Int,budget:OutcomeBudget) throws -> [OutcomeBranch] {
        let a = try branch.model.unit(attacker)
        let subtype = try OriginalCombat.normalPhysicalSubtype(classID:a.stats.classID,tables:branch.model.combat)
        var result:[OutcomeBranch] = []
        for (primary,input,hit) in try physicalHit(branch,attacker:attacker,target:target,subtype:subtype,budget:budget) {
            let targetNow = try primary.model.unit(target)
            let counterChoices = Set([0,149].map {OriginalCombat.physicalCounterEligible(input,damage:hit.damage,roll:$0,tables:branch.model.combat) && targetNow.live.scriptFlags&2 == 0 && targetNow.stats.troops != 0})
            for counter in counterChoices.sorted(by:{$0 == false && $1 == true}) {
                if counter {
                    for (value,_,_) in try physicalHit(primary,attacker:target,target:attacker,subtype:7,budget:budget) {
                        var next = value;try stopAtRetirement(attacker,&next)
                        if !budget.admit(next,to:&result) {break}
                    }
                } else {
                    var next = primary;try stopAtRetirement(target,&next)
                    if !budget.admit(next,to:&result) {break}
                }
            }
        }
        return result
    }
    private static func strategyTargetOutcomes(_ branch:OutcomeBranch,caster:Int,ability:Int,target:Int,budget:OutcomeBudget) throws -> [OutcomeBranch] {
        let model = branch.model,a = try model.unit(caster),d = try model.unit(target),category = model.movement.strategyCategories![ability]
        var result:[OutcomeBranch] = []
        if ability < 15 {
            let input = OriginalStrategyInput(attacker:a.stats,defender:d.stats,terrainID:Int(model.key.terrain[d.live.position.y*model.key.width+d.live.position.x]),subtype:((ability/5)<<4)|category,kind:2,weatherCode:model.key.weather)
            let kernel = try OriginalCombat.strategyKernel(input,tables:model.combat)
            let chance = try OriginalCombat.rollProbability(bound:kernel.bound) {OriginalCombat.strategyResult(input,kernel:kernel,successRoll:$0,jitter:0).success}
            let rolls = [false,true].compactMap { desired in drawValues(kernel.bound).first {OriginalCombat.strategyResult(input,kernel:kernel,successRoll:$0,jitter:0).success == desired} }
            for roll in rolls {
                let succeeds = OriginalCombat.strategyResult(input,kernel:kernel,successRoll:roll,jitter:0).success
                for jitter in succeeds ? drawValues(kernel.jitterBound) : 0..<1 {
                    let hit = OriginalCombat.strategyResult(input,kernel:kernel,successRoll:roll,jitter:jitter)
                    let gain = try OriginalCombat.experienceGain(attackerLevel:a.stats.level,defenderLevel:d.stats.level,attackerRuntimeSlot:caster,defenderRuntimeSlot:target,damage:hit.damage,defenderTroops:d.stats.troops)
                    var base = branch;try base.model.projectedHP(target,hit.remainingTroops);try base.model.projectedExperience(caster,gain.total)
                    base.hits.append(.init(target:target,kind:"피해 책략",success:hit.success,troops:hit.damage,morale:hit.moraleLoss,casterLevel:a.stats.level,successPercent:chance))
                    let variants = hit.damage == d.stats.troops ? [base] : try moraleOutcomes(d,requested:hit.remainingMorale).map {mutation -> OutcomeBranch in
                        var next = base;next.model.projectedMorale(target,mutation);return next
                    }
                    for var next in variants {try stopAtRetirement(target,&next);if !budget.admit(next,to:&result) {break}}
                    if budget.work > budget.workLimit {break}
                }
            }
        } else if ability < 21 {
            let parameters = try OriginalCombat.strategySuccessParameters(caster:a.stats,target:d.stats,denominatorByte:ability < 18 ? 2 : 4)
            let chance = try OriginalCombat.rollProbability(bound:parameters.bound) {$0 > parameters.threshold}
            let successes = Set(drawValues(parameters.bound).map {$0 > parameters.threshold})
            for success in successes.sorted(by:{$0 == false && $1 == true}) {
                var base = branch
                let amount = success && ability >= 18 ? try OriginalCombat.moraleStrategyAmount(casterLevel:a.stats.level,targetLevel:d.stats.level,category:category,targetMorale:d.stats.morale) : 0
                base.hits.append(.init(target:target,kind:ability < 18 ? "혼란" : "사기 책략",success:success,troops:0,morale:amount,casterLevel:a.stats.level,successPercent:chance))
                var variants = [base]
                if success,ability < 18 {let index = base.model.key.units.firstIndex(where:{$0.live.slot == target})!;base.model.key.units[index].live.scriptFlags |= 2;variants = [base]}
                if success,ability >= 18 {variants = try moraleOutcomes(d,requested:d.stats.morale-amount).map {mutation in var next = base;next.model.projectedMorale(target,mutation);return next}}
                for var next in variants {if success {try stopAtRetirement(target,&next)};if !budget.admit(next,to:&result) {break}}
            }
        } else {
            let subtype = ability >= 30 ? (((ability-30)%3)<<4)|(ability > 32 ? 1 : 2) : ((category<<4)|(ability >= 27 ? 3 : ability >= 24 ? 1 : 2))&255
            let input = OriginalHealingInput(caster:a.stats,target:d.stats,targetStatus:d.live.status,targetConditionFlags:Int(d.live.scriptFlags),encodedSubtype:subtype)
            let kernel = try OriginalCombat.healingKernel(input,tables:model.combat),flags = subtype&15
            let hpValues = flags&1 == 0 ? [d.stats.troops] : Array(Set(drawValues(kernel.troopBound).map {kernel.troops(roll:$0)})).sorted()
            let moraleValues = flags&2 == 0 ? [0] : Array(Set(drawValues(kernel.moraleBound).map {kernel.moraleAmount(roll:$0)})).sorted()
            for hp in hpValues {for amount in moraleValues {
                var base = branch;try base.model.projectedHP(target,hp)
                base.hits.append(.init(target:target,kind:"회복",success:true,troops:d.stats.troops-hp,morale:0-amount,casterLevel:a.stats.level))
                let variants = flags&2 == 0 ? [base] : try moraleOutcomes(d,requested:d.stats.morale+amount).map {mutation in var next = base;next.model.projectedMorale(target,mutation);return next}
                for next in variants {if !budget.admit(next,to:&result) {break}}
                if budget.work > budget.workLimit {break}
            }}
        }
        return result
    }
}
