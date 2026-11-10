// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct OriginalItemEffect: Codable, Equatable {
    var id: Int
    var category: Int
    var value: Int
    /// Local-only record texts, absent from synthetic tables.
    var name: String? = nil
    var description: String? = nil
}

struct OriginalCombatTables: Codable {
    var format: Int
    var attackBase: [Int]
    var defenseBase: [Int]
    var troopBase: [Int]
    var troopGrowth: [Int]
    var physicalSubtypeByClass: [Int]
    var terrainDefensePercent: [Int]
    var strategyEnvironmentLookup: [Int]
    var items: [OriginalItemEffect]
    var source: JSONValue?

    static func load(from url: URL) throws -> OriginalCombatTables {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf:url))
        try value.validate(); return value
    }
    func validate() throws {
        let classes = [attackBase, defenseBase, troopBase, troopGrowth, physicalSubtypeByClass]
        guard format == 1, classes.allSatisfy({$0.count == 19 && $0.allSatisfy({(0...255).contains($0)})}),
              terrainDefensePercent.count == 256, terrainDefensePercent.allSatisfy({(0...255).contains($0)}),
              strategyEnvironmentLookup.count == 256, strategyEnvironmentLookup.allSatisfy({(0...255).contains($0)}),
              items.count == 64, Set(items.map(\.id)) == Set(0..<64),
              items.allSatisfy({(0...15).contains($0.category) && (0...255).contains($0.value)}) else {
            throw BattleError.invalid("Original combat table format/cardinality/value domain is invalid")
        }
    }
}

struct OriginalPersonStats: Codable, Equatable {
    var classID: Int
    var level: Int
    var troops: Int
    var attackScalar: Int
    var defenseScalar: Int
    var intellectScalar: Int
    var morale: Int
    var itemIDs: [Int]
}

/// MAIN181D4..18227. One state belongs to the game, not one state per combat.
/// A bound of zero returns zero without consuming the original generator.
struct OriginalRNG: Codable, Equatable {
    var state: UInt32
    /// MAIN181FA..18212 reads bytes2..5 of runtimeCA8A's clock structure.
    /// Preserve the raw RTC bytes; the source does not convert their BCD form
    /// to decimal before packing the state. Failed RTC reads need their own
    /// caller-owned fallback record rather than an invented seed here.
    static func clockSeed(dayByte:UInt8,hourByte:UInt8,minuteByte:UInt8,secondByte:UInt8) -> OriginalRNG {
        OriginalRNG(state:UInt32(dayByte) | UInt32(hourByte)<<8 | UInt32(minuteByte)<<16 | UInt32(secondByte)<<24)
    }
    mutating func next(bound: Int) throws -> Int {
        guard (0...65535).contains(bound) else { throw BattleError.invalid("Original RNG bound is not a source word") }
        if bound == 0 { return 0 }
        state = state &* 0x41C64E6D &+ 0x3039
        return Int((state >> 16) & 0x7FFF) % bound
    }
}

struct OriginalPhysicalInput: Codable, Equatable {
    var attacker: OriginalPersonStats
    var defender: OriginalPersonStats
    var terrainID: Int
    var subtype: Int
    /// Source battle-unit condition tested with mask2 before counter recursion.
    var defenderCounterDisabled: Bool
}

struct OriginalPhysicalResult: Codable, Equatable {
    var attack: Int
    var defense: Int
    var adjustedDefense: Int
    var damage: Int
    var moraleLoss: Int
    var counterRoll: Int?
    var counterEligible: Bool
    var remainingTroops: Int
    var remainingMorale: Int
    var source: String = "MAIN31474/317CC/3198E/321E2; physical producer, not a complete combat exchange"
}

struct OriginalMoraleKernel {
    let morale:Int;let flags:Int;let status:Int
    let lossRequired:Bool;let recoveryRequested:Bool;let threshold:Int
    var recoveryRollRequired:Bool {recoveryRequested && flags&2 != 0 && status == 2}
    func result(lossRoll:Int?,recoveryRoll:Int?)->OriginalMoraleMutation {
        var changed = flags
        if lossRequired,let lossRoll,lossRoll < 3 {changed |= 2}
        var condition:OriginalConditionRecovery?
        if recoveryRequested {
            let recovered = recoveryRollRequired && recoveryRoll.map {$0 < threshold} == true
            if recovered {changed &= 0xFD}
            condition = .init(roll:recoveryRollRequired ? recoveryRoll : nil,threshold:threshold,recovered:recovered,remainingFlags:changed)
        }
        return .init(remainingMorale:morale,remainingFlags:changed,lossRoll:lossRequired ? lossRoll : nil,conditionRecovery:condition)
    }
}

struct OriginalExperienceGain: Codable, Equatable {
    var hit: Int
    var defeatedTarget: Int
    var total: Int { hit + defeatedTarget }
}

