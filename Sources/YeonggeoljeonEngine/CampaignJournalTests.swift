// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func campaignJournalSelfTests() throws {
    var checks = 0
    func check(_ v:Bool,_ m:String) throws { guard v else { throw EngineError.invalid("Campaign journal: "+m) };checks += 1 }
    var log = BattleResultLog()
    for i in 0..<650 { log.append(round:i,actorPerson:0,actorEnemy:false,targetPerson:1,action:.attack(counter:false),result:.init(damage:3,retired:i == 649)) }
    try check(log.entries.count == 500 && log.totals.damageByPlayer == 1950,"totals outlive the 500 detail limit")
    log.append(round:650,actorPerson:nil,actorEnemy:true,targetPerson:1,action:.retirement,result:.init(retired:true))
    try check(log.totals.retiredPeople == [1],"a defeated-target event and retirement share one person count")
    log.totals.experience(person:0,gain:12,victory:false);log.totals.experience(person:0,gain:20,victory:true)
    let restored = try JSONDecoder().decode(BattleResultLog.self,from:JSONEncoder().encode(log))
    try check(restored == log,"save keeps attempt identity, aggregates and detail")
    try check(restored.totals.actionExperience[0] == 12 && restored.totals.victoryExperience[0] == 20,"XP sources remain distinct")
    var legacyObject = try JSONSerialization.jsonObject(with:JSONEncoder().encode(log)) as! [String:Any]
    legacyObject.removeValue(forKey:"totals");legacyObject.removeValue(forKey:"attemptID")
    let legacy = try JSONDecoder().decode(BattleResultLog.self,from:JSONSerialization.data(withJSONObject:legacyObject))
    try check(!legacy.totals.complete && legacy.totals.damageByPlayer < log.totals.damageByPlayer,"legacy partial history explicitly remains partial")
    var journal = CampaignJournal()
    for i in 0..<1010 { journal.record(chapter:0,map:1,kind:"선택",text:"choice \(i)") }
    try journal.validate()
    try check(journal.journey.count == 1000 && journal.omittedJourney == 10 && journal.journey.first?.sequence == 10,"journey bounds preserve sequence")
    let retry = CampaignJourneyCheckpoint(journal:journal,dialogueHistory:DialogueHistory())
    for i in 0..<1001 {journal.record(chapter:0,map:1,kind:"선택",text:"failed attempt \(i)")}
    let failed = BattleSummary(attemptID:UUID(),battleID:"synthetic",name:"Test",result:1,turns:2,totals:BattleTotals())
    journal.summaries.append(failed);journal.restoreJourney(retry)
    try check(journal.journey == retry.journey && journal.summaries == [failed],"retry rolls back even pruned observations without losing failure statistics")
    try retry.validate();try journal.validate()
    var rewards = ConfirmedBattleRewards()
    rewards.grant(.init(person:0,itemID:1,insertedSlot:nil,replacedItemID:nil,cancelled:true))
    try check(rewards.grantedItems.isEmpty,"declined reward does not count")
    rewards.grant(.init(person:0,itemID:1,insertedSlot:0,replacedItemID:2,cancelled:false))
    try check(rewards.grantedItems == [1:1] && rewards.replacedItems == [2:1],"actual reward replacement keeps both confirmed deltas")
    log.totals.sourceRewards = rewards
    try check(try JSONDecoder().decode(BattleResultLog.self,from:JSONEncoder().encode(log)).totals.sourceRewards == rewards,"confirmed rewards share the action accumulator snapshot")
    var defeat = failed;defeat.result = 3;defeat.endingReason = "제한 턴 도달"
    try check(defeat.label == "패배" && failed.label == "총퇴각·재시도","defeat and checkpoint retreat are distinct")
    var extras = CampaignExtras();extras.journal = journal;extras.retryJourney = retry
    try extras.setItemProtection(personID:0,itemID:1,enabled:true,protectUse:true)
    var save = try nativeSaveTestResume(money:10);save.extras = extras
    let native = try JSONDecoder().decode(OriginalCampaignResume.self,from:JSONEncoder().encode(save))
    try check(native.extras == extras,"journal and protection share the same resume payload")
    save.extras = nil
    let old = try JSONDecoder().decode(OriginalCampaignResume.self,from:JSONEncoder().encode(save))
    try check((old.extras ?? CampaignExtras()).journal.journey.isEmpty,"older save never inherits future observations")
    var bad = extras;bad.journal.nextSequence = -1
    do { try bad.validate();throw EngineError.invalid("invalid journal accepted") } catch EngineError.invalid(let text) where text != "invalid journal accepted" { checks += 1 }
    print("Campaign journal self-tests passed: \(checks)")
}
