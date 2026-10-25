// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Synthetic examples contain no original game data, names, text or artwork.
func battleSelfTests() throws {
    var assertions = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw EngineError.invalid("Battle self-test failed: \(message)") }
        assertions += 1
    }
    func reject(_ message: String, _ action: () throws -> Void) throws {
        do { try action() }
        catch is BattleError { assertions += 1; return }
        throw EngineError.invalid("Battle self-test did not reject: \(message)")
    }
    func unit(_ id: Int, _ side: Int, _ x: Int, _ y: Int, person: Int? = nil) -> BattleUnitDefinition {
        BattleUnitDefinition(id: id, person: person, side: side, x: x, y: y, initiallyActive: true)
    }
    func definition(_ units: [BattleUnitDefinition], width: Int = 7, height: Int = 5) -> BattleDefinition {
        BattleDefinition(id: "synthetic", width: width, height: height,
                         coordinateSystem: "orthogonal", units: units)
    }
    func make(_ units: [BattleUnitDefinition], width: Int = 7, height: Int = 5) throws -> BattleSession {
        try BattleSession(definition: definition(units, width: width, height: height), policy: .experimentalV1)
    }
    let base = definition([unit(10, 0, 1, 1, person: 70), unit(20, 1, 5, 1, person: 80)])
    try reject("unimplemented original rules") { _ = try BattleSession(definition: base, policy: .original) }
    let session = try BattleSession(definition: base, policy: .experimentalV1)
    try check(session.units[10]?.person == 70 && session.units[70] == nil, "slot identity is separate from person identity")
    try check(session.snapshot().ruleOrigin.contains("Experimental"), "prototype provenance survives snapshot")
    try reject("enemy selection on player turn") { try session.select(unit: 20) }
    try session.select(unit: 10)
    try check(session.selectedUnit == 10, "selection addresses the native placement identity")
    let beforeInvalidMove = session.snapshot()
    try reject("out-of-bounds move") { _ = try session.move(unit: 10, to: GridPoint(x: -1, y: 1)) }
    try reject("occupied move") { _ = try session.move(unit: 10, to: GridPoint(x: 5, y: 1)) }
    try check(session.snapshot() == beforeInvalidMove, "invalid moves do not partially mutate battle state")
    let cells = try session.reachable()
    try check(cells.allSatisfy { $0.cost <= 4 && $0.path.first == GridPoint(x: 1, y: 1) && $0.path.last == $0.position }, "reachable paths retain origin, destination and budget")
    let path = try session.move(unit: 10, to: GridPoint(x: 4, y: 1))
    try check(path == [GridPoint(x: 1,y: 1),GridPoint(x: 2,y: 1),GridPoint(x: 3,y: 1),GridPoint(x: 4,y: 1)], "shortest route follows deterministic orthogonal neighbors")
    try reject("second move in same turn") { _ = try session.move(unit: 10, to: GridPoint(x: 4,y: 2)) }
    let hit = try session.attack(unit: 10, target: 20)
    try check(hit.damage == 20 && hit.remainingHP == 80 && !hit.defeated, "explicit prototype attack applies its own formula")
    try check(session.units[10]?.acted == true && session.units[10]?.moved == true, "attack consumes action and movement")
    let afterAttack = session.snapshot()
    try reject("duplicate attack") { _ = try session.attack(unit: 10, target: 20) }
    try check(session.snapshot() == afterAttack, "illegal repeated attack has no state side effects")
    try session.endTurn()
    try check(session.activeSide == 1 && session.round == 1, "end player turn selects enemy faction")
    try reject("player move during enemy turn") { try session.wait(unit: 10) }
    try session.performEnemyTurn()
    try check(session.activeSide == 0 && session.round == 2, "deterministic enemy turn returns to next player round")
    try check(session.units[20]?.position == GridPoint(x: 5,y: 1) && session.units[10]?.hp == 80, "adjacent enemy attacks without a spurious move")
    try check(session.units[10]?.moved == false && session.units[10]?.acted == false, "new side turn resets only current faction action flags")

    // Occupancy forms an impassable wall in the explicit prototype graph.
    let blocked = try make([unit(0,0,0,1),unit(1,0,1,0),unit(2,0,1,1),unit(3,0,1,2),unit(4,1,2,1)],width:3,height:3)
    let blockedReachable = try blocked.reachable(unit: 0)
    try check(!blockedReachable.contains { $0.position.x == 2 }, "occupied cells cannot be crossed or ended on")
    try reject("no-route move") { _ = try blocked.move(unit:0,to:GridPoint(x:2,y:0)) }
    try reject("friendly attack") { _ = try blocked.attack(unit:0,target:2) }
    try reject("out-of-range attack") { _ = try blocked.attack(unit:0,target:4) }

    let duel = try make([unit(0,0,0,0),unit(1,1,1,0)],width:2,height:1)
    for index in 0..<5 {
        _ = try duel.attack(unit:0,target:1)
        if index < 4 { try duel.endTurn(); try duel.wait(unit:1); try duel.endTurn() }
    }
    try check(duel.outcome == .victory && duel.units[1]?.hp == 0, "prototype active-roster elimination produces victory")
    try check(duel.events.filter { $0.operation == "defeated" }.count == 1, "one defeated unit emits one defeat event")
    try reject("actions after victory") { try duel.endTurn() }
    let loss = try make([unit(0,0,0,0),unit(1,1,1,0)],width:2,height:1)
    for index in 0..<5 {
        try loss.wait(unit:0); try loss.endTurn(); _ = try loss.attack(unit:1,target:0)
        if index < 4 { try loss.endTurn() }
    }
    try check(loss.outcome == .defeat, "prototype elimination of controlled faction produces defeat")

    // Multiple exported placements may share a person value; they are never merged.
    let samePerson = try make([unit(0,0,0,0,person:9),unit(1,0,0,1,person:9),unit(59,1,2,1)],width:3,height:2)
    try check(samePerson.units.count == 3 && samePerson.units[59] != nil,
              "equal people remain distinct and export identity is not constrained to a DOS runtime slot range")
    var original = unit(0,0,0,0); original.hp = 17; original.attack = 999
    let stats = try make([original,unit(1,1,1,0)],width:2,height:1)
    try check(stats.definition.units[0].hp == 17 && stats.definition.units[0].attack == 999, "original stats remain unmodified source facts")
    try check(stats.units[0]?.hp == 100 && stats.units[0]?.stats.attack == 25, "prototype effective stats retain their own origin")
    var partial = base
    var conditional = unit(30,0,2,2); conditional.initiallyActive = nil
    partial.conditionalUnits = [conditional]; partial.rosterScope = "unconditional-placement-records-only"
    partial.originalRosterComplete = false
    let partialSession = try BattleSession(definition:partial,policy:.experimentalV1)
    try check(partialSession.definition.conditionalUnits?[0].initiallyActive == nil && partialSession.units[30] == nil,
              "unresolved conditional placement remains unknown rather than false or activated")
    try check(partialSession.snapshot().unresolvedConditionalUnits == 1 && partialSession.snapshot().originalRosterComplete == false,
              "prototype replay carries its partial source-roster coverage")

    var unresolved = unit(0,0,0,0); unresolved.initiallyActive = nil
    try reject("unknown source activation") { _ = try make([unresolved,unit(1,1,1,0)],width:2,height:1) }
    var unknownFaction = unit(0,0,0,0); unknownFaction.side = nil
    try reject("unknown faction") { _ = try make([unknownFaction,unit(1,1,1,0)],width:2,height:1) }
    try reject("overlapping source placements") { _ = try make([unit(0,0,0,0),unit(1,1,0,0)],width:2,height:1) }
    try reject("duplicate slot IDs") { _ = try make([unit(0,0,0,0),unit(0,1,1,0)],width:2,height:1) }
    try reject("unbounded grid dimensions") { _ = try make([unit(0,0,0,0),unit(1,1,1,0)],width:Int.max,height:2) }

    let a = try make([unit(9,0,0,0),unit(3,0,0,2),unit(8,1,6,0),unit(2,1,6,2)])
    let b = try make(Array([unit(9,0,0,0),unit(3,0,0,2),unit(8,1,6,0),unit(2,1,6,2)].reversed()))
    var turns = 0
    while a.outcome == .ongoing && turns < 200 { try a.performAutomaticTurn(); turns += 1 }
    for _ in 0..<turns { if b.outcome == .ongoing { try b.performAutomaticTurn() } }
    try check(a.outcome != .ongoing, "bounded synthetic automatic match reaches an explicit outcome")
    try check(a.snapshot() == b.snapshot() && a.events == b.events, "dictionary/input ordering does not change deterministic replay")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let snapshot = try encoder.encode(a.snapshot())
    let decodedSnapshot = try JSONDecoder().decode(BattleSnapshot.self,from:snapshot)
    try check(decodedSnapshot == a.snapshot(), "Codable snapshot preserves policy, ownership and outcome")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("battle-source-contract-" + UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
    defer { try? FileManager.default.removeItem(at:folder) }
    let input = folder.appendingPathComponent("catalog.json")
    let catalog = BattleCatalog(format:1,battles:[base])
    try encoder.encode(catalog).write(to:input)
    let loaded = try BattleCatalog.load(from:input)
    try check(loaded.battles.count == 1 && loaded.battles[0].units[0].hp == nil,
              "JSON catalog retains unresolved original statistics instead of inserting defaults")
    try encoder.encode(BattleCatalog(format:1,battles:[partial])).write(to:input)
    let loadedPartial = try BattleCatalog.load(from:input)
    try check(loadedPartial.battles[0].conditionalUnits?.count == 1 && loadedPartial.battles[0].originalRosterComplete == false,
              "catalog roundtrip preserves conditional roster and incomplete coverage")
    try encoder.encode(BattleCatalog(format:2,battles:[base])).write(to:input)
    try reject("unknown catalog format") { _ = try BattleCatalog.load(from:input) }
    try encoder.encode(BattleCatalog(format:1,battles:[base,base])).write(to:input)
    try reject("duplicate source battle IDs") { _ = try BattleCatalog.load(from:input) }
    print("Battle self-tests passed: \(assertions)")
}