struct OriginalExperienceMutation: Codable, Equatable {
    var level: Int
    var experience: Int
    var levelsGained: Int
    var ignoredReason: String?
}

/// The source damage context accepts encoded subtypes and kinds2/3. These
/// values do not establish strategy availability, cost, range or target rules.
struct OriginalStrategyInput: Codable, Equatable {
    var attacker: OriginalPersonStats
    var defender: OriginalPersonStats
    var terrainID: Int
    var subtype: Int
    var kind: Int
    /// Original battle-object byte4; its source name is not yet established.
    var weatherCode: Int
}

struct OriginalStrategyResult: Codable, Equatable {
    var chanceBound: Int
    var chanceRollByte: Int
    var defenderThreshold: Int
    var jitterBound: Int
    var jitterRoll: Int
    var resisted: Bool
    var success: Bool
    var damage: Int
    var moraleLoss: Int
    var remainingTroops: Int
    var remainingMorale: Int
    var source: String = "MAIN315ED..31853; damage context only, strategy command rules remain separate"
}

struct OriginalRecoveryInput: Codable, Equatable {
    /// Inactive source slots still consume both draws, without requiring a
    /// fabricated person/terrain interpretation for their unused values.
    var stats: OriginalPersonStats?
    var terrainID: Int?
    var unitStatus: Int
    var conditionFlags: Int
}

struct OriginalRecoveryResult: Codable, Equatable {
    var troopRoll: Int
    var moraleRoll: Int
    var recoveryFlags: Int
    var troopsDelta: Int
    var moraleDelta: Int
    var remainingTroops: Int?
    var remainingMorale: Int?
    var remainingFlags: Int
    var moraleMutation: OriginalMoraleMutation?
    /// Source class12 grants this amount to each occupied cardinal neighbor.
    /// Board enumeration and shared-person mutation belong to the turn owner.
    var adjacentMPGain: Int
}

struct OriginalConditionRecovery: Codable, Equatable {
    var roll: Int?
    var threshold: Int?
    var recovered: Bool
    var remainingFlags: Int
}

struct OriginalMoraleMutation: Codable, Equatable {
    var remainingMorale: Int
    var remainingFlags: Int
    var lossRoll: Int?
    var conditionRecovery: OriginalConditionRecovery?
}

struct OriginalStrategySuccess: Codable, Equatable {
    var chanceBound: Int
    var roll: Int
    var threshold: Int
    var success: Bool
}

struct OriginalHealingInput {
    /// Source caster-slot255 omits caster-derived bonuses.
    var caster: OriginalPersonStats?
    var target: OriginalPersonStats
    var targetStatus: Int
    var targetConditionFlags: Int
    var encodedSubtype: Int
}

struct OriginalHealingResult: Codable, Equatable {
    var troopRoll: Int?
    var moraleRoll: Int?
    var troopsDelta: Int
    var moraleDelta: Int
    var remainingTroops: Int
    var remainingMorale: Int
    var remainingFlags: Int
    var moraleMutation: OriginalMoraleMutation?
}

/// Pure source arithmetic shared by execution and read-only assistance.
/// The caller still owns the exact random-call order and morale side effects.
struct OriginalHealingKernel {
    var troopBase:Int;var troopBound:Int;var moraleBase:Int;var moraleBound:Int
    var maximum:Int;var target:OriginalPersonStats
    func troops(roll:Int)->Int {
        let amount = min(troopBase+roll,maximum-target.troops)
        return min(maximum,Int(UInt16(truncatingIfNeeded:target.troops+amount)))
    }
    func moraleAmount(roll:Int)->Int {min(100-target.morale,Int(UInt8(truncatingIfNeeded:moraleBase+roll)))}
}

struct OriginalStrategyKernel {
    var bound:Int;var threshold:Int;var damageBase:Int64;var jitterBound:Int;var resisted:Bool
}

struct OriginalStrategyCompletion: Codable, Equatable {
    var remainingMP: Int
    var flatExperience: Int
}

