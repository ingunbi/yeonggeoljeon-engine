// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct ConfirmedBattleRewards:Codable,Equatable {
    var moneyChange = 0
    var grantedItems:[Int:Int] = [:]
    var replacedItems:[Int:Int] = [:]
    mutating func grant(_ receipt:OriginalScriptInventoryGrant) {
        guard !receipt.cancelled,receipt.insertedSlot != nil else { return }
        grantedItems[receipt.itemID,default:0] += 1
        if let old = receipt.replacedItemID { replacedItems[old,default:0] += 1 }
    }
    func validate() throws {
        guard (-1_000_000_000...1_000_000_000).contains(moneyChange),
              [grantedItems,replacedItems].allSatisfy({$0.count <= 64 && $0.allSatisfy{(0..<64).contains($0.key) && (1...1_000_000).contains($0.value)}}) else { throw EngineError.invalid("Confirmed battle rewards are invalid") }
    }
}
struct BattleTotals:Codable,Equatable {
    var damageByPlayer = 0
    var damageByEnemy = 0
    var recoveredByPlayer = 0
    var actionExperience:[Int:Int] = [:]
    var victoryExperience:[Int:Int] = [:]
    var retiredPeople:[Int] = []
    var complete = true
    var sourceRewards:ConfirmedBattleRewards? = nil
    /// Gold and items the story events give after the battle ended and before
    /// the next one began, kept apart from the battle's own rewards. Nil in
    /// summaries saved before this field existed.
    var afterBattleRewards:ConfirmedBattleRewards? = nil
    mutating func receive(_ entry:BattleResultLog.Entry) {
        if entry.actorEnemy { damageByEnemy += entry.result.damage ?? 0 }
        else { damageByPlayer += entry.result.damage ?? 0;recoveredByPlayer += max(0,entry.result.troopsRecovered ?? 0) }
        if entry.result.retired,let id = entry.targetPerson,!retiredPeople.contains(id) { retiredPeople.append(id) }
    }
    mutating func experience(person:Int,gain:Int,victory:Bool) {
        guard gain > 0 else { return }
        if victory { victoryExperience[person,default:0] += gain } else { actionExperience[person,default:0] += gain }
    }
    func validate() throws {
        try sourceRewards?.validate();try afterBattleRewards?.validate()
        guard [damageByPlayer,damageByEnemy,recoveredByPlayer].allSatisfy({(0...1_000_000_000).contains($0)}),
              [actionExperience,victoryExperience].allSatisfy({$0.count <= 384 && $0.allSatisfy{(0..<384).contains($0.key) && (0...1_000_000_000).contains($0.value)}}),
              retiredPeople.count <= 384,Set(retiredPeople).count == retiredPeople.count,retiredPeople.allSatisfy({(0..<384).contains($0)}) else { throw EngineError.invalid("Battle totals are invalid") }
    }
}
struct BattleSummary:Codable,Equatable {
    var attemptID:UUID
    var battleID:String
    var name:String
    var result:Int
    var turns:Int
    var totals:BattleTotals
    var endingReason:String? = nil
    var label:String {
        switch result {case 1:return "총퇴각·재시도";case 2:return "승리";case 3:return "패배";case 4:return "전투 중 종료";default:return "전투 종료 (결과 \(result))"}
    }
    func validate() throws {
        guard battleID.count <= 128,name.count <= 256,(endingReason?.count ?? 0) <= 256,(0...65535).contains(result),(1...65536).contains(turns) else { throw EngineError.invalid("Battle summary is invalid") }
        try totals.validate()
    }
}
struct CampaignJourneyEntry:Codable,Equatable {
    var sequence:Int
    var chapter:Int
    var map:Int
    var kind:String
    var text:String
    var person:Int? = nil
    var record:String? = nil
    var sourceOffset:Int? = nil
    var dialogueID:UUID? = nil
}
/// The source36 retry boundary owns journey observations independently of
/// completed-attempt statistics. Keep the bounded value, not just an index:
/// pruning a long battle must not destroy the start-of-attempt history.
struct CampaignJourneyCheckpoint:Codable,Equatable {
    var journey:[CampaignJourneyEntry]
    var nextSequence:Int
    var omittedJourney:Int
    var dialogueHistory:DialogueHistory
    var eventHints:ReviewedEventHints.Progress? = nil
    init(journal:CampaignJournal,dialogueHistory:DialogueHistory,eventHints:ReviewedEventHints.Progress? = nil) {
        journey = journal.journey;nextSequence = journal.nextSequence
        omittedJourney = journal.omittedJourney;self.dialogueHistory = dialogueHistory
        self.eventHints = eventHints
    }
    func validate() throws {
        var value = CampaignJournal();value.journey = journey;value.nextSequence = nextSequence;value.omittedJourney = omittedJourney
        try value.validate();try dialogueHistory.validate();try eventHints?.validate()
    }
}
struct CampaignJournal:Codable,Equatable {
    var summaries:[BattleSummary] = []
    var journey:[CampaignJourneyEntry] = []
    var nextSequence = 0
    var omittedJourney = 0
    var omittedSummaries = 0
    mutating func finish(_ battle:OriginalBattleSession) {
        guard !summaries.contains(where:{$0.attemptID == battle.resultLog.attemptID}) else { return }
        let timedOut = battle.turns.result == 3 && battle.turns.roundIndex >= battle.header.turnLimit
        summaries.append(.init(attemptID:battle.resultLog.attemptID,battleID:battle.definition.id,name:battle.definition.name ?? "전투",
            result:Int(battle.turns.result),turns:timedOut ? max(1,battle.header.turnLimit) : battle.turns.roundIndex+1,totals:battle.resultLog.totals,
            endingReason:timedOut ? "제한 턴 도달" : nil))
        if summaries.count > 256 { summaries.removeFirst();omittedSummaries += 1 }
    }
    mutating func record(chapter:Int,map:Int,kind:String,text:String,person:Int? = nil,record:String? = nil,sourceOffset:Int? = nil,dialogueID:UUID? = nil) {
        guard nextSequence < Int.max else { return }
        journey.append(.init(sequence:nextSequence,chapter:chapter,map:map,kind:kind,text:String(text.prefix(2048)),person:person,record:record,sourceOffset:sourceOffset,dialogueID:dialogueID))
        nextSequence += 1
        if journey.count > 1000 { journey.removeFirst();omittedJourney += 1 }
    }
    /// A story event after the battle gave gold or an item: attach it to the
    /// battle it follows (the latest finished one), never to a later battle.
    mutating func attachAfterBattle(attempt:UUID,money:Int = 0,grant:OriginalScriptInventoryGrant? = nil) {
        guard let index = summaries.lastIndex(where:{ $0.attemptID == attempt }) else { return }
        var rewards = summaries[index].totals.afterBattleRewards ?? ConfirmedBattleRewards()
        rewards.moneyChange += money
        if let grant = grant { rewards.grant(grant) }
        summaries[index].totals.afterBattleRewards = rewards
    }
    mutating func restoreJourney(_ checkpoint:CampaignJourneyCheckpoint) {
        journey = checkpoint.journey;nextSequence = checkpoint.nextSequence;omittedJourney = checkpoint.omittedJourney
    }
    func validate() throws {
        guard summaries.count <= 256,Set(summaries.map(\.attemptID)).count == summaries.count,
              journey.count <= 1000,omittedJourney >= 0,omittedSummaries >= 0,nextSequence >= omittedJourney,
              journey.count == nextSequence-omittedJourney,
              journey.enumerated().allSatisfy({ index,entry in
                entry.sequence == omittedJourney+index && (0...255).contains(entry.chapter) && (0...65535).contains(entry.map) &&
                ["선택","방문","합류","사건"].contains(entry.kind) && entry.text.count <= 2048 &&
                (entry.person == nil || (0..<384).contains(entry.person!)) && (entry.record?.count ?? 0) <= 256 &&
                (entry.sourceOffset == nil || (0...16_777_215).contains(entry.sourceOffset!))
              }) else { throw EngineError.invalid("Campaign journal ordering is invalid") }
        for summary in summaries { try summary.validate() }
    }
}

