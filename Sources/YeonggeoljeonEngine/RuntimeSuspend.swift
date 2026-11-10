// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Native engine suspension only; no original save format or rule is changed.
struct OriginalBattleSuspension:Codable {
    var battleID:String
    var terrain:[UInt8]
    var pictureTiles:[UInt8]?
    var scriptActions:OriginalScriptActionState
    var movementOrigins:[Int:GridPoint]
    var retirements:[OriginalRetirementNotice]
    var nextRetirementSequence:Int
    var exchanges:[OriginalStrikeExchange]
    var strategyExecutions:[OriginalStrategyExecution]
    var objectiveEvents:[OriginalCampaignEvent]
    var sourceOptionsWord:Int
    var scriptSounds:[Int]
    /// Optional for saves made before the engine result journal existed.
    var resultLog:BattleResultLog? = nil

    func matchesSource(program:OriginalCampaignProgram,state:OriginalCampaignState) -> Bool {
        // A script can change its block after loading this same battle. The
        // VM digest binds the program; the decoded load binds the map and ID.
        program.records.contains { record in
            record.instructions.contains { instruction in
                [9,0x11].contains(instruction.opcode) && instruction.battleID == battleID && instruction.arguments.first == state.packedMap
            }
        }
    }
}

struct OriginalSuspendedCitizen:Codable {
    var person:Int
    var home:GridPoint
    var direction:Int
    var counter:Int
    var standing:Bool
}

struct OriginalCampaignSuspension:Codable {
    var format = 1
    var presentation:RuntimeSuspension
    var battle:OriginalBattleSuspension?
    var wasWaiting:Bool
    var controllerEvent:Int?
    var pendingCache:[Command]
    var pendingBattleCommands:[Command]
    var wanderers:[OriginalSuspendedCitizen]
    var wanderDice:OriginalRNG
    var wanderTime:Int64
    var sounds:[Int]

    static func canResumeWaiting(_ state:OriginalCampaignState) -> Bool {
        state.pending == nil && state.invocationActive != true &&
        (state.currentRecordID == nil || state.invocationMayResume == true)
    }
}
