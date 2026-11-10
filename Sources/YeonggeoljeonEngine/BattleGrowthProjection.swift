// SPDX-License-Identifier: GPL-3.0-only
import Foundation

extension BattleProjection {
    struct GrowthBranch:Equatable {
        var condition:String
        var hit:Int;var defeated:Int;var completion:Int
        var level:Int;var experience:Int;var ignoredReason:String?
        var nextStrategies:[StrategyLearningGuide.Entry]
        var total:Int {hit+defeated+completion}
    }
    struct GrowthForecast:Equatable {var branches:[GrowthBranch];var limitation:String?}
    /// Single-target damage branches and the command's definite completion
    /// grant. Splash effects after retirement/level changes are not summed.
    func growth(_ slot:Int,target:Int?,ability:Int?,names:[String]) throws -> GrowthForecast {
        let attacker = try unit(slot)
        guard attacker.live.scriptFlags&0x82 == 0 else {return .init(branches:[],limitation:"행동 완료 또는 혼란 상태에서는 행동 보상을 예상하지 않습니다.")}
        var results:[GrowthBranch] = []
        func branch(_ label:String,damage:Int?,completion:Int) throws {
            let gain:OriginalExperienceGain
            if let damage,let target {
                let defender = try unit(target)
                gain = try OriginalCombat.experienceGain(attackerLevel:attacker.stats.level,defenderLevel:defender.stats.level,
                    attackerRuntimeSlot:slot,defenderRuntimeSlot:target,damage:damage,defenderTroops:defender.stats.troops)
            } else {gain = .init(hit:0,defeatedTarget:0)}
            let changed = try OriginalCombat.applyExperience(sourcePersonWord:attacker.live.person|0x200,
                level:attacker.stats.level,experience:attacker.experience,gain:gain.total+completion)
            var next:[StrategyLearningGuide.Entry] = []
            if changed.level < 99,let levels = movement.strategyLevelRequirements,let costs = movement.strategyMPCosts {
                let entries = try StrategyLearningGuide.entries(classID:attacker.stats.classID,level:changed.level,levels:levels,costs:costs,names:names).filter {!$0.learned}
                if let level = entries.first?.requiredLevel {next = entries.filter {$0.requiredLevel == level}}
            }
            results.append(.init(condition:label,hit:gain.hit,defeated:gain.defeatedTarget,completion:completion,
                level:changed.level,experience:changed.experience,ignoredReason:changed.ignoredReason,nextStrategies:next))
        }
        guard let ability else {
            guard let target else {return .init(branches:[],limitation:"공격 대상을 선택하세요.")}
            guard try preview(slot,at:attacker.live.position).attackTargets.contains(target) else {
                return .init(branches:[],limitation:"현재 위치에서 공격 가능한 적을 선택해야 보상을 계산할 수 있습니다.")
            }
            let impact = try physical(slot,target:target)
            try branch(impact.remainingTroops == 0 ? "이 일반 공격으로 격파" : "이 일반 공격 명중",damage:impact.damage,completion:0)
            return .init(branches:results,limitation:"선택한 일반 공격의 보상입니다. 반격·퇴각 이벤트·전투 종료 보너스는 포함하지 않습니다.")
        }
        guard try availableStrategies(slot).contains(ability) else {return .init(branches:[],limitation:"현재 습득·MP·날씨 조건에서는 사용할 수 없습니다. 실행 거부 시 완료 보상이 없습니다.")}
        let candidates = try preview(slot,at:attacker.live.position).strategies[ability] ?? []
        guard ability >= 30 ? !candidates.isEmpty : target.map(candidates.contains) == true else {
            return .init(branches:[],limitation:"현재 위치의 사거리·대상·회복 조건을 통과하지 않아 완료 보상을 계산하지 않습니다.")
        }
        let completion = try OriginalCombat.completeStrategy(abilityID:ability,casterClassID:attacker.stats.classID,
            currentMP:Int(attacker.live.mp),mpCost:movement.strategyMPCosts![ability]).flatExperience
        if ability < 15 {
            guard let target else {return .init(branches:[],limitation:"책략의 주 대상을 선택하세요.")}
            let effect = try strategyEffect(slot,ability:ability,target:target),defender = try unit(target)
            if effect.successPercent ?? 0 < 100 {try branch("책략 실패 · 피해 없음",damage:0,completion:completion)}
            if effect.successPercent ?? 0 > 0 {
                if effect.troops.lowerBound < defender.stats.troops {try branch("성공 · 주 대상 생존",damage:effect.troops.lowerBound,completion:completion)}
                if effect.troops.upperBound == defender.stats.troops {try branch("성공 · 주 대상 격파",damage:defender.stats.troops,completion:completion)}
            }
            return .init(branches:results,limitation:ability%5 >= 3 ? "주 대상 보상만 계산합니다. 주변 대상 처리 중 레벨 상승·퇴각 이벤트가 바꾸는 총보상은 합산하지 않습니다." : "현재 주 대상 기준입니다. 후속 이벤트·전투 종료 보너스는 포함하지 않습니다.")
        }
        try branch(ability < 21 ? "성공·실패와 관계없이 책략 시도 완료" : "회복 책략 실행 완료",damage:nil,completion:completion)
        return .init(branches:results,limitation:"실제 대상 조건을 통과해 실행이 완료되어야 받는 보상입니다. 대상 없음·회복 불필요·취소에는 완료 보상이 없습니다.")
    }
}
