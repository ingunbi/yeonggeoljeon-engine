// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct OriginalPartyProfile:Codable {
    var format:Int
    var classSortRanks:[Int]
    var personZeroDefaultWord:Int
    var source:JSONValue?
    static func load(from url:URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self,from:Data(contentsOf:url));try value.validate();return value
    }
    func validate() throws {
        guard format == 1,classSortRanks.count == 256,classSortRanks.allSatisfy({(0...255).contains($0)}),
              (0...65535).contains(personZeroDefaultWord) else {throw BattleError.invalid("Original party profile is invalid")}
    }
}

struct OriginalPartyAssignment:Codable,Equatable {var person:Int;var setupSlot:Int}
struct OriginalPartyConfirmation:Codable {
    var roster:OriginalRoster
    var selectedPeople:[Int]
    var assignments:[OriginalPartyAssignment]
    var clearedSetupSlots:[Int]
}
struct OriginalPartySelection:Codable {
    var candidates:[Int]
    var selectedSlots:[Int]
    var fixedCount:Int
    var capacity:Int
    var remaining:Int
    var preparedRoster:OriginalRoster

    /// MAIN356D4..35843 leaves holes and inserts at the first empty source
    /// selection slot. The fixed prefix cannot be deselected.
    mutating func toggle(person:Int) throws {
        guard candidates.contains(person),selectedSlots.count == 15,(0...15).contains(capacity),
              (0...capacity).contains(fixedCount) else {throw BattleError.illegalAction("Original party candidate/selection is invalid")}
        if let index = selectedSlots[..<capacity].firstIndex(of:person) {
            guard index >= fixedCount else {throw BattleError.illegalAction("Original fixed party member cannot be deselected")}
            selectedSlots[index] = 65535;remaining = Int(UInt16(truncatingIfNeeded:remaining+1))
        } else {
            guard remaining != 0 else {throw BattleError.illegalAction("Original party has no remaining selection capacity")}
            guard let index = selectedSlots[..<capacity].firstIndex(of:65535) else {
                throw BattleError.unsupported("Original party insertion would exceed the interpreted selection array")
            }
            selectedSlots[index] = person;remaining -= 1
        }
    }
    /// MAIN35D24 and3500A..350A1. Only the person word changes in setup rows;
    /// their coordinates/flags remain source facts, including cleared rows.
    func confirm() throws -> OriginalPartyConfirmation {
        guard selectedSlots.count == 15,preparedRoster.slots.count == 45,(0...15).contains(capacity),
              (0...capacity).contains(fixedCount) else {throw BattleError.invalid("Original party confirmation state is invalid")}
        let selected = selectedSlots[..<capacity].filter{$0 != 65535}
        var roster = preparedRoster,scan = 0,assignments:[OriginalPartyAssignment] = []
        for person in selected.dropFirst(fixedCount) {
            guard let index = (scan..<45).first(where:{Int16(bitPattern:UInt16(truncatingIfNeeded:roster.slots[$0].person)) >= 0x400}) else {break}
            roster.slots[index].person = person;scan = index
            assignments.append(OriginalPartyAssignment(person:person,setupSlot:index))
        }
        // The source obtains row0, but limits this cleanup by45-lastScan.
        // Preserve that producing behavior rather than clear every later row.
        var cleared:[Int] = []
        for index in 0..<(45-scan) where Int16(bitPattern:UInt16(truncatingIfNeeded:roster.slots[index].person)) >= 0x400 {
            roster.slots[index].person = 65535;cleared.append(index)
        }
        return OriginalPartyConfirmation(roster:roster,selectedPeople:Array(selected),assignments:assignments,clearedSetupSlots:cleared)
    }
}

struct OriginalPartyCarryover:Codable {
    var liveSlots:[OriginalLiveUnit]
    var roundIndex:Int
    var weatherIndex:UInt8
}
struct OriginalPartySpawnAttempt:Codable,Equatable {
    var runtimeSlot:Int;var setupSlot:Int;var requested:GridPoint;var applied:Bool;var position:GridPoint;var fallback:Bool
}
struct OriginalPartyDeployment {
    var units:[Int:OriginalLiveUnit]
    var roster:OriginalRoster
    var roundIndex:Int
    var weatherIndex:UInt8
    var attempts:[OriginalPartySpawnAttempt]
}

