// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Presentation facts only. It never interprets objective prose or executes a VM predicate.
enum BattleObjectiveTracker {
    enum State:String {case pending = "완료 사건 대기",confirmed = "완료 확인",unavailable = "진행 판정 자료 없음"}
    struct Condition:Equatable {
        var id:String;var battleID:String;var publicText:String;var state:State
        var targetPerson:Int?;var sourceReference:String
    }
    struct Entry:Equatable {var text:String;var state:State;var target:GridPoint?;var sourceReference:String}
    static func conditions(catalog:ReviewedEventHints.Catalog?,context:ReviewedEventHints.Context,
                           progress:ReviewedEventHints.Progress?,publicText:String) -> [Condition] {
        guard let catalog,catalog.sourceIdentity == context.sourceIdentity,(try? catalog.validate()) != nil else {return []}
        let completed = progress.flatMap {$0.sourceIdentity == context.sourceIdentity && (try? $0.validate()) != nil ? Set($0.completed) : nil} ?? []
        return catalog.hints.compactMap {hint in
            guard hint.battleID == context.battleID,hint.objectiveText == publicText,hint.completion != nil else {return nil}
            return Condition(id:hint.id,battleID:hint.battleID,publicText:publicText,state:completed.contains(hint.id) ? .confirmed : .pending,
                targetPerson:hint.publicTargetPerson,sourceReference:hint.evidence.map {"\($0.relativeFile) @ \($0.byteOffset)"}.joined(separator:" · "))
        }
    }
    static func entries(session:OriginalBattleSession,publicText:String,conditions:[Condition]) -> [Entry] {
        let matching = conditions.filter {$0.battleID == session.definition.id && $0.publicText == publicText && !$0.sourceReference.isEmpty}
        guard !matching.isEmpty else {return [.init(text:publicText,state:.unavailable,target:nil,sourceReference:"현재 공개 목표와 정확히 연결된 검토 자료가 없습니다.")]}
        return matching.map {condition in
            let candidates = session.units.values.filter {$0.status == 2 && (!$0.enemy || $0.scriptFlags&0x20 != 0) && $0.person == condition.targetPerson}
            return .init(text:condition.publicText,state:condition.state,target:candidates.count == 1 ? candidates.first?.position : nil,sourceReference:condition.sourceReference)
        }
    }
}

extension OriginalCampaignHost {
    /// Catalog/progress reading only. A duel completion without objectiveText is
    /// deliberately not promoted to victory progress.
    func reviewedObjectiveProgress(publicText:String) -> [BattleObjectiveTracker.Condition] {
        guard let context = eventHintContext else {return []}
        return BattleObjectiveTracker.conditions(catalog:eventHintCatalog,context:context,progress:extras.eventHints,publicText:publicText)
    }
}
