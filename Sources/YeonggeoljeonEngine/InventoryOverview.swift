// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// A view over the caller-selected current companions. Grouping duplicates
/// changes only the display; source slot order and transfer semantics remain.
enum InventoryOverview {
    enum Filter:String,CaseIterable {case all,equipment,recovery,promotion,protected
        var title:String {
            switch self {case .all:return "전체";case .equipment:return "장비";case .recovery:return "회복";case .promotion:return "전직";case .protected:return "보호"}
        }
    }
    struct Entry:Equatable {
        var personID:Int;var personName:String;var sourceSlot:Int;var itemID:Int;var itemName:String
        var itemDescription:String;var count:Int;var occupiedSlots:Int;var protected:Bool;var useProtected:Bool
    }
    static func entries(people:[OriginalPersonDefinition],combat:OriginalCombatTables,extras:CampaignExtras = .init(),
                        query:String = "",filter:Filter = .all) throws -> [Entry] {
        try combat.validate();try extras.validate()
        guard Set(people.map(\.id)).count == people.count else {throw EngineError.invalid("Inventory overview has duplicate people")}
        var result:[Entry] = []
        let needle = query.trimmingCharacters(in:.whitespacesAndNewlines)
        for person in people {
            try OfficerComparison.validatePerson(person)
            var seen = Set<Int>()
            for (slot,id) in person.itemIDs.enumerated() where id != 255 && seen.insert(id).inserted {
                guard let item = combat.items.first(where:{$0.id == id}) else {throw EngineError.invalid("Inventory item has no source effect")}
                let name = item.name.flatMap {$0.isEmpty ? nil : $0} ?? "도구 \(id)"
                let locked = extras.protects(personID:person.id,itemID:id,operation:.sell)
                let include:Bool
                switch filter {
                case .all:include = true
                case .equipment:include = [0,4,5].contains(item.category)
                case .protected:include = locked
                case .recovery:
                    switch OriginalItemUse.of(id) {case .recovery,.areaRecovery:include = true;default:include = false}
                case .promotion:
                    switch OriginalItemUse.of(id) {case .classChange,.promotion:include = true;default:include = false}
                }
                guard include,needle.isEmpty || (person.name+" "+name).range(of:needle,options:[.caseInsensitive,.diacriticInsensitive]) != nil else {continue}
                result.append(.init(personID:person.id,personName:person.name,sourceSlot:slot,itemID:id,itemName:name,
                    itemDescription:item.description ?? "",count:person.itemIDs.filter {$0 == id}.count,
                    occupiedSlots:person.itemIDs.filter {$0 != 255}.count,protected:locked,
                    useProtected:extras.protects(personID:person.id,itemID:id,operation:.use)))
            }
        }
        return result
    }
    #if canImport(AppKit)
    static func sheet(_ entries:[Entry],filter:Filter = .all,selected:Int = 0,onChoose:@escaping(Int?)->Void) -> CanvasSheet {
        let rows:[CanvasSheet.Row] = entries.map {entry in
            let lock = entry.protected ? (entry.useProtected ? "매각·버리기·사용 보호" : "매각·버리기 보호") : "보호 안 함"
            return .init(label:entry.itemName,value:"\(entry.personName) · \(entry.count)개"+(entry.protected ? " · 보호" : ""),
                detail:.init(heading:entry.itemName,body:entry.itemDescription,
                    list:["같은 장수의 동일 물품을 묶어 표시합니다.","교환할 때에는 원본 소지품 순서의 첫 1개를 전달합니다.","보호는 동일 물품 전체에 적용되며 시나리오의 강제 회수에는 적용되지 않습니다."],
                    facts:[("소유 장수",entry.personName),("수량","\(entry.count)개"),("소지품","\(entry.occupiedSlots)/8칸"),("물품 보호",lock)]))
        }
        return CanvasSheet(portrait:nil,speaker:"소지품 통합 보기",line:entries.isEmpty ? "조건에 맞는 소지품이 없습니다." : "장수별 소지품 · 선택하면 물품 관리",
            badge:("분류",filter.title),rows:rows,selected:rows.isEmpty ? 0 : min(max(selected,0),rows.count-1),mode:.list,
            detail:rows.isEmpty ? .init(heading:"소지품 없음",body:"분류나 검색 조건을 바꾸어 확인하세요.") : nil,
            hint:"↑↓ 물품 확인 · Enter 물품 관리 · Esc 돌아가기",fullCanvas:true,onChoose:onChoose)
    }
    #endif
}
