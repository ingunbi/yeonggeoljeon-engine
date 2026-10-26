// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Owns source phase transitions and suspension across campaign dialogue and
/// choices. The AppKit view only supplies inputs and draws the current state.
final class OriginalBattleFlow {
    let session:OriginalBattleSession
    var onHook:((OriginalTurnHook)throws->Bool)?
    var onRetirement:((OriginalRetirementNotice)throws->Bool)?
    private(set) var suspended = false
    private var pendingManualSlot:Int?
    private var pendingNativeSlot:Int?
    private(set) var hooks:[OriginalTurnHook] = []
    private var retirementsDelivered = 0
    private var strategyOperation:OriginalStrategyOperation?
    private var strategyIsNative = false
    private var strategyRetirementAcknowledgement:OriginalRetirementNotice?
    private(set) var lastStrategy:OriginalStrategyExecution?
    private var attackOperation:OriginalAttackOperation?
    private var attackIsNative = false
    private var attackRetirementAcknowledgement:OriginalRetirementNotice?
    private(set) var lastAttack:OriginalStrikeExchange?
    var canLeaveBattle:Bool { session.turns.result != 0 && !suspended && attackOperation == nil && strategyOperation == nil }
    init(session:OriginalBattleSession) { self.session = session }
    var acceptsManualInput:Bool { !suspended && attackOperation == nil && strategyOperation == nil && session.turns.stage == .manualFriendly && session.turns.result == 0 }
    @discardableResult
    func manualAttack(_ slot:Int,target:Int) throws -> OriginalStrikeExchange? {
        guard acceptsManualInput else { throw BattleError.illegalAction("Original source phase is not accepting manual input") }
        _ = try session.requireManualUnit(slot)
        attackOperation = try OriginalAttackOperation.begin(in:session,attackerSlot:slot,targetSlot:target)
        attackIsNative = false;lastAttack = nil;try drivePhases();return lastAttack
    }
    func manualWait(_ slot:Int) throws {
        guard acceptsManualInput else { throw BattleError.illegalAction("Original source phase is not accepting manual input") }
        _ = try session.waitManually(slot);try finishManualAction(slot)
    }
    @discardableResult
    func manualStrategy(_ slot:Int,abilityID:Int,target:Int?) throws -> OriginalStrategyExecution? {
        guard acceptsManualInput else { throw BattleError.illegalAction("Original source phase is not accepting manual input") }
        _ = try session.requireManualUnit(slot)
        strategyOperation = try OriginalStrategyOperation.begin(in:session,casterSlot:slot,abilityID:abilityID,target:target)
        strategyIsNative = false;lastStrategy = nil
        try drivePhases();return lastStrategy
    }
    func start() throws { try drivePhases() }
    func resumeSourceFlow() throws {
        guard suspended else { return }
        suspended = false;try drivePhases()
    }
    @discardableResult
    private func hook(_ value:OriginalTurnHook) throws -> Bool {
        hooks.append(value)
        if let onHook = onHook,try !onHook(value) { suspended = true;return false }
        return true
    }
    private func objectives() throws -> Bool {
        while retirementsDelivered < session.retirements.count {
            let notice = session.retirements[retirementsDelivered]
            retirementsDelivered += 1
            if let onRetirement = onRetirement {
                if try !onRetirement(notice) { suspended = true;return false }
            }
        }
        return true
    }
    private func advanceStrategy() throws -> Bool {
        while var operation = strategyOperation {
            if let notice = strategyRetirementAcknowledgement {
                guard try objectives() else { return false }
                try operation.resumeRetirement(notice);strategyRetirementAcknowledgement = nil
            }
            let step = try operation.advance(in:session);strategyOperation = operation
            switch step {
            case .target:continue
            case .retirement(let notice):
                strategyRetirementAcknowledgement = notice
                guard try objectives() else { return false }
            case .finished(let result):
                session.recordStrategyExecution(result);lastStrategy = result;strategyOperation = nil
                if result.completed {
                    if strategyIsNative { pendingNativeSlot = result.casterSlot }
                    else { pendingManualSlot = result.casterSlot }
                } else if strategyIsNative { pendingNativeSlot = result.casterSlot }
                return true
            }
        }
        return true
    }
    private func advanceAttack() throws -> Bool {
        while var operation = attackOperation {
            if let notice = attackRetirementAcknowledgement {
                guard try objectives() else { return false }
                try operation.resumeRetirement(notice);attackRetirementAcknowledgement = nil
            }
            let step = try operation.advance(in:session);attackOperation = operation
            switch step {
            case .context:continue
            case .retirement(let notice):
                attackRetirementAcknowledgement = notice
                guard try objectives() else { return false }
            case .finished(let result):
                session.recordAttackExchange(result);lastAttack = result;attackOperation = nil
                if attackIsNative { pendingNativeSlot = result.attackerSlot }
                else { pendingManualSlot = result.attackerSlot }
                return true
            }
        }
        return true
    }
    private func finishManualAction(_ slot:Int) throws {
        pendingManualSlot = slot
        try drivePhases()
    }
    private func drivePhases() throws {
        guard !suspended else { return }
        if attackOperation != nil { guard try advanceAttack() else { return } }
        if strategyOperation != nil { guard try advanceStrategy() else { return } }
        if pendingManualSlot != nil {
            guard try objectives() else { return }
            let slot = pendingManualSlot!;pendingManualSlot = nil
            if session.turns.result == 0,try !hook(session.sourceUnitHook(slot)) { return }
        }
        if session.turns.result != 0 { pendingNativeSlot = nil;return }
        while !suspended,session.turns.result == 0 {
            switch session.turns.stage {
            case .unstarted,.roundComplete:
                guard let value = try session.beginRound() else { return }
                if try !hook(value) { return }
            case .roundEvent:
                if try !hook(session.prepareFriendlyRound()) { return }
            case .globalEvent:try session.enterManualFriendly();return
            case .manualFriendly:return
            case .friendlyAI:
                try nativeActions();if suspended || session.turns.result != 0 { if !suspended { pendingNativeSlot = nil };return }
                try session.prepareEnemyPhase()
            case .enemyAI:
                try nativeActions();if suspended || session.turns.result != 0 { if !suspended { pendingNativeSlot = nil };return }
                try session.completeRound()
            case .finished:return
            }
        }
    }
    /// MAIN27D77..27DA3: retreat is refused when script context+1CB (the
    /// setup header's preserved-slot byte) is set; otherwise raw result one.
    var retreatAllowed:Bool { !session.header.preserveFriendlySlots }
    func requestRetreat() throws {
        guard acceptsManualInput else { throw BattleError.illegalAction("Original battle menu is outside the manual phase") }
        guard retreatAllowed else { throw BattleError.illegalAction("Original retreat is refused for a preserved-slot battle") }
        try session.acceptSourceResult(1)
    }
    /// MAIN27E87..27EA3: quit writes raw result four after its question.
    func requestQuit() throws {
        guard acceptsManualInput else { throw BattleError.illegalAction("Original battle menu is outside the manual phase") }
        try session.acceptSourceResult(4)
    }
    func finishManual() throws {
        guard acceptsManualInput else { throw BattleError.illegalAction("Original manual phase has a pending source operation") }
        try session.finishManualFriendly();try drivePhases()
    }
    private func nativeActions() throws {
        while session.turns.result == 0 {
            if let slot = pendingNativeSlot {
                guard try objectives() else { return }
                pendingNativeSlot = nil
                if session.turns.result != 0 { return }
                if let value = try session.completeNativeUnit(slot),try !hook(value) { return }
                continue
            }
            guard let slot = session.turns.pendingAI.first else { return }
            guard let unit = session.units[slot],unit.status == 2,unit.orderMode != 7,unit.scriptFlags&0x80 == 0 else {
                try session.skipNativeUnit(slot);continue
            }
            let decision = try session.aiDecision(slot)
            try session.applyAIMovement(slot,decision)
            if let strategy = decision.strategyID {
                strategyOperation = try OriginalStrategyOperation.begin(in:session,casterSlot:slot,abilityID:strategy,target:decision.targetSlot)
                strategyIsNative = true;lastStrategy = nil
                guard try advanceStrategy() else { return }
            } else {
                if let target = decision.targetSlot {
                    attackOperation = try OriginalAttackOperation.begin(in:session,attackerSlot:slot,targetSlot:target)
                    attackIsNative = true;lastAttack = nil
                    guard try advanceAttack() else { return }
                } else { pendingNativeSlot = slot }
            }
        }
    }
}
