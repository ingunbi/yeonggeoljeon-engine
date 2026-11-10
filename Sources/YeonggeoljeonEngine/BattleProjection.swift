// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// F1 captures values only. There is no session, mutable people owner or RNG.
/// Hidden enemies are removed before either a query or its cache key is made.
struct BattleProjection {
    struct Unit:Equatable {var live:OriginalLiveUnit;var stats:OriginalPersonStats;var name:String;var experience:Int}
    struct Key:Equatable {var width:Int;var height:Int;var terrain:[UInt8];var units:[Unit];var weather:Int}
    // Value copies may advance a bounded hypothetical branch; no live owner is retained.
    var key:Key
    let movement:OriginalMovementProfile
    let combat:OriginalCombatTables
    init(_ session:OriginalBattleSession) throws {
        key = Key(width:session.width,height:session.height,terrain:session.terrain,
            units:try session.units.values.filter {$0.status == 2 && (!$0.enemy || $0.scriptFlags&0x20 != 0)}.sorted {$0.slot < $1.slot}.map {
                Unit(live:$0,stats:try session.people.stats($0.person,morale:$0.morale),name:try session.people.person($0.person).name,experience:try session.people.person($0.person).experience)
            },weather:Int(session.turns.weatherIndex))
        movement = session.movement;combat = session.combat
    }
    func unit(_ slot:Int) throws -> Unit {
        guard let value = key.units.first(where:{$0.live.slot == slot}) else {throw BattleError.invalid("Projection unit is unavailable")}
        return value
    }
    func board(moving slot:Int? = nil,to origin:GridPoint? = nil)->OriginalMovementBoard {
        .init(width:key.width,height:key.height,terrain:key.terrain,actors:key.units.map {
            .init(runtimeSlot:$0.live.slot,position:$0.live.slot == slot ? origin ?? $0.live.position : $0.live.position,
                  classID:$0.stats.classID,scriptFlags:$0.live.scriptFlags,active:true)
        })
    }
    func budget(_ value:Unit) throws -> UInt8 {
        let bonuses = value.stats.itemIDs.compactMap { id in combat.items.first {$0.id == id && $0.category == 4}?.value }
        return try movement.budget(classID:value.stats.classID,equipmentMovementBonuses:bonuses)
    }
    func origins(_ slot:Int) throws -> [(point:GridPoint,cost:Int)] {
        let value = try unit(slot),board = board(),actor = board.actors.first {$0.runtimeSlot == slot}!
        guard value.live.scriptFlags&0x82 == 0 else {return []}
        if value.live.scriptFlags&0x60 != 0x20 {return [(value.live.position,0)]}
        let field = try OriginalMovement.distanceField(profile:movement,board:board,moving:actor,seed:actor.position,limit:budget(value))
        return (0..<key.height).flatMap { y in (0..<key.width).compactMap { x -> (point:GridPoint,cost:Int)? in
            let point = GridPoint(x:x,y:y),cost = Int(field.value(point))
            guard cost != 255,board.occupant(point) == nil || point == actor.position else {return nil}
            return (point,cost)
        }}.sorted { $0.cost == $1.cost ? ($0.point.y == $1.point.y ? $0.point.x < $1.point.x : $0.point.y < $1.point.y) : $0.cost < $1.cost }
    }
    func availableStrategies(_ slot:Int) throws -> [Int] {
        let value = try unit(slot)
        guard value.live.scriptFlags&0x82 == 0,value.live.enemy || value.stats.classID != 17 else {return []}
        return try movement.availableStrategies(classID:value.stats.classID,level:value.stats.level,mp:value.live.mp).filter {
            !($0 < 5 && combat.strategyEnvironmentLookup[key.weather] == 2)
        }
    }
    struct MovePreview:Equatable {var origin:GridPoint;var attackCells:Set<GridPoint>;var attackTargets:[Int];var strategies:[Int:[Int]]}
    func preview(_ slot:Int,at origin:GridPoint) throws -> MovePreview {
        let value = try unit(slot),board = board(moving:slot,to:origin)
        guard value.live.scriptFlags&0x82 == 0,let actor = board.actors.first(where:{$0.runtimeSlot == slot}) else {
            return MovePreview(origin:origin,attackCells:[],attackTargets:[],strategies:[:])
        }
        let cells = Set(try OriginalAI.attackCells(profile:movement,board:board,actor:actor))
        let targets = key.units.filter {$0.live.enemy != value.live.enemy && cells.contains($0.live.position)}.map {$0.live.slot}
        var strategies:[Int:[Int]] = [:]
        for ability in try availableStrategies(slot) {
            let candidates = try OriginalAI.strategyTargetSlots(profile:movement,board:board,actor:actor,abilityID:ability)
            let eligible = try candidates.filter { target in
                let other = try unit(target)
                if ability < 15 {
                    return try movement.strategyTerrainEligible(family:ability/5,terrain:key.terrain[other.live.position.y*key.width+other.live.position.x])
                }
                if (21..<30).contains(ability) {
                    return try OriginalCombat.healingUseful(target:other.stats,conditionFlags:Int(other.live.scriptFlags),
                        recoveryFlags:ability >= 27 ? 3 : ability >= 24 ? 1 : 2,tables:combat)
                }
                return true
            }
            strategies[ability] = eligible
        }
        return MovePreview(origin:origin,attackCells:cells,attackTargets:targets,strategies:strategies)
    }
    struct ThreatMap {var physical:[GridPoint:Set<Int>] = [:];var strategies:[GridPoint:Set<Int>] = [:]
        var cells:Set<GridPoint> {Set(physical.keys).union(strategies.keys)}
        func sources(_ point:GridPoint)->Set<Int> {(physical[point] ?? []).union(strategies[point] ?? [])}
    }
    func threats(only slot:Int? = nil) throws -> ThreatMap {
        var result = ThreatMap()
        for value in key.units where value.live.enemy && (slot == nil || slot == value.live.slot) && value.live.scriptFlags&0x82 == 0 {
            let abilities = try availableStrategies(value.live.slot).filter {$0 < 21}
            let board = board(),actor = board.actors.first {$0.runtimeSlot == value.live.slot}!
            for origin in try origins(value.live.slot) {
                for point in try OriginalAI.attackCells(profile:movement,board:board,actor:actor,origin:origin.point) {
                    result.physical[point,default:[]].insert(value.live.slot)
                }
                for ability in abilities {
                    for point in try OriginalAI.strategyRangeCells(profile:movement,board:board,point:origin.point,abilityID:ability) {
                        if ability < 15,try !movement.strategyTerrainEligible(family:ability/5,terrain:key.terrain[board.index(point)]) {continue}
                        result.strategies[point,default:[]].insert(value.live.slot)
                    }
                }
            }
        }
        return result
    }
    func physical(_ slot:Int,target:Int) throws -> OriginalPhysicalResult {
        let attacker = try unit(slot),defender = try unit(target)
        return try OriginalCombat.physicalImpact(.init(attacker:attacker.stats,defender:defender.stats,
            terrainID:Int(key.terrain[defender.live.position.y*key.width+defender.live.position.x]),
            subtype:OriginalCombat.normalPhysicalSubtype(classID:attacker.stats.classID,tables:combat),
            defenderCounterDisabled:defender.live.scriptFlags&2 != 0),tables:combat)
    }
    enum RecoveryAction:Equatable {case strategy(Int),item(Int)}
    struct RecoveryOption:Equatable {
        var caster:Int;var target:Int;var action:RecoveryAction;var origins:[GridPoint];var cost:Int
        var troops:ClosedRange<Int>;var morale:ClosedRange<Int>;var conditionChance:ClosedRange<Int>?
    }
    func recoveries(target:Int) throws -> [RecoveryOption] {
        let recipient = try unit(target)
        guard !recipient.live.enemy else {return []}
        var results:[RecoveryOption] = []
        for caster in key.units where !caster.live.enemy && caster.live.orderMode == 7 && caster.live.scriptFlags&0x86 == 0 {
            let origins = try origins(caster.live.slot)
            var actions:[(RecoveryAction,Int,Int)] = [] // action, subtype, MP cost
            for ability in try availableStrategies(caster.live.slot) where ability >= 21 {
                let category = movement.strategyCategories![ability]
                let subtype = ability >= 30 ? (((ability-30)%3)<<4)|(ability > 32 ? 1 : 2) :
                    ((category<<4)|(ability >= 27 ? 3 : ability >= 24 ? 1 : 2))&255
                actions.append((.strategy(ability),subtype,movement.strategyMPCosts![ability]))
            }
            for item in Set(caster.stats.itemIDs).sorted() where item != 255 {
                switch OriginalItemUse.of(item) {
                case let .recovery(kind,power),let .areaRecovery(kind,power):actions.append((.item(item),(power<<4)|kind,0))
                default:break
                }
            }
            for (action,subtype,cost) in actions {
                let flags = subtype&15
                guard try OriginalCombat.healingUseful(target:recipient.stats,conditionFlags:Int(recipient.live.scriptFlags),recoveryFlags:flags,tables:combat) else {continue}
                var validOrigins:[GridPoint] = []
                for origin in origins {
                    let projected = board(moving:caster.live.slot,to:origin.point),actor = projected.actors.first {$0.runtimeSlot == caster.live.slot}!
                    let slots:[Int]
                    switch action {
                    case .strategy(let ability):slots = try OriginalAI.strategyTargetSlots(profile:movement,board:projected,actor:actor,abilityID:ability)
                    case .item(let item):
                        let cells = Set(try OriginalAI.rangeCells(profile:movement,board:projected,point:origin.point,raw:OriginalItemUse.of(item).rangeCode!)).union([origin.point])
                        slots = projected.actors.filter {$0.sourceFaction == actor.sourceFaction && cells.contains($0.position)}.map(\.runtimeSlot)
                    }
                    if slots.contains(target) {validOrigins.append(origin.point)}
                }
                guard !validOrigins.isEmpty else {continue}
                let effect = try recoveryEffect(caster:{if case .item = action {return nil};return caster.stats}(),target:recipient,subtype:subtype)
                let chance = effect.conditionPercent.map {Int($0.lowerBound.rounded())...Int($0.upperBound.rounded())}
                results.append(RecoveryOption(caster:caster.live.slot,target:target,action:action,origins:validOrigins,cost:cost,
                    troops:effect.troops,morale:effect.morale,conditionChance:chance))
            }
        }
        return results
    }
}
