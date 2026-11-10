// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct BattleAnnotations:Codable,Equatable {
    enum Kind:String,Codable,CaseIterable {case pin,line,arrow,note
        var label:String {switch self {case .pin:return "핀";case .line:return "방어선";case .arrow:return "화살표";case .note:return "짧은 메모"}}
    }
    enum Style:String,Codable,CaseIterable {case gold,blue,pink
        var label:String {switch self {case .gold:return "금색 실선";case .blue:return "파란 점선";case .pink:return "분홍 파선"}}
    }
    struct Entry:Codable,Equatable,Identifiable {
        var id:UUID;var kind:Kind;var start:GridPoint;var end:GridPoint?;var text:String;var style:Style
    }
    var format = 1
    var battleID:String
    var attemptID:UUID
    var width:Int;var height:Int
    private(set) var entries:[Entry] = []
    init(battleID:String,attemptID:UUID,width:Int,height:Int) {
        self.battleID = battleID;self.attemptID = attemptID;self.width = width;self.height = height
    }
    func matches(_ session:OriginalBattleSession)->Bool {
        battleID == session.definition.id && attemptID == session.resultLog.attemptID && width == session.width && height == session.height
    }
    func validate() throws {
        func contains(_ p:GridPoint)->Bool {(0..<width).contains(p.x) && (0..<height).contains(p.y)}
        guard format == 1,!battleID.isEmpty,battleID.count <= 128,(1...127).contains(width),(1...127).contains(height),width*height <= 960,
              entries.count <= 100,Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ entry in
                  contains(entry.start) && (entry.end.map(contains) ?? true) && entry.text.count <= 80 &&
                  (entry.kind == .line || entry.kind == .arrow ? entry.end != nil : entry.end == nil)
              }) else {throw EngineError.invalid("Battle annotations have invalid identity, coordinates or capacity")}
    }
    mutating func upsert(_ entry:Entry) throws {
        var candidate = self
        if let index = candidate.entries.firstIndex(where:{$0.id == entry.id}) {candidate.entries[index] = entry}
        else {candidate.entries.append(entry)}
        try candidate.validate();self = candidate
    }
    mutating func remove(_ id:UUID) {entries.removeAll {$0.id == id}}
    mutating func clear() {entries = []}
}
