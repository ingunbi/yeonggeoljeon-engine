// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct OriginalScriptBattleMutation: Codable, Equatable {
    var person: Int
    var selector: Int
    var runtimeSlot: Int?
    var modeSetterApplied: Bool
    var targetSetterApplied: Bool
    var goalSetterApplied: Bool
    var flag4ClearApplied: Bool
}

struct OriginalScriptInventoryGrant: Codable, Equatable {
    var person: Int
    var itemID: Int
    var insertedSlot: Int?
    var replacedItemID: Int?
    var cancelled: Bool
}

extension OriginalBattleSession {
    /// MAIN1C946..1C9E5 consumes the campaign owner's typed arguments. The
    /// native methods3356A/3385A/33F5C/33F8E search all45 source slots in order,
    /// including reserves and retired slots, rather than requiring an active
    /// board actor. This operation changes AI orders/targets, not person stats.
    @discardableResult
    func applyScriptAttribute(arguments:[Int]) throws -> OriginalScriptBattleMutation {
        guard arguments.count >= 2, (0...65535).contains(arguments[0]),
              (0...255).contains(arguments[1]) else {
            throw BattleError.invalid("Original battle attribute requires typed person and selector")
        }
        let personID = arguments[0], selector = arguments[1]
        let count = [0,1,2,3,5].contains(selector) ? 3 : [4,6].contains(selector) ? 4 : 2
        guard arguments.count == count else {
            throw BattleError.invalid("Original battle attribute operand shape does not match its selector")
        }
        if count == 3 && !(0...65535).contains(arguments[2]) {
            throw BattleError.invalid("Original battle attribute word operand is invalid")
        }
        if count == 4 && !arguments[2...3].allSatisfy({(0...255).contains($0)}) {
            throw BattleError.invalid("Original battle attribute coordinate operands are not bytes")
        }
        var result = OriginalScriptBattleMutation(person:personID,selector:selector,runtimeSlot:nil,
            modeSetterApplied:false,targetSetterApplied:false,goalSetterApplied:false,flag4ClearApplied:false)
        guard let slot = units.keys.sorted().first(where:{units[$0]?.person == personID}),
              var unit = units[slot] else { return result }
        result.runtimeSlot = slot
        let person = try people.person(personID)
        // For an out-of-board byte coordinate the source reads outside the
        // interpreted map. Preserve that uncertainty before committing changes.
        let coordinate:GridPoint?
        if [4,6].contains(selector) {
            let point = GridPoint(x:arguments[2],y:arguments[3])
            guard (0..<width).contains(point.x),(0..<height).contains(point.y) else {
                throw BattleError.unsupported("Original script goal reads outside the interpreted map geometry")
            }
            coordinate = point
        } else { coordinate = nil }
        // Source3385A's affiliation gate applies only to the mode setter. The
        // later target/goal setters execute even when this first method declines.
        if person.sourceFlags&31 != 0 {
            unit.orderMode = try movement.orderMode(rawMode:UInt8(selector),currentMode:unit.orderMode)
            unit.scriptFlags &= ~UInt8(4)
            result.modeSetterApplied = true; result.flag4ClearApplied = true
        }
        if [3,5].contains(selector),
           let target = units.keys.sorted().first(where:{units[$0]?.person == arguments[2]}) {
            unit.scriptFlags &= ~UInt8(4)
            unit.preferredTarget = target
            // Source changes unit+5 only; preserve its stored coordinate fields.
            result.targetSetterApplied = true; result.flag4ClearApplied = true
        }
        if let point = coordinate {
            unit.scriptFlags &= ~UInt8(4); result.flag4ClearApplied = true
            let cost = try movement.cost(classID:person.classID,terrain:Int(terrain[point.y*width+point.x]))
            if cost != 255 {
                unit.goal = point; unit.preferredTarget = nil
                result.goalSetterApplied = true
            }
        }
        // Selectors0/1/2 consume a typed word without further use. Selectors
        // above6 have no trailing operands after the common mode method.
        units[slot] = unit
        return result
    }
}

extension OriginalPeople {
    /// MAIN1C902..1C943 resolves the recipient in its host: person0 outside a
    /// battle, or the explicit battle-context+7 person within map kind3.
    /// MAIN1A6EC's first-empty insertion is automatic. A full inventory needs
    /// the original replacement choice; absent input remains an explicit stop.
    @discardableResult
    func grantScriptItem(person personID:Int,itemID:Int,replacementChoice:Int? = nil) throws -> OriginalScriptInventoryGrant {
        guard (0..<64).contains(itemID) else {
            throw BattleError.unsupported("Original script item identity is outside the examined item population")
        }
        let person = try self.person(personID)
        guard person.itemIDs.count == 8, person.itemIDs.allSatisfy({$0 == 255 || (0..<64).contains($0)}) else {
            throw BattleError.unsupported("Original script recipient inventory has unexamined item identities")
        }
        if let empty = person.itemIDs.firstIndex(of:255) {
            try update(personID) { $0.itemIDs[empty] = itemID }
            return OriginalScriptInventoryGrant(person:personID,itemID:itemID,insertedSlot:empty,replacedItemID:nil,cancelled:false)
        }
        guard let choice = replacementChoice else {
            throw BattleError.unsupported("Original full-inventory replacement requires a player choice")
        }
        if choice == 255 {
            return OriginalScriptInventoryGrant(person:personID,itemID:itemID,insertedSlot:nil,replacedItemID:nil,cancelled:true)
        }
        guard (0..<8).contains(choice) else { throw BattleError.invalid("Original inventory replacement choice is invalid") }
        // Source1A82C chooses an old item ID, then1A834 finds its first slot.
        // Duplicate old IDs therefore replace the first match, not the chosen
        // duplicate's visual index. Retain that observable source behavior.
        let oldID = person.itemIDs[choice]
        let slot = person.itemIDs.firstIndex(of:oldID)!
        try update(personID) { $0.itemIDs[slot] = itemID }
        return OriginalScriptInventoryGrant(person:personID,itemID:itemID,insertedSlot:slot,replacedItemID:oldID,cancelled:false)
    }
}
