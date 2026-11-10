// SPDX-License-Identifier: GPL-3.0-only
import AppKit

enum BattleResultLogSheet {
    static func sheet(_ log:BattleResultLog,selected:Int = 0,personName:(Int)->String,
                      strategyName:(Int)->String,itemName:(Int)->String,className:(Int)->String,
                      onChoose:@escaping (Int?)->Void) -> CanvasSheet {
        func title(_ action:BattleResultLog.Action) -> String {
            switch action {
            case .attack(let counter):return counter ? "반격" : "공격"
            case .strategy(let id):return strategyName(id)
            case .item(let id):return itemName(id)
            case .retirement:return "퇴각"
            }
        }
        var rows = log.entries.reversed().map { entry -> CanvasSheet.Row in
            let result = entry.result,action = title(entry.action)
            let actor = entry.actorPerson.map(personName) ?? "",target = entry.targetPerson.map(personName) ?? ""
            var facts:[(label:String,value:String)] = []
            if let damage = result.damage { facts.append(("병력 피해",String(damage))) }
            if let healing = result.troopsRecovered { facts.append((healing < 0 ? "병력 조정" : "병력 회복",String(healing))) }
            if let morale = result.moraleChange { facts.append(("사기 변화",morale > 0 ? "+\(morale)" : String(morale))) }
            if let remaining = result.remainingTroops { facts.append(("남은 병력",String(remaining))) }
            if let remaining = result.remainingMorale { facts.append(("남은 사기",String(remaining))) }
            var states:[String] = []
            if result.success == false { states.append("효과 실패") }
            if result.confused { states.append("혼란 상태") }
            if result.confusionRecovered { states.append("혼란 회복") }
            if result.retired { states.append("전선에서 퇴각") }
            if let newClass = result.newClass { states.append("전직 완료 · "+className(newClass)) }
            let heading = actor.isEmpty ? target : "\(actor) → \(target)"
            let value = result.success == false ? "실패" : result.retired ? "퇴각" : result.damage.map { "피해 \($0)" } ?? result.troopsRecovered.map { $0 < 0 ? "조정 \($0)" : "회복 \($0)" } ?? "\(entry.round+1)턴"
            return .init(label:action+" · "+(actor.isEmpty ? target : actor),value:value,
                detail:.init(heading:heading,body:"\(entry.round+1)턴 · \(entry.actorEnemy ? "적군" : "아군") · \(action)",
                             list:states,facts:facts))
        }
        if rows.isEmpty { rows = [.init(label:"아직 기록 없음",detail:.init(heading:"전투 결과 기록",body:"공격·책략·도구의 결과가 확정되면\n여기에 차례로 기록됩니다."))] }
        return CanvasSheet(portrait:nil,speaker:"전투 결과 기록",line:"최근 결과부터 표시 · 현재 전투의 확정된 결과",
            badge:("보관 중","\(log.entries.count) / \(BattleResultLog.capacity)"),rows:rows,
            selected:min(max(0,selected),rows.count-1),mode:.list,
            hint:log.discarded > 0 ? "↑↓ · 휠로 보기 · esc 돌아가기 · 이전 \(log.discarded)건 제외" : "↑↓ · 휠로 보기 · esc 돌아가기 · 중단 저장에 함께 보관",
            fullCanvas:true,onChoose:onChoose)
    }
}
