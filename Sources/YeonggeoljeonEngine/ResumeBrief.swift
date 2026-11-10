// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum ResumeBrief {
    static func text(_ host:OriginalCampaignHost) -> String {
        var lines = [host.resumedFrom ?? "저장한 지점부터 재개합니다."]
        if let battle = host.battle,host.stage.palette == 3 {
            lines.append("\(battle.definition.name ?? "전투") · \(battle.turns.roundIndex+1)턴")
            let ready = battle.units.values.filter {
                $0.status == 2 && OriginalBattleCommand.denial($0) == nil && (try? battle.requireManualUnit($0.slot)) != nil
            }.count
            lines.append("행동 가능한 아군 \(ready)부대")
            if let objective = host.vm.state.objectiveText,!objective.isEmpty { lines.append(objective) }
        } else {
            if let location = host.fieldScreenState()?.territory,!location.isEmpty { lines.append(location) }
            if host.choice != nil { lines.append("선택 대기 중입니다. 계속을 누르면 선택으로 돌아갑니다.") }
            else if host.stage.dialogue != nil { lines.append("대사 진행 중입니다. 읽던 대사에서 이어갑니다.") }
            else { lines.append("저장한 장소와 진행 상태로 돌아갑니다.") }
        }
        let choices = host.extras.journal.journey.filter {$0.kind == "선택"}.suffix(3)
        lines += choices.map { "최근 선택: "+$0.text }
        return lines.joined(separator:"\n")
    }
}
