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
struct OriginalRetirementNotice:Codable,Equatable {
    var sequence:Int
    var runtimeSlot:Int
    var person:Int
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
    private(set) var retirements:[OriginalRetirementNotice] = []
    private var nextRetirementSequence = 0
    private var movementOrigins:[Int:GridPoint] = [:]
    private func movementFacing(_ flags:UInt8,path:[GridPoint]) throws -> UInt8 {
        guard path.count >= 2 else { return flags }
        let a = path[path.count-2],b = path[path.count-1]
        let direction = b.x > a.x ? 1 : b.x < a.x ? 3 : b.y < a.y ? 0 : 2
        return try OriginalBattleSprites.movementFlags(flags,direction:direction)
    }

    init(definition:BattleDefinition,roster:inout OriginalRoster,people:OriginalPeople,
         combat:OriginalCombatTables,movement:OriginalMovementProfile,rng:OriginalRNG,
         carryover:OriginalPartyCarryover? = nil) throws {
        guard let w = definition.width,let h = definition.height,let tiles = definition.tiles,
              (1...127).contains(w),(1...127).contains(h),w*h <= 960,tiles.count == w*h,
              tiles.allSatisfy({(0...255).contains($0)}),let header = roster.header,roster.slots.count == 45 else {
            throw BattleError.invalid("Original source battle geometry/header/roster is incomplete")
        }
        if header.preserveFriendlySlots && carryover == nil {
            throw BattleError.unsupported("Original battle requires preserved friendly live slots; previous state is unavailable")
        }
        // MAIN27057 clears the source occupancy grid before preserved status1
        // units activate. A surviving status2 slot's absent grid entry needs a
        // separate occupancy representation; do not fabricate it from position.
        if header.preserveFriendlySlots,carryover!.liveSlots.contains(where:{$0.slot < 15 && $0.status == 2}) {
            throw BattleError.unsupported("Original preserved status2 slot requires explicit source occupancy state")
        }
        self.definition = definition; self.people = people; self.combat = combat; self.movement = movement
        self.width = w; self.height = h; self.terrain = tiles.map(UInt8.init); self.header = header; self.rng = rng
        if let pictures = definition.pictureTiles,definition.pictureColumns == w*2,definition.pictureRows == h*2,
           pictures.count == w*h*4,pictures.allSatisfy({(0...255).contains($0)}) { pictureTiles = pictures.map(UInt8.init) }
        // The caller owns the one canonical setup table. Commit its changed
        // fallback person words only after every producer and board check pass.
        var preparedRoster = roster
        try people.transaction {
            if header.preserveFriendlySlots {
                let carry = carryover!
                guard carry.liveSlots.count <= 45,Set(carry.liveSlots.map(\.slot)).count == carry.liveSlots.count,
                      carry.liveSlots.allSatisfy({(0..<45).contains($0.slot)}) else {
                    throw BattleError.invalid("Original preserved friendly slot identities are invalid")
                }
                units = Dictionary(uniqueKeysWithValues:carry.liveSlots.map{($0.slot,$0)})
            }
            var friendly = 0,enemy = 15,occupancy:[GridPoint:Int] = [:]
            // MAIN26E86 consumes setup rows in order. Enemy order setters see
            // the live slots reached at that source point, not a later roster.
            for placement in preparedRoster.slots where placement.person != 65535 {
                if placement.person == 0x400 {continue}
                guard (0..<384).contains(placement.person) else {
                    throw BattleError.unsupported("Original dynamic roster identity \(placement.person) is unresolved")
                }
                guard [placement.x,placement.y,placement.flags,placement.rawMode,placement.classID,placement.level].allSatisfy({(0...255).contains($0)}),
                      (0...65535).contains(placement.parameter) else {throw BattleError.invalid("Original setup row exceeds source widths")}
                if !placement.enemy && header.preserveFriendlySlots {continue}
                let slot:Int
                if placement.enemy {slot = enemy;enemy += 1;guard enemy <= 45 else {throw BattleError.invalid("Original enemy slots overflow")}}
                else {slot = friendly;friendly += 1;guard friendly <= 15 else {throw BattleError.invalid("Original friendly slots overflow")}}
                // Source837C sets status1 and MP using the existing shared
                // person. Reset coordinates stayFF until actual activation.
                let initialMP = UInt8(truncatingIfNeeded:try OriginalCombat.maxMP(stats:people.stats(placement.person,morale:100)))
                var unit = OriginalLiveUnit(slot:slot,person:placement.person,position:GridPoint(x:255,y:255),status:1,mp:initialMP)
                if placement.enemy {
                    guard (0..<19).contains(placement.classID) else {throw BattleError.unsupported("Enemy source class is not initialized by a reached replacement producer")}
                    // MAIN2B724 updates class/level, then MP, HP, morale100
                    // and flags20, before the setup row's activation call.
                    try people.update(placement.person) {$0.classID = placement.classID;$0.level = placement.level}
                    unit.mp = UInt8(truncatingIfNeeded:try OriginalCombat.maxMP(stats:people.stats(placement.person,morale:100)))
                    let person = try people.person(placement.person)
                    let maximum = try OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:combat)
                    try people.update(placement.person) {$0.rawTroops = maximum}
                }
                if placement.flags&2 == 0 {
                    _ = try OriginalParty.activate(unit:&unit,classID:people.person(placement.person).classID,
                        requested:GridPoint(x:placement.x,y:placement.y),flipped:placement.flags&4 == 0,
                        movement:movement,width:w,height:h,terrain:terrain,occupancy:&occupancy)
                }
                if !placement.enemy {
                    // Friendly setup repeats MPmax after activation, then HP.
                    unit.mp = UInt8(truncatingIfNeeded:try OriginalCombat.maxMP(stats:people.stats(placement.person,morale:100)))
                    let person = try people.person(placement.person)
                    let maximum = try OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:combat)
                    try people.update(placement.person) {$0.rawTroops = maximum}
                }
                units[slot] = unit
                if placement.enemy {
                    let arguments:[Int]
                    if [0,1,2,3,5].contains(placement.rawMode) {arguments = [placement.person,placement.rawMode,placement.parameter]}
                    else if [4,6].contains(placement.rawMode) {arguments = [placement.person,placement.rawMode,placement.parameter&255,placement.parameter>>8]}
                    else {arguments = [placement.person,placement.rawMode]}
                    _ = try applyScriptAttribute(arguments:arguments)
                }
            }
            // Source26FF0 resets every unused enemy slot after row creation.
            for slot in units.keys where slot >= enemy {units.removeValue(forKey:slot)}
            if header.preserveFriendlySlots {
                let deployed = try OriginalParty.deploy(carryover:carryover!,roster:preparedRoster,people:people,movement:movement,
                    existingUnits:units,width:w,height:h,terrain:terrain)
                units = deployed.units;preparedRoster = deployed.roster
                turns.roundIndex = deployed.roundIndex;turns.weatherIndex = deployed.weatherIndex
            } else {
                // MAIN2711B clears condition4 in all slots and assigns friendly
                // affiliation-based order modes after setup creation.
                for slot in units.keys {
                    units[slot]!.scriptFlags &= ~UInt8(4)
                    if slot < 15 {units[slot]!.orderMode = try people.person(units[slot]!.person).sourceFlags&31 == 0 ? 7 : 1}
                }
            }
            _ = try board()
        }
        roster = preparedRoster
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
        units[slot]!.position = point; units[slot]!.scriptFlags = try movementFacing(unit.scriptFlags|0x40,path:path)
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
    /// Synchronous convenience over the same resumable source contexts used
    /// by campaign flow. Source retirements complete before the next tail reads
    /// the shared context, and acted80 is set only after the outer return.
    func attack(_ slot:Int,target:Int,afterRetirement:((OriginalRetirementNotice)throws->Void)? = nil) throws -> OriginalStrikeExchange {
        var operation = try OriginalAttackOperation.begin(in:self,attackerSlot:slot,targetSlot:target)
        while true {
            switch try operation.advance(in:self) {
            case .context:continue
            case .retirement(let notice):
                try afterRetirement?(notice);try operation.resumeRetirement(notice)
            case .finished(let result):recordAttackExchange(result);return result
            }
        }
    }
    func recordAttackExchange(_ result:OriginalStrikeExchange) {exchanges.append(result)}

    /// MAIN3216F/321E2: one primary or subtype7 recursive context. This is the
    /// sole mutable physical producer; the operation owns recursion/retirement.
    func physicalContext(attackerSlot:Int,targetSlot:Int,subtype:Int) throws -> OriginalAttackContextEffect {
        guard let attacker = units[attackerSlot],let target = units[targetSlot] else {
            throw BattleError.unsupported("Original physical context lost a source live slot")
        }
        let a = try people.stats(attacker.person,morale:attacker.morale),d = try people.stats(target.person,morale:target.morale)
        guard (0..<width).contains(target.position.x),(0..<height).contains(target.position.y) else {
            throw BattleError.unsupported("Original physical target coordinate is outside its source map")
        }
        let prelude = try OriginalCombat.physicalPrelude(classID:a.classID,subtype:subtype,sourceOptionsWord:sourceOptionsWord,rng:&rng)
        let strike = try OriginalCombat.physicalStrike(OriginalPhysicalInput(attacker:a,defender:d,
            terrainID:Int(terrain[target.position.y*width+target.position.x]),subtype:subtype,
            defenderCounterDisabled:target.scriptFlags&2 != 0),tables:combat,rng:&rng)
        let gain = try OriginalCombat.experienceGain(attackerLevel:a.level,defenderLevel:d.level,
            attackerRuntimeSlot:attackerSlot,defenderRuntimeSlot:targetSlot,damage:strike.damage,defenderTroops:d.troops)
        try people.update(target.person) {$0.rawTroops = strike.remainingTroops}
        var morale:OriginalMoraleMutation?
        if strike.damage != d.troops {
            morale = try OriginalCombat.setMorale(stats:d,unitStatus:target.status,conditionFlags:Int(target.scriptFlags),requestedMorale:strike.remainingMorale,rng:&rng)
            units[targetSlot]!.morale = morale!.remainingMorale;units[targetSlot]!.scriptFlags = UInt8(morale!.remainingFlags)
        }
        let experience = try people.applyExperience(person:attacker.person,gain:gain.total)
        return OriginalAttackContextEffect(attackerSlot:attackerSlot,targetSlot:targetSlot,attackerPerson:attacker.person,
            targetPerson:target.person,subtype:subtype,preludeDraws:prelude,strike:strike,morale:morale,experience:experience)
    }
    @discardableResult
    func retireContextTarget(_ slot:Int) throws -> Int? {
        guard let unit = units[slot],unit.status == 2 else { return nil }
        guard try OriginalCombat.shouldRetire(troops:people.person(unit.person).rawTroops,morale:unit.morale,conditionFlags:Int(unit.scriptFlags)) else { return nil }
        return retireUnit(slot)
    }
    /// MAIN2BA64 owns status4 and native order0 target-cache cleanup. Script
    /// removal uses the same producer under flag4, suppressing script notices.
    @discardableResult
    func retireUnit(_ slot:Int) -> Int? {
        guard let unit = units[slot],unit.status == 2 else { return nil }
        units[slot]!.status = 4
        for other in units.keys.sorted() where units[other]!.orderMode == 0 && units[other]!.preferredTarget == slot {
            units[other]!.preferredTarget = nil;units[other]!.orderMode = 1
        }
        if unit.scriptFlags&4 == 0 {
            retirements.append(OriginalRetirementNotice(sequence:nextRetirementSequence,runtimeSlot:slot,person:unit.person))
            nextRetirementSequence += 1
            if let objective = header.objectives.first(where:{$0.enabled && $0.person == unit.person}) {
                objectiveEvents.append(OriginalCampaignEvent(kind:objective.eventKind,arguments:[]))
            }
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
        if unit.position != decision.destination {
            units[slot]!.position = decision.destination;units[slot]!.scriptFlags = try movementFacing(unit.scriptFlags|0x40,path:decision.path)
        }
        try commitAIDecision(slot,decision)
    }
    @discardableResult
    func executeStrategy(_ slot:Int,abilityID:Int,target:Int? = nil,confirmed:Bool = true) throws -> OriginalStrategyExecution {
        let result = try castStrategy(slot,abilityID:abilityID,target:target,confirmed:confirmed)
        recordStrategyExecution(result);return result
    }
    func recordStrategyExecution(_ result:OriginalStrategyExecution) { strategyExecutions.append(result) }
}
