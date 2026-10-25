// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Source facts can remain unknown in a catalog. Session construction is the
/// boundary that decides whether those facts support an executable battle.
struct BattleCatalog: Codable {
    var format: Int
    var battles: [BattleDefinition]
    var provenance: JSONValue? = nil
    var limitations: [String]? = nil

    static func load(from url: URL) throws -> BattleCatalog {
        let value = try JSONDecoder().decode(BattleCatalog.self, from: Data(contentsOf: url))
        guard value.format == 1 else { throw BattleError.unsupported("Unknown battle catalog format") }
        guard Set(value.battles.map(\.id)).count == value.battles.count else {
            throw BattleError.invalid("Duplicate battle identity in catalog")
        }
        return value
    }
}

struct BattleDefinition: Codable {
    var id: String
    var name: String? = nil
    var width: Int? = nil
    var height: Int? = nil
    var coordinateSystem: String? = nil
    var tiles: [Int]? = nil
    var image: String? = nil
    var units: [BattleUnitDefinition] = []
    var conditionalUnits: [BattleUnitDefinition]? = nil
    var rosterScope: String? = nil
    var originalRosterComplete: Bool? = nil
    var source: JSONValue? = nil
    var rules: JSONValue? = nil
    var limitations: [String]? = nil
}

struct BattleUnitDefinition: Codable {
    // Export-local placement identity. It is neither a person ID nor a
    // reconstructed DOS runtime slot; original ordinal/allocation facts stay in source.
    var id: Int
    var person: Int? = nil
    var name: String? = nil
    var side: Int? = nil
    var x: Int? = nil
    var y: Int? = nil
    var initiallyActive: Bool? = nil
    var hp: Int? = nil
    var maxHP: Int? = nil
    var attack: Int? = nil
    var defense: Int? = nil
    var movement: Int? = nil
    var range: Int? = nil
    var source: JSONValue? = nil
}

enum BattleError: Error, CustomStringConvertible, Equatable {
    case unsupported(String)
    case invalid(String)
    case illegalAction(String)

    var description: String {
        switch self {
        case .unsupported(let reason): return "Unsupported battle: \(reason)"
        case .invalid(let reason): return "Invalid battle: \(reason)"
        case .illegalAction(let reason): return "Illegal battle action: \(reason)"
        }
    }
}

/// Selecting this policy is mandatory. Experimental mechanics are never used as
/// a fallback for an original-game session or written back over source stats.
enum BattlePolicy: String, Codable {
    case original
    case experimentalV1

    var label: String {
        switch self {
        case .original: return "Original rules (not implemented)"
        case .experimentalV1: return "Experimental engine rules v1 — not original combat rules"
        }
    }
}

struct BattleEffectiveStats: Codable, Equatable {
    var maxHP: Int
    var attack: Int
    var defense: Int
    var movement: Int
    var range: Int
    var origin: String

    static let experimentalV1 = BattleEffectiveStats(maxHP: 100, attack: 25, defense: 5,
        movement: 4, range: 1, origin: "experimental-uniform-v1; original stats preserved separately")
}

enum BattleOutcome: String, Codable { case ongoing, victory, defeat }

struct BattleUnitState: Codable, Equatable {
    var id: Int
    var person: Int?
    var name: String?
    var side: Int
    var position: GridPoint
    var active: Bool
    var hp: Int
    var stats: BattleEffectiveStats
    var moved: Bool
    var acted: Bool

    var alive: Bool { active && hp > 0 }
}

struct BattleReachableCell: Codable, Equatable {
    var position: GridPoint
    var cost: Int
    var path: [GridPoint]
}

struct BattleAttackResult: Codable, Equatable {
    var attacker: Int
    var target: Int
    var damage: Int
    var remainingHP: Int
    var defeated: Bool
    var ruleOrigin: String
}

struct BattleEvent: Codable, Equatable {
    var sequence: Int
    var round: Int
    var side: Int // Faction whose turn produced the event, not necessarily the event unit's faction.
    var operation: String
    var unit: Int?
    var target: Int?
    var path: [GridPoint]?
    var damage: Int?
    var detail: String
}

