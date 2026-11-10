// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Projects first-matching-item removal and first-empty-slot insertion on
/// values only. The original host still checks funds and commits the action.
enum EquipmentComparison {
    struct Change:Equatable {
        var before:OfficerComparison.Snapshot
        var after:OfficerComparison.Snapshot
    }
    struct Comparison:Equatable {
        var itemID:Int;var itemName:String;var giver:Change?;var receiver:Change
    }
    static func transfer(giver:OriginalPersonDefinition,receiver:OriginalPersonDefinition,item:Int,
                         giverMorale:Int = 100,receiverMorale:Int = 100,combat:OriginalCombatTables,
                         movement:OriginalMovementProfile) throws -> Comparison {
        try OfficerComparison.validatePerson(giver);try OfficerComparison.validatePerson(receiver)
        guard giver.id != receiver.id,let source = giver.itemIDs.firstIndex(of:item),
              let target = receiver.itemIDs.firstIndex(of:255) else {
            throw BattleError.illegalAction("Item transfer needs different officers, a held item and a free receiver slot")
        }
        let name = try itemName(item,combat:combat)
        var senderAfter = giver,receiverAfter = receiver
        senderAfter.itemIDs[source] = 255;receiverAfter.itemIDs[target] = item
        return try Comparison(itemID:item,itemName:name,
            giver:change(before:giver,after:senderAfter,morale:giverMorale,combat:combat,movement:movement),
            receiver:change(before:receiver,after:receiverAfter,morale:receiverMorale,combat:combat,movement:movement))
    }
    static func purchase(receiver:OriginalPersonDefinition,item:Int,morale:Int = 100,combat:OriginalCombatTables,
                         movement:OriginalMovementProfile) throws -> Comparison {
        try OfficerComparison.validatePerson(receiver)
        guard let target = receiver.itemIDs.firstIndex(of:255) else {throw BattleError.illegalAction("Item purchase needs a free inventory slot")}
        let name = try itemName(item,combat:combat)
        var after = receiver;after.itemIDs[target] = item
        return try Comparison(itemID:item,itemName:name,giver:nil,receiver:change(before:receiver,after:after,morale:morale,combat:combat,movement:movement))
    }
    private static func itemName(_ item:Int,combat:OriginalCombatTables) throws -> String {
        try combat.validate()
        guard (0..<64).contains(item),let record = combat.items.first(where:{$0.id == item}) else {throw EngineError.invalid("Equipment comparison item is invalid")}
        return record.name.flatMap {$0.isEmpty ? nil : $0} ?? "도구 \(item)"
    }
    private static func change(before:OriginalPersonDefinition,after:OriginalPersonDefinition,morale:Int,
                               combat:OriginalCombatTables,movement:OriginalMovementProfile) throws -> Change {
        try Change(before:OfficerComparison.snapshot(person:before,morale:morale,combat:combat,movement:movement),
                   after:OfficerComparison.snapshot(person:after,morale:morale,combat:combat,movement:movement))
    }
    #if canImport(AppKit)
    static func sheet(_ value:Comparison,selected:Int = 0,confirmTitle:String = "교환",onChoose:@escaping(Int?)->Void,
                      onButton:@escaping(Int)->Void) -> CanvasSheet {
        var rows:[CanvasSheet.Row] = []
        for (role,change) in (value.giver.map {[("주는 장수",$0)]} ?? [])+[("받는 장수",value.receiver)] {
            let a = change.before,b = change.after
            func metric(_ title:String,_ before:Int,_ after:Int) {
                let delta = after-before,changeText = delta == 0 ? "변화 없음" : delta > 0 ? "+\(delta)" : "\(delta)"
                rows.append(.init(label:a.name+" · "+title,value:"\(before) → \(after)",detail:.init(heading:a.name+" · "+title,
                    body:"\(role) · Lv.\(a.level) · 사기 \(a.morale)\n현재 장비 기준입니다. 같은 종류의 장비 보너스는 최댓값만 적용됩니다.",
                    facts:[("전달 전",String(before)),("전달 후",String(after)),("변화",changeText)])))
            }
            metric("공격력",a.attack,b.attack);metric("방어력",a.defense,b.defense);metric("이동력",a.movement,b.movement)
            metric("소지품",a.itemIDs.filter {$0 != 255}.count,b.itemIDs.filter {$0 != 255}.count)
        }
        return CanvasSheet(portrait:nil,speaker:"물품 전후 비교",line:value.giver.map {$0.before.name+" → "+value.receiver.before.name} ?? value.receiver.before.name+"에게 구입",
            badge:("물품",value.itemName),rows:rows,selected:min(max(selected,0),rows.count-1),mode:.list,buttons:[confirmTitle,"취소"],
            hint:"↑↓ 비교 · Tab 버튼 · Esc 취소",fullCanvas:true,onButton:onButton,onChoose:onChoose)
    }
    #endif
}
