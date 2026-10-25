// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Caller-owned converted data. None of these files is shipped by the public
/// source repository. Source identity is retained by the individual exporters.
struct OriginalGameData {
    let root:URL
    let combat:OriginalCombatTables
    let movement:OriginalMovementProfile
    let people:OriginalPersonCatalog
    let rosters:OriginalRosterCatalog
    let battles:BattleCatalog
    init(root:URL) throws {
        self.root = root
        combat = try OriginalCombatTables.load(from:root.appendingPathComponent("combat.json"))
        movement = try OriginalMovementProfile.load(from:root.appendingPathComponent("movement.json"))
        people = try OriginalPersonCatalog.load(from:root.appendingPathComponent("people.json"))
        rosters = try OriginalRosterCatalog.load(from:root.appendingPathComponent("rosters.json"))
        battles = try BattleCatalog.load(from:root.appendingPathComponent("battles.json"))
    }
    /// An explicitly isolated source-state research setup. Lexical projection
    /// plus initial clear flags does not prove this is a reachable campaign.
    func isolatedBattle(_ id:String,rng:OriginalRNG) throws -> OriginalBattleSession {
        guard let definition = battles.battles.first(where:{$0.id == id}),let refs = definition.placementProgramRefs,!refs.isEmpty else {
            throw BattleError.invalid("Source battle has no typed placement producer references")
        }
        var roster = OriginalRoster()
        let state = OriginalCampaignState()
        for ref in refs { try roster.apply(rosters.program(chapter:ref.chapter,member:ref.member,offset:ref.offset),flags:state) }
        return try OriginalBattleSession(definition:definition,roster:roster,
            people:OriginalPeople(catalog:people,tables:combat),combat:combat,movement:movement,rng:rng)
    }
}
