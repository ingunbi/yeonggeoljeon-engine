// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct OriginalStrategyAITargetInput {
    var caster: OriginalPersonStats
    var target: OriginalPersonStats
    var targetStatus: Int
    var targetConditionFlags: Int
    var abilityID: Int
    var category: Int
    var terrainID: Int
    var terrainEligible: Bool
    var weatherCode: Int
}

struct OriginalStrategyAISupportInput {
    var caster: OriginalPersonStats
    var target: OriginalPersonStats
    var targetStatus: Int
    var encodedSubtype: Int
}

/// These source AI estimates are deliberately distinct from actual strategy
/// damage/effect producers. Their random draws belong to the shared game RNG.
enum OriginalStrategyAI {
    private static func word(_ value:Int) -> Int { Int(UInt16(truncatingIfNeeded:value)) }
    private static func validate(_ value:OriginalPersonStats) throws {
        guard (0..<19).contains(value.classID), (0...255).contains(value.level),
              (0...65535).contains(value.troops), (0...100).contains(value.intellectScalar),
              (0...100).contains(value.morale) else {
            throw BattleError.invalid("Original strategy AI requires source person quantities")
        }
    }
    /// MAIN30824..30A87 (D2C4). Categories and terrain eligibility are supplied
    /// by the movement/strategy-profile owner; original bytes are not reparsed.
    static func targetScore(_ input:OriginalStrategyAITargetInput,tables:OriginalCombatTables,rng:inout OriginalRNG) throws -> Int {
        try validate(input.caster); try validate(input.target); try tables.validate()
        guard (0..<36).contains(input.abilityID), (0...255).contains(input.category),
              (0...255).contains(input.terrainID), (0...255).contains(input.weatherCode),
              (0...255).contains(input.targetStatus), (0...255).contains(input.targetConditionFlags) else {
            throw BattleError.invalid("Original strategy AI target context is invalid")
        }
        let a = input.caster, d = input.target, ability = input.abilityID
        if ability <= 14 {
            let family = ability/5
            let environment = tables.strategyEnvironmentLookup[input.weatherCode]
            if (family == 0 && environment == 2) || !input.terrainEligible { return 0 }
            let offense = a.intellectScalar+a.level*a.intellectScalar/50
            let targetLevelTerm = d.level*d.intellectScalar/50
            let coefficient = ((input.category+1)*4+family)*50
            var score = word(word(word(coefficient+offense)*2)-targetLevelTerm-d.intellectScalar)
            if (family == 0 && input.terrainID == 1) || (family == 1 && environment == 2) {
                score = word(score+score/4)
            }
            return word(score+(try rng.next(bound:score/50)))
        }
        if ability <= 17 {
            if input.targetConditionFlags&2 != 0 { return 0 }
            let success = try OriginalCombat.strategySuccess(caster:a,target:d,denominatorByte:0x82,rng:&rng).success
            // MAIN30995 loads AX300 then branches directly to3095B. The RNG
            // bound remains300 even when the success-derived SI is zero.
            return word((success ? 300 : 0)+(try rng.next(bound:300)))
        }
        if ability <= 20 {
            let base = word(a.level/10+(input.category+2)*10-d.level/10)
            let limited = min(base,d.morale)
            return word(limited*((try rng.next(bound:10))+1))
        }
        if ability <= 29 {
            let flags = ability >= 27 ? 3 : ability >= 24 ? 1 : 2
            let maximum = try OriginalCombat.maxTroops(classID:d.classID,level:d.level,tables:tables)
            if flags == 1 && d.troops == maximum { return 0 }
            if flags == 2 && d.morale == 100 { return 0 }
            if flags == 3 && d.troops == maximum && d.morale == 100 { return 0 }
            let subtype = ((input.category<<4)&255)|flags
            return try supportScore(OriginalStrategyAISupportInput(caster:a,target:d,targetStatus:input.targetStatus,
                encodedSubtype:subtype),tables:tables,rng:&rng)
        }
        return 0
    }
    /// MAIN30A88..30C57 (D528). This returns a word utility score, not a heal
    /// quantity. Its threshold/level bonuses and low-morale multiplication
    /// belong to AI estimation and must not mutate troops or morale.
    static func supportScore(_ input:OriginalStrategyAISupportInput,tables:OriginalCombatTables,rng:inout OriginalRNG) throws -> Int {
        try validate(input.caster); try validate(input.target); try tables.validate()
        guard (0...255).contains(input.targetStatus), (0...255).contains(input.encodedSubtype) else {
            throw BattleError.invalid("Original strategy AI support context is invalid")
        }
        if input.targetStatus != 2 { return 0 }
        let a = input.caster, d = input.target, high = input.encodedSubtype>>4
        var troopScore = 0, moraleScore = 0
        if input.encodedSubtype&1 != 0 {
            let base = (high+1)*600+a.level*a.intellectScalar/20
            let roll = try rng.next(bound:word(base)/10)
            let maximum = try OriginalCombat.maxTroops(classID:d.classID,level:d.level,tables:tables)
            troopScore = min(base+roll,maximum-d.troops)
            if troopScore < maximum/10 { troopScore = 0 }
            if troopScore > 0 { troopScore += (2-high)*50 }
        }
        if input.encodedSubtype&2 != 0 {
            let base = (high+3)*10+a.level/10
            let roll = try rng.next(bound:word(base)/10)
            moraleScore = min(base+roll,100-d.morale)
            if moraleScore < 10 { moraleScore = 0 }
            if moraleScore > 0 { moraleScore += (2-high)*5 }
            if d.morale < 40 { moraleScore *= 20 }
        }
        return word(moraleScore+troopScore)
    }
}
