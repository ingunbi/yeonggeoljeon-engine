// SPDX-License-Identifier: GPL-3.0-only
import Foundation

extension BattleProjection {
    struct Effect:Equatable {
        enum Kind:Equatable {case damage,healing,confusion,morale}
        var kind:Kind
        /// Damage/removal are positive; healing may be negative at a source cap.
        var troops:ClosedRange<Int>
        var morale:ClosedRange<Int>
        var successPercent:Double?
        var successPercentRange:ClosedRange<Double>? = nil
        var conditionPercent:ClosedRange<Double>?
        var facts:[Fact] = []
        struct Fact:Equatable {var label:String;var value:String}
    }
    func strategyEffect(_ caster:Int,ability:Int,target:Int) throws -> Effect {
        guard (0..<36).contains(ability),let categories = movement.strategyCategories,categories.count == 36 else {
            throw BattleError.invalid("Strategy projection has no source category")
        }
        let a = try unit(caster),d = try unit(target),category = categories[ability]
        if ability < 15 {
            let terrain = Int(key.terrain[d.live.position.y*key.width+d.live.position.x])
            let input = OriginalStrategyInput(attacker:a.stats,defender:d.stats,terrainID:terrain,
                subtype:(((ability/5)<<4)|category)&255,kind:2,weatherCode:key.weather)
            let kernel = try OriginalCombat.strategyKernel(input,tables:combat)
            let low = OriginalCombat.strategyQuantity(kernel,jitter:0,targetTroops:d.stats.troops)
            let high = OriginalCombat.strategyQuantity(kernel,jitter:max(0,kernel.jitterBound-1),targetTroops:d.stats.troops)
            let chance = try OriginalCombat.rollProbability(bound:kernel.bound) {Int(UInt8(truncatingIfNeeded:$0)) > kernel.threshold}
            return Effect(kind:.damage,troops:min(low,high)...max(low,high),morale:0...0,successPercent:chance,
                facts:[.init(label:"성공 판정",value:"바이트 난수 > \(kernel.threshold)"),.init(label:"난수 범위",value:"0..<\(kernel.bound) · 원본 15비트 분포"),
                    .init(label:"기본 피해",value:"\(kernel.damageBase)"),.init(label:"피해 변동",value:"0~\(max(0,kernel.jitterBound-1))"),
                    .init(label:"책략 내성",value:kernel.resisted ? "원본 병과 내성 적용" : "없음")])
        }
        if ability < 21 {
            let parameters = try OriginalCombat.strategySuccessParameters(caster:a.stats,target:d.stats,denominatorByte:ability < 18 ? 2 : 4)
            let chance = try OriginalCombat.rollProbability(bound:parameters.bound) {$0 > parameters.threshold}
            let morale = ability < 18 ? 0 : try OriginalCombat.moraleStrategyAmount(casterLevel:a.stats.level,targetLevel:d.stats.level,category:category,targetMorale:d.stats.morale)
            return Effect(kind:ability < 18 ? .confusion : .morale,troops:0...0,morale:morale...morale,successPercent:chance,
                facts:[.init(label:"성공 판정",value:"난수 > \(parameters.threshold)"),.init(label:"난수 범위",value:"0..<\(parameters.bound) · 원본 15비트 분포")])
        }
        let subtype = ability >= 30 ? (((ability-30)%3)<<4)|(ability > 32 ? 1 : 2) :
            ((category<<4)|(ability >= 27 ? 3 : ability >= 24 ? 1 : 2))&255
        return try recoveryEffect(caster:a.stats,target:d,subtype:subtype)
    }
    func recoveryEffect(caster:OriginalPersonStats?,target:Unit,subtype:Int) throws -> Effect {
        let input = OriginalHealingInput(caster:caster,target:target.stats,targetStatus:target.live.status,
            targetConditionFlags:Int(target.live.scriptFlags),encodedSubtype:subtype)
        let kernel = try OriginalCombat.healingKernel(input,tables:combat),flags = subtype&15
        let hp = flags&1 == 0 ? [0] : (0..<max(1,kernel.troopBound)).map {kernel.troops(roll:$0)-target.stats.troops}
        let morale = flags&2 == 0 ? [0] : (0..<max(1,kernel.moraleBound)).map {kernel.moraleAmount(roll:$0)}
        var chances:[Double] = []
        if flags&2 != 0,target.live.scriptFlags&2 != 0 {
            for amount in Set(morale).sorted() {
                var changed = target.stats;changed.morale += amount
                let threshold = OriginalCombat.conditionRecoveryThreshold(changed)
                chances.append(try OriginalCombat.rollProbability(bound:100) {$0 < threshold})
            }
        }
        return Effect(kind:.healing,troops:hp.min()!...hp.max()!,morale:morale.min()!...morale.max()!,successPercent:nil,
            conditionPercent:chances.isEmpty ? nil : chances.min()!...chances.max()!,
            facts:[.init(label:"병력 상한",value:"\(kernel.maximum)"),.init(label:"회복 보너스",value:caster == nil ? "도구: 시전자 보너스 없음" : "시전자 레벨·지력 반영")])
    }
}
