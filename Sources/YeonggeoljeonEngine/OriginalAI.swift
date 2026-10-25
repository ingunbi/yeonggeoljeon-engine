// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum OriginalAIError: Error, CustomStringConvertible {
    case invalid(String), unsupported(String), unreachable(String)
    var description:String {
        switch self {
        case .invalid(let reason): return "Invalid original movement/AI input: \(reason)"
        case .unsupported(let reason): return "Unsupported original AI behavior: \(reason)"
        case .unreachable(let reason): return "Original route unavailable: \(reason)"
        }
    }
}

struct OriginalAIOffset:Codable,Equatable { var dx:Int; var dy:Int }
struct OriginalMovementProfile:Codable {
    var format:Int
    var classMovementTypes:[Int]
    var classMovementBudgets:[Int]
    var attackRangeCodes:[Int]
    var movementCosts:[[Int]]
    var cardinalOffsets:[OriginalAIOffset]
    var diagonalOffsets:[OriginalAIOffset]
    var extendedOffsets:[OriginalAIOffset]
    var setupOrderModes:[Int]?
    var strategyLevelRequirements:[[Int]]?
    var strategyMPCosts:[Int]?
    var strategyCategories:[Int]?
    var strategyTerrainEligibility:[[Int]]?
    var scriptEnvironment:OriginalScriptEnvironmentTables?
    var source:JSONValue?
    var limitations:[String]?

    static func load(from url:URL) throws -> OriginalMovementProfile {
        let value = try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
        try value.validate(); return value
    }
    func validate() throws {
        guard format == 1, classMovementTypes.count == 19,
              classMovementBudgets.count == 19, attackRangeCodes.count == 19,
              movementCosts.count == 4,
              classMovementTypes.allSatisfy({(0..<4).contains($0)}),
              classMovementBudgets.allSatisfy({(0...255).contains($0)}),
              attackRangeCodes.allSatisfy({(0...255).contains($0)}),
              movementCosts.allSatisfy({$0.count == 256 && $0.allSatisfy({(0...255).contains($0)})}) else {
            throw OriginalAIError.invalid("lookup dimensions or byte domain")
        }
        if let modes = setupOrderModes, modes.count != 256 || !modes.allSatisfy({(0...255).contains($0)}) {
            throw OriginalAIError.invalid("raw setup order mode window")
        }
        let strategyFields = [strategyLevelRequirements != nil,strategyMPCosts != nil,strategyCategories != nil]
        if strategyFields.contains(true) {
            guard strategyFields.allSatisfy({$0}), let levels = strategyLevelRequirements,
                  let costs = strategyMPCosts, let categories = strategyCategories,
                  levels.count == 36, levels.allSatisfy({$0.count == 19 && $0.allSatisfy({(0...255).contains($0)})}),
                  costs.count == 36, categories.count == 36,
                  (costs+categories).allSatisfy({(0...255).contains($0)}) else {
                throw OriginalAIError.invalid("strategy availability lookup dimensions")
            }
        }
        if let terrain = strategyTerrainEligibility,
           terrain.count != 3 || terrain.contains(where:{$0.count != 4 || !$0.allSatisfy({(0...255).contains($0)})}) {
            throw OriginalAIError.invalid("strategy terrain eligibility lookup")
        }
        try scriptEnvironment?.validate()
        for offsets in [cardinalOffsets,diagonalOffsets,extendedOffsets] {
            guard offsets.count == 4, Set(offsets.map{"\($0.dx),\($0.dy)"}).count == 4,
                  offsets.allSatisfy({(-1...1).contains($0.dx) && (-1...1).contains($0.dy) && ($0.dx != 0 || $0.dy != 0)}) else {
                throw OriginalAIError.invalid("source neighbor/range offsets")
            }
        }
    }
    /// The source setter accepts only modes0...7; other table values leave the
    /// current mode unchanged. Goal/person lookup is owned by native placement.
    func orderMode(rawMode:UInt8,currentMode:UInt8) throws -> UInt8 {
        guard let modes = setupOrderModes, modes.count == 256 else {
            throw OriginalAIError.unsupported("source setup order lookup is absent")
        }
        let candidate = modes[Int(rawMode)]
        return candidate <= 7 ? UInt8(candidate) : currentMode
    }
    /// C9BC flags4 visits all36 IDs in ascending order, then writes FF.
    func availableStrategies(classID:Int,level:Int,mp:UInt8) throws -> [Int] {
        guard (0..<19).contains(classID), (0...255).contains(level),
              let levels = strategyLevelRequirements, let costs = strategyMPCosts,
              levels.count == 36, costs.count == 36,
              levels.allSatisfy({$0.count == 19}) else {
            throw OriginalAIError.unsupported("source strategy availability is absent or invalid")
        }
        return (0..<36).filter { levels[$0][classID] <= level && costs[$0] <= Int(mp) }
    }
    /// A392 keeps all four byte comparisons, including an FF byte matching
    /// literal raw terrain255. These are not a terminated list.
    func strategyTerrainEligible(family:Int,terrain:UInt8) throws -> Bool {
        guard (0..<3).contains(family),let rows = strategyTerrainEligibility,
              rows.count == 3,rows.allSatisfy({$0.count == 4}) else {
            throw OriginalAIError.unsupported("source strategy terrain eligibility is absent")
        }
        return rows[family].contains(Int(terrain))
    }
    func cost(classID:Int,terrain:Int) throws -> Int {
        guard classMovementTypes.indices.contains(classID), (0...255).contains(terrain) else {
            throw OriginalAIError.invalid("class or raw terrain index")
        }
        return movementCosts[classMovementTypes[classID]][terrain]
    }
    /// MAIN2B17E: the maximum category4 equipment value is added once.
    /// The caller owns item-category interpretation; values are not summed.
    func budget(classID:Int,equipmentMovementBonuses:[Int]) throws -> UInt8 {
        guard classMovementBudgets.indices.contains(classID), equipmentMovementBonuses.count <= 8,
              equipmentMovementBonuses.allSatisfy({(0...255).contains($0)}) else {
            throw OriginalAIError.invalid("movement budget class/equipment")
        }
        return UInt8(truncatingIfNeeded:classMovementBudgets[classID]+(equipmentMovementBonuses.max() ?? 0))
    }
}

