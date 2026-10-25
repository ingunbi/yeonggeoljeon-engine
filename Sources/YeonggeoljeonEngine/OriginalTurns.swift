// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum OriginalTurnStage:String,Codable {
    case unstarted, roundEvent, globalEvent, manualFriendly, friendlyAI, enemyAI, roundComplete, finished
}
struct OriginalTurnState:Codable,Equatable {
    var roundIndex = 0
    var weatherIndex:UInt8 = 1
    var stage:OriginalTurnStage = .unstarted
    var result:UInt8 = 0
    var pendingAI:[Int] = []
}
enum OriginalTurnHookKind:String,Codable { case numberedRound, globalConditions, unitConditions }
struct OriginalTurnHook:Codable,Equatable {
    var kind:OriginalTurnHookKind
    var round:Int
    var runtimeSlot:Int?
    var sourcePerson:Int? = nil
}

/// Source turn ordering and phase boundaries. The campaign owner dispatches the
/// returned source hook before calling the next phase method; hooks never stand
/// in for forced victory, elimination, or guessed campaign event conditions.
enum OriginalTurnRules {
    /// MAIN2820C: step toward the original RNG6 value, then swap endpoints.
    static func weather(current:UInt8,draw:Int) throws -> UInt8 {
        guard current <= 5,(0..<6).contains(draw) else { throw BattleError.invalid("Original weather source index/draw") }
        let next = Int(current) + (Int(current) < draw ? 1 : Int(current) > draw ? -1 : 0)
        return UInt8(next == 0 ? 5 : next == 5 ? 0 : next)
    }
    /// MAIN27372 visits each tier in source runtime-slot order.
    static func priorityTier(terrain:UInt8,troops:Int,maximumTroops:Int,morale:Int) -> Int {
        if [8,13,14].contains(terrain) { return 0 }
        if troops <= (maximumTroops/5)*2 || morale < 40 { return 1 }
        return 2
    }
    static func permitsManual(slot:Int,status:Int,mode:UInt8,flags:UInt8) -> Bool {
        (0..<15).contains(slot) && status == 2 && mode == 7 && flags&6 == 0
    }
}

