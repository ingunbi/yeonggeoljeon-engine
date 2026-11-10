// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// A read-only forecast of MAIN2E127..2E211 / 2E6DD..2E7F9. It changes a
/// value copy only; the real item operation still owns refusal, consumption,
/// action completion and troop clamping. No gameplay RNG is used here.
enum PromotionPreview {
    struct Facts:Equatable {
        var classID:Int
        var attack:Int
        var defense:Int
        var maximumTroops:Int
        var maximumMP:Int
        var troops:Int
        var movement:Int
        var movementType:Int
        var attackOffsets:[OriginalAIOffset]
    }
    struct TerrainChange:Equatable { var name:String; var before:Int; var after:Int }
    struct StrategyChange:Equatable {
        var abilityID:Int; var name:String; var beforeLevel:Int?; var afterLevel:Int?
    }
    struct Comparison:Equatable {
        var personID:Int; var personName:String; var level:Int; var morale:Int
        var itemID:Int; var itemName:String; var beforeClass:String; var afterClass:String
        var before:Facts; var after:Facts
        var terrainChanges:[TerrainChange]
        var strategyChanges:[StrategyChange]
    }

    static func build(person:OriginalPersonDefinition,morale:Int,item:Int,combat:OriginalCombatTables,
                      movement:OriginalMovementProfile,classNames:[String],strategyNames:[String],terrainNames:[String]) throws -> Comparison {
        try combat.validate();try movement.validate()
        guard classNames.count == 19,strategyNames.count == 36,(0..<19).contains(person.classID),
              (0...99).contains(person.level),person.itemIDs.contains(item),
              let levels = movement.strategyLevelRequirements,let costs = movement.strategyMPCosts,
              let itemRecord = combat.items.first(where:{$0.id == item}),let itemName = itemRecord.name,!itemName.isEmpty,
              terrainNames.count <= 256 else {
            throw BattleError.invalid("Promotion preview needs complete source names, strategy tables and a held item")
        }
        let target:Int,clamp:Bool
        switch OriginalItemUse.of(item) {
        case .classChange(let value):target = value;clamp = true
        case .promotion(let required,let level):
            guard person.classID == required,person.level >= level else { throw BattleError.illegalAction("Promotion preview class or level is ineligible") }
            target = required+1;clamp = false
        default:throw BattleError.illegalAction("Only class-changing items have a promotion preview")
        }
        func facts(_ value:OriginalPersonDefinition) throws -> Facts {
            let stats = OriginalPersonStats(classID:value.classID,level:value.level,troops:value.rawTroops,
                attackScalar:value.attackScalar,defenseScalar:value.defenseScalar,intellectScalar:value.intellectScalar,
                morale:morale,itemIDs:value.itemIDs)
            let bonuses = value.itemIDs.compactMap { id in combat.items.first(where:{$0.id == id && $0.category == 4})?.value }
            let center = GridPoint(x:4,y:4),board = OriginalMovementBoard(width:9,height:9,terrain:Array(repeating:0,count:81),actors:[])
            let range = try OriginalAI.rangeCells(profile:movement,board:board,point:center,raw:movement.attackRangeCodes[value.classID])
            return try Facts(classID:value.classID,attack:OriginalCombat.attackStat(stats,tables:combat),
                defense:OriginalCombat.defenseStat(stats,tables:combat),maximumTroops:OriginalCombat.maxTroops(classID:value.classID,level:value.level,tables:combat),
                maximumMP:OriginalCombat.maxMP(stats:stats),troops:value.rawTroops,
                movement:Int(movement.budget(classID:value.classID,equipmentMovementBonuses:bonuses)),
                movementType:movement.classMovementTypes[value.classID],attackOffsets:range.map{.init(dx:$0.x-center.x,dy:$0.y-center.y)})
        }
        var projected = person;projected.classID = target
        if clamp { projected.rawTroops = min(person.rawTroops,try OriginalCombat.maxTroops(classID:target,level:person.level,tables:combat)) }
        // The first matching tool is consumed by the real completion. Keep
        // every other equipment slot exactly as it is for the comparison.
        if let index = projected.itemIDs.firstIndex(of:item) { projected.itemIDs[index] = 255 }
        let before = try facts(person),after = try facts(projected)
        let oldSkills = try StrategyLearningGuide.entries(classID:person.classID,level:person.level,levels:levels,costs:costs,names:strategyNames)
        let newSkills = try StrategyLearningGuide.entries(classID:target,level:person.level,levels:levels,costs:costs,names:strategyNames)
        let oldLevels = Dictionary(uniqueKeysWithValues:oldSkills.map{($0.abilityID,$0.requiredLevel)})
        let newLevels = Dictionary(uniqueKeysWithValues:newSkills.map{($0.abilityID,$0.requiredLevel)})
        let skillChanges = Set(oldLevels.keys).union(newLevels.keys).sorted().compactMap { id -> StrategyChange? in
            guard oldLevels[id] != newLevels[id] else {return nil}
            return .init(abilityID:id,name:strategyNames[id],beforeLevel:oldLevels[id],afterLevel:newLevels[id])
        }
        let terrainChanges = try terrainNames.indices.compactMap { id -> TerrainChange? in
            let old = try movement.cost(classID:person.classID,terrain:id),new = try movement.cost(classID:target,terrain:id)
            guard old != new,!terrainNames[id].isEmpty else {return nil}
            return .init(name:terrainNames[id],before:old,after:new)
        }
        return Comparison(personID:person.id,personName:person.name,level:person.level,morale:morale,itemID:item,itemName:itemName,
            beforeClass:classNames[person.classID],afterClass:classNames[target],before:before,after:after,
            terrainChanges:terrainChanges,strategyChanges:skillChanges)
    }