#if canImport(AppKit)
enum CampaignJournalSheet {
    static func history(_ journal:CampaignJournal,onChoose:@escaping (Int?)->Void) -> CanvasSheet {
        let rows = journal.summaries.reversed().map { record -> CanvasSheet.Row in
            let totals = record.totals
            return .init(label:record.name,value:record.label,detail:.init(heading:record.name,body:record.label,
                list:[totals.complete ? "전체 확정 행동 집계" : "이전 저장의 기록이 없어 일부 행동은 미집계","금·물품은 상세 화면에서 확인"],
                facts:[("소요 턴","\(record.turns)"),("아군 피해량","\(totals.damageByPlayer)"),("적군 피해량","\(totals.damageByEnemy)"),
                ("아군 회복량","\(totals.recoveredByPlayer)"),("행동 경험치","\(totals.actionExperience.values.reduce(0,+))"),("승리 경험치","\(totals.victoryExperience.values.reduce(0,+))"),("퇴각 인원","\(totals.retiredPeople.count)")]))
        }
        return CanvasSheet(portrait:nil,speaker:"누적 전적",line:"저장한 진행에 속한 확정 결과 · 이전 저장 이전의 전적은 없습니다.",badge:("",""),
            rows:rows.isEmpty ? [.init(label:"기록된 전투가 없습니다.")] : rows,selected:0,mode:.list,
            hint:"최근 256전투 · 생략 \(journal.omittedSummaries) · Esc 돌아가기",fullCanvas:true,onChoose:onChoose)
    }
    static func journey(_ journal:CampaignJournal,onChoose:@escaping (Int?)->Void) -> CanvasSheet {
        let rows = journal.journey.reversed().map { entry -> CanvasSheet.Row in
            .init(label:entry.kind,value:entry.text,detail:.init(heading:entry.kind,body:entry.text,facts:[("장","\(entry.chapter)"),("대사 기록","별도 대사 기록에서 확인")]))
        }
        return CanvasSheet(portrait:nil,speaker:"여정",line:"실제 방문과 확정한 선택만 표시합니다.",badge:("",""),rows:rows.isEmpty ? [.init(label:"이 저장 이전의 여정은 없습니다.")] : rows,selected:0,mode:.list,
            hint:"최근 1,000건 · 생략 \(journal.omittedJourney) · Esc 돌아가기",fullCanvas:true,onChoose:onChoose)
    }
}
#endif