enum OriginalCombat {
    private static func person(_ value: OriginalPersonStats) throws {
        guard (0..<19).contains(value.classID), (0...255).contains(value.level),
              (0...65535).contains(value.troops), (0...100).contains(value.attackScalar),
              (0...100).contains(value.defenseScalar), (0...100).contains(value.intellectScalar),
              (0...100).contains(value.morale), value.itemIDs.count == 8,
              value.itemIDs.allSatisfy({$0 == 255 || (0..<64).contains($0)}) else {
            throw BattleError.invalid("Original person stat/object domain is incomplete or invalid")
        }
    }
    private static func signed32(_ value: Int64) -> Int64 { Int64(Int32(truncatingIfNeeded:value)) }
    private static func multiply32(_ a:Int64,_ b:Int64)->Int64 { signed32(a*b) }
    private static func add32(_ a:Int64,_ b:Int64)->Int64 { signed32(a+b) }
    private static func divide32(_ a:Int64,_ b:Int64) throws -> Int64 {
        guard b != 0, !(a == Int64(Int32.min) && b == -1) else {
            throw BattleError.invalid("Original signed arithmetic division is undefined for these inputs")
        }
        return a/b
    }
    static func maxTroops(classID:Int,level:Int,tables:OriginalCombatTables) throws -> Int {
        try tables.validate()
        guard (0..<19).contains(classID), (0...255).contains(level) else { throw BattleError.invalid("Original class/level is invalid") }
        // Source uses word arithmetic and BX-- before MUL, including underflow.
        let prior = UInt16(truncatingIfNeeded:level-1)
        let growth = UInt16(truncatingIfNeeded:tables.troopGrowth[classID]) &* prior
        let base = UInt16(truncatingIfNeeded:10*tables.troopBase[classID]) &+ growth
        return Int(base &* 10)
    }
    private static func bonus(_ value:OriginalPersonStats,category:Int,tables:OriginalCombatTables) throws -> Int {
        var maximum = 0
        for id in value.itemIDs where id != 255 {
            guard let item = tables.items.first(where:{$0.id == id}) else { throw BattleError.invalid("Original item identity is unavailable") }
            if item.category == category { maximum = max(maximum,item.value) }
        }
        return maximum
    }
    private static func stat(_ value:OriginalPersonStats,attack:Bool,tables:OriginalCombatTables) throws -> Int {
        try person(value); try tables.validate()
        let scalar = attack ? value.attackScalar : value.defenseScalar
        let base = attack ? tables.attackBase[value.classID] : tables.defenseBase[value.classID]
        let q = try divide32(4000,Int64(140-scalar))
        let combined = add32(add32(Int64(base)*2,Int64(value.morale)),q)
        var result = try divide32(multiply32(combined,Int64(value.level+10)),10)
        let equipment = try bonus(value,category:attack ? 0 : 5,tables:tables)
        result = add32(result,try divide32(multiply32(result,Int64(equipment)),100))
        // CF5:468E selects signed-long max with1; return AX, not an invented cap.
        return Int(UInt16(truncatingIfNeeded:max(1,result)))
    }
    static func attackStat(_ value:OriginalPersonStats,tables:OriginalCombatTables) throws -> Int {
        try stat(value,attack:true,tables:tables)
    }
    static func defenseStat(_ value:OriginalPersonStats,tables:OriginalCombatTables) throws -> Int {
        try stat(value,attack:false,tables:tables)
    }
    /// Player UI2DB49 and AI3038F obtain normal attack subtype from the same
    /// class table. It also governs the counter-class test; it is not boolean.
    static func normalPhysicalSubtype(classID:Int,tables:OriginalCombatTables) throws -> Int {
        try tables.validate()
        guard (0..<19).contains(classID) else { throw BattleError.invalid("Original attack class is invalid") }
        return tables.physicalSubtypeByClass[classID]
    }
    /// MAIN2C6E4..2C727, as consumed by source byte-MP callers. The source
    /// discards MUL's high word before dividing, clamps only values greater
    /// than256, then callers discard AH: a quotient of256 becomes byte zero.
    static func maxMP(stats:OriginalPersonStats) throws -> Int {
        try person(stats)
        let product = UInt16(truncatingIfNeeded:(stats.level+10)*5*stats.intellectScalar)
        let quotient = Int(product)/200
        return Int(UInt8(truncatingIfNeeded:quotient > 256 ? 255 : quotient))
    }
    /// MAIN2D5DA..2D606. The source tests its word sum as signed, then writes
    /// one byte; this preserves unusual word operands as well as normal aura.
    static func applyMPGain(current:Int,gain:Int,stats:OriginalPersonStats) throws -> Int {
        guard (0...255).contains(current), (0...65535).contains(gain) else {
            throw BattleError.invalid("Original MP mutation requires a byte and source word")
        }
        let maximum = try maxMP(stats:stats)
        let sum = UInt16(truncatingIfNeeded:current+gain)
        if Int(Int16(bitPattern:sum)) > maximum { return maximum }
        return Int(UInt8(truncatingIfNeeded:current+gain))
    }
    /// MAIN2B228..2B43B: the later part of the source method presents the
    /// already-mutated recovery. Both random calls precede its status2 gate.
    static func recover(_ input:OriginalRecoveryInput,tables:OriginalCombatTables,rng:inout OriginalRNG) throws -> OriginalRecoveryResult {
        guard (0...255).contains(input.unitStatus), (0...255).contains(input.conditionFlags) else { throw BattleError.invalid("Original unit status/flags are not bytes") }
        if input.unitStatus == 2 {
            guard let value = input.stats, let terrain = input.terrainID, (0...255).contains(terrain) else {
                throw BattleError.invalid("Active original recovery requires person and raw terrain")
            }
            try person(value); try tables.validate()
        }
        let troopRoll = try rng.next(bound:11), moraleRoll = try rng.next(bound:5)
        guard input.unitStatus == 2, let value = input.stats, let terrain = input.terrainID else {
            return OriginalRecoveryResult(troopRoll:troopRoll,moraleRoll:moraleRoll,recoveryFlags:0,
                troopsDelta:0,moraleDelta:0,remainingTroops:nil,remainingMorale:nil,
                remainingFlags:input.conditionFlags,moraleMutation:nil,adjacentMPGain:0)
        }
        var troopGain = (troopRoll+15)*10
        var moraleGain = value.defenseScalar/10+moraleRoll+1
        let maximum = try maxTroops(classID:value.classID,level:value.level,tables:tables)
        let troopSum = Int(UInt16(truncatingIfNeeded:value.troops+troopGain))
        if maximum > troopSum && Int(UInt16(truncatingIfNeeded:troopSum+10)) > maximum {
            troopGain = Int(UInt16(truncatingIfNeeded:maximum-value.troops))
        }
        if value.morale+moraleGain < 100 && value.morale+moraleGain+10 > 100 { moraleGain = 100-value.morale }
        var flags = [8,13].contains(terrain) ? 3 : terrain == 14 ? 1 : 0
        for id in value.itemIDs {
            // These are source method immediates, not copied item-table data.
            if id == 55 { flags |= 2 }
            if id == 56 { flags |= 1 }
            if id == 8 { flags |= 3 }
        }
        let troops = flags&1 == 0 ? value.troops : min(maximum,Int(UInt16(truncatingIfNeeded:value.troops+troopGain)))
        let mutation = flags&2 == 0 ? nil : try setMorale(stats:value,unitStatus:input.unitStatus,
            conditionFlags:input.conditionFlags,requestedMorale:value.morale+moraleGain,rng:&rng)
        let morale = mutation?.remainingMorale ?? value.morale
        return OriginalRecoveryResult(troopRoll:troopRoll,moraleRoll:moraleRoll,recoveryFlags:flags,
            troopsDelta:troops-value.troops,moraleDelta:morale-value.morale,
            remainingTroops:troops,remainingMorale:morale,remainingFlags:mutation?.remainingFlags ?? input.conditionFlags,
            moraleMutation:mutation,adjacentMPGain:value.classID == 12 ? value.level/10+1 : 0)
    }
    /// MAIN2B690..2B708. Invoke after any preceding recovery has mutated unit
    /// morale. Only condition-mask2 and source status2 consume random(100).
    static func recoverCondition2(stats:OriginalPersonStats?,unitStatus:Int,conditionFlags:Int,rng:inout OriginalRNG) throws -> OriginalConditionRecovery {
        guard (0...255).contains(unitStatus), (0...255).contains(conditionFlags) else {
            throw BattleError.invalid("Original condition recovery requires source bytes")
        }
        if let stats { try person(stats) }
        let threshold = stats.map(conditionRecoveryThreshold)
        guard conditionFlags&2 != 0, unitStatus == 2 else {
            return OriginalConditionRecovery(roll:nil,threshold:threshold,recovered:false,remainingFlags:conditionFlags)
        }
        guard let threshold else { throw BattleError.invalid("Active original condition recovery requires person stats") }
        let roll = try rng.next(bound:100), recovered = roll < threshold
        return OriginalConditionRecovery(roll:roll,threshold:threshold,recovered:recovered,
            remainingFlags:recovered ? conditionFlags & 0xFD : conditionFlags)
    }
    static func conditionRecoveryThreshold(_ stats:OriginalPersonStats)->Int {(stats.defenseScalar+stats.morale)/3}
    /// MAIN2BEEC..2BF51 owns morale clamping and its condition side effects.
    /// The source comparisons use the requested signed word, not its clamped
    /// morale. Callers must retain the lethal-damage gate that skips this setter.
    static func setMorale(stats:OriginalPersonStats,unitStatus:Int,conditionFlags:Int,requestedMorale:Int,rng:inout OriginalRNG) throws -> OriginalMoraleMutation {
        let kernel = try moraleKernel(stats:stats,unitStatus:unitStatus,conditionFlags:conditionFlags,requestedMorale:requestedMorale)
        let loss = kernel.lossRequired ? try rng.next(bound:5) : nil
        let recovery = kernel.recoveryRollRequired ? try rng.next(bound:100) : nil
        return kernel.result(lossRoll:loss,recoveryRoll:recovery)
    }
    /// Live execution and finite prediction share this deterministic producer.
    static func moraleKernel(stats:OriginalPersonStats,unitStatus:Int,conditionFlags:Int,requestedMorale:Int) throws -> OriginalMoraleKernel {
        try person(stats)
        guard (0...255).contains(unitStatus), (0...255).contains(conditionFlags),
              (-32768...65535).contains(requestedMorale) else {
            throw BattleError.invalid("Original morale mutation requires source bytes and word")
        }
        let raw = UInt16(truncatingIfNeeded:requestedMorale), requested = Int(Int16(bitPattern:raw))
        let morale = max(0,min(100,requested))
        var changed = stats;changed.morale = morale
        return .init(morale:morale,flags:conditionFlags,status:unitStatus,
            lossRequired:stats.morale > requested && raw < 30,
            recoveryRequested:stats.morale <= requested && (stats.morale < requested || requested == 100),
            threshold:conditionRecoveryThreshold(changed))
    }
    /// MAIN2D630..2D67E. Retirement itself invokes source campaign hooks and
    /// changes live-slot status; that stateful operation remains caller-owned.
    static func shouldRetire(troops:Int,morale:Int,conditionFlags:Int) throws -> Bool {
        guard (0...65535).contains(troops), (0...100).contains(morale), (0...255).contains(conditionFlags) else {
            throw BattleError.invalid("Original retirement predicate requires source quantities/flags")
        }
        return troops == 0 || (conditionFlags&2 != 0 && morale == 0)
    }
    /// MAIN2D80A..2D8F0. The raw denominator byte is not masked before
    /// division, including the AI's0x82 message-suppression operand.
    static func strategySuccess(caster:OriginalPersonStats,target:OriginalPersonStats,denominatorByte:Int,rng:inout OriginalRNG) throws -> OriginalStrategySuccess {
        let parameters = try strategySuccessParameters(caster:caster,target:target,denominatorByte:denominatorByte)
        let roll = try rng.next(bound:parameters.bound)
        return OriginalStrategySuccess(chanceBound:parameters.bound,roll:roll,threshold:parameters.threshold,success:roll>parameters.threshold)
    }
    static func strategySuccessParameters(caster:OriginalPersonStats,target:OriginalPersonStats,denominatorByte:Int) throws -> (bound:Int,threshold:Int) {
        try person(caster); try person(target)
        guard (1...255).contains(denominatorByte) else {
            throw BattleError.invalid("Original strategy success denominator is zero or not a byte")
        }
        let bound = caster.intellectScalar+caster.level*caster.intellectScalar/100
        var threshold = (target.intellectScalar+target.level*target.intellectScalar/100)/denominatorByte
        if [12,15,18].contains(target.classID) { threshold = Int(UInt16(truncatingIfNeeded:threshold*2)) }
        return (bound,threshold)
    }
    /// Marginal probability over the source 15-bit draw domain, including its
    /// modulo bias. No current or future RNG state is accepted by this query.
    static func rollProbability(bound:Int,accepts:(Int)->Bool) throws -> Double {
        guard (0...65535).contains(bound) else {throw BattleError.invalid("Original probability bound is invalid")}
        if bound == 0 {return accepts(0) ? 100 : 0}
        let quotient = 32768/bound,remainder = 32768%bound
        let count = (0..<min(32768,bound)).reduce(0) { $0+(accepts($1) ? quotient+($1 < remainder ? 1 : 0) : 0) }
        return Double(count)*100/32768
    }
    /// MAIN2D760..2D808 permits healing at full morale when condition2 can be
    /// cured. The AI utility gate is a distinct source method and differs here.
    static func healingUseful(target:OriginalPersonStats,conditionFlags:Int,recoveryFlags:Int,tables:OriginalCombatTables) throws -> Bool {
        try person(target)
        guard (0...255).contains(conditionFlags), (1...3).contains(recoveryFlags) else {
            throw BattleError.invalid("Original healing eligibility flags are invalid")
        }
        let maximum = try maxTroops(classID:target.classID,level:target.level,tables:tables)
        if recoveryFlags == 1 && target.troops == maximum { return false }
        if recoveryFlags == 2 && target.morale == 100 && conditionFlags&2 == 0 { return false }
        if recoveryFlags == 3 && target.troops == maximum && target.morale == 100 && conditionFlags&2 == 0 { return false }
        return true
    }
    /// MAIN2EE20..2F052 (B8C0), actual healing rather than AI support utility.
    /// HP mutation precedes morale mutation and its condition-recovery draw.
    static func healingKernel(_ input:OriginalHealingInput,tables:OriginalCombatTables) throws -> OriginalHealingKernel {
        try person(input.target);if let caster = input.caster {try person(caster)};try tables.validate()
        guard (0...255).contains(input.encodedSubtype) else {throw BattleError.invalid("Original healing subtype is invalid")}
        let high = input.encodedSubtype>>4
        let troopBase = (high+1)*600+(input.caster.map{$0.level*$0.intellectScalar/20} ?? 0)
        let moraleBase = (high+3)*10+(input.caster.map{$0.level/10} ?? 0)
        return OriginalHealingKernel(troopBase:troopBase,troopBound:Int(UInt16(truncatingIfNeeded:troopBase))/10,
            moraleBase:moraleBase,moraleBound:moraleBase/10,
            maximum:try maxTroops(classID:input.target.classID,level:input.target.level,tables:tables),target:input.target)
    }
    static func heal(_ input:OriginalHealingInput,tables:OriginalCombatTables,rng:inout OriginalRNG) throws -> OriginalHealingResult {
        try person(input.target); if let caster = input.caster { try person(caster) };try tables.validate()
        guard (0...255).contains(input.targetStatus), (0...255).contains(input.targetConditionFlags),
              (0...255).contains(input.encodedSubtype) else { throw BattleError.invalid("Original healing context is invalid") }
        let target = input.target,flags = input.encodedSubtype&15
        var result = OriginalHealingResult(troopRoll:nil,moraleRoll:nil,troopsDelta:0,moraleDelta:0,
            remainingTroops:target.troops,remainingMorale:target.morale,remainingFlags:input.targetConditionFlags,moraleMutation:nil)
        if input.targetStatus != 2 { return result }
        let kernel = try healingKernel(input,tables:tables)
        if flags&1 != 0 {
            let roll = try rng.next(bound:kernel.troopBound)
            result.troopRoll = roll
            result.remainingTroops = kernel.troops(roll:roll)
            result.troopsDelta = result.remainingTroops-target.troops
        }
        if flags&2 != 0 {
            let roll = try rng.next(bound:kernel.moraleBound);result.moraleRoll = roll
            let amount = kernel.moraleAmount(roll:roll)
            var afterTroops = target;afterTroops.troops = result.remainingTroops
            let mutation = try setMorale(stats:afterTroops,unitStatus:input.targetStatus,conditionFlags:input.targetConditionFlags,
                requestedMorale:target.morale+amount,rng:&rng)
            result.moraleMutation = mutation;result.remainingMorale = mutation.remainingMorale
            result.remainingFlags = mutation.remainingFlags;result.moraleDelta = mutation.remainingMorale-target.morale
        }
        return result
    }
    /// MAIN2EC00..2EC50. Actual morale strategy uses this word quantity after
    /// a denominator4 success check; AI's random multiplier is absent here.
    static func moraleStrategyAmount(casterLevel:Int,targetLevel:Int,category:Int,targetMorale:Int) throws -> Int {
        guard (0...255).contains(casterLevel), (0...255).contains(targetLevel), (0...255).contains(category),
              (0...100).contains(targetMorale) else { throw BattleError.invalid("Original morale strategy inputs are invalid") }
        let quantity = Int(UInt16(truncatingIfNeeded:casterLevel/10+(category+2)*10-targetLevel/10))
        return min(quantity,targetMorale)
    }
    /// MAIN2EDB4..2EE18. Invoke only after the dispatcher marks a completed
    /// attempt; cancelled targets, weather rejection and rejected healing skip
    /// both MP consumption and this flat EXP. Damage-context EXP is separate.
    static func completeStrategy(abilityID:Int,casterClassID:Int,currentMP:Int,mpCost:Int) throws -> OriginalStrategyCompletion {
        guard (0..<36).contains(abilityID), (0..<19).contains(casterClassID), (0...255).contains(currentMP),
              (0...255).contains(mpCost) else { throw BattleError.invalid("Original strategy completion input is invalid") }
        let experience = abilityID < 15 ? 0 : ((21...29).contains(abilityID) && [12,18].contains(casterClassID) ? 12 : 8)
        return OriginalStrategyCompletion(remainingMP:Int(UInt8(truncatingIfNeeded:currentMP-mpCost)),flatExperience:experience)
    }
    /// MAIN31FDB..3216F consumes these presentation draws before producing
    /// physical damage. Its globals are explicit: the word comes from source
    /// global-object byte4/5, not from the battle object's weather byte4.
    /// Each consecutive four draws belongs to one projectile presentation.
    static func physicalPrelude(classID:Int,subtype:Int,sourceOptionsWord:Int,rng:inout OriginalRNG) throws -> [Int] {
        guard (0..<19).contains(classID), (0...255).contains(subtype),
              (0...65535).contains(sourceOptionsWord) else {
            throw BattleError.invalid("Original physical prelude requires source class/subtype/options")
        }
        if subtype == 7 || !(3...5).contains(classID) { return [] }
        let drawCount = (sourceOptionsWord & 0xF0) == 0 ? 8 : 16
        return try (0..<drawCount).map { _ in try rng.next(bound:16) }
    }
    /// MAIN31854..31925, called before writeback and recursive subtype7 combat.
    /// The first45 original runtime slots have faction semantics; export-local
    /// placement IDs and literal person IDs must not be substituted here.
    static func experienceGain(attackerLevel:Int,defenderLevel:Int,attackerRuntimeSlot:Int,
                               defenderRuntimeSlot:Int,damage:Int,defenderTroops:Int) throws -> OriginalExperienceGain {
        guard (0...255).contains(attackerLevel), (0...255).contains(defenderLevel),
              (0..<45).contains(attackerRuntimeSlot), (0..<45).contains(defenderRuntimeSlot),
              (0...65535).contains(defenderTroops), (0...defenderTroops).contains(damage) else {
            throw BattleError.invalid("Original experience inputs require valid runtime slots/quantities")
        }
        if attackerRuntimeSlot >= 15 { return OriginalExperienceGain(hit:0,defeatedTarget:0) }
        let hit = min(16,defenderLevel < attackerLevel ? 4 : 2*(defenderLevel-attackerLevel+3))
        let extra:Int
        if damage != defenderTroops { extra = 0 }
        else if defenderRuntimeSlot == 15 { extra = 48 }
        else if defenderLevel > attackerLevel { extra = 32 }
        else { extra = 64/(attackerLevel-defenderLevel+2) }
        return OriginalExperienceGain(hit:hit,defeatedTarget:extra)
    }
    /// MAIN1A8B4..1A9C8. Existing EXP plus a new gain is a source word. NPC
    /// identity range256..351 and an initially capped level retain old state.
    /// The source does not reapply the99 cap during a multi-level increment.
    static func applyExperience(sourcePersonWord:Int,level:Int,experience:Int,gain:Int) throws -> OriginalExperienceMutation {
        guard (0...65535).contains(sourcePersonWord), (0...255).contains(level),
              (0...255).contains(experience), (0...65535).contains(gain) else {
            throw BattleError.invalid("Original experience mutation input is not a source byte/word")
        }
        let identity = sourcePersonWord & 0xF1FF
        if (0x100...0x15F).contains(identity) {
            return OriginalExperienceMutation(level:level,experience:experience,levelsGained:0,ignoredReason:"source NPC identity range")
        }
        if level >= 99 {
            return OriginalExperienceMutation(level:level,experience:experience,levelsGained:0,ignoredReason:"source initial level cap")
        }
        let total = Int(UInt16(truncatingIfNeeded:experience+gain))
        let gained = total/100
        return OriginalExperienceMutation(level:Int(UInt8(truncatingIfNeeded:level+gained)),experience:total%100,
                                          levelsGained:gained,ignoredReason:nil)
    }
    static func physicalImpact(_ input:OriginalPhysicalInput,tables:OriginalCombatTables) throws -> OriginalPhysicalResult {
        try person(input.attacker); try person(input.defender); try tables.validate()
        guard tables.terrainDefensePercent.indices.contains(input.terrainID), (0...255).contains(input.subtype) else {
            throw BattleError.invalid("Original physical terrain/subtype is unresolved")
        }
        let attack = try attackStat(input.attacker,tables:tables)
        let defense = try defenseStat(input.defender,tables:tables)
        let a = input.attacker.classID/3, d = input.defender.classID/3
        var adjusted = Int64(defense)
        if (a == 0 && d == 1) || (a == 1 && d == 2) || (a == 2 && d == 0) { adjusted -= adjusted/4 }
        if (d == 0 && a == 1) || (d == 1 && a == 2) || (d == 2 && a == 0) { adjusted += adjusted/4 }
        var damage = max(0,Int64(attack)-adjusted/2)
        damage = try divide32(multiply32(damage,Int64(100-tables.terrainDefensePercent[input.terrainID])),100)
        if input.subtype == 7 { damage = try divide32(damage,2) }
        damage = min(Int64(input.defender.troops),max(1,damage))
        let loss:Int
        if damage == input.defender.troops { loss = input.defender.morale }
        else {
            let q = Int(damage)/(input.defender.level+5)/3
            loss = min(input.defender.morale,damage == 0 ? 0 : max(1,q))
        }
        return OriginalPhysicalResult(attack:attack,defense:defense,adjustedDefense:Int(adjusted),damage:Int(damage),
            moraleLoss:loss,counterRoll:nil,counterEligible:false,remainingTroops:input.defender.troops-Int(damage),
            remainingMorale:damage == input.defender.troops ? input.defender.morale : input.defender.morale-loss)
    }
    static func physicalStrike(_ input:OriginalPhysicalInput,tables:OriginalCombatTables,rng:inout OriginalRNG) throws -> OriginalPhysicalResult {
        var result = try physicalImpact(input,tables:tables)
        // Source draws before subtype/kill/status suppression; preserving that
        // otherwise unused draw is necessary to preserve later game randomness.
        var roll:Int?
        if tables.physicalSubtypeByClass[input.defender.classID] == 0 {
            roll = try rng.next(bound:150)
        }
        result.counterRoll = roll;result.counterEligible = physicalCounterEligible(input,damage:result.damage,roll:roll,tables:tables)
        return result
    }
    static func physicalCounterEligible(_ input:OriginalPhysicalInput,damage:Int,roll:Int?,tables:OriginalCombatTables)->Bool {
        tables.physicalSubtypeByClass[input.defender.classID] == 0 && roll.map {input.defender.attackScalar > $0} == true &&
            [0,2,5].contains(input.subtype) && damage != input.defender.troops && !input.defenderCounterDisabled
    }

