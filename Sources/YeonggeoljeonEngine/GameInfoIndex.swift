// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Seed only with current public people, their learning tables, owned items
/// and observed shops. Full source catalogs are never the public search seed.
enum GameInfoIndex {
    enum Kind:String,CaseIterable {case person = "장수",item = "물품",strategy = "책략"}
    enum Filter:String,CaseIterable {case all = "전체",owned = "보유·현재 습득",future = "향후 습득"}
    struct Entry:Equatable {
        var kind:Kind;var id:Int;var name:String;var body:String;var tags:[String]
        var owners:[Int];var current:Bool;var future:Bool;var source:String
        var strategy:StrategyGuideDetails.Description? = nil
    }
    static func build(people:[OriginalPersonDefinition],combat:OriginalCombatTables,movement:OriginalMovementProfile,
                      strategyNames:[String],terrainNames:[String],observed:ObservedShopStock,sourceIdentity:String? = nil) throws -> [Entry] {
        try combat.validate();try movement.validate();try observed.validate()
        guard Set(people.map(\.id)).count == people.count else {throw EngineError.invalid("Information search repeats a public person")}
        var entries:[Entry] = [],owned:[Int:[Int]] = [:]
        for person in people {
            try OfficerComparison.validatePerson(person)
            entries.append(.init(kind:.person,id:person.id,name:person.name,body:"현재 동료 · Lv.\(person.level)",tags:[],owners:[person.id],current:true,future:false,source:"현재 동료"))
            for item in Set(person.itemIDs.filter {$0 != 255}) {owned[item,default:[]].append(person.id)}
        }
        let seenItems = Set(observed.visits.flatMap {$0.items.map(\.id)})
        for id in Set(owned.keys).union(seenItems).sorted() {
            let latest = observed.visits.sorted {$0.sequence > $1.sequence}.first {$0.items.contains {$0.id == id}}
            if owned[id] == nil,latest?.matchesSource(sourceIdentity) != true,
               let recorded = latest?.items.first(where:{$0.id == id}) {
                entries.append(.init(kind:.item,id:id,name:recorded.name,body:recorded.description,tags:[],owners:[],current:false,future:false,source:"관측 당시 자료 · 현재 자료와 연결하지 않음"))
                continue
            }
            guard let item = combat.items.first(where:{$0.id == id}) else {continue}
            var tags:[String] = []
            switch item.category {case 0:tags += ["장비","공격력"];case 4:tags += ["장비","이동력"];case 5:tags += ["장비","방어력"];default:break}
            switch OriginalItemUse.of(id) {
            case .classChange,.promotion:tags += ["전직","병종 변경","성장"]
            case .attack:tags += ["공격","피해"]
            case .confuse:tags += ["혼란","상태 이상"]
            case .recovery(let kind,_),.areaRecovery(let kind,_):
                tags += ["회복"]
                if kind&1 != 0 {tags += ["병력","치료","HP"]}
                if kind&2 != 0 {tags += ["사기","혼란 회복","혼란 해제"]}
            case .bomb:tags += ["공격","피해","폭탄"]
            default:break
            }
            entries.append(.init(kind:.item,id:id,name:item.name ?? "도구 \(id)",body:item.description ?? "",tags:tags,owners:owned[id] ?? [],
                current:owned[id] != nil,future:false,source:owned[id] != nil ? "현재 소지품" : "방문 상점 관측"))
        }
        if let levels = movement.strategyLevelRequirements,let costs = movement.strategyMPCosts {
            guard strategyNames.count == 36 else {throw EngineError.invalid("Information search needs the current strategy names")}
            var learned:[Int:[Int]] = [:],future:[Int:[Int]] = [:]
            for person in people {
                for skill in try StrategyLearningGuide.entries(classID:person.classID,level:person.level,levels:levels,costs:costs,names:strategyNames) {
                    if skill.learned {learned[skill.abilityID,default:[]].append(person.id)}
                    else {future[skill.abilityID,default:[]].append(person.id)}
                }
            }
            for id in Set(learned.keys).union(future.keys).sorted() {
                let detail = try? StrategyGuideDetails.describe(abilityID:id,profile:movement,terrainNames:terrainNames)
                var tags:[String] = []
                if let detail {
                    switch detail.kind {
                    case .damage:tags = ["공격","피해"]
                    case .confusion:tags = ["혼란","상태 이상"]
                    case .lowerMorale:tags = ["사기 감소"]
                    case .recoverMorale:tags = ["회복","사기","혼란 회복","혼란 해제"]
                    case .recoverTroops:tags = ["회복","병력","치료","HP"]
                    case .recoverBoth:tags = ["회복","병력","치료","HP","사기","혼란 회복","혼란 해제"]
                    }
                    if detail.effectOffsets.count > 1 {tags += ["범위","광역"]}
                }
                entries.append(.init(kind:.strategy,id:id,name:strategyNames[id],body:detail?.effect ?? "현재 자료로 효과를 설명할 수 없습니다.",tags:tags,
                    owners:learned[id] ?? [],current:learned[id] != nil,future:future[id] != nil,source:"현재 동료의 책략 습득표",strategy:detail))
            }
        }
        return entries
    }
    static func search(_ entries:[Entry],query:String,kind:Kind? = nil,filter:Filter = .all)->[Entry] {
        let words = query.precomposedStringWithCanonicalMapping.lowercased().split(whereSeparator:{$0.isWhitespace}).map(String.init)
        return entries.filter {entry in
            let text = ([entry.name,entry.body]+entry.tags).joined(separator:" ").precomposedStringWithCanonicalMapping.lowercased()
            return (kind == nil || entry.kind == kind) && (filter == .all || filter == .owned && entry.current || filter == .future && entry.future) && words.allSatisfy {text.contains($0)}
        }
    }
}
