// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// A planning-only view. Missing tools and unmet levels are explained without
/// weakening PromotionPreview's checks or invoking the real item operation.
enum PromotionPlanning {
    struct Candidate:Equatable {
        var itemID:Int;var targetClass:Int;var requiredLevel:Int?;var conditions:[String]
    }
    struct Plan:Equatable {var candidate:Candidate;var comparison:PromotionPreview.Comparison;var scope:String}
    static func candidates(person:OriginalPersonDefinition) throws -> [Candidate] {
        try OfficerComparison.validatePerson(person)
        return (0..<64).compactMap {id in
            let target:Int,required:Int?
            var conditions:[String] = []
            switch OriginalItemUse.of(id) {
            case .classChange(let value):
                guard value != person.classID,person.classID/3*3 != value else {return nil}
                target = value;required = nil
                if person.id == 0 {conditions.append("주인공은 병종 변경 도구를 사용할 수 없습니다.")}
                conditions.append("전투에서 현재 지형에 진입할 수 있는 병과여야 합니다.")
            case .promotion(let value,let level):
                guard value == person.classID else {return nil}
                target = value+1;required = level
                if person.level < level {conditions.append("Lv.\(level) 필요 · \(level-person.level)레벨 남음")}
            default:return nil
            }
            if !person.itemIDs.contains(id) {conditions.append("필요 도구를 소지하고 있지 않습니다.")}
            conditions.append("실제 사용은 전투의 도구 명령에서 행동·상태 조건을 다시 검사합니다.")
            return Candidate(itemID:id,targetClass:target,requiredLevel:required,conditions:conditions)
        }
    }
    static func build(person:OriginalPersonDefinition,item:Int,morale:Int = 100,combat:OriginalCombatTables,
                      movement:OriginalMovementProfile,classNames:[String],strategyNames:[String],terrainNames:[String]) throws -> Plan {
        guard let candidate = try candidates(person:person).first(where:{$0.itemID == item}),
              classNames.count == 19,strategyNames.count == 36,terrainNames.count <= 256,
              let levels = movement.strategyLevelRequirements,let costs = movement.strategyMPCosts,
              let record = combat.items.first(where:{$0.id == item}) else {
            throw EngineError.invalid("Promotion planning needs a source-linked candidate and complete display tables")
        }
        let before = try OfficerComparison.snapshot(person:person,morale:morale,combat:combat,movement:movement)
        var projected = person;projected.classID = candidate.targetClass
        if case .classChange = OriginalItemUse.of(item) {
            projected.rawTroops = min(projected.rawTroops,try OriginalCombat.maxTroops(classID:projected.classID,level:projected.level,tables:combat))
        }
        if let slot = projected.itemIDs.firstIndex(of:item) {projected.itemIDs[slot] = 255}
        let after = try OfficerComparison.snapshot(person:projected,morale:morale,combat:combat,movement:movement)
        func facts(_ value:OfficerComparison.Snapshot)->PromotionPreview.Facts {
            .init(classID:value.classID,attack:value.attack,defense:value.defense,maximumTroops:value.maximumTroops,
                maximumMP:value.maximumMP,troops:value.troops,movement:value.movement,movementType:movement.classMovementTypes[value.classID],attackOffsets:value.attackOffsets)
        }
        let old = try StrategyLearningGuide.entries(classID:person.classID,level:person.level,levels:levels,costs:costs,names:strategyNames)
        let new = try StrategyLearningGuide.entries(classID:projected.classID,level:person.level,levels:levels,costs:costs,names:strategyNames)
        let oldLevels = Dictionary(uniqueKeysWithValues:old.map {($0.abilityID,$0.requiredLevel)})
        let newLevels = Dictionary(uniqueKeysWithValues:new.map {($0.abilityID,$0.requiredLevel)})
        let skills:[PromotionPreview.StrategyChange] = Set(oldLevels.keys).union(newLevels.keys).sorted().compactMap {id in
            oldLevels[id] == newLevels[id] ? nil : .init(abilityID:id,name:strategyNames[id],beforeLevel:oldLevels[id],afterLevel:newLevels[id])
        }
        let terrain:[PromotionPreview.TerrainChange] = try terrainNames.indices.compactMap {id in
            let a = try movement.cost(classID:person.classID,terrain:id),b = try movement.cost(classID:projected.classID,terrain:id)
            return a == b || terrainNames[id].isEmpty ? nil : .init(name:terrainNames[id],before:a,after:b)
        }
        let held = person.itemIDs.contains(item)
        let scope = "현재 Lv.\(person.level)·사기 \(morale) 기준의 계획 비교입니다.\n"+(held ? "보유한 전직 도구 1개를 사용한 뒤의 장비를 가정합니다." : "미보유 도구를 가상으로 소지품에 넣지 않고 현재 장비를 유지합니다.")
        let comparison = PromotionPreview.Comparison(personID:person.id,personName:person.name,level:person.level,morale:morale,itemID:item,
            itemName:record.name ?? "도구 \(item)",beforeClass:classNames[person.classID],afterClass:classNames[projected.classID],
            before:facts(before),after:facts(after),terrainChanges:terrain,strategyChanges:skills)
        return Plan(candidate:candidate,comparison:comparison,scope:scope)
    }
    #if canImport(AppKit)
    static func sheet(_ plan:Plan,selected:Int = 0,onChoose:@escaping(Int?)->Void)->CanvasSheet {
        var result = PromotionPreview.sheet(plan.comparison,selected:max(0,selected-1),onChoose:{_ in},onButton:{_ in})
        result.speaker = plan.comparison.personName+" · 성장 계획"
        result.line = plan.comparison.beforeClass+" → "+plan.comparison.afterClass+" · 조회 전용"
        result.badge = ("필요 도구",plan.comparison.itemName)
        result.rows.insert(.init(label:"전직 조건과 비교 기준",value:"계획",detail:.init(heading:"전직 조건과 비교 기준",body:plan.scope,list:plan.candidate.conditions)),at:0)
        result.selected = min(max(selected,0),result.rows.count-1)
        result.buttons = [];result.onButton = nil;result.onChoose = onChoose
        result.hint = "↑↓ 계획 확인 · Esc 돌아가기 · 실제 전직은 전투 도구 명령"
        return result
    }
    #endif
}
