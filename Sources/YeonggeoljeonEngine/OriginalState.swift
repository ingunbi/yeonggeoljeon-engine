// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Original initial person values. They do not establish a native faction,
/// battle slot, conditional eligibility, or a selected saved campaign state.
/// In a catalog, `sourceRole` is raw BAKDATA state byte one. In
/// `OriginalPeople` it is the constructed object field2B (raw plus two).
struct OriginalPersonDefinition: Codable {
    var id:Int
    var name:String
    var classID:Int
    var level:Int
    var experience:Int
    var rawTroops:Int
    var defenseScalar:Int
    var attackScalar:Int
    var intellectScalar:Int
    var personality:Int
    var personalScalar:Int
    var itemIDs:[Int]
    var sourceFlags:Int
    var sourceRole:Int
    var sourceContext2:Int
    var sourceContext3:Int
    var source:JSONValue?
}

struct OriginalPersonCatalog:Codable {
    var format:Int
    var people:[OriginalPersonDefinition]
    var source:JSONValue?
    var limitations:[String]?

    static func load(from url:URL) throws -> OriginalPersonCatalog {
        let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
        guard let size = attributes[.size] as? NSNumber, (1...8*1024*1024).contains(size.intValue) else {
            throw EngineError.invalid("Original person catalog exceeds its supported input size")
        }
        let value = try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
        try value.validate(); return value
    }
    func validate() throws {
        guard format == 1, people.count == 384, Set(people.map(\.id)) == Set(0..<384) else {
            throw EngineError.invalid("Original person catalog does not cover the examined source population")
        }
        for person in people {
            guard (0...255).contains(person.classID), (0...255).contains(person.level),
                  (0...255).contains(person.experience), (0...65535).contains(person.rawTroops),
                  (0...100).contains(person.attackScalar), (0...100).contains(person.defenseScalar),
                  (0...100).contains(person.intellectScalar), (0...100).contains(person.personalScalar),
                  person.itemIDs.count == 8, person.itemIDs.allSatisfy({(0...255).contains($0)}),
                  [person.sourceFlags,person.sourceRole,person.sourceContext2,person.sourceContext3,person.personality].allSatisfy({(0...255).contains($0)}) else {
                throw EngineError.invalid("Original person values exceed their source widths")
            }
        }
    }
    func person(_ id:Int) throws -> OriginalPersonDefinition {
        guard let person = people.first(where:{$0.id == id}) else {
            throw EngineError.invalid("Original person identity is unavailable: \(id)")
        }
        return person
    }
}

/// One shared original person object. Live battle units hold identity and
/// morale, never a private copy of troops, class, level, EXP or equipment.
final class OriginalPeople {
    private(set) var values:[Int:OriginalPersonDefinition]
    init(catalog:OriginalPersonCatalog,tables:OriginalCombatTables) throws {
        try catalog.validate()
        var values = Dictionary(uniqueKeysWithValues:catalog.people.map { ($0.id,$0) })
        for id in values.keys {
            var person = values[id]!
            person.rawTroops = min(person.rawTroops,try OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:tables))
            // MAIN1AAEE..1AAF3 stores BAKDATA state byte one plus two in
            // object field2B. Script2F later writes that field directly.
            person.sourceRole = (person.sourceRole + 2) & 0xFF
            values[id] = person
        }
        self.values = values
    }
    func person(_ id:Int) throws -> OriginalPersonDefinition {
        guard let value = values[id] else { throw BattleError.invalid("Original shared person identity \(id) is unavailable") }
        return value
    }
    func update(_ id:Int,_ body:(inout OriginalPersonDefinition)throws->Void) throws {
        var person = try self.person(id)
        try body(&person)
        values[id] = person
    }
    /// Shared-person savepoint. A failed native operation must not leave a
    /// partial source class/level/HP mutation visible to another live unit.
    /// Nested transactions retain their own value-semantic savepoints.
    func transaction<T>(_ body:() throws -> T) rethrows -> T {
        let before = values
        do { return try body() }
        catch { values = before;throw error }
    }
    func stats(_ id:Int,morale:Int) throws -> OriginalPersonStats {
        let value = try person(id)
        return OriginalPersonStats(classID:value.classID,level:value.level,troops:value.rawTroops,
            attackScalar:value.attackScalar,defenseScalar:value.defenseScalar,intellectScalar:value.intellectScalar,
            morale:morale,itemIDs:value.itemIDs)
    }
    func applyExperience(person id:Int,gain:Int) throws -> OriginalExperienceMutation {
        let value = try person(id)
        let result = try OriginalCombat.applyExperience(sourcePersonWord:id|0x200,level:value.level,experience:value.experience,gain:gain)
        try update(id) { $0.level = result.level; $0.experience = result.experience }
        return result
    }
    /// MAIN15B78 keeps the upper three bits; these flags are not unit status.
    func setAffiliation(person id:Int,value:Int) throws {
        guard (0...255).contains(value) else { throw BattleError.invalid("Original affiliation operand is not a byte") }
        try update(id) { $0.sourceFlags = ($0.sourceFlags & 0xE0) | (value & 0x1F) }
    }
}

