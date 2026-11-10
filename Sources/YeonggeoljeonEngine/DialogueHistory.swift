// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Only presentation events belong here. Never populate from a dialogue export.
struct DialogueHistory:Codable,Equatable {
    struct Entry:Codable,Equatable,Identifiable {
        var id:UUID;var sequence:Int;var person:Int?;var speaker:String;var text:String
        var chapter:Int;var map:Int;var record:String?;var bookmarked:Bool
    }
    private(set) var entries:[Entry] = []
    private(set) var nextSequence = 0
    private(set) var activeID:UUID?
    private(set) var activeSignature:String?
    static let recentLimit = 300
    static let bookmarkLimit = 200
    private enum CodingKeys:String,CodingKey {case entries,nextSequence,activeID,activeSignature}
    init() {}
    init(from decoder:Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        entries = try c.decodeIfPresent([Entry].self,forKey:.entries) ?? []
        nextSequence = try c.decodeIfPresent(Int.self,forKey:.nextSequence) ?? 0
        activeID = try c.decodeIfPresent(UUID.self,forKey:.activeID)
        activeSignature = try c.decodeIfPresent(String.self,forKey:.activeSignature)
        try validate()
    }
    @discardableResult mutating func present(person:Int?,speaker:String,text:String,chapter:Int,map:Int,record:String?,signature:String) throws -> UUID {
        if activeSignature == signature,let activeID,entries.contains(where:{$0.id == activeID}) {return activeID}
        guard nextSequence < Int.max else {throw EngineError.invalid("Dialogue history sequence limit reached")}
        var next = self
        let entry = Entry(id:UUID(),sequence:nextSequence,person:person,speaker:speaker,text:text,chapter:chapter,map:map,record:record,bookmarked:false)
        next.entries.append(entry);next.nextSequence += 1;next.activeID = entry.id;next.activeSignature = signature
        next.prune();try next.validate();self = next;return entry.id
    }
    mutating func finishPresentation() {activeID = nil;activeSignature = nil}
    mutating func setBookmark(_ id:UUID,enabled:Bool) throws {
        guard let index = entries.firstIndex(where:{$0.id == id}) else {throw EngineError.invalid("보관된 대사가 없습니다.")}
        var next = self;next.entries[index].bookmarked = enabled;next.prune();try next.validate();self = next
    }
    func search(query:String = "",person:Int? = nil,chapter:Int? = nil,map:Int? = nil,record:String? = nil,bookmarksOnly:Bool = false)->[Entry] {
        let needle = query.precomposedStringWithCanonicalMapping.trimmingCharacters(in:.whitespacesAndNewlines)
        return entries.filter {entry in
            (person == nil || entry.person == person) && (chapter == nil || entry.chapter == chapter) &&
            (map == nil || entry.map == map) && (record == nil || entry.record == record) && (!bookmarksOnly || entry.bookmarked) &&
            (needle.isEmpty || (entry.speaker+" "+entry.text).precomposedStringWithCanonicalMapping.range(of:needle,options:[.caseInsensitive,.diacriticInsensitive]) != nil)
        }
    }
    private mutating func prune() {
        let cutoff = max(0,nextSequence-Self.recentLimit)
        entries.removeAll {!$0.bookmarked && $0.sequence < cutoff && $0.id != activeID}
        while entries.reduce(0,{$0+$1.text.utf8.count+$1.speaker.utf8.count}) > 1_000_000,
              let index = entries.firstIndex(where:{!$0.bookmarked && $0.id != activeID}) {entries.remove(at:index)}
    }
    func validate() throws {
        guard nextSequence >= 0,entries.count <= Self.recentLimit+Self.bookmarkLimit,
              entries.filter(\.bookmarked).count <= Self.bookmarkLimit,
              Set(entries.map(\.id)).count == entries.count,Set(entries.map(\.sequence)).count == entries.count,
              entries.map(\.sequence) == entries.map(\.sequence).sorted(),
              entries.allSatisfy({(0..<nextSequence).contains($0.sequence) && ($0.person == nil || (0...65535).contains($0.person!)) &&
                $0.speaker.count <= 256 && !$0.text.isEmpty && $0.text.utf8.count <= 32768 && (0...255).contains($0.chapter) &&
                (0...65535).contains($0.map) && ($0.record?.count ?? 0) <= 256}),
              entries.reduce(0,{$0+$1.text.utf8.count+$1.speaker.utf8.count}) <= 1_000_000,
              (activeSignature?.utf8.count ?? 0) <= 65536,(activeID == nil) == (activeSignature == nil),
              activeID == nil || entries.contains(where:{$0.id == activeID}) else {
            throw EngineError.invalid("대사 기록 한도(최근 300건·북마크 200건) 또는 저장 형식이 올바르지 않습니다.")
        }
    }
}
