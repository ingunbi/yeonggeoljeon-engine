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
    private var itemOperation:OriginalItemOperation?
    private var itemRetirementAcknowledgement:OriginalRetirementNotice?
    private(set) var lastItem:OriginalItemExecution?
    /// A view that plays each native action sets this. The flow then holds
    /// before the action commits, so dialogue and results wait for the picture.
    var presentsNativeActions = false
    private var heldCues:[OriginalBattleCue] = []
    func takeCues() -> [OriginalBattleCue] { defer { heldCues = [] };return heldCues }
    var peekCues:[OriginalBattleCue] { heldCues }
    /// MAIN3145E: the view runs while the option word's high nibble is clear.
    /// Around it sit the ambush line (MAIN31926), the map's failure line when
    /// the view is off (MAIN31E49..31E6B) and the level notices.
    private func holdCombat(_ snapshot:OriginalCombatSnapshot?,ambush:Bool?,experience:OriginalExperienceMutation?,
                            then lines:[OriginalBattleNotice] = []) throws -> Bool {
        var cues:[OriginalBattleCue] = []
        if let snapshot = snapshot {
            if ambush == true { cues.append(.notice(.ambush(friendly:snapshot.attackerSlot < 15))) }
            if session.sourceOptionsWord&0xF0 == 0 { cues.append(.combat(snapshot)) }
            else if snapshot.kind == 2,snapshot.damage == 0 { cues.append(.notice(.strategyFailed(person:snapshot.attackerPerson))) }
            if let experience = experience {
                cues += try session.levelNotices(person:snapshot.attackerPerson,experience:experience).map { .notice($0) }
            }
        }
        return hold(cues+lines.map { .notice($0) })
    }
    /// Upkeep lines come before the next phase takes the screen.
    private func holdUpkeep() -> Bool {
        defer { session.upkeepNotices = [] }
        return hold(session.upkeepNotices.map { .notice($0) })
    }
    private func hold(_ cues:[OriginalBattleCue]) -> Bool {
        guard presentsNativeActions,!cues.isEmpty else { return false }
        heldCues = cues;suspended = true;return true
    }
    var canLeaveBattle:Bool { session.turns.result != 0 && !suspended && attackOperation == nil && strategyOperation == nil && itemOperation == nil }
    init(session:OriginalBattleSession) { self.session = session }
    var acceptsManualInput:Bool { !suspended && attackOperation == nil && strategyOperation == nil && itemOperation == nil && session.turns.stage == .manualFriendly && session.turns.result == 0 }
    @discardableResult
    func manualAttack(_ slot:Int,target:Int) throws -> OriginalStrikeExchange? {
        try beginManualAttack(slot,target:target)
        return try finishManualOperation().attack
    }
    /// The view plays these cues between the two halves of a manual action.
    @discardableResult
    func beginManualAttack(_ slot:Int,target:Int) throws -> [OriginalBattleCue] {
        guard acceptsManualInput else { throw BattleError.illegalAction("Original source phase is not accepting manual input") }
        _ = try session.requireManualUnit(slot)
        attackOperation = try OriginalAttackOperation.begin(in:session,attackerSlot:slot,targetSlot:target)
        attackIsNative = false;lastAttack = nil
        return try session.attackCues(slot,target:target)
    }
    func finishManualOperation() throws -> (attack:OriginalStrikeExchange?,strategy:OriginalStrategyExecution?) {
        try drivePhases();return (lastAttack,lastStrategy)
    }
    func manualWait(_ slot:Int) throws {
        guard acceptsManualInput else { throw BattleError.illegalAction("Original source phase is not accepting manual input") }
        _ = try session.waitManually(slot);try finishManualAction(slot)
    }
    /// MAIN2E0E6..2E833. A source refusal finishes without consuming the item
    /// or the unit's action. Nil means retirement dialogue is pending.
    @discardableResult
    func manualItem(_ slot:Int,item:Int,target:Int? = nil,confirmed:Bool = true) throws -> OriginalItemExecution? {
        guard acceptsManualInput else { throw BattleError.illegalAction("Original source phase is not accepting manual input") }
        _ = try session.requireManualUnit(slot)
        itemOperation = try OriginalItemOperation.begin(in:session,userSlot:slot,item:item,target:target,confirmed:confirmed)
        lastItem = nil;try drivePhases();return lastItem
    }
    /// MAIN2DF80..2E01B: a completed gift ends the unit's action like a wait.
    /// False leaves the unit able to act because the receiver is full.
    func manualGive(_ slot:Int,to target:Int,item:Int) throws -> Bool {
        guard acceptsManualInput else { throw BattleError.illegalAction("Original source phase is not accepting manual input") }
        let unit = try session.requireManualUnit(slot)
        guard let receiver = session.units[target],!receiver.enemy,receiver.status == 2 else {
            throw BattleError.illegalAction("Original gift target must be a live friendly unit")
        }
        guard try session.people.giveItem(from:unit.person,to:receiver.person,item:item) else { return false }
        try manualWait(slot);return true
    }
    /// MAIN2DDAD..2DDCB clears the hidden state; the unit may still act.
    func manualReleaseAmbush(_ slot:Int) throws {
        guard acceptsManualInput else { throw BattleError.illegalAction("Original source phase is not accepting manual input") }
        let unit = try session.requireManualUnit(slot)
        guard unit.scriptFlags&0x20 == 0 else { throw BattleError.illegalAction("Original unit is not in ambush") }
        session.units[slot]!.scriptFlags |= 0x20
    }
    @discardableResult
    func manualStrategy(_ slot:Int,abilityID:Int,target:Int?) throws -> OriginalStrategyExecution? {
        try beginManualStrategy(slot,abilityID:abilityID,target:target)
        return try finishManualOperation().strategy
    }
    @discardableResult
    func beginManualStrategy(_ slot:Int,abilityID:Int,target:Int?) throws -> [OriginalBattleCue] {
        guard acceptsManualInput else { throw BattleError.illegalAction("Original source phase is not accepting manual input") }
        _ = try session.requireManualUnit(slot)
        strategyOperation = try OriginalStrategyOperation.begin(in:session,casterSlot:slot,abilityID:abilityID,target:target)
        strategyIsNative = false;lastStrategy = nil
        return strategyOperation?.cues(in:session) ?? []
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
    private var pendingDefeatCheck = false
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
            case .target(let effect):
                if try holdCombat(effect.combat,ambush:effect.ambush,experience:effect.experience,then:operation.notices(for:effect)) { return false }
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
    private func advanceItem() throws -> Bool {
        while var operation = itemOperation {
            if let notice = itemRetirementAcknowledgement {
                guard try objectives() else { return false }
                try operation.resumeRetirement(notice);itemRetirementAcknowledgement = nil
            }
            let step = try operation.advance(in:session);itemOperation = operation
            switch step {
            case .target(let effect):
                if try holdCombat(effect.combat,ambush:effect.ambush,experience:effect.experience) { return false }
            case .retirement(let notice):
                itemRetirementAcknowledgement = notice
                guard try objectives() else { return false }
            case .finished(let result):
                lastItem = result;itemOperation = nil
                if result.completed { pendingManualSlot = result.userSlot }
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
            case .context(let effect):
                if try holdCombat(effect.combat,ambush:effect.ambush,experience:effect.experience) { return false }
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
    /// True when the source flow may continue. The check survives a unit hook
    /// that suspended for its script.
    private func checkDefeatedEnemies() throws -> Bool {
        guard pendingDefeatCheck else { return true }
        pendingDefeatCheck = false
        guard let value = session.enemiesDefeatedHook() else { return true }
        return try hook(value)
    }
    private func finishManualAction(_ slot:Int) throws {
        pendingManualSlot = slot
        try drivePhases()
    }
    private func drivePhases() throws {
        guard !suspended else { return }
        if attackOperation != nil { guard try advanceAttack() else { return } }
        if strategyOperation != nil { guard try advanceStrategy() else { return } }
        if itemOperation != nil { guard try advanceItem() else { return } }
        if pendingManualSlot != nil {
            guard try objectives() else { return }
            let slot = pendingManualSlot!;pendingManualSlot = nil
            pendingDefeatCheck = true
            if session.turns.result == 0,try !hook(session.sourceUnitHook(slot)) { return }
        }
        guard try checkDefeatedEnemies() else { return }
        if session.turns.result != 0 { pendingNativeSlot = nil;return }
        while !suspended,session.turns.result == 0 {
            switch session.turns.stage {
            case .unstarted,.roundComplete:
                guard let value = try session.beginRound() else {
                    // MAIN281A4: the turn limit ran out.
                    _ = hold([.notice(.delayRetreat)]);return
                }
                if try !hook(value) { return }
            case .roundEvent:
                if try !hook(session.prepareFriendlyRound()) { return }
                if holdUpkeep() { return }
            case .globalEvent:try session.enterManualFriendly();return
            case .manualFriendly:return
            case .friendlyAI:
                try nativeActions();if suspended || session.turns.result != 0 { if !suspended { pendingNativeSlot = nil };return }
                try session.prepareEnemyPhase()
                if holdUpkeep() { return }
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
                if let value = try session.completeNativeUnit(slot) {
                    pendingDefeatCheck = true
                    if try !hook(value) { return }
                }
                guard try checkDefeatedEnemies() else { return }
                if session.turns.result != 0 { return }
                continue
            }
            guard let slot = session.turns.pendingAI.first else { return }
            guard let unit = session.units[slot],unit.status == 2,unit.orderMode != 7,unit.scriptFlags&0x80 == 0 else {
                try session.skipNativeUnit(slot);continue
            }
            let decision = try session.aiDecision(slot)
            let walk:[OriginalBattleCue] = decision.path.count > 1 ? [.walk(slot:slot,path:decision.path,sound:try session.walkSound(slot))] : []
            try session.applyAIMovement(slot,decision)
            if let strategy = decision.strategyID {
                strategyOperation = try OriginalStrategyOperation.begin(in:session,casterSlot:slot,abilityID:strategy,target:decision.targetSlot)
                strategyIsNative = true;lastStrategy = nil
                // MAIN2E8A9: a computer caster announces itself first.
                let used:[OriginalBattleCue] = [.notice(.strategyUsed(person:unit.person,ability:strategy))]
                if hold(walk+used+(strategyOperation?.cues(in:session) ?? [])) { return }
                guard try advanceStrategy() else { return }
            } else {
                if let target = decision.targetSlot {
                    attackOperation = try OriginalAttackOperation.begin(in:session,attackerSlot:slot,targetSlot:target)
                    attackIsNative = true;lastAttack = nil
                    if hold(walk+(try session.attackCues(slot,target:target))) { return }
                    guard try advanceAttack() else { return }
                } else {
                    pendingNativeSlot = slot
                    if hold(walk) { return }
                }
            }
        }
    }
}