struct OriginalMovementActor:Codable,Equatable {
    var runtimeSlot:Int
    var position:GridPoint
    var classID:Int
    var scriptFlags:UInt8
    var active:Bool
    /// MAIN28486 reads unit+2, the source runtime index, then compares15.
    var sourceFaction:Int { runtimeSlot < 15 ? 1 : 0 }
}
struct OriginalMovementBoard:Codable {
    var width:Int; var height:Int; var terrain:[UInt8]; var actors:[OriginalMovementActor]
    func contains(_ point:GridPoint)->Bool {
        (0..<width).contains(point.x) && (0..<height).contains(point.y)
    }
    func index(_ point:GridPoint)->Int { point.y*width+point.x }
    func occupant(_ point:GridPoint)->OriginalMovementActor? {
        actors.first {$0.active && $0.position == point}
    }
    func validate(profile:OriginalMovementProfile,moving:OriginalMovementActor) throws {
        try profile.validate()
        guard (1...127).contains(width), (1...127).contains(height), terrain.count == width*height, terrain.count <= 960,
              Set(actors.map(\.runtimeSlot)).count == actors.count,
              actors.allSatisfy({(0..<45).contains($0.runtimeSlot) && contains($0.position) && (0..<19).contains($0.classID)}),
              contains(moving.position), (0..<45).contains(moving.runtimeSlot),
              (0..<19).contains(moving.classID), moving.active,
              actors.first(where:{$0.runtimeSlot == moving.runtimeSlot}) == moving else {
            throw OriginalAIError.invalid("source board, slot, class, activation or actor identity")
        }
        let active = actors.filter(\.active)
        guard Set(active.map(\.position)).count == active.count else {
            throw OriginalAIError.invalid("source occupancy has duplicate active cells")
        }
    }
}
struct OriginalDistanceField:Codable,Equatable {
    var width:Int; var height:Int; var seed:GridPoint; var limit:UInt8
    var distances:[UInt8]
    var stoppedAtRequestedCell:Bool
    var assignmentOrder:[GridPoint] = []
    func value(_ point:GridPoint)->UInt8 { distances[point.y*width+point.x] }
}

enum OriginalMovement {
    static func hasHostileAdjacent(_ point:GridPoint,faction:Int,board:OriginalMovementBoard,
                                   profile:OriginalMovementProfile)->Bool {
        profile.cardinalOffsets.contains { delta in
            let p = GridPoint(x:point.x+delta.dx,y:point.y+delta.dy)
            return board.contains(p) && board.occupant(p).map{$0.sourceFaction != faction} == true
        }
    }

