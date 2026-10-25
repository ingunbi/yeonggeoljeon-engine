// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct OriginalLiveUnit:Codable,Equatable {
    var slot:Int; var person:Int; var position:GridPoint; var status:Int
    var scriptFlags:UInt8 = 0x20
    var orderMode:UInt8 = 0
    var preferredTarget:Int?
    var goal:GridPoint?
    var morale = 100
    var mp:UInt8
    var aiPriority:UInt8 = 255
    var enemy:Bool { slot >= 15 }
}
struct OriginalStrikeExchange:Codable {
    var attackerSlot:Int; var targetSlot:Int
    var preludeDraws:[Int]
    var strike:OriginalPhysicalResult
    var experience:OriginalExperienceMutation
    var counter:OriginalPhysicalResult?
    var counterExperience:OriginalExperienceMutation?
    var fallenPeople:[Int]
    var rngBefore:UInt32; var rngAfter:UInt32
}

/// Executable original battle kernels. Campaign objectives remain source
/// events; generic elimination and prototype AI never substitute for them.
final class OriginalBattleSession {
    let definition:BattleDefinition
    let people:OriginalPeople
    let combat:OriginalCombatTables
    let movement:OriginalMovementProfile
    let header:OriginalBattleHeader
    let width:Int; let height:Int; var terrain:[UInt8]
    var pictureTiles:[UInt8]?
    var units:[Int:OriginalLiveUnit] = [:]
    var rng:OriginalRNG
    var turns = OriginalTurnState()
    var scriptActions = OriginalScriptActionState()
    var scriptValue24:UInt8 = 0 // MAIN27038 initial value; script2B selector4 ->3413C byte store.
    var sourceOptionsWord:Int = 0 // MAIN1A423 initial object+4; saved/user settings are separate.
    private(set) var exchanges:[OriginalStrikeExchange] = []
    private(set) var strategyExecutions:[OriginalStrategyExecution] = []
    var objectiveEvents:[OriginalCampaignEvent] = []
    private var movementOrigins:[Int:GridPoint] = [:]

