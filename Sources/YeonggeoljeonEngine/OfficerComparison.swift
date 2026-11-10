// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Read-only current-level comparison. Uses value definitions, not a shared
/// OriginalPeople reference, and never consumes game RNG or performs actions.
enum OfficerComparison {
    enum Tab:String,CaseIterable {case stats = "능력",movement = "이동·범위",strategies = "책략",items = "소지품"}
    struct Snapshot:Equatable {
        var personID:Int;var name:String;var classID:Int;var level:Int;var experience:Int;var morale:Int
        var troops:Int;var maximumTroops:Int;var maximumMP:Int;var attack:Int;var defense:Int;var movement:Int
        var attackOffsets:[OriginalAIOffset];var itemIDs:[Int]
        /// Nil means source learning tables were unavailable; [] means none learned.
        var learnedAbilities:[Int]?
        var terrainCosts:[Int]
    }
    static func snapshot(person:OriginalPersonDefinition,morale:Int = 100,combat:OriginalCombatTables,
                         movement:OriginalMovementProfile) throws -> Snapshot {
        try combat.validate();try movement.validate();try validatePerson(person)
        guard (0...100).contains(morale) else {throw EngineError.invalid("Officer comparison morale is invalid")}
        let stats = OriginalPersonStats(classID:person.classID,level:person.level,troops:person.rawTroops,
            attackScalar:person.attackScalar,defenseScalar:person.defenseScalar,intellectScalar:person.intellectScalar,
            morale:morale,itemIDs:person.itemIDs)
        let bonuses = person.itemIDs.compactMap {id in combat.items.first(where:{$0.id == id && $0.category == 4})?.value}
        let origin = GridPoint(x:4,y:4),board = OriginalMovementBoard(width:9,height:9,terrain:Array(repeating:0,count:81),actors:[])
        let offsets = try OriginalAI.rangeCells(profile:movement,board:board,point:origin,raw:movement.attackRangeCodes[person.classID])
            .map {OriginalAIOffset(dx:$0.x-origin.x,dy:$0.y-origin.y)}
        let learned = movement.strategyLevelRequirements.map {levels in
            person.classID == 17 ? [] : levels.indices.filter {levels[$0][person.classID] <= person.level}
        }
        return try Snapshot(personID:person.id,name:person.name,classID:person.classID,level:person.level,
            experience:person.experience,morale:morale,troops:person.rawTroops,
            maximumTroops:OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:combat),
            maximumMP:OriginalCombat.maxMP(stats:stats),attack:OriginalCombat.attackStat(stats,tables:combat),
            defense:OriginalCombat.defenseStat(stats,tables:combat),movement:Int(movement.budget(classID:person.classID,equipmentMovementBonuses:bonuses)),
            attackOffsets:offsets,itemIDs:person.itemIDs,learnedAbilities:learned,terrainCosts:movement.movementCosts[movement.classMovementTypes[person.classID]])
    }
    static func validatePerson(_ person:OriginalPersonDefinition) throws {
        guard (0..<384).contains(person.id),(0..<19).contains(person.classID),(0...99).contains(person.level),
              person.itemIDs.count == 8,person.itemIDs.allSatisfy({$0 == 255 || (0..<64).contains($0)}) else {
            throw EngineError.invalid("Officer helper needs a valid person and eight inventory slots")
        }
    }
    #if canImport(AppKit)
    static func sheet(left:Snapshot,right:Snapshot,classNames:[String],strategyNames:[String],
                      itemName:((Int)->String)? = nil,tab:Tab = .stats,terrainNames:[String] = [],selected:Int = 0,onChoose:@escaping(Int?)->Void) -> CanvasSheet {
        func className(_ value:Snapshot)->String {classNames.indices.contains(value.classID) ? classNames[value.classID] : "병과 \(value.classID)"}
        let scope = "\(left.name) Lv.\(left.level)·사기 \(left.morale) / \(right.name) Lv.\(right.level)·사기 \(right.morale)\n각 장수의 현재 레벨·장비 기준이며 피해 예상값이 아닙니다."
        func row(_ label:String,_ a:String,_ b:String,_ body:String = "") -> CanvasSheet.Row {
            .init(label:label,value:a+" / "+b,detail:.init(heading:label,body:body.isEmpty ? scope : body+"\n"+scope,
                facts:[(left.name,a),(right.name,b)]))
        }
        var rows:[CanvasSheet.Row] = []
        if tab == .stats {rows = [row("병과",className(left),className(right)),row("레벨",String(left.level),String(right.level)),
            row("공격력",String(left.attack),String(right.attack)),row("방어력",String(left.defense),String(right.defense)),
            row("병력","\(left.troops)/\(left.maximumTroops)","\(right.troops)/\(right.maximumTroops)"),
            row("최대 책략치",String(left.maximumMP),String(right.maximumMP))]}
        if tab == .movement {
            rows.append(row("이동력",String(left.movement),String(right.movement)))
            rows.append(.init(label:"일반 공격 범위",value:"격자 비교",detail:.init(heading:"일반 공격 범위",body:scope,
                rangeComparison:.init(leftName:left.name,left:left.attackOffsets,rightName:right.name,right:right.attackOffsets))))
            func cost(_ value:Int)->String {value == 255 ? "진입 불가" : "\(value) 소모"}
            for id in terrainNames.indices where left.terrainCosts.indices.contains(id) && right.terrainCosts.indices.contains(id) && !terrainNames[id].isEmpty {
                rows.append(row(terrainNames[id],cost(left.terrainCosts[id]),cost(right.terrainCosts[id]),"해당 지형 한 칸에서 소모하는 원본 이동 비용입니다."))
            }
        }
        for value in [left,right] {
            let names = value.learnedAbilities?.map {strategyNames.indices.contains($0) ? strategyNames[$0] : "책략 \($0)"}
            if tab == .strategies {rows.append(.init(label:value.name+" · 습득 책략",value:names.map {"\($0.count)개"} ?? "자료 없음",
                detail:.init(heading:value.name+" · 현재 습득 책략",body:names == nil ? "원본 습득표가 없어 확인할 수 없습니다." : "현재 레벨 기준입니다. 실제 사용에는 책략치·지형 등 조건이 적용됩니다.",list:names ?? [])))}
            let held = value.itemIDs.filter {$0 != 255}
            if tab == .items {rows.append(.init(label:value.name+" · 소지품",value:"\(held.count)/8칸",detail:.init(heading:value.name+" · 소지품",list:held.map {itemName?($0) ?? "도구 \($0)"})))}
        }
        return CanvasSheet(portrait:nil,speaker:"장수 비교 · "+tab.rawValue,line:left.name+" / "+right.name,badge:("현재 전력","장비 포함"),
            rows:rows,selected:min(max(selected,0),rows.count-1),mode:.list,hint:"↑↓ 항목 확인 · Esc 돌아가기",fullCanvas:true,onChoose:onChoose)
    }
    #endif
}