    /// C9BC's distance-layer scan. A cell's terrain cost is read with its raw
    /// byte index. Friendly occupants do not block expansion; hostile ones do.
    /// The ordinary seed may leave hostile ZOC, but later ZOC cells do not expand.
    static func distanceField(profile:OriginalMovementProfile,board:OriginalMovementBoard,
                              moving:OriginalMovementActor,seed:GridPoint,limit:UInt8,
                              stoppingAt:GridPoint? = nil,ignoreZOC:Bool = false) throws -> OriginalDistanceField {
        try board.validate(profile:profile,moving:moving)
        guard board.contains(seed), stoppingAt.map(board.contains) ?? true else {
            throw OriginalAIError.invalid("distance seed/stop outside source map")
        }
        var distances = Array(repeating:UInt8.max,count:board.terrain.count)
        var assignmentOrder = [seed]
        distances[board.index(seed)] = 0
        if stoppingAt == seed {
            // The source returns FF before clearing its prior shared scratch
            // field. This stateless API cannot invent the previous contents.
            throw OriginalAIError.unsupported("seed-equals-target field retains prior source scratch state")
        }
        if try profile.cost(classID:moving.classID,terrain:Int(board.terrain[board.index(seed)])) == 255 {
            return OriginalDistanceField(width:board.width,height:board.height,seed:seed,limit:limit,
                                         distances:distances,stoppedAtRequestedCell:false,assignmentOrder:assignmentOrder)
        }
        var level = 0
        while level < Int(limit) {
            var changed = false, nextLevel = 255
            for y in 0..<board.height {
                for x in 0..<board.width {
                    let current = GridPoint(x:x,y:y)
                    guard distances[board.index(current)] == UInt8(level) else { continue }
                    if current != seed && !ignoreZOC && moving.scriptFlags&4 == 0 &&
                        hasHostileAdjacent(current,faction:moving.sourceFaction,board:board,profile:profile) { continue }
                    for delta in profile.cardinalOffsets {
                        let neighbor = GridPoint(x:x+delta.dx,y:y+delta.dy)
                        guard board.contains(neighbor), distances[board.index(neighbor)] == 255 else { continue }
                        let cost = try profile.cost(classID:moving.classID,terrain:Int(board.terrain[board.index(neighbor)]))
                        guard cost != 255, level+cost <= Int(limit) else { continue }
                        if let occupant = board.occupant(neighbor), occupant.sourceFaction != moving.sourceFaction { continue }
                        let distance = level+cost
                        distances[board.index(neighbor)] = UInt8(distance)
                        assignmentOrder.append(neighbor)
                        changed = true; nextLevel = min(nextLevel,distance)
                        if neighbor == stoppingAt {
                            return OriginalDistanceField(width:board.width,height:board.height,seed:seed,limit:limit,
                                distances:distances,stoppedAtRequestedCell:true,assignmentOrder:assignmentOrder)
                        }
                    }
                }
            }
            if !changed { break }
            level = nextLevel
        }
        return OriginalDistanceField(width:board.width,height:board.height,seed:seed,limit:limit,
                                     distances:distances,stoppedAtRequestedCell:false,assignmentOrder:assignmentOrder)
    }

    /// C772 chooses the first strictly smaller neighbor in source direction
    /// order. The current cell may be FF, so this helper does not reject it.
    static func descendingTrace(profile:OriginalMovementProfile,board:OriginalMovementBoard,
                                moving:OriginalMovementActor,field:OriginalDistanceField,
                                from:GridPoint,toward:GridPoint,budget:UInt8 = 255) throws -> OriginalRouteTrace {
        try board.validate(profile:profile,moving:moving)
        guard board.contains(from), board.contains(toward), field.width == board.width,
              field.height == board.height, field.distances.count == board.terrain.count else {
            throw OriginalAIError.invalid("descending route geometry")
        }
        var current = from, remaining = Int(budget), path = [from]
        while current != toward {
            var best:GridPoint?, bestDistance = Int(field.value(current)), bestCost = 0
            for delta in profile.cardinalOffsets {
                let neighbor = GridPoint(x:current.x+delta.dx,y:current.y+delta.dy)
                guard board.contains(neighbor) else { continue }
                if neighbor != toward && moving.scriptFlags&4 == 0 &&
                    hasHostileAdjacent(neighbor,faction:moving.sourceFaction,board:board,profile:profile) { continue }
                let distance = Int(field.value(neighbor))
                guard distance < bestDistance else { continue }
                let cost = try profile.cost(classID:moving.classID,terrain:Int(board.terrain[board.index(neighbor)]))
                guard cost <= remaining else { continue }
                best = neighbor; bestDistance = distance; bestCost = cost
            }
            guard let next = best else { return OriginalRouteTrace(path:path,complete:false) }
            current = next; remaining -= bestCost; path.append(next)
            guard path.count <= board.terrain.count+1 else { throw OriginalAIError.invalid("descending source route did not terminate") }
        }
        return OriginalRouteTrace(path:path,complete:true)
    }
    static func descendingPath(profile:OriginalMovementProfile,board:OriginalMovementBoard,
                               moving:OriginalMovementActor,field:OriginalDistanceField,
                               from:GridPoint,toward:GridPoint,budget:UInt8 = 255) throws -> [GridPoint] {
        let trace = try descendingTrace(profile:profile,board:board,moving:moving,field:field,
            from:from,toward:toward,budget:budget)
        guard trace.complete else { throw OriginalAIError.unreachable("no strict-lower source neighbor within the route budget") }
        return trace.path
    }

    /// Player-route composition: first establish reachability using C9BC from
    /// the unit, then trace destination→unit and reverse it, as C772 does.
    static func route(profile:OriginalMovementProfile,board:OriginalMovementBoard,moving:OriginalMovementActor,
                      to target:GridPoint,budget:UInt8,requireFreeDestination:Bool = true) throws -> [GridPoint] {
        try board.validate(profile:profile,moving:moving)
        guard board.contains(target) else { throw OriginalAIError.invalid("route target outside source map") }
        if target == moving.position { return [target] }
        if requireFreeDestination, board.occupant(target) != nil {
            throw OriginalAIError.unreachable("destination is occupied")
        }
        let field = try distanceField(profile:profile,board:board,moving:moving,seed:moving.position,limit:budget)
        guard field.value(target) != 255 else { throw OriginalAIError.unreachable("destination outside source distance field") }
        let reverse = try descendingPath(profile:profile,board:board,moving:moving,field:field,from:target,toward:moving.position)
        return reverse.reversed()
    }
}

