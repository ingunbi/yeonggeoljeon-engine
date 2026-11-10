// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Campaign-owned helpers. Encode and restore this value in the same atomic
/// snapshot as the original state; it must never be merged with a newer game.
/// Application preferences do not belong here. Future additions need their
/// own default decoding and an explicit schema migration when semantics change.
struct CampaignExtras:Codable,Equatable {
    static let currentFormat = 1
    var format = currentFormat
    var favoritePeople:[Int] = []
    var partyPresets:[PartyPreset] = []
    var protectedItems:[ProtectedItemRule] = []
    var journal = CampaignJournal()
    var retryJourney:CampaignJourneyCheckpoint? = nil
    var commandFavorites = OfficerCommandFavorites()
    var dialogueHistory = DialogueHistory()
    var observedShops = ObservedShopStock()
    var battleArchives = BattleArchiveProgress()
    var annotations:BattleAnnotations? = nil
    var eventHints:ReviewedEventHints.Progress? = nil

    struct PartyPreset:Codable,Equatable,Identifiable {
        var id:UUID
        var name:String
        /// Source person IDs in the user's preferred order, not source slots.
        var people:[Int]
        var sourceIdentity:String? = nil
        func sourceIssue(for identity:String?) -> String? {
            guard let identity,SourceCatalogIdentity.valid(identity),sourceIdentity == identity else {
                return "저장한 편성의 원본 자료를 확인할 수 없습니다. 현재 자료에서 편성을 다시 저장해 주세요."
            }
            return nil
        }
    }
    struct ProtectedItemRule:Codable,Equatable {
        var personID:Int
        var itemID:Int
        /// Selling/discarding are always protected; use protection is opt-in.
        var protectUse = false
        private enum CodingKeys:String,CodingKey {case personID,itemID,protectUse}
        init(personID:Int,itemID:Int,protectUse:Bool = false) {
            self.personID = personID;self.itemID = itemID;self.protectUse = protectUse
        }
        init(from decoder:Decoder) throws {
            let c = try decoder.container(keyedBy:CodingKeys.self)
            personID = try c.decode(Int.self,forKey:.personID)
            itemID = try c.decode(Int.self,forKey:.itemID)
            protectUse = try c.decodeIfPresent(Bool.self,forKey:.protectUse) ?? false
        }
    }
    enum ProtectedItemOperation {case sell,discard,use,script}
    private enum CodingKeys:String,CodingKey {case format,favoritePeople,partyPresets,protectedItems,journal,retryJourney,commandFavorites,dialogueHistory,observedShops,battleArchives,annotations,eventHints}
    init() {}
    init(from decoder:Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        format = try c.decodeIfPresent(Int.self,forKey:.format) ?? Self.currentFormat
        favoritePeople = try c.decodeIfPresent([Int].self,forKey:.favoritePeople) ?? []
        partyPresets = try c.decodeIfPresent([PartyPreset].self,forKey:.partyPresets) ?? []
        protectedItems = try c.decodeIfPresent([ProtectedItemRule].self,forKey:.protectedItems) ?? []
        commandFavorites = try c.decodeIfPresent(OfficerCommandFavorites.self,forKey:.commandFavorites) ?? OfficerCommandFavorites()
        journal = try c.decodeIfPresent(CampaignJournal.self,forKey:.journal) ?? CampaignJournal()
        retryJourney = try c.decodeIfPresent(CampaignJourneyCheckpoint.self,forKey:.retryJourney)
        dialogueHistory = try c.decodeIfPresent(DialogueHistory.self,forKey:.dialogueHistory) ?? DialogueHistory()
        observedShops = try c.decodeIfPresent(ObservedShopStock.self,forKey:.observedShops) ?? ObservedShopStock()
        battleArchives = try c.decodeIfPresent(BattleArchiveProgress.self,forKey:.battleArchives) ?? BattleArchiveProgress()
        annotations = try c.decodeIfPresent(BattleAnnotations.self,forKey:.annotations)
        eventHints = try c.decodeIfPresent(ReviewedEventHints.Progress.self,forKey:.eventHints)
        try validate()
    }
    func validate() throws {
        try journal.validate()
        try retryJourney?.validate()
        try commandFavorites.validate()
        try dialogueHistory.validate();try observedShops.validate()
        try battleArchives.validate();try annotations?.validate()
        try eventHints?.validate()
        guard format == Self.currentFormat,favoritePeople.count <= 384,
              favoritePeople.allSatisfy({(0..<384).contains($0)}),Set(favoritePeople).count == favoritePeople.count,
              partyPresets.count <= 20,Set(partyPresets.map(\.id)).count == partyPresets.count,
              protectedItems.count <= 384*64 else {
            throw EngineError.invalid("Campaign extras schema, favorites or preset identity is invalid")
        }
        for preset in partyPresets {
            if let identity = preset.sourceIdentity,!SourceCatalogIdentity.valid(identity) {throw EngineError.invalid("Party preset source identity is invalid")}
            guard !preset.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,preset.name.count <= 64,
                  preset.people.count <= 15,Set(preset.people).count == preset.people.count,
                  preset.people.allSatisfy({(0..<384).contains($0)}) else {
                throw EngineError.invalid("Campaign party preset has an invalid name or person list")
            }
        }
        var keys = Set<Int>()
        for rule in protectedItems {
            guard (0..<384).contains(rule.personID),(0..<64).contains(rule.itemID),
                  keys.insert(rule.personID*64+rule.itemID).inserted else {
                throw EngineError.invalid("Campaign item protection has an invalid or duplicate key")
            }
        }
    }
    func protects(personID:Int,itemID:Int,operation:ProtectedItemOperation) -> Bool {
        // Story/event consumption and forced collection retain original rules.
        if case .script = operation {return false}
        guard let rule = protectedItems.first(where:{$0.personID == personID && $0.itemID == itemID}) else {return false}
        if case .use = operation {return rule.protectUse}
        return true
    }
    mutating func setFavorite(_ personID:Int,enabled:Bool) throws {
        guard (0..<384).contains(personID) else {throw EngineError.invalid("Favorite person ID is invalid")}
        var next = self
        next.favoritePeople.removeAll {$0 == personID}
        if enabled {next.favoritePeople.append(personID)}
        try next.validate();self = next
    }
    mutating func setItemProtection(personID:Int,itemID:Int,enabled:Bool,protectUse:Bool = false) throws {
        guard (0..<384).contains(personID),(0..<64).contains(itemID) else {throw EngineError.invalid("Item protection key is invalid")}
        var next = self
        next.protectedItems.removeAll {$0.personID == personID && $0.itemID == itemID}
        if enabled {next.protectedItems.append(.init(personID:personID,itemID:itemID,protectUse:protectUse))}
        try next.validate();self = next
    }
    /// Call only with a successful item transfer, inside the same transaction.
    /// The sender's type-level rule remains for duplicates or future copies.
    mutating func transferProtection(from:Int,to:Int,item:Int) throws {
        guard (0..<384).contains(from),(0..<384).contains(to),(0..<64).contains(item) else {
            throw EngineError.invalid("Item protection transfer key is invalid")
        }
        guard let original = protectedItems.first(where:{$0.personID == from && $0.itemID == item}) else {return}
        let use = original.protectUse || protectedItems.contains {$0.personID == to && $0.itemID == item && $0.protectUse}
        try setItemProtection(personID:to,itemID:item,enabled:true,protectUse:use)
    }
    @discardableResult mutating func savePreset(name:String,people:[Int],id:UUID? = nil,sourceIdentity:String? = nil) throws -> UUID {
        var next = self
        let identity = sourceIdentity ?? id.flatMap {key in partyPresets.first {$0.id == key}?.sourceIdentity}
        let value = PartyPreset(id:id ?? UUID(),name:name.trimmingCharacters(in:.whitespacesAndNewlines),people:people,sourceIdentity:identity)
        if let index = next.partyPresets.firstIndex(where:{$0.id == value.id}) {next.partyPresets[index] = value}
        else {next.partyPresets.append(value)}
        try next.validate();self = next;return value.id
    }
    mutating func removePreset(_ id:UUID) {partyPresets.removeAll {$0.id == id}}
}
