// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Engine-only journal of already committed operations. Entries never replay
/// commands or consume RNG. Keeping the result, rather than a UI callback,
/// makes the journal independent of animation speed and window lifetime.
struct BattleResultLog:Codable,Equatable {
    enum Action:Codable,Equatable {
        case attack(counter:Bool), strategy(Int), item(Int), retirement
    }
    struct Result:Codable,Equatable {
        var damage:Int? = nil
        /// Signed: the source healer may clamp an over-cap troop count down.
        var troopsRecovered:Int? = nil
        var moraleChange:Int? = nil
        var remainingTroops:Int? = nil
        var remainingMorale:Int? = nil
        var success:Bool? = nil
        var confused = false
        var confusionRecovered = false
        var retired = false
        var newClass:Int? = nil
    }
    struct Entry:Codable,Equatable {
        var sequence:Int
        var round:Int
        var actorPerson:Int?
        var actorEnemy:Bool
        var targetPerson:Int?
        var action:Action
        var result:Result
    }
    var attemptID = UUID()
    var totals = BattleTotals()
    private enum CodingKeys:String,CodingKey { case attemptID,totals,entries,discarded,nextSequence }
    init() {}
    init(from decoder:Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        attemptID = try c.decodeIfPresent(UUID.self,forKey:.attemptID) ?? UUID()
        entries = try c.decode([Entry].self,forKey:.entries)
        discarded = try c.decode(Int.self,forKey:.discarded)
        nextSequence = try c.decode(Int.self,forKey:.nextSequence)
        if let saved = try c.decodeIfPresent(BattleTotals.self,forKey:.totals) { totals = saved }
        else { totals.complete = false;entries.forEach{totals.receive($0)} }
        try validate()
    }
    static let capacity = 500
    private(set) var entries:[Entry] = []
    private(set) var discarded = 0
    private(set) var nextSequence = 0

    mutating func append(round:Int,actorPerson:Int?,actorEnemy:Bool,targetPerson:Int?,action:Action,result:Result) {
        guard nextSequence < Int.max else { return }
        entries.append(Entry(sequence:nextSequence,round:round,actorPerson:actorPerson,actorEnemy:actorEnemy,
                             targetPerson:targetPerson,action:action,result:result))
        totals.receive(entries.last!)
        nextSequence += 1
        if entries.count > Self.capacity { entries.removeFirst();discarded += 1 }
    }
    func validate() throws {
        try totals.validate()
        func valid(_ entry:Entry) -> Bool {
            let actionValid:Bool
            switch entry.action {
            case .attack,.retirement:actionValid = true
            case .strategy(let id):actionValid = (0..<36).contains(id)
            case .item(let id):actionValid = (0..<64).contains(id)
            }
            let result = entry.result
            return actionValid && (0...65535).contains(entry.round) &&
                (entry.actorPerson.map { (0..<384).contains($0) } ?? true) &&
                (entry.targetPerson.map { (0..<384).contains($0) } ?? true) &&
                [result.damage,result.remainingTroops].allSatisfy { $0.map { (0...65535).contains($0) } ?? true } &&
                (result.troopsRecovered.map { (-65535...65535).contains($0) } ?? true) &&
                (result.moraleChange.map { (-100...100).contains($0) } ?? true) &&
                (result.remainingMorale.map { (0...100).contains($0) } ?? true) &&
                (result.newClass.map { (0..<19).contains($0) } ?? true)
        }
        guard entries.count <= Self.capacity,discarded >= 0,nextSequence >= 0,
              discarded <= nextSequence,entries.count == nextSequence-discarded,
              entries.enumerated().allSatisfy({ index,entry in
                  entry.sequence == discarded+index && valid(entry)
              }) else { throw EngineError.invalid("Native battle journal has invalid ordering or identities") }
    }
    static func physical(_ effect:OriginalAttackContextEffect) -> Result {
        Result(damage:effect.strike.damage,moraleChange:effect.morale == nil ? nil : -effect.strike.moraleLoss,
               remainingTroops:effect.strike.remainingTroops,remainingMorale:effect.morale?.remainingMorale,
               confused:effect.morale.map { $0.remainingFlags&2 != 0 } ?? false,
               confusionRecovered:effect.morale?.conditionRecovery?.recovered == true)
    }
    static func target(_ effect:OriginalStrategyTargetEffect) -> Result {
        let success = effect.success?.success ?? effect.damage?.success
        return Result(damage:effect.damage?.damage ?? effect.quantity,troopsRecovered:effect.healing?.troopsDelta,
            moraleChange:effect.moraleChange ?? effect.healing?.moraleDelta ?? (effect.morale == nil ? nil : effect.damage.map { -$0.moraleLoss }),
            remainingTroops:effect.damage?.remainingTroops ?? effect.healing?.remainingTroops,
            remainingMorale:effect.morale?.remainingMorale ?? effect.healing?.remainingMorale,success:success,
            confused:(effect.kind == "condition2" && success != false) || effect.morale.map { $0.remainingFlags&2 != 0 } == true,
            confusionRecovered:effect.morale?.conditionRecovery?.recovered == true || effect.healing?.moraleMutation?.conditionRecovery?.recovered == true,
            retired:effect.retiredPerson != nil || effect.retirement != nil)
    }
}

extension OriginalBattleSession {
    func logPhysicalResult(_ effect:OriginalAttackContextEffect,counter:Bool) {
        resultLog.append(round:turns.roundIndex,actorPerson:effect.attackerPerson,actorEnemy:effect.attackerSlot >= 15,
                         targetPerson:effect.targetPerson,action:.attack(counter:counter),result:BattleResultLog.physical(effect))
    }
    func logTargetResult(_ effect:OriginalStrategyTargetEffect,actorSlot:Int,action:BattleResultLog.Action) {
        resultLog.append(round:turns.roundIndex,actorPerson:units[actorSlot]?.person,actorEnemy:actorSlot >= 15,
                         targetPerson:effect.person,action:action,result:BattleResultLog.target(effect))
    }
    func logRetirementResult(_ notice:OriginalRetirementNotice) {
        resultLog.append(round:turns.roundIndex,actorPerson:nil,actorEnemy:notice.runtimeSlot >= 15,
                         targetPerson:notice.person,action:.retirement,result:.init(retired:true))
    }
    func logClassResult(userSlot:Int,item:Int,newClass:Int) {
        resultLog.append(round:turns.roundIndex,actorPerson:units[userSlot]?.person,actorEnemy:userSlot >= 15,
                         targetPerson:units[userSlot]?.person,action:.item(item),result:.init(newClass:newClass))
    }
}