struct OriginalRouteTrace { var path:[GridPoint]; var complete:Bool }

struct OriginalAICombatStats:Codable,Equatable {
    var runtimeSlot:Int; var attack:Int; var defense:Int; var currentTroops:Int
}
struct OriginalAITargetCandidate:Codable,Equatable { var runtimeSlot:Int; var rawScore:UInt16; var weight:UInt8 }
struct OriginalAIPhysicalChoice:Codable,Equatable {
    var targetSlot:Int?; var weight:UInt8; var candidates:[OriginalAITargetCandidate]
}

enum OriginalAI {
    /// Source C018 range enumeration, including its non-Manhattan patterns.
    /// The returned order is meaningful to target-score tie handling.
    static func attackCells(profile:OriginalMovementProfile,board:OriginalMovementBoard,
                            actor:OriginalMovementActor,origin:GridPoint? = nil) throws -> [GridPoint] {
        try board.validate(profile:profile,moving:actor)
        return try rangeCells(profile:profile,board:board,point:origin ?? actor.position,
                              raw:profile.attackRangeCodes[actor.classID])
    }
    private static func rangeCells(profile:OriginalMovementProfile,board:OriginalMovementBoard,
                                   point:GridPoint,raw:Int) throws -> [GridPoint] {
        guard board.contains(point),(0...255).contains(raw) else { throw OriginalAIError.invalid("attack origin/range code") }
        if raw == 255 { return [] }
        let extended = raw&128 != 0
        let range = (raw&127)+(extended ? 1 : 0)
        var offsets:[OriginalAIOffset] = []
        if range <= 1 || extended { offsets += profile.cardinalOffsets }
        if range >= 1 { offsets += profile.diagonalOffsets }
        if range == 2 { offsets += profile.extendedOffsets.map { OriginalAIOffset(dx:$0.dx*2,dy:$0.dy*2) } }
        if range >= 3 {
            for x in -1...1 { offsets += [OriginalAIOffset(dx:x,dy:-2),OriginalAIOffset(dx:x,dy:2)] }
            for y in -1...1 { offsets += [OriginalAIOffset(dx:2,dy:y),OriginalAIOffset(dx:-2,dy:y)] }
        }
        if range == 4 {
            offsets += profile.extendedOffsets.map { OriginalAIOffset(dx:$0.dx*3,dy:$0.dy*3) }
            offsets += profile.diagonalOffsets.map { OriginalAIOffset(dx:$0.dx*2,dy:$0.dy*2) }
        }
        return offsets.map { GridPoint(x:point.x+$0.dx,y:point.y+$0.dy) }.filter(board.contains)
    }

    /// C616 prediction score, not inflicted combat damage. Terrain percentages
    /// are supplied by the combat table owner. Word-width operations are kept.
    static func targetScore(attacker:OriginalMovementActor,attackerStats:OriginalAICombatStats,
                            defender:OriginalMovementActor,defenderStats:OriginalAICombatStats,
                            terrainDefensePercent:Int,preferredTarget:Int?) throws -> UInt16 {
        guard attacker.runtimeSlot == attackerStats.runtimeSlot, defender.runtimeSlot == defenderStats.runtimeSlot,
              (0..<19).contains(attacker.classID), (0..<19).contains(defender.classID),
              [attackerStats.attack,attackerStats.currentTroops,defenderStats.defense].allSatisfy({(0...65535).contains($0)}),
              (0...255).contains(terrainDefensePercent) else { throw OriginalAIError.invalid("AI target score quantities/identity") }
        if attacker.sourceFaction == defender.sourceFaction { return 0 }
        let a = attacker.classID/3, d = defender.classID/3
        var defense = UInt16(defenderStats.defense)
        if (a == 0 && d == 1) || (a == 1 && d == 2) || (a == 2 && d == 0) { defense = defense &- (defense>>2) }
        if (d == 0 && a == 1) || (d == 1 && a == 2) || (d == 2 && a == 0) { defense = defense &+ (defense>>2) }
        let half = Int(defense>>1)
        let prediction:Int32 = attackerStats.attack > half ?
            (Int32(attackerStats.attack-half)*Int32(100-terrainDefensePercent))/100 : 1
        var score = UInt16(attackerStats.currentTroops/6)
        if preferredTarget == defender.runtimeSlot { score = score &+ 30 }
        return score &+ UInt16(truncatingIfNeeded:prediction)
    }

