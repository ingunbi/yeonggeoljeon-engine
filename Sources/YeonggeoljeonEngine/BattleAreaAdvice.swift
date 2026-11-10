// SPDX-License-Identifier: GPL-3.0-only
import Foundation

extension BattleProjection {
    struct AreaAssessment:Equatable {
        var effects:[Effect];var usefulTargets:Int;var troops:ClosedRange<Int>;var morale:ClosedRange<Int>
        var exhaustive:Bool;var branches:Int;var limitation:String?
    }
    struct AreaCandidate:Equatable {
        var caster:Int;var ability:Int;var origin:GridPoint;var movementCost:Int;var center:Int?
        var targets:[Int];var assessment:AreaAssessment
        var effects:[Effect] {assessment.effects}
        var usefulTargets:Int {assessment.usefulTargets}
        var limitation:String? {assessment.limitation}
        var troops:ClosedRange<Int> {assessment.troops}
        var morale:ClosedRange<Int> {assessment.morale}
    }
    struct AreaSearch {var candidates:[AreaCandidate];var examined:Int;var limited:Bool}
    static func isAreaStrategy(_ ability:Int)->Bool {(0..<15).contains(ability) && ability%5 >= 3 || ability == 17 || (30..<36).contains(ability)}
    func areaAssessment(_ slot:Int,ability:Int,origin:GridPoint,center:Int?,targets:[Int]) throws -> AreaAssessment {
        let outcome = try projectedStep(.init(actor:slot,origin:origin,action:.strategy(ability),target:center),branchLimit:128)
        var effects:[Effect] = [],useful = 0
        for target in targets {
            let hits = outcome.branches.flatMap(\.hits).filter {$0.target == target}
            var effect = try strategyEffect(slot,ability:ability,target:target)
            let successful = hits.filter(\.success)
            let hp = successful.map {ability >= 30 ? -$0.troops : $0.troops},morale = successful.map {ability >= 30 ? -$0.morale : $0.morale}
            if let low = hp.min(),let high = hp.max() {effect.troops = low...high}
            if let low = morale.min(),let high = morale.max() {effect.morale = low...high}
            let chances = hits.compactMap(\.successPercent)
            if let low = chances.min(),let high = chances.max() {effect.successPercentRange = low...high}
            let levels = hits.map(\.casterLevel)
            effect.facts.append(.init(label:"순차 시전자 레벨",value:levels.isEmpty ? "이벤트 경계 뒤 미확정" : "\(levels.min()!)~\(levels.max()!)"))
            if hits.isEmpty {effect.facts.append(.init(label:"효과 범위",value:"아래 수치는 처음 상태의 참고값입니다. 앞 대상의 퇴각 경계 이후는 미확정입니다."))}
            if ability < 30 ? successful.contains(where:{$0.troops > 0 || $0.morale > 0 || $0.kind == "혼란"}) : successful.contains(where:{$0.troops < 0 || $0.morale < 0}) {useful += 1}
            effects.append(effect)
        }
        let totalHP = outcome.branches.map {$0.hits.reduce(0) {$0+(ability >= 30 ? -$1.troops : $1.troops)}}
        let totalMorale = outcome.branches.map {$0.hits.reduce(0) {$0+(ability >= 30 ? -$1.morale : $1.morale)}}
        let boundaries = Array(Set(outcome.branches.compactMap(\.boundary))).sorted()
        let limitations = [outcome.limitation]+boundaries.map(Optional.some)
        return .init(effects:effects,usefulTargets:useful,troops:(totalHP.min() ?? 0)...(totalHP.max() ?? 0),morale:(totalMorale.min() ?? 0)...(totalMorale.max() ?? 0),
            exhaustive:outcome.exhaustive,branches:outcome.branches.count,limitation:limitations.compactMap {$0}.isEmpty ? nil : limitations.compactMap {$0}.joined(separator:"\n"))
    }
    func areaAdvice(_ slot:Int,ability:Int,limit:Int = 256) throws -> AreaSearch {
        let caster = try unit(slot)
        guard !caster.live.enemy,caster.live.scriptFlags&0x20 != 0,OriginalBattleCommand.denial(caster.live) == nil,
              Self.isAreaStrategy(ability),(1...1024).contains(limit),try availableStrategies(slot).contains(ability) else {return .init(candidates:[],examined:0,limited:false)}
        var candidates:[AreaCandidate] = [],examined = 0,limited = false,cache:[[Int]:AreaAssessment] = [:]
        outer: for origin in try origins(slot) {
            let preview = try preview(slot,at:origin.point)
            let centers:[Int?] = ability >= 30 ? [nil] : (preview.strategies[ability] ?? []).map(Optional.some)
            for center in centers {
                if examined == limit {limited = true;break outer};examined += 1
                var targets:[Int]
                if let center {
                    let primary = try unit(center);targets = [center]
                    for offset in movement.cardinalOffsets {
                        let point = GridPoint(x:primary.live.position.x+offset.dx,y:primary.live.position.y+offset.dy)
                        guard let target = key.units.first(where:{$0.live.enemy != caster.live.enemy && $0.live.position == point}) else {continue}
                        if ability < 15,try !movement.strategyTerrainEligible(family:ability/5,terrain:key.terrain[point.y*key.width+point.x]) {continue}
                        if !targets.contains(target.live.slot) {targets.append(target.live.slot)}
                    }
                } else {targets = preview.strategies[ability] ?? []}
                guard !targets.isEmpty else {continue}
                // The ordered source target list and unchanged caster/target values
                // determine this result. Movement itself never changes those values.
                let assessment:AreaAssessment
                if let known = cache[targets] {assessment = known}
                else {assessment = try areaAssessment(slot,ability:ability,origin:origin.point,center:center,targets:targets);cache[targets] = assessment}
                guard assessment.usefulTargets > 0 else {continue}
                candidates.append(.init(caster:slot,ability:ability,origin:origin.point,movementCost:origin.cost,center:center,targets:targets,assessment:assessment))
            }
        }
        candidates.sort {
            if $0.usefulTargets != $1.usefulTargets {return $0.usefulTargets > $1.usefulTargets}
            if $0.limitation == nil,$1.limitation == nil,$0.troops.lowerBound != $1.troops.lowerBound {return $0.troops.lowerBound > $1.troops.lowerBound}
            if $0.movementCost != $1.movementCost {return $0.movementCost < $1.movementCost}
            if $0.origin.y != $1.origin.y {return $0.origin.y < $1.origin.y}
            if $0.origin.x != $1.origin.x {return $0.origin.x < $1.origin.x}
            return ($0.center ?? -1) < ($1.center ?? -1)
        }
        return .init(candidates:candidates,examined:examined,limited:limited)
    }
}