struct BattleSnapshot: Codable, Equatable {
    var format: Int = 1
    var battle: String
    var policy: BattlePolicy
    var width: Int
    var height: Int
    var round: Int
    var activeSide: Int
    var selectedUnit: Int?
    var outcome: BattleOutcome
    var units: [BattleUnitState]
    var ruleOrigin: String
    var completedActions: Int
    var sourceRosterScope: String? = nil
    var originalRosterComplete: Bool? = nil
    var unresolvedConditionalUnits: Int = 0
}

/// A deterministic, orthogonal tactical engine. This first policy deliberately
/// demonstrates engine mechanics independently from unknown original formulas.
/// Its explicit rules are documented in research/battle-rules.md.
final class BattleSession {
    let definition: BattleDefinition
    let policy: BattlePolicy
    let width: Int
    let height: Int
    private(set) var round = 1
    private(set) var activeSide = 0
    private(set) var selectedUnit: Int?
    private(set) var outcome = BattleOutcome.ongoing
    private(set) var units: [Int: BattleUnitState] = [:]
    private(set) var events: [BattleEvent] = []
    private(set) var completedActions = 0

    init(definition: BattleDefinition, policy: BattlePolicy) throws {
        guard policy == .experimentalV1 else {
            throw BattleError.unsupported("Original damage, class movement costs, AI and objectives have not been implemented; select experimentalV1 explicitly to test the engine")
        }
        guard !definition.id.isEmpty, definition.coordinateSystem == "orthogonal" else {
            throw BattleError.unsupported("Battle identity or established orthogonal coordinate system is missing")
        }
        guard let width = definition.width, let height = definition.height,
              width > 0, height > 0, width <= 256, height <= 256 else {
            throw BattleError.invalid("Grid dimensions exceed the 65,536-cell prototype budget or are unresolved")
        }
        if let tiles = definition.tiles, tiles.count != width * height {
            throw BattleError.invalid("Source tile count does not match battle-cell dimensions")
        }
        guard !definition.units.isEmpty, definition.units.count <= width * height else {
            throw BattleError.invalid("Empty roster or more slots than grid cells")
        }
        self.definition = definition; self.policy = policy
        self.width = width; self.height = height
        var occupied = Set<GridPoint>()
        for original in definition.units {
            guard original.id >= 0, units[original.id] == nil else {
                throw BattleError.invalid("Duplicate or negative unit slot identity")
            }
            guard let side = original.side, side == 0 || side == 1 else {
                throw BattleError.unsupported("Unit slot \(original.id) has an unresolved or unsupported faction")
            }
            guard let active = original.initiallyActive,
                  let x = original.x, let y = original.y, (0..<width).contains(x), (0..<height).contains(y) else {
                throw BattleError.unsupported("Unit slot \(original.id) lacks established activation or in-bounds placement")
            }
            let position = GridPoint(x: x, y: y)
            if active && !occupied.insert(position).inserted {
                throw BattleError.invalid("Two initially active unit slots occupy one battle cell")
            }
            let stats = BattleEffectiveStats.experimentalV1
            units[original.id] = BattleUnitState(id: original.id, person: original.person,
                name: original.name, side: side, position: position, active: active,
                hp: stats.maxHP, stats: stats, moved: false, acted: false)
        }
        guard units.values.contains(where: { $0.alive && $0.side == 0 }),
              units.values.contains(where: { $0.alive && $0.side == 1 }) else {
            throw BattleError.unsupported("An executable prototype requires an established active roster on both sides")
        }
        record("begin", detail: policy.label)
    }

    func snapshot() -> BattleSnapshot {
        BattleSnapshot(battle: definition.id, policy: policy, width: width, height: height,
            round: round, activeSide: activeSide, selectedUnit: selectedUnit, outcome: outcome,
            units: units.values.sorted { $0.id < $1.id }, ruleOrigin: policy.label,
            completedActions: completedActions, sourceRosterScope: definition.rosterScope,
            originalRosterComplete: definition.originalRosterComplete,
            unresolvedConditionalUnits: definition.conditionalUnits?.count ?? 0)
    }