    /// C58E: candidates follow C018's range order, weights use low8(score>>4),
    /// zero becomes one, and equal weights retain the earlier candidate.
    static func physicalAttackChoice(profile:OriginalMovementProfile,board:OriginalMovementBoard,
                                     actor:OriginalMovementActor,origin:GridPoint? = nil,
                                     stats:[OriginalAICombatStats],terrainDefensePercent:[Int],
                                     preferredTarget:Int?) throws -> OriginalAIPhysicalChoice {
        guard terrainDefensePercent.count == 256, terrainDefensePercent.allSatisfy({(0...255).contains($0)}),
              Set(stats.map(\.runtimeSlot)).count == stats.count,
              let attackerStats = stats.first(where:{$0.runtimeSlot == actor.runtimeSlot}) else {
            throw OriginalAIError.invalid("combat lookup owner/stats identities")
        }
        var selected:Int?, weight:UInt8 = 0, candidates:[OriginalAITargetCandidate] = []
        for point in try attackCells(profile:profile,board:board,actor:actor,origin:origin) {
            guard let target = board.occupant(point), target.sourceFaction != actor.sourceFaction else { continue }
            guard let targetStats = stats.first(where:{$0.runtimeSlot == target.runtimeSlot}) else {
                throw OriginalAIError.unsupported("target combat quantities are unresolved")
            }
            let score = try targetScore(attacker:actor,attackerStats:attackerStats,defender:target,defenderStats:targetStats,
                terrainDefensePercent:terrainDefensePercent[Int(board.terrain[board.index(point)])],preferredTarget:preferredTarget)
            let candidateWeight = max(1,UInt8(truncatingIfNeeded:score>>4))
            candidates.append(OriginalAITargetCandidate(runtimeSlot:target.runtimeSlot,rawScore:score,weight:candidateWeight))
            if candidateWeight > weight { selected = target.runtimeSlot; weight = candidateWeight }
        }
        return OriginalAIPhysicalChoice(targetSlot:selected,weight:weight,candidates:candidates)
    }
}

struct OriginalAIDecision:Codable,Equatable {
    var mode:UInt8
    var destination:GridPoint
    var path:[GridPoint]
    var targetSlot:Int?
    var positionWeight:UInt8
    var activatedByInfluence:Bool
    var preferredTarget:Int? = nil
    var changedGoal:GridPoint? = nil
    var strategyID:Int? = nil
    var rngAfter:UInt32? = nil
}

extension OriginalAI {
    /// C2BE marks source-opponent range cells in ascending runtime-slot order.
    /// It intentionally uses the moving actor's range code for every opponent.
    static func influenceGrid(profile:OriginalMovementProfile,board:OriginalMovementBoard,
                              actor:OriginalMovementActor) throws -> [Int?] {
        try board.validate(profile:profile,moving:actor)
        var result = Array<Int?>(repeating:nil,count:board.terrain.count)
        for opponent in board.actors.sorted(by:{$0.runtimeSlot < $1.runtimeSlot}) where
            opponent.active && opponent.sourceFaction != actor.sourceFaction {
            for point in try attackCells(profile:profile,board:board,actor:actor,origin:opponent.position) {
                result[board.index(point)] = opponent.runtimeSlot
            }
        }
        return result
    }

