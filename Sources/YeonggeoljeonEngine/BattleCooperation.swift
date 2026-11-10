// SPDX-License-Identifier: GPL-3.0-only
import Foundation

extension BattleProjection {
    struct CooperativeStep:Equatable {
        var actor:Int;var origin:GridPoint;var movementCost:Int
        var action:PlannedAction = .attack
        var damage:Int;var remainingTroops:Int;var remainingMorale:Int
        var damageRange:ClosedRange<Int> = 0...0
    }
    struct CooperativeCandidate:Equatable {
        var target:Int;var steps:[CooperativeStep];var condition:String
        var remaining:ClosedRange<Int>;var counterLoss:ClosedRange<Int>
        var branches:Int;var exhaustive:Bool;var boundaries:[String]
        var defeats:Bool {remaining.lowerBound == 0}
        var guaranteed:Bool {exhaustive && remaining.upperBound == 0}
        var damage:Int {steps.reduce(0) {$0+$1.damage}}
    }
    struct CooperativeSearch {var candidates:[CooperativeCandidate];var examined:Int;var limited:Bool;var limitation:String}
    func cooperativeChoices(target:Int,limit:Int = 32) throws -> [PlannedStep] {
        var byAction:[[PlannedStep]] = []
        for actor in key.units where !actor.live.enemy && actor.live.scriptFlags&0x20 != 0 && OriginalBattleCommand.denial(actor.live) == nil {
            var physical:[PlannedStep] = [],strategies:[Int:[PlannedStep]] = [:]
            let abilities = try availableStrategies(actor.live.slot).filter {$0 < 21}
            for origin in try origins(actor.live.slot) {
                let preview = try preview(actor.live.slot,at:origin.point)
                if preview.attackTargets.contains(target) {physical.append(.init(actor:actor.live.slot,origin:origin.point,action:.attack,target:target))}
                for ability in abilities where preview.strategies[ability]?.contains(target) == true {
                    strategies[ability,default:[]].append(.init(actor:actor.live.slot,origin:origin.point,action:.strategy(ability),target:target))
                }
            }
            if !physical.isEmpty {byAction.append(physical)}
            for ability in abilities {if let choices = strategies[ability],!choices.isEmpty {byAction.append(choices)}}
        }
        // Include physical and strategy alternatives before additional origins.
        var choices:[PlannedStep] = [],offset = 0
        while choices.count < limit {
            let batch = byAction.compactMap {$0.indices.contains(offset) ? $0[offset] : nil}
            if batch.isEmpty {break}
            for value in batch.prefix(limit-choices.count) {choices.append(value)}
            offset += 1
        }
        return choices
    }
    func evaluateCooperation(_ plan:[PlannedStep],target:Int,branchLimit:Int = 128) throws -> CooperativeCandidate {
        guard (1...2).contains(plan.count),Set(plan.map(\.actor)).count == plan.count,try unit(target).live.enemy else {
            throw BattleError.illegalAction("협공은 서로 다른 아군의 두 행동까지 비교합니다.")
        }
        var branches = [OutcomeBranch(model:self)],exhaustive = true,steps:[CooperativeStep] = []
        for choice in plan {
            var next:[OutcomeBranch] = [],quantities:[Int] = [],morale:[Int] = [],costs:[Int] = []
            let collector = OutcomeBudget(branches:branchLimit,work:branchLimit*4)
            for branch in branches {
                if branch.boundary != nil {quantities.append(0);morale.append(try branch.model.unit(target).stats.morale);_ = collector.admit(branch,to:&next,countWork:false);continue}
                do {
                    let before = try branch.model.unit(target)
                    let cost = try branch.model.origins(choice.actor).first(where:{$0.point == choice.origin})?.cost ?? 0
                    let result = try branch.model.projectedStep(choice,branchLimit:branchLimit)
                    exhaustive = exhaustive && result.exhaustive;costs.append(cost)
                    for value in result.branches {
                        let after = try value.model.unit(target)
                        quantities.append(before.stats.troops-after.stats.troops);morale.append(after.stats.morale)
                        var combined = value;combined.hits = branch.hits+value.hits
                        if !collector.admit(combined,to:&next,countWork:false) {break}
                    }
                } catch BattleError.illegalAction(let reason) {
                    quantities.append(0);morale.append(try branch.model.unit(target).stats.morale)
                    var stopped = branch;stopped.boundary = "뒤 행동을 실행할 수 없는 분기: "+reason
                    _ = collector.admit(stopped,to:&next,countWork:false)
                }
            }
            exhaustive = exhaustive && collector.exhaustive
            if next.isEmpty {exhaustive = false;break}
            branches = next
            let hp = try branches.map {try $0.model.unit(target).stats.troops}
            let low = quantities.min() ?? 0,high = quantities.max() ?? 0
            steps.append(.init(actor:choice.actor,origin:choice.origin,movementCost:costs.max() ?? 0,action:choice.action,
                damage:low,remainingTroops:hp.max() ?? 0,remainingMorale:morale.max() ?? 0,damageRange:low...high))
        }
        guard !branches.isEmpty else {throw BattleError.illegalAction("현재 상태에서 비교할 수 있는 행동 결과가 없습니다.")}
        let hp = try branches.map {try $0.model.unit(target).stats.troops}
        let losses = try branches.map {branch in try plan.reduce(0) {sum,step in
            sum+max(0,(try unit(step.actor).stats.troops)-(try branch.model.unit(step.actor).stats.troops))
        }}
        let remaining = exhaustive ? hp.min()!...hp.max()! : 0...(try unit(target).stats.troops)
        let boundaries = Array(Set(branches.compactMap(\.boundary))).sorted()
        let condition = !exhaustive ? "계산 한도 · 확정 판정 없음" : remaining.upperBound == 0 ? "모든 계산 분기에서 대상 병력 0 · 퇴각 처리 직전" : remaining.lowerBound == 0 ? "일부 분기에서 대상 병력 0 · 성공·반격 조건에 따라 달라짐" : "계산한 모든 분기에서 대상 병력이 남음"
        return .init(target:target,steps:steps,condition:condition,remaining:remaining,counterLoss:losses.min()!...losses.max()!,
            branches:branches.count,exhaustive:exhaustive,boundaries:boundaries)
    }
    /// Bounded two-action search; commands still require independent confirmation.
    func cooperation(target:Int,limit:Int = 128,timeLimit:TimeInterval = 0.35) throws -> CooperativeSearch {
        guard (1...1024).contains(limit),try unit(target).live.enemy else {return .init(candidates:[],examined:0,limited:false,limitation:"공개된 적을 선택하세요.")}
        let start = ProcessInfo.processInfo.systemUptime
        let choices = try cooperativeChoices(target:target,limit:32)
        var candidates:[CooperativeCandidate] = [],examined = 0,limited = false
        outer: for first in choices {
            if examined >= limit || ProcessInfo.processInfo.systemUptime-start > timeLimit {limited = true;break}
            let single = try evaluateCooperation([first],target:target)
            candidates.append(single);examined += 1
            if single.guaranteed {continue}
            for second in choices where second.actor != first.actor {
                if examined >= limit || ProcessInfo.processInfo.systemUptime-start > timeLimit {limited = true;break outer}
                candidates.append(try evaluateCooperation([first,second],target:target));examined += 1
            }
        }
        candidates.sort {
            if $0.guaranteed != $1.guaranteed {return $0.guaranteed}
            if $0.exhaustive != $1.exhaustive {return $0.exhaustive}
            if $0.remaining.upperBound != $1.remaining.upperBound {return $0.remaining.upperBound < $1.remaining.upperBound}
            if $0.counterLoss.upperBound != $1.counterLoss.upperBound {return $0.counterLoss.upperBound < $1.counterLoss.upperBound}
            if $0.steps.count != $1.steps.count {return $0.steps.count < $1.steps.count}
            return $0.steps.map {$0.actor}.lexicographicallyPrecedes($1.steps.map {$0.actor})
        }
        return .init(candidates:candidates,examined:examined,limited:limited,
            limitation:"서로 다른 아군의 일반 공격·공격/혼란/사기 책략 최대 두 번을 비교합니다. 반격·실패·저사기 혼란을 포함하며 개별 난수 결과를 포괄하는 범위입니다. 조합 확률은 추정하지 않습니다. 퇴각 스크립트 경계 뒤는 진행하지 않습니다. 도구는 이 협공 탐색에 포함하지 않습니다.")
    }
}
