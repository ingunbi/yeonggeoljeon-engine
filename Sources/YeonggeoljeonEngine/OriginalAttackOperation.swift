// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct OriginalAttackContextEffect:Codable {
    var attackerSlot:Int
    var targetSlot:Int
    var attackerPerson:Int
    var targetPerson:Int
    var subtype:Int
    var preludeDraws:[Int]
    var strike:OriginalPhysicalResult
    var morale:OriginalMoraleMutation?
    var experience:OriginalExperienceMutation
}
struct OriginalAttackRetirementCheck:Codable {
    var runtimeSlot:Int
    var queriedPerson:Int
    var retiredPerson:Int?
    var notice:OriginalRetirementNotice?
}
struct OriginalAttackPendingRetirement:Codable,Equatable {
    var checkIndex:Int
    var notice:OriginalRetirementNotice
}
enum OriginalAttackStep {
    case context(OriginalAttackContextEffect)
    case retirement(OriginalRetirementNotice)
    case finished(OriginalStrikeExchange)
}

/// MAIN322B9 passes the same mutable context into E91A. Recursion overwrites
/// its current attacker/target orientation; the caller does not restore it.
/// Each retirement tail therefore queries the current target after callbacks.
struct OriginalAttackOperation:Codable {
    private enum Continuation:Codable {
        case primary
        case counterDecision
        case counterRetirement
        case outerRetirement
        case completion
        case finished(OriginalStrikeExchange)
    }
    private var format = 1
    private var battleID:String
    private var width:Int
    private var height:Int
    let attackerSlot:Int
    let targetSlot:Int
    private var subtype:Int
    private var rngBefore:UInt32
    private var continuation:Continuation = .primary
    private(set) var contextAttackerSlot:Int
    private(set) var contextTargetSlot:Int
    private(set) var contexts:[OriginalAttackContextEffect] = []
    private(set) var retirementChecks:[OriginalAttackRetirementCheck] = []
    private(set) var pendingRetirement:OriginalAttackPendingRetirement?
    var execution:OriginalStrikeExchange? {
        if case .finished(let result) = continuation {return result};return nil
    }
    /// Selection and source class-range validation consume no gameplay RNG.
    static func begin(in session:OriginalBattleSession,attackerSlot:Int,targetSlot:Int) throws -> Self {
        let attacker = try session.live(attackerSlot),target = try session.live(targetSlot)
        guard attacker.enemy != target.enemy,attacker.scriptFlags&0x80 == 0 else {throw BattleError.illegalAction("Original physical attack faction/action state")}
        let board = try session.board()
        guard let actor = board.actors.first(where:{$0.runtimeSlot == attackerSlot}),
              try OriginalAI.attackCells(profile:session.movement,board:board,actor:actor).contains(target.position) else {
            throw BattleError.illegalAction("Target is outside the original class range pattern")
        }
        let subtype = try OriginalCombat.normalPhysicalSubtype(classID:session.people.person(attacker.person).classID,tables:session.combat)
        return Self(battleID:session.definition.id,width:session.width,height:session.height,attackerSlot:attackerSlot,
            targetSlot:targetSlot,subtype:subtype,rngBefore:session.rng.state,contextAttackerSlot:attackerSlot,contextTargetSlot:targetSlot)
    }
    mutating func resumeRetirement(_ notice:OriginalRetirementNotice) throws {
        guard pendingRetirement?.notice == notice else {throw BattleError.illegalAction("Original attack retirement acknowledgement is stale")}
        pendingRetirement = nil
    }
    mutating func advance(in session:OriginalBattleSession) throws -> OriginalAttackStep {
        guard format == 1,battleID == session.definition.id,width == session.width,height == session.height,
              [attackerSlot,targetSlot,contextAttackerSlot,contextTargetSlot].allSatisfy({(0..<45).contains($0)}),
              (0...255).contains(subtype),contexts.count <= 2,retirementChecks.count <= 2 else {
            throw BattleError.invalid("Original attack continuation does not match its source session")
        }
        if let pending = pendingRetirement {
            guard retirementChecks.indices.contains(pending.checkIndex),retirementChecks[pending.checkIndex].notice == pending.notice else {
                throw BattleError.invalid("Original attack checkpoint lost its retirement/check identity")
            }
            return .retirement(pending.notice)
        }
        while true {
            switch continuation {
            case .primary:
                guard let a = session.units[contextAttackerSlot],let d = session.units[contextTargetSlot] else {throw BattleError.unsupported("Original attack lost its facing operands")}
                // Source30E21..30E41/3034F..30373 retain a vertical attack's
                // old flip and turn horizontally once before context creation.
                if d.position.x > a.position.x {session.units[contextAttackerSlot]!.scriptFlags &= ~UInt8(0x10)}
                else if d.position.x < a.position.x {session.units[contextAttackerSlot]!.scriptFlags |= 0x10}
                let effect = try session.physicalContext(attackerSlot:contextAttackerSlot,targetSlot:contextTargetSlot,subtype:subtype)
                contexts.append(effect);continuation = .counterDecision;return .context(effect)
            case .counterDecision:
                guard let primary = contexts.first,let target = session.units[contextTargetSlot] else {throw BattleError.unsupported("Original counter decision lost its context target")}
                if primary.strike.counterEligible,target.scriptFlags&2 == 0,try session.people.person(target.person).rawTroops != 0 {
                    // E91A overwrites the same source context. Updated shared
                    // HP, EXP/level and live morale are read by this producer.
                    let nextAttacker = contextTargetSlot,nextTarget = contextAttackerSlot
                    let effect = try session.physicalContext(attackerSlot:nextAttacker,targetSlot:nextTarget,subtype:7)
                    contextAttackerSlot = nextAttacker;contextTargetSlot = nextTarget
                    contexts.append(effect);continuation = .counterRetirement;return .context(effect)
                }
                continuation = .outerRetirement
            case .counterRetirement:
                let notice = try checkRetirement(in:session)
                continuation = .outerRetirement
                if let notice {return .retirement(notice)}
            case .outerRetirement:
                // There is no context+8/+9 restore after recursive E91A. The
                // first retirement script can change this slot's person/HP/
                // status before the caller's current-target check executes.
                let notice = try checkRetirement(in:session)
                continuation = .completion
                if let notice {return .retirement(notice)}
            case .completion:
                guard let primary = contexts.first,session.units[attackerSlot] != nil else {throw BattleError.unsupported("Original physical command lost its completion slot/context")}
                // Player30E61 and AI303A1 set80 after the entire context call.
                session.units[attackerSlot]!.scriptFlags |= 0x80;session.commitMove(attackerSlot)
                let counter = contexts.count == 2 ? contexts[1] : nil
                let result = OriginalStrikeExchange(attackerSlot:attackerSlot,targetSlot:targetSlot,
                    preludeDraws:primary.preludeDraws,strike:primary.strike,experience:primary.experience,
                    counter:counter?.strike,counterExperience:counter?.experience,
                    fallenPeople:retirementChecks.compactMap(\.retiredPerson),rngBefore:rngBefore,rngAfter:session.rng.state)
                continuation = .finished(result);return .finished(result)
            case .finished(let result):return .finished(result)
            }
        }
    }
    private mutating func checkRetirement(in session:OriginalBattleSession) throws -> OriginalRetirementNotice? {
        guard let unit = session.units[contextTargetSlot] else {throw BattleError.unsupported("Original retirement tail lost its current context target")}
        let cursor = session.retirements.count,person = try session.retireContextTarget(contextTargetSlot)
        let notice = session.retirements.dropFirst(cursor).first
        retirementChecks.append(OriginalAttackRetirementCheck(runtimeSlot:contextTargetSlot,queriedPerson:unit.person,retiredPerson:person,notice:notice))
        if let notice {pendingRetirement = OriginalAttackPendingRetirement(checkIndex:retirementChecks.count-1,notice:notice)}
        return notice
    }
}