enum OriginalParty {
    private static func resetTroops(_ id:Int,people:OriginalPeople,combat:OriginalCombatTables) throws {
        let person = try people.person(id)
        let maximum = try OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:combat)
        try people.update(id) {$0.rawTroops = maximum}
    }
    /// MAIN34EB6..34FAE fixes the first candidate, swapping person0 into it
    /// when present, then uses nested swaps by class rank and descending level.
    static func orderedCandidates(_ ids:[Int],people:OriginalPeople,profile:OriginalPartyProfile) throws -> [Int] {
        try profile.validate();var values = ids
        if let index = values.firstIndex(of:0),!values.isEmpty {values.swapAt(0,index)}
        guard values.count > 1 else {return values}
        for index in 1..<values.count {
            for other in (index+1)..<values.count {
                let a = try people.person(values[index]),b = try people.person(values[other])
                guard (0...255).contains(a.classID),(0...255).contains(b.classID) else {throw BattleError.invalid("Original party class is not a byte")}
                let ar = profile.classSortRanks[a.classID],br = profile.classSortRanks[b.classID]
                if br < ar || (br == ar && b.level > a.level) {values.swapAt(index,other)}
            }
        }
        return values
    }
    /// MAIN350EC/35F1C/36068. Prepare the source deployment phase after its
    /// optional inventory-management phase. HP resets apply to eligible people
    /// even if the player does not ultimately select them.
    static func prepareSelection(people:OriginalPeople,roster:OriginalRoster,profile:OriginalPartyProfile,combat:OriginalCombatTables) throws -> OriginalPartySelection {
        try profile.validate()
        guard roster.slots.count == 45 else {throw BattleError.invalid("Original party setup must contain45 source slots")}
        var roster = roster,selected = Array(repeating:65535,count:15),fixed = 0,capacity = 0
        for row in roster.slots where row.person != 65535 {
            if row.person < 0x400 {try resetTroops(row.person,people:people,combat:combat)}
            if row.enemy {continue}
            if Int16(bitPattern:UInt16(truncatingIfNeeded:row.person)) >= 0x400 {capacity += 1}
            else if try people.person(row.person).sourceFlags&31 == 0 {
                guard fixed < 15 else {throw BattleError.invalid("Original fixed party exceeds15 slots")}
                selected[fixed] = row.person;fixed += 1;capacity += 1
            }
        }
        guard capacity <= 15 else {throw BattleError.invalid("Original party selection capacity exceeds15 slots")}
        if profile.personZeroDefaultWord != 0 {
            if !selected[..<capacity].contains(0) {
                guard let empty = selected[..<capacity].firstIndex(of:65535) else {throw BattleError.unsupported("Original default person0 insertion has no interpreted source slot")}
                selected[empty] = 0
            }
        } else if let index = selected[..<capacity].firstIndex(of:0) {
            selected[index] = 65535
            if let setup = roster.slots.firstIndex(where:{$0.person == 0}) {roster.slots[setup].person = 65535}
        }
        let initialRemaining = capacity-fixed,faction = try people.person(0).sourceFlags&31
        var candidates:[Int] = []
        for id in 0..<384 {
            let person = try people.person(id)
            guard person.sourceFlags&31 == faction,person.sourceFlags&0x80 != 0 else {continue}
            if initialRemaining != 0 || roster.slots.contains(where:{$0.person == id}) {candidates.append(id)}
            try resetTroops(id,people:people,combat:combat)
            if candidates.count == 66 {break}
        }
        let available = Int(UInt16(truncatingIfNeeded:candidates.count-fixed))
        let remaining = min(initialRemaining,available)
        return OriginalPartySelection(candidates:try orderedCandidates(candidates,people:people,profile:profile),selectedSlots:selected,
            fixedCount:fixed,capacity:capacity,remaining:remaining,preparedRoster:roster)
    }

    /// MAIN2B068..2B0ED: depth-first, no visited set, depth5, cardinal source
    /// order. Occupied/blocked nodes still recurse; only a candidate requires
    /// both an empty cell and movement cost other than255.
    static func spawnPoint(requested:GridPoint,classID:Int,movement:OriginalMovementProfile,width:Int,height:Int,
                           terrain:[UInt8],occupancy:[GridPoint:Int]) throws -> GridPoint? {
        guard (1...127).contains(width),(1...127).contains(height),width*height <= 960,terrain.count == width*height else {
            throw BattleError.invalid("Original spawn marker geometry is invalid")
        }
        func contains(_ point:GridPoint)->Bool {(0..<width).contains(point.x) && (0..<height).contains(point.y)}
        guard contains(requested) else {return nil}
        func visit(_ point:GridPoint,_ depth:Int) throws -> GridPoint? {
            if occupancy[point] == nil,try movement.cost(classID:classID,terrain:Int(terrain[point.y*width+point.x])) != 255 {return point}
            if depth > 0 {
                for offset in movement.cardinalOffsets {
                    let next = GridPoint(x:point.x+offset.dx,y:point.y+offset.dy)
                    if contains(next),let result = try visit(next,depth-1) {return result}
                }
            }
            return nil
        }
        return try visit(requested,5)
    }
    /// MAIN2B982..2BA60. Facing is scriptFlags mask10, not live byte8's AI
    /// priority. Only the status1 activation path searches a spawn marker.
    @discardableResult
    static func activate(unit:inout OriginalLiveUnit,classID:Int,requested:GridPoint,flipped:Bool,
                         movement:OriginalMovementProfile,width:Int,height:Int,terrain:[UInt8],occupancy:inout[GridPoint:Int]) throws -> Bool {
        guard (0..<width).contains(requested.x),(0..<height).contains(requested.y) else {return false}
        var next = unit
        if next.status == 1 {
            next.status = 2
            if flipped {next.scriptFlags |= 0x10} else {next.scriptFlags &= ~UInt8(0x10)}
            guard let position = try spawnPoint(requested:requested,classID:classID,movement:movement,width:width,height:height,terrain:terrain,occupancy:occupancy) else {
                throw BattleError.unsupported("Original spawn marker remainedFF; unresolved raw marker coordinate is not substituted")
            }
            next.position = position
        } else {
            occupancy.removeValue(forKey:next.position);next.position = requested
        }
        occupancy[next.position] = next.slot;unit = next;return true
    }
    /// MAIN27016..2726B preserves original slot identities and statuses. Named
    /// rows can match more than once; fallback consumes the first unsigned
    /// person>=400 row, including an all-FF row whose255 coordinates reject.
    static func deploy(carryover:OriginalPartyCarryover,roster:OriginalRoster,people:OriginalPeople,movement:OriginalMovementProfile,
                       existingUnits:[Int:OriginalLiveUnit]? = nil,width:Int,height:Int,terrain:[UInt8]) throws -> OriginalPartyDeployment {
        guard let header = roster.header,header.preserveFriendlySlots,roster.slots.count == 45,
              carryover.liveSlots.count <= 45,Set(carryover.liveSlots.map(\.slot)).count == carryover.liveSlots.count,
              carryover.liveSlots.allSatisfy({(0..<45).contains($0.slot)}),(0...255).contains(carryover.roundIndex) else {
            throw BattleError.invalid("Original preserved party state is incomplete")
        }
        var units = existingUnits ?? Dictionary(uniqueKeysWithValues:carryover.liveSlots.map{($0.slot,$0)}),roster = roster,attempts:[OriginalPartySpawnAttempt] = []
        for slot in units.keys {
            units[slot]!.scriptFlags &= ~UInt8(4)
            if slot < 15 {units[slot]!.orderMode = try people.person(units[slot]!.person).sourceFlags&31 == 0 ? 7 : 1}
        }
        var occupancy:[GridPoint:Int] = [:]
        for unit in units.values.sorted(by:{$0.slot < $1.slot}) where unit.status == 2 {
            if (0..<width).contains(unit.position.x),(0..<height).contains(unit.position.y) {occupancy[unit.position] = unit.slot}
        }
        for slot in 0..<15 {
            guard var unit = units[slot],unit.status == 1 else {continue}
            unit.scriptFlags &= ~UInt8(0xC6)
            let matches = (0..<15).filter{roster.slots[$0].person == unit.person}
            let sources = matches.isEmpty ? (0..<15).first(where:{roster.slots[$0].person >= 0x400}).map{[$0]} ?? [] : matches
            for index in sources {
                let row = roster.slots[index],requested = GridPoint(x:row.x,y:row.y)
                let cls = try people.person(unit.person).classID
                let applied = try activate(unit:&unit,classID:cls,requested:requested,flipped:row.flags&4 == 0,
                    movement:movement,width:width,height:height,terrain:terrain,occupancy:&occupancy)
                attempts.append(OriginalPartySpawnAttempt(runtimeSlot:slot,setupSlot:index,requested:requested,applied:applied,position:unit.position,fallback:matches.isEmpty))
                if matches.isEmpty {roster.slots[index].person = unit.person}
            }
            units[slot] = unit
        }
        return OriginalPartyDeployment(units:units,roster:roster,roundIndex:header.sourceByte2 == 0 ? carryover.roundIndex : 0,
            weatherIndex:carryover.weatherIndex,attempts:attempts)
    }
}

extension OriginalBattleSession {
    /// MAIN27F90..28019: only victory result2 awards the source byte24 bonus
    /// to active friendlies, then converts every active slot to status1.
    func finishBattleForCarryover() throws -> OriginalPartyCarryover {
        if turns.result == 2 {
            for slot in 0..<45 {
                guard let unit = units[slot],unit.status == 2 else {continue}
                if slot < 15 && scriptValue24 != 0 {_ = try people.applyExperience(person:unit.person,gain:Int(scriptValue24))}
                units[slot]!.status = 1
            }
        }
        return OriginalPartyCarryover(liveSlots:units.values.sorted{$0.slot < $1.slot},
            roundIndex:turns.roundIndex,weatherIndex:turns.weatherIndex)
    }
}