    private static func firstInfluence(_ field:OriginalDistanceField,grid:[Int?],board:OriginalMovementBoard) -> Int? {
        for point in field.assignmentOrder.dropFirst() {
            if let slot = grid[board.index(point)],
               let opponent = board.actors.first(where:{$0.runtimeSlot == slot}),
               opponent.scriptFlags&0x20 != 0 { return slot }
        }
        return nil
    }
    /// C4F2's recursive bonus visits N/E/S/W and only writes an empty baseline
    /// cell once. Recursion crosses blocked terrain; the source gates the write,
    /// rather than the recursion, on occupancy and the raw defense lookup.
    private static func addGoalBonus(_ point:GridPoint,strength:Int,baseline:inout [UInt8],
                                     board:OriginalMovementBoard,profile:OriginalMovementProfile,
                                     terrainDefensePercent:[Int]) {
        guard strength > 0,board.contains(point) else { return }
        let index = board.index(point)
        if terrainDefensePercent[Int(board.terrain[index])] != 255 && baseline[index] == 0 && board.occupant(point) == nil {
            baseline[index] = UInt8(truncatingIfNeeded:strength)
        }
        for delta in profile.cardinalOffsets {
            addGoalBonus(GridPoint(x:point.x+delta.dx,y:point.y+delta.dy),strength:strength-20,
                baseline:&baseline,board:board,profile:profile,terrainDefensePercent:terrainDefensePercent)
        }
    }
    /// CD4A/C018 executes the selected target if still present in source range;
    /// an absent/unselected target falls through to the final range candidate.
    static func executionTarget(profile:OriginalMovementProfile,board:OriginalMovementBoard,
                                actor:OriginalMovementActor,origin:GridPoint? = nil,selected:Int?) throws -> Int? {
        let targets = try attackCells(profile:profile,board:board,actor:actor,origin:origin).compactMap { point -> Int? in
            guard let target = board.occupant(point),target.sourceFaction != actor.sourceFaction else { return nil }
            return target.runtimeSlot
        }
        if let selected = selected,targets.contains(selected) { return selected }
        return targets.last
    }
    /// Source C3B0/CD00 native orders0...4. Every ordinary movement branch feeds
    /// one D6F8 evaluator. Strategy scoring consumes a copied source RNG state;
    /// execution remains a separate owner from the returned plan.
    static func decision(profile:OriginalMovementProfile,board:OriginalMovementBoard,
                         actor:OriginalMovementActor,mode:UInt8,movementBudget:UInt8,
                         level:Int,mp:UInt8,morale:UInt8,maximumTroops:Int,
                         stats:[OriginalAICombatStats],terrainDefensePercent:[Int],
                         preferredTarget:Int?,goal:GridPoint? = nil,
                         strategyContext:OriginalAIStrategyContext? = nil) throws -> OriginalAIDecision {
        try board.validate(profile:profile,moving:actor)
        guard mode <= 4 else { throw OriginalAIError.unsupported("native order mode\(mode) controller") }
        guard terrainDefensePercent.count == 256,terrainDefensePercent.allSatisfy({(0...255).contains($0)}),
              (0...65535).contains(maximumTroops),
              let ownStats = stats.first(where:{$0.runtimeSlot == actor.runtimeSlot}) else {
            throw OriginalAIError.invalid("native AI combat/terrain state")
        }
        if actor.scriptFlags&0x82 != 0 {
            return OriginalAIDecision(mode:mode,destination:actor.position,path:[actor.position],
                targetSlot:nil,positionWeight:0,activatedByInfluence:false)
        }
        var effectiveMode = mode,preferred = preferredTarget
        if let target = preferred,board.actors.first(where:{$0.runtimeSlot == target && $0.active}) == nil {
            preferred = nil;effectiveMode = 1
        }
        let scripted = actor.scriptFlags&4 != 0
        let workingBudget:UInt8 = scripted ? 100 : movementBudget
        if scripted && (effectiveMode == 0 || effectiveMode == 4) {
            guard let target = preferred.flatMap({id in board.actors.first(where:{$0.runtimeSlot == id})?.position}) ?? goal else {
                throw OriginalAIError.unsupported("source scripted goal point/target identity is unresolved")
            }
            var destination = actor.position,path = [actor.position],changedGoal:GridPoint?
            if board.contains(target),target != actor.position {
                if let occupant = board.occupant(target),occupant.sourceFaction == actor.sourceFaction {
                    throw OriginalAIError.unsupported("scripted overlapping friendly destination requires original occupancy-grid ownership")
                }
                let direct = try OriginalMovement.distanceField(profile:profile,board:board,moving:actor,
                    seed:actor.position,limit:255,stoppingAt:target,ignoreZOC:true)
                if direct.stoppedAtRequestedCell {
                    destination = target
                    path = Array(try OriginalMovement.descendingPath(profile:profile,board:board,moving:actor,
                        field:direct,from:target,toward:actor.position).reversed())
                } else { changedGoal = actor.position }
            } else { changedGoal = actor.position }
            if preferred == nil { effectiveMode = 3 }
            return OriginalAIDecision(mode:effectiveMode,destination:destination,path:path,targetSlot:nil,
                positionWeight:0,activatedByInfluence:false,preferredTarget:preferred,changedGoal:changedGoal)
        }
        let influence = try influenceGrid(profile:profile,board:board,actor:actor)
        let field = try OriginalMovement.distanceField(profile:profile,board:board,moving:actor,
            seed:actor.position,limit:effectiveMode == 2 ? 0 : workingBudget)
        let trigger = firstInfluence(field,grid:influence,board:board)
        let needsRecovery = ownStats.currentTroops <= (maximumTroops/5)*2 || morale < 40
        var baseline = board.terrain.map { needsRecovery && [8,13,14].contains(Int($0)) ? UInt8(50) : 0 }
        var evaluate = true
        func approach(_ point:GridPoint) throws -> Bool {
            guard board.contains(point),point != actor.position else { return false }
            let reverse = try OriginalMovement.distanceField(profile:profile,board:board,moving:actor,
                seed:point,limit:255,stoppingAt:actor.position,ignoreZOC:true)
            guard reverse.stoppedAtRequestedCell else { return false }
            let trace = try OriginalMovement.descendingTrace(profile:profile,board:board,moving:actor,
                field:reverse,from:actor.position,toward:point,budget:workingBudget)
            if !trace.complete,let endpoint = trace.path.last {
                addGoalBonus(endpoint,strength:board.occupant(endpoint) == nil ? 30 : 50,
                    baseline:&baseline,board:board,profile:profile,terrainDefensePercent:terrainDefensePercent)
            }
            return true
        }
        func aggressiveBranch() throws -> Bool {
            if trigger != nil { return true }
            let extended = try OriginalMovement.distanceField(profile:profile,board:board,moving:actor,
                seed:actor.position,limit:255)
            guard let slot = firstInfluence(extended,grid:influence,board:board),
                  let target = board.actors.first(where:{$0.runtimeSlot == slot}) else { return false }
            return try approach(target.position)
        }
        switch effectiveMode {
        case 0,4:
            guard let target = preferred.flatMap({id in board.actors.first(where:{$0.runtimeSlot == id})?.position}) ?? goal else {
                throw OriginalAIError.unsupported("source order goal point/target identity is unresolved")
            }
            if preferred != nil && trigger == preferred {
                addGoalBonus(target,strength:50,baseline:&baseline,board:board,profile:profile,terrainDefensePercent:terrainDefensePercent)
            } else {
                addGoalBonus(target,strength:30,baseline:&baseline,board:board,profile:profile,terrainDefensePercent:terrainDefensePercent)
                if try !approach(target) { evaluate = try aggressiveBranch() }
            }
        case 1:evaluate = try aggressiveBranch()
        case 2:break
        case 3:evaluate = trigger != nil
        default:throw OriginalAIError.unsupported("native source order")
        }
        var bestPoint = actor.position,bestWeight:UInt8 = 0,bestTarget:Int?,bestStrategy:Int?
        var strategies:[Int] = []
        var plannerRNG = OriginalRNG(state:strategyContext?.rngState ?? 0)
        var evaluatedStrategies = false
        if evaluate {
            if effectiveMode != 4 && !scripted {
                strategies = try profile.availableStrategies(classID:actor.classID,level:level,mp:mp)
                if !strategies.isEmpty && strategyContext == nil {
                    throw OriginalAIError.unsupported("source strategy context is required for available IDs\(strategies)")
                }
            }
            for point in field.assignmentOrder {
                if scripted && point == actor.position { continue }
                if point != actor.position && board.occupant(point) != nil { continue }
                let terrain = Int(board.terrain[board.index(point)])
                var weight = baseline[board.index(point)],target:Int?,physical:UInt8 = 0
                if effectiveMode != 4 && !scripted && (point == actor.position || influence[board.index(point)] != nil) {
                    let choice = try physicalAttackChoice(profile:profile,board:board,actor:actor,origin:point,
                        stats:stats,terrainDefensePercent:terrainDefensePercent,preferredTarget:preferred)
                    target = choice.targetSlot;physical = choice.weight
                }
                var strategy = OriginalAIStrategyChoice(abilityID:nil,targetSlot:nil,weight:0,candidates:[])
                if !strategies.isEmpty,let context = strategyContext {
                    strategy = try strategyChoice(profile:profile,board:board,actor:actor,origin:point,
                        available:strategies,context:context,preferredTarget:preferred,rng:&plannerRNG)
                    evaluatedStrategies = true
                }
                if !scripted {
                    weight = weight &+ max(physical,strategy.weight)
                    weight += UInt8(min(terrainDefensePercent[terrain]/5,255-Int(weight)))
                    if point == actor.position { weight += UInt8(min(1,255-Int(weight))) }
                }
                baseline[board.index(point)] = weight
                if weight > bestWeight {
                    bestWeight = weight;bestPoint = point
                    if strategy.weight > physical { bestStrategy = strategy.abilityID;bestTarget = strategy.targetSlot }
                    else { bestStrategy = nil;bestTarget = target }
                }
            }
        }
        let path = bestPoint == actor.position ? [actor.position] : Array(try OriginalMovement.descendingPath(
            profile:profile,board:board,moving:actor,field:field,from:bestPoint,toward:actor.position).reversed())
        // Source8A6E turns a reached coordinate goal in modes0/4 into mode3
        // before the final attack gate is read.
        if preferred == nil && [UInt8(0),4].contains(effectiveMode),bestPoint == goal { effectiveMode = 3 }
        let target = scripted || effectiveMode == 4 ? nil : bestStrategy != nil ? bestTarget : try executionTarget(
            profile:profile,board:board,actor:actor,origin:bestPoint,selected:bestTarget)
        return OriginalAIDecision(mode:effectiveMode,destination:bestPoint,path:path,targetSlot:target,
            positionWeight:bestWeight,activatedByInfluence:trigger != nil,preferredTarget:preferred,
            strategyID:bestStrategy,rngAfter:evaluatedStrategies ? plannerRNG.state : nil)
    }
}

