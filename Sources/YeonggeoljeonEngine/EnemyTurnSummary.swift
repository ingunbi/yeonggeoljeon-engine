// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Public, observed values at the boundary. Hidden enemies never enter the
/// snapshot, and their absence is not interpreted as an event location.
struct EnemyTurnSnapshot {
    struct Unit:Equatable {
        var person:Int;var name:String;var troops:Int;var morale:Int;var mp:Int;var flags:UInt8;var point:GridPoint
    }
    var round:Int
    var units:[Int:Unit]
    init(_ session:OriginalBattleSession) {
        round = session.turns.roundIndex
        units = Dictionary(uniqueKeysWithValues:session.units.values.compactMap { value in
            guard value.status == 2,(!value.enemy || value.scriptFlags&0x20 != 0),let person = try? session.people.person(value.person) else { return nil }
            return (value.person,Unit(person:value.person,name:person.name,troops:person.rawTroops,morale:value.morale,mp:Int(value.mp),flags:value.scriptFlags,point:value.position))
        })
    }
    struct Change:Equatable { var person:Int;var name:String;var detail:String;var point:GridPoint? }
    func changes(to next:EnemyTurnSnapshot) -> [Change] {
        var result:[Change] = []
        for id in units.keys.sorted() {
            let old = units[id]!
            guard let new = next.units[id] else { result.append(.init(person:id,name:old.name,detail:"전장을 떠났거나 현재 확인할 수 없습니다.",point:nil));continue }
            var facts:[String] = []
            if new.troops != old.troops { facts.append("병력 \(old.troops) → \(new.troops)") }
            if new.morale != old.morale { facts.append("사기 \(old.morale) → \(new.morale)") }
            if new.mp != old.mp { facts.append("책략치 \(old.mp) → \(new.mp)") }
            if (new.flags^old.flags)&2 != 0 { facts.append(new.flags&2 != 0 ? "혼란 발생" : "혼란 회복") }
            if new.point != old.point { facts.append("위치 이동") }
            if !facts.isEmpty { result.append(.init(person:id,name:new.name,detail:facts.joined(separator:" · "),point:new.point)) }
        }
        for id in next.units.keys.sorted() where units[id] == nil {
            let value = next.units[id]!
            result.append(.init(person:id,name:value.name,detail:"이번 턴에 새로 확인한 부대",point:value.point))
        }
        return result
    }
    #if canImport(AppKit)
    static func sheet(_ changes:[Change],onChoose:@escaping (Int?)->Void) -> CanvasSheet {
        CanvasSheet(portrait:nil,speaker:"적 턴 변화",line:"적 턴 전후에 공개된 상태의 변화",badge:("변화","\(changes.count)"),
            rows:changes.isEmpty ? [.init(label:"확인된 변화 없음")] : changes.map {.init(label:$0.name,detail:.init(heading:$0.name,body:$0.detail))},
            mode:.list,hint:"선택: 현재 위치 보기 · Esc 닫기 · 중간 공격 순서는 전투 결과 기록에서 확인",fullCanvas:true,onChoose:onChoose)
    }
    #endif
}