    func select(unit id: Int) throws {
        _ = try actionable(id)
        selectedUnit = id; record("select", unit: id)
    }

    func reachable(unit id: Int? = nil) throws -> [BattleReachableCell] {
        guard let id = id ?? selectedUnit else { throw BattleError.illegalAction("No unit selected") }
        let actor = try actionable(id)
        if actor.moved { return [BattleReachableCell(position: actor.position, cost: 0, path: [actor.position])] }
        return reachableCells(actor)
    }

    @discardableResult
    func move(unit id: Int, to target: GridPoint) throws -> [GridPoint] {
        var actor = try actionable(id)
        guard !actor.moved, !actor.acted else { throw BattleError.illegalAction("The selected unit has already moved or acted") }
        guard target != actor.position else { throw BattleError.illegalAction("A move must change the unit's cell") }
        guard let cell = reachableCells(actor).first(where: { $0.position == target }) else {
            throw BattleError.illegalAction("Destination is occupied, outside the grid, or beyond this policy's movement budget")
        }
        actor.position = target; actor.moved = true; units[id] = actor; completedActions += 1
        record("move", unit: id, path: cell.path)
        return cell.path
    }

    @discardableResult
    func attack(unit id: Int, target targetID: Int) throws -> BattleAttackResult {
        var actor = try actionable(id)
        guard !actor.acted, let target = units[targetID], target.alive, target.side != actor.side else {
            throw BattleError.illegalAction("Attack target is absent, friendly, defeated, or the attacker has acted")
        }
        guard distance(actor.position, target.position) <= actor.stats.range else {
            throw BattleError.illegalAction("Attack target is outside the experimental Manhattan range")
        }
        // Explicit prototype formula, not a translation of KOEI combat code.
        let damage = max(1, actor.stats.attack - target.stats.defense)
        var victim = target; victim.hp = max(0, victim.hp - damage)
        actor.acted = true; actor.moved = true
        units[id] = actor; units[targetID] = victim; completedActions += 1
        let result = BattleAttackResult(attacker: id, target: targetID, damage: damage,
            remainingHP: victim.hp, defeated: victim.hp == 0, ruleOrigin: "experimental-attack-minus-defense-v1")
        record("attack", unit: id, target: targetID, damage: damage, detail: result.ruleOrigin)
        if victim.hp == 0 { record("defeated", unit: targetID) }
        updateOutcome()
        return result
    }

    func wait(unit id: Int) throws {
        var actor = try actionable(id)
        guard !actor.acted else { throw BattleError.illegalAction("The unit has already acted") }
        actor.moved = true; actor.acted = true; units[id] = actor; completedActions += 1
        record("wait", unit: id)
    }

    func endTurn() throws {
        guard outcome == .ongoing else { throw BattleError.illegalAction("The battle has ended") }
        activeSide = 1 - activeSide
        if activeSide == 0 { round += 1 }
        selectedUnit = nil
        for id in units.keys.sorted() where units[id]!.side == activeSide {
            units[id]!.moved = false; units[id]!.acted = false
        }
        record("turn", detail: "Experimental side turn begins")
    }

    /// Deterministic prototype AI: ascending slot order; attack the lowest-HP
    /// adjacent opponent, otherwise move to minimize nearest opponent distance
    /// (ties: lower cost, y, x), then attack or wait. It is not original AI.
    func performEnemyTurn() throws {
        guard activeSide == 1, outcome == .ongoing else {
            throw BattleError.illegalAction("Enemy AI may run only during an ongoing enemy turn")
        }
        try performAutomaticTurn()
    }