extension OriginalBattleSession {
    /// MAIN280D0..281A4: weather is drawn before the numbered-turn script hook.
    /// A source event may finish the battle while the hook is being dispatched.
    func beginRound() throws -> OriginalTurnHook? {
        guard [.unstarted,.roundComplete].contains(turns.stage),turns.result == 0 else {
            throw BattleError.illegalAction("Original round cannot begin in its current source stage")
        }
        if turns.roundIndex >= header.turnLimit {
            turns.result = 3; turns.stage = .finished; return nil
        }
        turns.weatherIndex = try OriginalTurnRules.weather(current:turns.weatherIndex,draw:rng.next(bound:6))
        turns.stage = .roundEvent
        return OriginalTurnHook(kind:.numberedRound,round:turns.roundIndex+1,runtimeSlot:nil)
    }
    /// MAIN27312: clear both action bits in all live source slots, then visit
    /// every friendly slot, including absent/inactive ones, for recovery draws.
    func prepareFriendlyRound() throws -> OriginalTurnHook {
        guard turns.stage == .roundEvent,turns.result == 0 else {
            throw BattleError.illegalAction("Original numbered-round event must precede friendly upkeep")
        }
        for slot in units.keys { units[slot]!.scriptFlags &= ~UInt8(0xC0) }
        for slot in 0..<15 { try sourceUpkeep(slot) }
        turns.stage = .globalEvent
        return OriginalTurnHook(kind:.globalConditions,round:turns.roundIndex+1,runtimeSlot:nil)
    }
    /// MAIN27AEB: friendly condition recovery occurs after the global wrapper
    /// and before manual input, in source slot order.
    func enterManualFriendly() throws {
        guard turns.stage == .globalEvent,turns.result == 0 else {
            throw BattleError.illegalAction("Original global condition event must precede manual input")
        }
        for slot in 0..<15 { try sourceConditionRecovery(slot) }
        turns.stage = .manualFriendly
    }
    func requireManualUnit(_ slot:Int) throws -> OriginalLiveUnit {
        let unit = try live(slot)
        guard turns.stage == .manualFriendly,turns.result == 0,
              OriginalTurnRules.permitsManual(slot:slot,status:unit.status,mode:unit.orderMode,flags:unit.scriptFlags) else {
            throw BattleError.illegalAction("Original unit is outside the manual friendly input gate")
        }
        return unit
    }
    /// Source command4 (wait) sets80 and leaves morale unchanged.
    func waitManually(_ slot:Int) throws -> OriginalTurnHook {
        let unit = try requireManualUnit(slot)
        guard unit.scriptFlags&0x80 == 0 else { throw BattleError.illegalAction("Original unit already completed its action") }
        units[slot]!.scriptFlags |= 0x80
        commitMove(slot)
        return sourceUnitHook(slot)
    }
    func sourceUnitHook(_ slot:Int) -> OriginalTurnHook {
        OriginalTurnHook(kind:.unitConditions,round:turns.roundIndex+1,runtimeSlot:slot,sourcePerson:units[slot]?.person)
    }
    func finishManualFriendly() throws {
        guard turns.stage == .manualFriendly,turns.result == 0 else {
            throw BattleError.illegalAction("Original manual phase cannot finish in its current stage")
        }
        turns.pendingAI = try sourceAIOrder(enemy:false)
        turns.stage = .friendlyAI
    }
    /// MAIN274BC: each enemy slot recovers, then attempts condition2 recovery,
    /// before source priority is assigned to the enemy side.
    func prepareEnemyPhase() throws {
        guard turns.stage == .friendlyAI,turns.pendingAI.isEmpty,turns.result == 0 else {
            throw BattleError.illegalAction("Original friendly AI actions must precede enemy upkeep")
        }
        for slot in 15..<45 { try sourceUpkeep(slot); try sourceConditionRecovery(slot) }
        turns.pendingAI = try sourceAIOrder(enemy:true)
        turns.stage = .enemyAI
    }
    /// The owner executes movement/attack and dispatches this unit's source
    /// event hook before accepting the next pending slot.
    func completeNativeUnit(_ slot:Int) throws -> OriginalTurnHook? {
        guard [.friendlyAI,.enemyAI].contains(turns.stage),turns.pendingAI.first == slot,turns.result == 0 else {
            throw BattleError.illegalAction("Original native AI unit is out of source priority order")
        }
        turns.pendingAI.removeFirst()
        guard let unit = units[slot],unit.scriptFlags&0xC0 != 0 else { return nil }
        return sourceUnitHook(slot)
    }
    /// Source2754C rechecks each slot's priority/order, and C3B0 rejects
    /// inactive or already-acted units before its post-action event wrapper.
    func skipNativeUnit(_ slot:Int) throws {
        guard [.friendlyAI,.enemyAI].contains(turns.stage),turns.pendingAI.first == slot,turns.result == 0 else {
            throw BattleError.illegalAction("Original skipped AI unit is out of source priority order")
        }
        if let unit = units[slot],unit.status == 2,unit.orderMode != 7,unit.scriptFlags&0x80 == 0 {
            throw BattleError.illegalAction("Original native unit still has an executable source turn")
        }
        turns.pendingAI.removeFirst()
    }
    func completeRound() throws {
        guard turns.stage == .enemyAI,turns.pendingAI.isEmpty,turns.result == 0 else {
            throw BattleError.illegalAction("Original enemy AI actions must precede round completion")
        }
        turns.roundIndex += 1; turns.stage = .roundComplete
    }
    func acceptSourceResult(_ result:UInt8) throws {
        guard result != 0 else { throw BattleError.illegalAction("Original battle result is absent") }
        turns.result = result; turns.stage = .finished; turns.pendingAI = []
    }
    func sourceAIOrder(enemy:Bool) throws -> [Int] {
        var candidates:[(slot:Int,tier:Int)] = []
        for unit in units.values.sorted(by:{$0.slot < $1.slot}) where unit.enemy == enemy && unit.status == 2 {
            let person = try people.person(unit.person)
            let maximum = try OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:combat)
            let tier = OriginalTurnRules.priorityTier(terrain:terrain[unit.position.y*width+unit.position.x],
                troops:person.rawTroops,maximumTroops:maximum,morale:unit.morale)
            candidates.append((unit.slot,tier))
        }
        candidates.sort {$0.tier == $1.tier ? $0.slot < $1.slot : $0.tier < $1.tier}
        // Inactive source slots may occupy priority numbers, but do not execute
        // actions or consume AI RNG. Omitting them preserves active ordering.
        return candidates.map(\.slot).filter { units[$0]!.orderMode != 7 }
    }
    private func sourceConditionRecovery(_ slot:Int) throws {
        guard let unit = units[slot] else { return }
        let stats = unit.status == 2 ? try people.stats(unit.person,morale:unit.morale) : nil
        let result = try OriginalCombat.recoverCondition2(stats:stats,unitStatus:unit.status,
            conditionFlags:Int(unit.scriptFlags),rng:&rng)
        units[slot]!.scriptFlags = UInt8(result.remainingFlags)
    }
    private func sourceUpkeep(_ slot:Int) throws {
        let unit = units[slot]
        let active = unit?.status == 2
        let stats = active ? try people.stats(unit!.person,morale:unit!.morale) : nil
        let terrainID = active ? Int(terrain[unit!.position.y*width+unit!.position.x]) : nil
        let recovery = try OriginalCombat.recover(OriginalRecoveryInput(stats:stats,terrainID:terrainID,
            unitStatus:unit?.status ?? 0,conditionFlags:Int(unit?.scriptFlags ?? 0)),tables:combat,rng:&rng)
        guard active,let unit = unit else { return }
        if let troops = recovery.remainingTroops { try people.update(unit.person) { $0.rawTroops = troops } }
        if let morale = recovery.remainingMorale { units[slot]!.morale = morale }
        // The combat owner includes the morale setter's immediate condition2
        // mutation before this source class12 aura is applied.
        units[slot]!.scriptFlags = UInt8(recovery.remainingFlags)
        if recovery.adjacentMPGain > 0 {
            for delta in movement.cardinalOffsets {
                let point = GridPoint(x:unit.position.x+delta.dx,y:unit.position.y+delta.dy)
                guard let neighbor = units.values.first(where:{$0.status == 2 && $0.position == point}) else { continue }
                let stats = try people.stats(neighbor.person,morale:neighbor.morale)
                let mp = try OriginalCombat.applyMPGain(current:Int(neighbor.mp),gain:recovery.adjacentMPGain,stats:stats)
                units[neighbor.slot]!.mp = UInt8(mp)
            }
        }
    }
}

