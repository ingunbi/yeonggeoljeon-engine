// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum BattleFavoriteAction:Codable,Hashable {
    case strategy(Int),item(Int)
    var valid:Bool {switch self {case .strategy(let id):return (0..<36).contains(id);case .item(let id):return (0..<64).contains(id)}}
}
/// F3 campaign data: IDs and user order only, never source inventory slots.
struct OfficerCommandFavorites:Codable,Equatable {
    struct Officer:Codable,Equatable {var personID:Int;var actions:[BattleFavoriteAction]}
    private(set) var officers:[Officer] = []
    private(set) var sourceIdentity:String? = nil
    init() {}
    func actions(for person:Int)->[BattleFavoriteAction] {officers.first {$0.personID == person}?.actions ?? []}
    func validate() throws {
        if let identity = sourceIdentity,!SourceCatalogIdentity.valid(identity) {throw EngineError.invalid("Favorite source identity is invalid")}
        guard officers.count <= 384,Set(officers.map(\.personID)).count == officers.count,
              officers.allSatisfy({(0..<384).contains($0.personID) && $0.actions.count <= 16 && $0.actions.allSatisfy(\.valid) && Set($0.actions).count == $0.actions.count}) else {
            throw EngineError.invalid("Officer command favorites contain invalid or duplicate IDs")
        }
    }
    func sourceIssue(for current:String?) -> String? {
        guard let current,SourceCatalogIdentity.valid(current) else {return "현재 원본 자료를 확인할 수 없습니다."}
        if officers.isEmpty {return nil}
        return sourceIdentity == current ? nil : "즐겨찾기가 다른 자료에서 저장되었거나 원본 정보가 없습니다. 확인 후 현재 자료로 초기화해 주세요."
    }
    mutating func reset(forSource identity:String) throws {
        guard SourceCatalogIdentity.valid(identity) else {throw EngineError.invalid("현재 원본 자료를 확인할 수 없습니다.")}
        officers = [];sourceIdentity = identity
    }
    mutating func set(person:Int,actions:[BattleFavoriteAction],sourceIdentity:String? = nil) throws {
        if sourceIdentity != nil || self.sourceIdentity != nil,let issue = sourceIssue(for:sourceIdentity) {throw EngineError.invalid(issue)}
        var candidate = self
        if let sourceIdentity {candidate.sourceIdentity = sourceIdentity}
        candidate.officers.removeAll {$0.personID == person}
        if !actions.isEmpty {candidate.officers.append(.init(personID:person,actions:actions))}
        guard (0..<384).contains(person) else {throw EngineError.invalid("Favorite person ID is invalid")}
        try candidate.validate();self = candidate
    }
    static func reasons(_ action:BattleFavoriteAction,in session:OriginalBattleSession,slot:Int) throws -> [String] {
        guard action.valid else {return ["알 수 없는 행동 ID"]}
        let unit = try session.live(slot),person = try session.people.person(unit.person)
        var reasons:[String] = []
        if unit.scriptFlags&2 != 0 {reasons.append("혼란 상태")}
        if unit.scriptFlags&0x80 != 0 {reasons.append("행동 완료")}
        if unit.scriptFlags&0x20 == 0 {reasons.append("매복을 해제한 뒤 사용")}
        switch action {
        case .strategy(let id):
            guard person.classID != 17 else {return reasons+["현재 병과는 책략 사용 불가"]}
            guard let levels = session.movement.strategyLevelRequirements,let costs = session.movement.strategyMPCosts,
                  levels.count == 36,costs.count == 36,levels[id].indices.contains(person.classID) else {return reasons+["책략 표 없음"]}
            if levels[id][person.classID] > person.level {reasons.append(levels[id][person.classID] > 99 ? "현재 병과에서 습득 불가" : "Lv.\(levels[id][person.classID]) 필요")}
            reasons += BattleAssistance.strategyReasons(ability:id,cost:costs[id],mp:unit.mp,rain:session.combat.strategyEnvironmentLookup[Int(session.turns.weatherIndex)] == 2).map(\.text)
        case .item(let id):
            if !person.itemIDs.contains(id) {reasons.append("소지품 없음")}
            let use = OriginalItemUse.of(id)
            if case .unusable = use {reasons.append("사용할 수 없는 물품")}
            if case .attack(let family,_) = use,family == 0,session.combat.strategyEnvironmentLookup[Int(session.turns.weatherIndex)] == 2 {reasons.append("비가 와서 화계 도구 사용 불가")}
            if let refusal = try OriginalItemOperation.classRefusal(in:session,userSlot:slot,use:use) {
                let labels = ["wrongClass":"현재 병과에서 사용할 수 없음","lowLevel":"전직에 필요한 레벨 부족"]
                reasons.append(labels[refusal] ?? "현재 전직 조건을 충족하지 않음")
            }
        }
        return reasons
    }
}
