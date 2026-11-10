// SPDX-License-Identifier: GPL-3.0-only
import AppKit

extension CampaignManagementUI {
    func showAccumulatedBattles(query:String = "",result:Int? = nil,selected:Int = 0,onClose:@escaping()->Void) {
        let journal = host.extras.journal
        let records = journal.summaries.reversed().filter {
            (result == nil || $0.result == result) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
        let names:[Int:String] = [1:"총퇴각",2:"승리",3:"패배",4:"종료"]
        let values = records.map {record in
            CanvasSheet.Row(label:record.name,value:"\(record.label) · \(record.turns)턴",detail:battleSummaryDetail(record))
        }
        rows(title:"누적 전적",line:"이 저장에 남은 \(journal.summaries.count)전투 · 승리 \(journal.summaries.filter{$0.result == 2}.count) · 생략 \(journal.omittedSummaries)",
            values:values.isEmpty ? [.init(label:"해당 전투 기록이 없습니다.",enabled:false)] : values,selected:selected,
            buttons:["전투 검색","결과: \(result.flatMap{names[$0]} ?? "전체")","닫기"],onButton:{button in
                if button == 0 {
                    let next = self.textInput(title:"전투명 검색",message:"비우면 모든 전투를 표시합니다.",value:query)
                    self.showAccumulatedBattles(query:next ?? query,result:result,onClose:onClose)
                } else if button == 1 {
                    let next = result == nil ? 2 : result == 2 ? 3 : result == 3 ? 1 : result == 1 ? 4 : nil
                    self.showAccumulatedBattles(query:query,result:next,onClose:onClose)
                } else {onClose()}
            }) {index in
                guard let index,records.indices.contains(index) else {onClose();return}
                let record = records[index],totals = record.totals
                let people = Set(totals.actionExperience.keys).union(totals.victoryExperience.keys).union(totals.retiredPeople).sorted()
                let back = {self.showAccumulatedBattles(query:query,result:result,selected:index,onClose:onClose)}
                var detailRows:[CanvasSheet.Row] = [.init(label:"전체 결과",detail:self.battleSummaryDetail(record))]
                detailRows += people.map {id in
                    .init(label:self.name(id),value:totals.retiredPeople.contains(id) ? "퇴각 기록" : "경험치 획득",
                        detail:.init(heading:self.name(id),facts:[("행동 경험치","\(totals.actionExperience[id,default:0])"),("승리 보너스","\(totals.victoryExperience[id,default:0])")]))
                }
                self.rows(title:record.name,line:record.label,values:detailRows) {_ in back()}
            }
    }
    private func battleSummaryDetail(_ record:BattleSummary)->CanvasSheet.Detail {
        let t = record.totals
        var list = [t.complete ? "전체 확정 행동 집계" : "이전 저장의 일부 행동은 미집계",
            "전투 밖에서 지급한 보상과 출처를 연결하지 못한 변화는 미집계입니다."]
        if let reason = record.endingReason {list.insert(reason,at:0)}
        if let rewards = t.sourceRewards {
            list.append("전투 중 확정 금 변화: \(rewards.moneyChange >= 0 ? "+" : "")\(rewards.moneyChange)")
            list += rewards.grantedItems.keys.sorted().map {"지급: \(itemName($0)) ×\(rewards.grantedItems[$0]!)"}
            list += rewards.replacedItems.keys.sorted().map {"지급을 위해 교체: \(itemName($0)) ×\(rewards.replacedItems[$0]!)"}
        } else {list.append("금·물품 지급 기록 없음 또는 이전 저장에서 미집계")}
        return .init(heading:record.name,body:record.label,list:list,
            facts:[("소요 턴","\(record.turns)"),("아군이 준 피해","\(t.damageByPlayer)"),("적군이 준 피해","\(t.damageByEnemy)"),
                ("아군 회복량","\(t.recoveredByPlayer)"),("행동 경험치","\(t.actionExperience.values.reduce(0,+))"),
                ("승리 경험치","\(t.victoryExperience.values.reduce(0,+))"),("퇴각 인원","\(t.retiredPeople.count)")])
    }
    func showJourney(chapter:Int? = nil,map:Int? = nil,kind:String? = nil,selected:Int = 0,onClose:@escaping()->Void) {
        let journal = host.extras.journal
        let entries = journal.journey.reversed().filter {
            (chapter == nil || $0.chapter == chapter) && (map == nil || $0.map == map) && (kind == nil || $0.kind == kind)
        }
        let back = {self.showJourney(chapter:chapter,map:map,kind:kind,selected:selected,onClose:onClose)}
        rows(title:"여정",line:"실제로 경험한 기록 · 최근 1,000건 · 생략 \(journal.omittedJourney)",
            values:entries.isEmpty ? [.init(label:"이 저장에 해당 여정이 없습니다.",enabled:false)] : entries.map {entry in
                .init(label:entry.kind,value:entry.text,detail:.init(heading:entry.kind,body:entry.text,facts:[("장",entry.chapter == 0 ? "서장" : "제\(entry.chapter)장")]))
            },selected:selected,buttons:["장","장소","종류","닫기"],onButton:{button in
                if button == 0 {
                    let chapters = Array(Set(journal.journey.map(\.chapter))).sorted()
                    self.rows(title:"기록된 장",values:[.init(label:"전체")]+chapters.map {.init(label:$0 == 0 ? "서장" : "제\($0)장")}) {index in
                        guard let index else {back();return}
                        self.showJourney(chapter:index == 0 ? nil : chapters[index-1],map:map,kind:kind,onClose:onClose)
                    }
                } else if button == 1 {
                    var seen = Set<Int>()
                    let places = journal.journey.reversed().filter {seen.insert($0.map).inserted}
                    self.rows(title:"기록된 장소",values:[.init(label:"전체")]+places.map {entry in
                        let name = journal.journey.last {$0.map == entry.map && $0.kind == "방문"}?.text ?? "기록된 장면 \(entry.map)"
                        return .init(label:name)
                    }) {index in
                        guard let index else {back();return}
                        self.showJourney(chapter:chapter,map:index == 0 ? nil : places[index-1].map,kind:kind,onClose:onClose)
                    }
                } else if button == 2 {
                    let kinds = ["선택","방문","합류","사건"]
                    self.rows(title:"사건 종류",values:[.init(label:"전체")]+kinds.map {.init(label:$0)}) {index in
                        guard let index else {back();return}
                        self.showJourney(chapter:chapter,map:map,kind:index == 0 ? nil : kinds[index-1],onClose:onClose)
                    }
                } else {onClose()}
            }) {index in
                guard let index,entries.indices.contains(index) else {onClose();return}
                let entry = entries[index]
                let back = {self.showJourney(chapter:chapter,map:map,kind:kind,selected:index,onClose:onClose)}
                let dialogue = entry.dialogueID.flatMap {id in self.host.extras.dialogueHistory.entries.first {$0.id == id}}
                var detailRows:[CanvasSheet.Row] = [.init(label:entry.kind,detail:.init(heading:entry.kind,body:entry.text))]
                if let dialogue {
                    detailRows.append(.init(label:"연결된 대사",value:dialogue.speaker,detail:.init(heading:dialogue.speaker,body:dialogue.text)))
                } else {detailRows.append(.init(label:"대사 기록 없음",value:"미연결 또는 보관 범위 밖"))}
                self.rows(title:"여정 상세",values:detailRows) {_ in back()}
            }
    }
}
