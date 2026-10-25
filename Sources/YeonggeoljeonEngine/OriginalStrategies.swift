// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct OriginalStrategyTargetEffect: Codable {
    var runtimeSlot: Int
    var person: Int
    var kind: String
    var damage: OriginalStrategyResult?
    var healing: OriginalHealingResult?
    var success: OriginalStrategySuccess?
    var morale: OriginalMoraleMutation?
    var experience: OriginalExperienceMutation?
    var retiredPerson: Int?
    var retirement:OriginalRetirementNotice?
}

struct OriginalStrategyExecution: Codable {
    var casterSlot: Int
    var abilityID: Int
    var completed: Bool
    var rejectionReason: String?
    var targets: [OriginalStrategyTargetEffect]
    var completion: OriginalStrategyCompletion?
    var completionExperience: OriginalExperienceMutation?
    var rngBefore: UInt32
    var rngAfter: UInt32
}

extension OriginalBattleSession {
    /// Synchronous convenience driver for the same resumable source operation
    /// used by campaign hosts. A throwing callback leaves the committed target
    /// intact; asynchronous hosts retain the operation instead of this wrapper.
    func castStrategy(_ slot:Int,abilityID:Int,target:Int? = nil,confirmed:Bool = true,
                      afterRetirement:((Int)throws->Void)? = nil) throws -> OriginalStrategyExecution {
        var operation = try OriginalStrategyOperation.begin(in:self,casterSlot:slot,abilityID:abilityID,target:target,confirmed:confirmed)
        while true {
            switch try operation.advance(in:self) {
            case .target:continue
            case .retirement(let notice):
                try afterRetirement?(notice.runtimeSlot)
                try operation.resumeRetirement(notice)
            case .finished(let execution):return execution
            }
        }
    }
}