struct OriginalObjective:Codable,Equatable { var eventKind:Int; var enabled:Bool; var person:Int }
struct OriginalBattleHeader:Codable,Equatable {
    var preserveFriendlySlots:Bool; var turnLimit:Int; var sourceByte2:Int
    var discardedBytes:[Int]; var objectives:[OriginalObjective]
}
struct OriginalPlacement:Codable,Equatable {
    var ordinal:Int; var person:Int; var x:Int; var y:Int; var selector:Int; var flag:Int
    var flags:Int; var rawMode:Int; var parameter:Int; var classID:Int; var level:Int
    var enemy:Bool { flags&1 != 0 }
    /// A source memset-FF setup row. The descriptor ordinal is unknown; the
    /// containing array index owns runtime setup-slot identity.
    static var cleared:Self { Self(ordinal:-1,person:65535,x:255,y:255,selector:255,flag:255,
        flags:65535,rawMode:255,parameter:65535,classID:255,level:255) }
}
struct OriginalPlacementProgram:Codable {
    var chapter:Int; var member:Int; var block:Int; var offset:Int
    var opcode:Int; var rows:[OriginalPlacement]; var replaceSide:Int?
    var header:OriginalBattleHeader?; var source:JSONValue?
}
struct OriginalRosterCatalog:Codable {
    var format:Int; var programs:[OriginalPlacementProgram]; var source:JSONValue?
    static func load(from url:URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
        guard value.format == 1, value.programs.count <= 4096 else { throw BattleError.invalid("Original placement catalog format/bounds") }
        var ids = Set<String>()
        for program in value.programs {
            guard ids.insert("\(program.chapter):\(program.member):\(program.offset)").inserted,
                  [3,0x22].contains(program.opcode),program.rows.count == 30,
                  (program.opcode == 3) == (program.header != nil),
                  program.rows.enumerated().allSatisfy({ pair in
                      let p = pair.element
                      return p.ordinal == pair.offset && (0...65535).contains(p.person) && (0...65535).contains(p.parameter) &&
                          [p.x,p.y,p.selector,p.flag,p.flags,p.rawMode,p.classID,p.level].allSatisfy({(0...255).contains($0)})
                  }) else { throw BattleError.invalid("Original placement identity/population/value domain") }
        }
        return value
    }
    func program(chapter:Int,member:Int,offset:Int) throws -> OriginalPlacementProgram {
        guard let program = programs.first(where:{$0.chapter == chapter && $0.member == member && $0.offset == offset}) else {
            throw BattleError.invalid("Original placement program identity is unavailable")
        }
        return program
    }
}

/// Source context's compacted45 setup slots. Eligibility is evaluated at the
/// executed opcode, never by lexical projection from a later battle catalog.
struct OriginalRoster:Codable,Equatable {
    var slots:[OriginalPlacement] = Array(repeating:.cleared,count:45)
    var header:OriginalBattleHeader?
    mutating func apply(_ program:OriginalPlacementProgram,flags:OriginalCampaignState) throws {
        var next = self
        if program.opcode == 3 {
            next.slots = Array(repeating:.cleared,count:45); next.header = program.header
        } else if program.opcode == 0x22, let side = program.replaceSide {
            // MAIN1CB3E clears only the person word. Empty source rows retain
            // their coordinates, flags and other fields for later carryover.
            for index in next.slots.indices where next.slots[index].person != 65535 && next.slots[index].enemy == (side != 0) {
                next.slots[index].person = 65535
            }
        } else { throw BattleError.invalid("Original placement producer is unsupported") }
        for row in program.rows {
            if row.person == 65535 { continue }
            if row.selector != 0 { if try !flags.flag(row.flag) { continue } }
            guard let free = next.slots.firstIndex(where:{$0.person == 65535}) else { throw BattleError.invalid("Original compacted roster exceeded45 slots") }
            next.slots[free] = row
        }
        self = next
    }
}