struct OriginalAIStrategyStats:Codable,Equatable {
    var runtimeSlot:Int
    var stats:OriginalPersonStats
}
struct OriginalAIStrategyContext:Codable {
    var stats:[OriginalAIStrategyStats]
    var tables:OriginalCombatTables
    /// Raw battle-object weather index, interpreted only by combat's lookup.
    var weatherCode:Int
    var rngState:UInt32
}
struct OriginalAIStrategyCandidate:Codable,Equatable {
    var abilityID:Int
    var targetSlot:Int?
    var rawScore:Int
    var comparisonWeight:Int
    var storedWeight:UInt8
}
struct OriginalAIStrategyChoice:Codable,Equatable {
    var abilityID:Int?
    var targetSlot:Int?
    var weight:UInt8
    var candidates:[OriginalAIStrategyCandidate]
}

extension OriginalAI {
    /// C018 support masks1/81 mark the origin before the surrounding range.
    /// AI origins may differ from the caster's current occupancy; do not move
    /// the caster implicitly while estimating a prospective position.
    static func strategyTargetSlots(profile:OriginalMovementProfile,board:OriginalMovementBoard,
                                    actor:OriginalMovementActor,abilityID:Int,origin:GridPoint? = nil) throws -> [Int] {
        try board.validate(profile:profile,moving:actor)
        guard (0..<36).contains(abilityID),let categories = profile.strategyCategories,categories.count == 36 else {
            throw OriginalAIError.invalid("strategy range category/ability identity")
        }
        let category = categories[abilityID],aggregate = category == 3,point = origin ?? actor.position
        let rangeCode = aggregate ? Int(UInt8(truncatingIfNeeded:(abilityID-30)%3)|0x80) : category|0x80
        if rangeCode == 255 { return [] }
        let friendly = aggregate || abilityID >= 21
        var cells = try rangeCells(profile:profile,board:board,point:point,raw:rangeCode)
        if friendly { cells.insert(point,at:0) }
        return cells.compactMap { cell -> Int? in
            guard let target = board.occupant(cell),
                  (target.sourceFaction == actor.sourceFaction) == friendly else { return nil }
            return target.runtimeSlot
        }
    }
    /// D0FA retains ascending availability order, source range candidate order,
    /// RNG calls for every candidate, strict ties, and byte truncation after a
    /// preferred-target bonus. It predicts utility; it does not execute effects.
    static func strategyChoice(profile:OriginalMovementProfile,board:OriginalMovementBoard,
                               actor:OriginalMovementActor,origin:GridPoint,available:[Int],
                               context:OriginalAIStrategyContext,preferredTarget:Int?,
                               rng:inout OriginalRNG) throws -> OriginalAIStrategyChoice {
        try board.validate(profile:profile,moving:actor)
        guard board.contains(origin),available.allSatisfy({(0..<36).contains($0)}),
              available == available.sorted(),Set(available).count == available.count,
              let categories = profile.strategyCategories,categories.count == 36,
              Set(context.stats.map(\.runtimeSlot)).count == context.stats.count,
              context.stats.count <= 45,(0...255).contains(context.weatherCode),
              board.actors.filter(\.active).allSatisfy({actor in
                  context.stats.first(where:{$0.runtimeSlot == actor.runtimeSlot})?.stats.classID == actor.classID
              }),let caster = context.stats.first(where:{$0.runtimeSlot == actor.runtimeSlot})?.stats else {
            throw OriginalAIError.invalid("source strategy candidate context/availability")
        }
        try context.tables.validate()
        var selected:Int?,targetSlot:Int?,weight:UInt8 = 0,candidates:[OriginalAIStrategyCandidate] = []
        for ability in available {
            let category = categories[ability]
            let aggregate = category == 3
            let targets = try strategyTargetSlots(profile:profile,board:board,actor:actor,abilityID:ability,origin:origin)
                .map { id in board.actors.first(where:{$0.runtimeSlot == id})! }
            if aggregate {
                var total:UInt16 = 0
                let encoded = UInt8(truncatingIfNeeded:(((ability-30)%3)<<4)|(ability > 32 ? 1 : 2))
                for target in targets {
                    let value = context.stats.first(where:{$0.runtimeSlot == target.runtimeSlot})!.stats
                    let score = try OriginalStrategyAI.supportScore(OriginalStrategyAISupportInput(caster:caster,
                        target:value,targetStatus:2,encodedSubtype:Int(encoded)),tables:context.tables,rng:&rng)
                    total = total &+ UInt16(truncatingIfNeeded:score)
                }
                let candidateWeight = min(255,max(0,Int(total)-100)>>4)
                candidates.append(OriginalAIStrategyCandidate(abilityID:ability,targetSlot:nil,rawScore:Int(total),
                    comparisonWeight:candidateWeight,storedWeight:UInt8(candidateWeight)))
                if candidateWeight > Int(weight) { selected = ability;targetSlot = nil;weight = UInt8(candidateWeight) }
            } else {
                for target in targets {
                    let value = context.stats.first(where:{$0.runtimeSlot == target.runtimeSlot})!.stats
                    let terrain = board.terrain[board.index(target.position)]
                    let eligible = ability < 15 ? try profile.strategyTerrainEligible(family:ability/5,terrain:terrain) : true
                    let score = try OriginalStrategyAI.targetScore(OriginalStrategyAITargetInput(caster:caster,target:value,
                        targetStatus:2,targetConditionFlags:Int(target.scriptFlags),abilityID:ability,category:category,
                        terrainID:Int(terrain),terrainEligible:eligible,weatherCode:context.weatherCode),tables:context.tables,rng:&rng)
                    var candidateWeight = min(255,Int(UInt16(truncatingIfNeeded:score))>>4)
                    if candidateWeight != 0 && target.runtimeSlot == preferredTarget { candidateWeight += 30 }
                    let stored = UInt8(truncatingIfNeeded:candidateWeight)
                    candidates.append(OriginalAIStrategyCandidate(abilityID:ability,targetSlot:target.runtimeSlot,
                        rawScore:score,comparisonWeight:candidateWeight,storedWeight:stored))
                    if candidateWeight > Int(weight) { selected = ability;targetSlot = target.runtimeSlot;weight = stored }
                }
            }
        }
        return OriginalAIStrategyChoice(abilityID:selected,targetSlot:targetSlot,weight:weight,candidates:candidates)
    }
}