    init(definition:BattleDefinition,roster:OriginalRoster,people:OriginalPeople,
         combat:OriginalCombatTables,movement:OriginalMovementProfile,rng:OriginalRNG) throws {
        guard let w = definition.width,let h = definition.height,let tiles = definition.tiles,
              (1...127).contains(w),(1...127).contains(h),w*h <= 960,tiles.count == w*h,
              tiles.allSatisfy({(0...255).contains($0)}),let header = roster.header,roster.slots.count == 45 else {
            throw BattleError.invalid("Original source battle geometry/header/roster is incomplete")
        }
        guard !header.preserveFriendlySlots else { throw BattleError.unsupported("Original battle requires preserved friendly live slots; previous state is unavailable in this isolated constructor") }
        self.definition = definition; self.people = people; self.combat = combat; self.movement = movement
        self.width = w; self.height = h; self.terrain = tiles.map(UInt8.init); self.header = header; self.rng = rng
        if let pictures = definition.pictureTiles,definition.pictureColumns == w*2,definition.pictureRows == h*2,
           pictures.count == w*h*4,pictures.allSatisfy({(0...255).contains($0)}) { pictureTiles = pictures.map(UInt8.init) }
        var friendly = 0,enemy = 15
        for placement in roster.slots where placement.person != 65535 {
            if placement.person == 0x400 { continue }
            guard (0..<384).contains(placement.person) else { throw BattleError.unsupported("Original dynamic roster identity \(placement.person) is unresolved") }
            let slot:Int
            if placement.enemy { slot = enemy; enemy += 1; guard enemy <= 45 else { throw BattleError.invalid("Original enemy slots overflow") } }
            else { slot = friendly; friendly += 1; guard friendly <= 15 else { throw BattleError.invalid("Original friendly slots overflow") } }
            if placement.enemy {
                guard (0..<19).contains(placement.classID) else { throw BattleError.unsupported("Enemy source class is not initialized by a reached replacement producer") }
                try people.update(placement.person) { $0.classID = placement.classID; $0.level = placement.level }
            }
            let person = try people.person(placement.person)
            let maxTroops = try OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:combat)
            try people.update(placement.person) { $0.rawTroops = maxTroops }
            let mp = UInt8(truncatingIfNeeded:try OriginalCombat.maxMP(stats:people.stats(placement.person,morale:100)))
            units[slot] = OriginalLiveUnit(slot:slot,person:placement.person,
                position:GridPoint(x:placement.x,y:placement.y),status:placement.flags&2 == 0 ? 2 : 1,mp:mp)
            if placement.flags&2 == 0,placement.flags&4 == 0 { units[slot]!.scriptFlags |= 0x10 }
            if slot < 15 { units[slot]!.orderMode = person.sourceFlags&31 == 0 ? 7 : 1 }
        }
        // Enemy order goals are resolved after all45 live slots exist. Source
        // person-target lookup returns the first matching slot, including reserves.
        for placement in roster.slots where placement.person != 65535 && placement.enemy {
            guard let slot = units.keys.sorted().first(where:{units[$0]?.person == placement.person}),
                  var unit = units[slot],try people.person(unit.person).sourceFlags&31 != 0 else { continue }
            unit.orderMode = try movement.orderMode(rawMode:UInt8(placement.rawMode),currentMode:unit.orderMode)
            if [3,5].contains(placement.rawMode) {
                unit.preferredTarget = units.keys.sorted().first(where:{units[$0]?.person == placement.parameter})
            } else if [4,6].contains(placement.rawMode) {
                let goal = GridPoint(x:placement.parameter&255,y:placement.parameter>>8)
                if (0..<w).contains(goal.x),(0..<h).contains(goal.y),
                   try movement.cost(classID:people.person(unit.person).classID,terrain:tiles[goal.y*w+goal.x]) != 255 {
                    unit.goal = goal; unit.preferredTarget = nil
                }
            }
            unit.scriptFlags &= ~UInt8(4); units[slot] = unit
        }
        _ = try board()
    }
    func live(_ slot:Int) throws -> OriginalLiveUnit {
        guard let unit = units[slot],unit.status == 2 else {
            throw BattleError.illegalAction("Original unit slot does not have active source status2")
        }
        return unit
    }
    func board() throws -> OriginalMovementBoard {
        let actors = try units.values.sorted(by:{$0.slot < $1.slot}).filter({$0.status == 2}).map { unit in
            OriginalMovementActor(runtimeSlot:unit.slot,position:unit.position,classID:try people.person(unit.person).classID,
                                  scriptFlags:unit.scriptFlags,active:true)
        }
        let board = OriginalMovementBoard(width:width,height:height,terrain:terrain,actors:actors)
        if let actor = actors.first(where:{$0.active}) { try board.validate(profile:movement,moving:actor) }
        return board
    }
    func movementBudget(_ slot:Int) throws -> UInt8 {
        let person = try people.person(live(slot).person)
        let bonuses = person.itemIDs.filter{$0 != 255}.compactMap { id in combat.items.first(where:{$0.id == id && $0.category == 4})?.value }
        return try movement.budget(classID:person.classID,equipmentMovementBonuses:bonuses)
    }
    func reachable(_ slot:Int) throws -> [GridPoint] {
        let board = try board()
        guard let actor = board.actors.first(where:{$0.runtimeSlot == slot}) else { return [] }
        let field = try OriginalMovement.distanceField(profile:movement,board:board,moving:actor,seed:actor.position,limit:movementBudget(slot))
        return (0..<height).flatMap { y in (0..<width).compactMap { x -> GridPoint? in
            let point = GridPoint(x:x,y:y)
            return field.value(point) != 255 && (board.occupant(point) == nil || point == actor.position) ? point : nil
        }}
    }
    @discardableResult
    func move(_ slot:Int,to point:GridPoint) throws -> [GridPoint] {
        let unit = try live(slot)
        guard unit.scriptFlags&0xC2 == 0 else { throw BattleError.illegalAction("Original moved/acted/condition flag prevents movement") }
        let board = try board(), actor = board.actors.first(where:{$0.runtimeSlot == slot})!
        let path = try OriginalMovement.route(profile:movement,board:board,moving:actor,to:point,budget:movementBudget(slot))
        movementOrigins[slot] = unit.position
        units[slot]!.position = point; units[slot]!.scriptFlags |= 0x40
        return path
    }
    func cancelMove(_ slot:Int) throws {
        let unit = try requireManualUnit(slot)
        guard unit.scriptFlags&0x80 == 0,let origin = movementOrigins.removeValue(forKey:slot) else { return }
        units[slot]!.position = origin; units[slot]!.scriptFlags &= ~UInt8(0x40)
    }
    func commitMove(_ slot:Int) { movementOrigins.removeValue(forKey:slot) }
    func attackStats() throws -> [OriginalAICombatStats] {
        try units.values.filter({$0.status == 2}).sorted(by:{$0.slot < $1.slot}).map { unit in
            let value = try people.stats(unit.person,morale:unit.morale)
            return OriginalAICombatStats(runtimeSlot:unit.slot,attack:try OriginalCombat.attackStat(value,tables:combat),
                defense:try OriginalCombat.defenseStat(value,tables:combat),currentTroops:value.troops)
        }
    }
    /// Caller supplies the source command subtype until that producing boundary
    /// is known. No fabricated critical-hit or nearest-enemy fallback exists.
    func attack(_ slot:Int,target:Int) throws -> OriginalStrikeExchange {
        let attacker = try live(slot),defender = try live(target)
        guard attacker.enemy != defender.enemy,attacker.scriptFlags&0x80 == 0 else { throw BattleError.illegalAction("Original physical attack faction/action state") }
        let board = try board(),actor = board.actors.first(where:{$0.runtimeSlot == slot})!
        guard try OriginalAI.attackCells(profile:movement,board:board,actor:actor).contains(defender.position) else {
            throw BattleError.illegalAction("Target is outside the original class range pattern")
        }
        let before = rng.state
        let attackerStats = try people.stats(attacker.person,morale:attacker.morale)
        let defenderStats = try people.stats(defender.person,morale:defender.morale)
        let subtype = try OriginalCombat.normalPhysicalSubtype(classID:attackerStats.classID,tables:combat)
        let prelude = try OriginalCombat.physicalPrelude(classID:attackerStats.classID,subtype:subtype,sourceOptionsWord:sourceOptionsWord,rng:&rng)
        let strike = try OriginalCombat.physicalStrike(OriginalPhysicalInput(attacker:attackerStats,defender:defenderStats,
            terrainID:Int(terrain[defender.position.y*width+defender.position.x]),subtype:subtype,
            defenderCounterDisabled:defender.scriptFlags&2 != 0),tables:combat,rng:&rng)
        let gain = try OriginalCombat.experienceGain(attackerLevel:attackerStats.level,defenderLevel:defenderStats.level,
            attackerRuntimeSlot:slot,defenderRuntimeSlot:target,damage:strike.damage,defenderTroops:defenderStats.troops)
        try people.update(defender.person) { $0.rawTroops = strike.remainingTroops }
        if strike.remainingTroops != 0 {
            let morale = try OriginalCombat.setMorale(stats:defenderStats,unitStatus:defender.status,
                conditionFlags:Int(defender.scriptFlags),requestedMorale:strike.remainingMorale,rng:&rng)
            units[target]!.morale = morale.remainingMorale; units[target]!.scriptFlags = UInt8(morale.remainingFlags)
        }
        let experience = try people.applyExperience(person:attacker.person,gain:gain.total)
        var counter:OriginalPhysicalResult?,counterExperience:OriginalExperienceMutation?
        if strike.counterEligible && units[target]!.scriptFlags&2 == 0 {
            // EXP/class/HP aliases are reread after source writeback, before the
            // recursive subtype7 producer. Morale remains a live-unit value.
            let a = try people.stats(defender.person,morale:units[target]!.morale)
            let d = try people.stats(attacker.person,morale:units[slot]!.morale)
            let result = try OriginalCombat.physicalStrike(OriginalPhysicalInput(attacker:a,defender:d,
                terrainID:Int(terrain[attacker.position.y*width+attacker.position.x]),subtype:7,
                defenderCounterDisabled:attacker.scriptFlags&2 != 0),tables:combat,rng:&rng)
            let gain = try OriginalCombat.experienceGain(attackerLevel:a.level,defenderLevel:d.level,
                attackerRuntimeSlot:target,defenderRuntimeSlot:slot,damage:result.damage,defenderTroops:d.troops)
            try people.update(attacker.person) { $0.rawTroops = result.remainingTroops }
            if result.remainingTroops != 0 {
                let morale = try OriginalCombat.setMorale(stats:d,unitStatus:attacker.status,
                    conditionFlags:Int(units[slot]!.scriptFlags),requestedMorale:result.remainingMorale,rng:&rng)
                units[slot]!.morale = morale.remainingMorale; units[slot]!.scriptFlags = UInt8(morale.remainingFlags)
            }
            counter = result; counterExperience = try people.applyExperience(person:defender.person,gain:gain.total)
        }
        units[slot]!.scriptFlags |= 0x80
        movementOrigins.removeValue(forKey:slot)
        var fallen:[Int] = []
        // Recursive counter context checks its target first, then the outer
        // context checks its own target. Shared aliases are not scanned.
        for id in (counter == nil ? [target] : [slot,target]) where units[id]?.status == 2 {
            if let person = try retireContextTarget(id) { fallen.append(person) }
        }
        let result = OriginalStrikeExchange(attackerSlot:slot,targetSlot:target,preludeDraws:prelude,strike:strike,
            experience:experience,counter:counter,counterExperience:counterExperience,fallenPeople:fallen,rngBefore:before,rngAfter:rng.state)
        exchanges.append(result); return result
    }
    @discardableResult
    func retireContextTarget(_ slot:Int) throws -> Int? {
        guard let unit = units[slot],unit.status == 2 else { return nil }
        guard try OriginalCombat.shouldRetire(troops:people.person(unit.person).rawTroops,morale:unit.morale,conditionFlags:Int(unit.scriptFlags)) else { return nil }
        units[slot]!.status = 4
        if let objective = header.objectives.first(where:{$0.enabled && $0.person == unit.person}) {
            objectiveEvents.append(OriginalCampaignEvent(kind:objective.eventKind,arguments:[]))
        }
        return unit.person
    }
    func aiDecision(_ slot:Int) throws -> OriginalAIDecision {
        let unit = try live(slot),board = try board(),person = try people.person(unit.person)
        let actor = board.actors.first(where:{$0.runtimeSlot == slot})!
        let strategyStats = try units.values.filter{$0.status == 2}.sorted{$0.slot < $1.slot}.map { unit in
            OriginalAIStrategyStats(runtimeSlot:unit.slot,stats:try people.stats(unit.person,morale:unit.morale))
        }
        let context = OriginalAIStrategyContext(stats:strategyStats,tables:combat,weatherCode:Int(turns.weatherIndex),rngState:rng.state)
        let decision = try OriginalAI.decision(profile:movement,board:board,actor:actor,mode:unit.orderMode,
            movementBudget:movementBudget(slot),level:person.level,mp:unit.mp,morale:UInt8(unit.morale),
            maximumTroops:OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:combat),
            stats:attackStats(),terrainDefensePercent:combat.terrainDefensePercent,preferredTarget:unit.preferredTarget,goal:unit.goal,strategyContext:context)
        return decision
    }
    func commitAIDecision(_ slot:Int,_ decision:OriginalAIDecision) throws {
        guard units[slot]?.position == decision.destination else { throw BattleError.invalid("Original AI plan has not reached its selected position") }
        units[slot]!.orderMode = decision.mode;units[slot]!.preferredTarget = decision.preferredTarget
        if let goal = decision.changedGoal { units[slot]!.goal = goal }
        commitMove(slot)
    }
    func applyAIMovement(_ slot:Int,_ decision:OriginalAIDecision) throws {
        let unit = try live(slot)
        guard decision.path.first == unit.position,decision.path.last == decision.destination,
              decision.path.count <= width*height+1 else { throw BattleError.invalid("Original AI path identity/extent is stale") }
        let board = try board()
        for (index,point) in decision.path.enumerated() {
            guard board.contains(point) else { throw BattleError.invalid("Original AI path leaves its source map") }
            if index > 0 {
                let prior = decision.path[index-1]
                guard movement.cardinalOffsets.contains(where:{point.x-prior.x == $0.dx && point.y-prior.y == $0.dy}) else {
                    throw BattleError.invalid("Original AI path step is not a source neighbor")
                }
            }
        }
        if let occupant = board.occupant(decision.destination),occupant.runtimeSlot != slot { throw BattleError.invalid("Original AI destination became occupied") }
        if let rngAfter = decision.rngAfter { rng.state = rngAfter }
        if unit.position != decision.destination { units[slot]!.position = decision.destination;units[slot]!.scriptFlags |= 0x40 }
        try commitAIDecision(slot,decision)
    }
    @discardableResult
    func executeStrategy(_ slot:Int,abilityID:Int,target:Int? = nil,confirmed:Bool = true) throws -> OriginalStrategyExecution {
        let result = try castStrategy(slot,abilityID:abilityID,target:target,confirmed:confirmed)
        strategyExecutions.append(result);return result
    }
}