struct OriginalTurnEventProbe:Codable,Equatable {
    var primary:OriginalCampaignEvent
    var friendlyFallback:OriginalCampaignEvent?
}
extension OriginalTurnHook {
    func campaignEvent() throws -> OriginalCampaignEvent {
        switch kind {
        case .numberedRound:return OriginalCampaignEvent(kind:9,arguments:[round])
        case .globalConditions:return OriginalCampaignEvent(kind:0,arguments:[])
        case .unitConditions:throw BattleError.invalid("Original unit hooks require ordered coordinate/region/adjacency probes")
        }
    }
}
extension OriginalBattleSession {
    /// Source2C032 probes kind6, kind11, then kind4 in cardinal direction order.
    /// A failed friendly-person lookup tries the source0x400 wildcard. The host
    /// requests each probe after the preceding script finishes so native script
    /// mutations to position and roster are observed by the next lookup.
    func sourceUnitProbe(_ slot:Int,kind:Int,direction:Int? = nil,sourcePerson:Int? = nil) throws -> OriginalTurnEventProbe? {
        guard let unit = units[slot],unit.status == 2,unit.scriptFlags&4 == 0 else { return nil }
        let person = sourcePerson ?? unit.person
        let arguments:[Int]
        if kind == 6 || kind == 11 {
            arguments = [person,unit.position.x,unit.position.y]
        } else if kind == 4,let direction = direction,(0..<4).contains(direction) {
            let delta = movement.cardinalOffsets[direction]
            let point = GridPoint(x:unit.position.x+delta.dx,y:unit.position.y+delta.dy)
            guard let neighbor = units.values.first(where:{$0.status == 2 && $0.position == point}) else { return nil }
            arguments = [person,neighbor.person]
        } else { throw BattleError.invalid("Original unit event probe kind/direction") }
        var fallback = arguments; fallback[0] = 0x400
        return OriginalTurnEventProbe(primary:OriginalCampaignEvent(kind:kind,arguments:arguments),
            friendlyFallback:unit.enemy ? nil : OriginalCampaignEvent(kind:kind,arguments:fallback))
    }
}