    /// MAIN315ED..317CB. The first random result is truncated to one byte;
    /// failure is tested after consuming the jitter draw. A zero bound does
    /// not advance the shared source RNG. Intermediate DI arithmetic wraps.
    static func strategyKernel(_ input:OriginalStrategyInput,tables:OriginalCombatTables) throws -> OriginalStrategyKernel {
        try person(input.attacker); try person(input.defender); try tables.validate()
        guard (0...255).contains(input.terrainID), (0...255).contains(input.subtype),
              (0...255).contains(input.weatherCode), [2,3].contains(input.kind) else {
            throw BattleError.invalid("Original strategy damage context is incomplete or invalid")
        }
        let a = input.attacker, d = input.defender
        let bound = a.intellectScalar + a.level*a.intellectScalar/100
        var threshold = (d.intellectScalar + d.level*d.intellectScalar/100)/4
        let high = input.subtype>>4, low = input.subtype&15
        let coefficient = (4*low+high+2)*100
        let offense = input.kind == 2 ? 2*(a.intellectScalar+a.level*a.intellectScalar/50) : 0
        let defense = d.intellectScalar+d.level*d.intellectScalar/50
        var damage = Int64(UInt16(truncatingIfNeeded:offense-defense+coefficient))
        // MAIN2D60A..2D62C tests these class immediates, not a resource table.
        let resisted = [12,15,18].contains(d.classID)
        if resisted { threshold = Int(UInt16(truncatingIfNeeded:threshold*2)); damage = try divide32(damage,2) }
        if (high == 0 && input.terrainID == 1) ||
           (high == 1 && tables.strategyEnvironmentLookup[input.weatherCode] == 2) {
            damage = add32(damage,try divide32(damage,4))
        }
        // Source takes only AX for this unsigned word division, even when the
        // preceding25% addition has carried into the high word.
        let jitterBound = Int(UInt16(truncatingIfNeeded:damage))/50
        return OriginalStrategyKernel(bound:bound,threshold:threshold,damageBase:damage,jitterBound:jitterBound,resisted:resisted)
    }
    static func strategyQuantity(_ kernel:OriginalStrategyKernel,jitter:Int,targetTroops:Int) -> Int {
        Int(min(Int64(targetTroops),add32(kernel.damageBase,Int64(jitter))))
    }
    static func strategyStrike(_ input:OriginalStrategyInput,tables:OriginalCombatTables,rng:inout OriginalRNG) throws -> OriginalStrategyResult {
        let kernel = try strategyKernel(input,tables:tables)
        // Keep the same draw order: success byte, then jitter even on failure.
        let roll = try rng.next(bound:kernel.bound)
        let jitter = try rng.next(bound:kernel.jitterBound)
        return strategyResult(input,kernel:kernel,successRoll:roll,jitter:jitter)
    }
    static func strategyResult(_ input:OriginalStrategyInput,kernel:OriginalStrategyKernel,successRoll:Int,jitter:Int)->OriginalStrategyResult {
        let d = input.defender,bound = kernel.bound,threshold = kernel.threshold,jitterBound = kernel.jitterBound
        let rollByte = Int(UInt8(truncatingIfNeeded:successRoll))
        let success = input.kind != 2 || rollByte > threshold
        let quantity = success ? strategyQuantity(kernel,jitter:jitter,targetTroops:d.troops) : 0
        let loss = quantity == d.troops ? d.morale : min(d.morale,quantity == 0 ? 0 : max(1,quantity/100))
        return OriginalStrategyResult(chanceBound:bound,chanceRollByte:rollByte,defenderThreshold:threshold,
            jitterBound:jitterBound,jitterRoll:jitter,resisted:kernel.resisted,success:success,damage:quantity,
            moraleLoss:loss,remainingTroops:d.troops-quantity,remainingMorale:quantity == d.troops ? d.morale : d.morale-loss)
    }
}