    /// Bounded diagnostics may drive both sides with the same explicit engine
    /// policy. Interactive callers normally control side zero themselves.
    func performAutomaticTurn() throws {
        guard outcome == .ongoing else { throw BattleError.illegalAction("The battle has ended") }
        let side = activeSide
        for id in units.keys.sorted() {
            guard outcome == .ongoing else { break }
            guard var actor = units[id], actor.alive, actor.side == side, !actor.acted else { continue }
            if let target = attackTarget(actor) { _ = try attack(unit: id, target: target.id); continue }
            let opponents = units.values.filter { $0.alive && $0.side != side }
            guard !opponents.isEmpty else { updateOutcome(); break }
            if !actor.moved {
                let choices = reachableCells(actor).filter { $0.position != actor.position }
                let selected = choices.min { lhs, rhs in
                    let ld = opponents.map { distance(lhs.position, $0.position) }.min()!
                    let rd = opponents.map { distance(rhs.position, $0.position) }.min()!
                    if ld != rd { return ld < rd }
                    if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
                    if lhs.position.y != rhs.position.y { return lhs.position.y < rhs.position.y }
                    return lhs.position.x < rhs.position.x
                }
                if let selected { _ = try move(unit: id, to: selected.position) }
            }
            actor = units[id]!
            if let target = attackTarget(actor) { _ = try attack(unit: id, target: target.id) }
            else { try wait(unit: id) }
        }
        if outcome == .ongoing { try endTurn() }
    }

    private func actionable(_ id: Int) throws -> BattleUnitState {
        guard outcome == .ongoing else { throw BattleError.illegalAction("The battle has ended") }
        guard let actor = units[id], actor.alive else { throw BattleError.illegalAction("Unknown or inactive unit slot") }
        guard actor.side == activeSide else { throw BattleError.illegalAction("The selected unit belongs to another side's turn") }
        return actor
    }

    private func reachableCells(_ actor: BattleUnitState) -> [BattleReachableCell] {
        let occupied = Set(units.values.filter { $0.alive && $0.id != actor.id }.map(\.position))
        var paths = [actor.position: [actor.position]], queue = [actor.position], cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]; cursor += 1
            let path = paths[current]!
            guard path.count - 1 < actor.stats.movement else { continue }
            for neighbor in neighbors(current) where paths[neighbor] == nil && !occupied.contains(neighbor) {
                paths[neighbor] = path + [neighbor]; queue.append(neighbor)
            }
        }
        return queue.map { BattleReachableCell(position: $0, cost: paths[$0]!.count - 1, path: paths[$0]!) }
    }

    private func neighbors(_ p: GridPoint) -> [GridPoint] {
        // This order agrees with the examined source direction table, but the
        // experimental unit-cost graph is not the source class-cost algorithm.
        [(0,-1),(1,0),(0,1),(-1,0)].compactMap { dx, dy in
            let next = GridPoint(x: p.x + dx, y: p.y + dy)
            return (0..<width).contains(next.x) && (0..<height).contains(next.y) ? next : nil
        }
    }

    private func distance(_ a: GridPoint, _ b: GridPoint) -> Int {
        abs(a.x - b.x) + abs(a.y - b.y)
    }

    private func attackTarget(_ actor: BattleUnitState) -> BattleUnitState? {
        units.values.filter { $0.alive && $0.side != actor.side && distance(actor.position, $0.position) <= actor.stats.range }
            .min { $0.hp == $1.hp ? $0.id < $1.id : $0.hp < $1.hp }
    }

    private func updateOutcome() {
        let friendly = units.values.contains { $0.alive && $0.side == 0 }
        let hostile = units.values.contains { $0.alive && $0.side == 1 }
        let next: BattleOutcome = !friendly ? .defeat : (!hostile ? .victory : .ongoing)
        if next != outcome {
            outcome = next; selectedUnit = nil
            record("outcome", detail: "Experimental active-roster elimination: \(outcome.rawValue)")
        }
    }

    private func record(_ operation: String, unit: Int? = nil, target: Int? = nil,
                        path: [GridPoint]? = nil, damage: Int? = nil, detail: String = "") {
        events.append(BattleEvent(sequence: events.count, round: round, side: activeSide,
            operation: operation, unit: unit, target: target, path: path, damage: damage, detail: detail))
    }
}