    static func rangeText(_ offsets:[OriginalAIOffset]) -> String {
        let points = Set(offsets.map{GridPoint(x:$0.dx,y:$0.dy)})
        if points.isEmpty {return "일반 공격 없음"}
        let cardinal:Set<GridPoint> = [.init(x:0,y:-1),.init(x:1,y:0),.init(x:0,y:1),.init(x:-1,y:0)]
        let diagonal:Set<GridPoint> = [.init(x:-1,y:-1),.init(x:1,y:-1),.init(x:1,y:1),.init(x:-1,y:1)]
        if points == cardinal { return "상하좌우 1칸" }
        if points == cardinal.union(diagonal) { return "주변 1칸 · 대각 포함" }
        let distant = Set(cardinal.map{GridPoint(x:$0.x*2,y:$0.y*2)})
        if points == diagonal.union(distant) { return "직선 2칸 · 대각 1칸\n상하좌우 인접 칸 제외" }
        let maximum = points.map{max(abs($0.x),abs($0.y))}.max() ?? 0
        let near = cardinal.isSubset(of:points) ? "상하좌우 인접 칸 포함" : "상하좌우 인접 칸 제외"
        return "최대 \(maximum)칸 · \(points.count)개 위치\n\(near)"
    }

    #if canImport(AppKit)
    static func sheet(_ value:Comparison,selected:Int = 0,onChoose:@escaping(Int?)->Void,onButton:@escaping(Int)->Void) -> CanvasSheet {
        var rows:[CanvasSheet.Row] = []
        let scope = "Lv.\(value.level) · 사기 \(value.morale) · 현재 장비 기준"
        func metric(_ label:String,_ old:Int,_ new:Int,_ body:String) {
            let delta = new-old,change = delta == 0 ? "변화 없음" : delta > 0 ? "+\(delta)" : "\(delta)"
            rows.append(.init(label:label,value:"\(old) → \(new)",detail:.init(heading:label,body:body+"\n"+scope,
                facts:[("전직 전","\(old)"),("전직 후","\(new)"),("차이",change)])))
        }
        metric("공격력",value.before.attack,value.after.attack,"같은 레벨과 사기의 공격력입니다.\n지형·대상에 따른 실제 피해는 별도입니다.")
        metric("방어력",value.before.defense,value.after.defense,"같은 레벨과 사기의 방어력입니다.\n전장의 지형 효과는 포함하지 않습니다.")
        metric("최대 병력",value.before.maximumTroops,value.after.maximumTroops,"병과 변경 후의 병력 상한입니다.\n전직만으로 현재 병력이 회복되지는 않습니다.")
        metric("현재 병력",value.before.troops,value.after.troops,value.after.troops < value.before.troops ? "병과 변경으로 새 상한을 넘는 병력이 줄어듭니다." : "현재 병력은 유지됩니다.")
        metric("최대 MP",value.before.maximumMP,value.after.maximumMP,"현재 지력과 레벨의 MP 상한입니다.\n전직만으로 MP가 회복되지는 않습니다.")
        metric("이동력",value.before.movement,value.after.movement,"한 번에 사용할 수 있는 이동력입니다.\n현재 이동력 장비를 반영합니다.")
        rows.append(.init(label:"일반 공격 범위",value:"\(value.before.attackOffsets.count) → \(value.after.attackOffsets.count)칸",
            detail:.init(heading:"일반 공격 범위",body:"전직 전: "+rangeText(value.before.attackOffsets)+"\n\n전직 후: "+rangeText(value.after.attackOffsets),
                         facts:[("비교 기준","장애물 없는 지도")])) )
        if value.terrainChanges.isEmpty {
            rows.append(.init(label:"지형 이동",value:"변화 없음",detail:.init(heading:"지형별 이동",body:"이름이 있는 지형의 통행 가능 여부와 이동력 소모가 같습니다.")))
        } else {
            for terrain in value.terrainChanges {
                func cost(_ n:Int)->String { n == 255 ? "통행 불가" : "\(n) 소모" }
                func brief(_ n:Int)->String { n == 255 ? "불가" : "\(n)" }
                rows.append(.init(label:terrain.name+" 이동",value:brief(terrain.before)+" → "+brief(terrain.after),
                    detail:.init(heading:terrain.name+" 이동",body:"이 지형 한 칸에 들어갈 때 드는 이동력입니다.\n통행 불가이면 이 병과로 들어갈 수 없습니다.",
                                 facts:[("전직 전",cost(terrain.before)),("전직 후",cost(terrain.after))])))
            }
        }
        if value.strategyChanges.isEmpty {
            rows.append(.init(label:"책략 습득",value:"변화 없음",detail:.init(heading:"책략 습득",body:"현재 병과와 전직할 병과의 습득 책략·레벨이 같습니다.")))
        } else {
            for skill in value.strategyChanges {
                func level(_ n:Int?)->String {n.map{"Lv.\($0)"} ?? "없음"}
                func status(_ n:Int?)->String {guard let n else{return "습득 불가"};return "Lv.\(n) · "+(value.level >= n ? "현재 습득" : "\(n-value.level)레벨 남음")}
                rows.append(.init(label:skill.name,value:level(skill.beforeLevel)+" → "+level(skill.afterLevel),
                    detail:.init(heading:skill.name+" · 책략 변화",body:"전직한 병과의 습득 조건이 적용됩니다.\n전직 전: "+status(skill.beforeLevel)+"\n전직 후: "+status(skill.afterLevel),
                        facts:[("현재 레벨","Lv.\(value.level)"),("전직 전",level(skill.beforeLevel)),("전직 후",level(skill.afterLevel))])))
            }
        }
        return CanvasSheet(portrait:nil,speaker:value.personName+" · 전직 전후 비교",line:value.beforeClass+" → "+value.afterClass+" · Lv.\(value.level)",
            badge:("사용 시 1개 소모",value.itemName),rows:rows,selected:min(max(0,selected),rows.count-1),mode:.list,
            buttons:["전직","취소"],hint:"↑↓ 비교 · Tab 버튼 · Esc 취소",fullCanvas:true,onButton:onButton,onChoose:onChoose)
    }
    #endif
}
