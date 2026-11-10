// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// A read-only view of the caller's decoded MAIN strategy tables. The menu's
/// source comparison is ability * 19 + class, required level <= person level
/// (MAIN 0x2DC9F..0x2DCAB). Class 17 skips that menu at MAIN 0x2DB64.
/// Future rows are an engine presentation; they do not grant an ability.
enum StrategyLearningGuide {
    struct Entry:Equatable {
        var abilityID:Int
        var name:String
        var requiredLevel:Int
        var mpCost:Int
        var learned:Bool
        var remainingLevels:Int
    }

    static func entries(classID:Int,level:Int,levels:[[Int]],costs:[Int],names:[String]) throws -> [Entry] {
        guard (0..<19).contains(classID),(0...99).contains(level),
              levels.count == 36,levels.allSatisfy({ $0.count == 19 && $0.allSatisfy({ (0...255).contains($0) }) }),
              costs.count == 36,costs.allSatisfy({ (0...255).contains($0) }),
              names.count == 36,names.allSatisfy({ !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }) else {
            throw EngineError.invalid("Strategy learning guide needs complete original class, level, name and MP tables")
        }
        guard classID != 17 else { return [] }
        return (0..<36).compactMap { ability -> Entry? in
            let required = levels[ability][classID]
            // Person levels stop at 99. In particular, byte FF means that
            // this class never learns the row; it is not a level-255 promise.
            guard required <= 99 else { return nil }
            return Entry(abilityID:ability,name:names[ability],requiredLevel:required,mpCost:costs[ability],
                         learned:required <= level,remainingLevels:max(0,required-level))
        }.sorted {
            $0.requiredLevel == $1.requiredLevel ? $0.abilityID < $1.abilityID : $0.requiredLevel < $1.requiredLevel
        }
    }

    /// All rows remain selectable so a future ability's requirements can be
    /// inspected. Callers reopen this sheet on a row choice and go back on nil.
    #if canImport(AppKit)
    static func sheet(person:OriginalPersonDefinition,levels:[[Int]],costs:[Int],names:[String],profile:OriginalMovementProfile,
                      terrainNames:[String]? = nil,className:String,
                      portrait:CGImage?,selected:Int = 0,onChoose:@escaping (Int?) -> Void) throws -> CanvasSheet {
        guard !className.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            throw EngineError.invalid("Strategy learning guide has no original class name")
        }
        let learned = try entries(classID:person.classID,level:person.level,levels:levels,costs:costs,names:names)
        let count = learned.filter(\.learned).count
        var rows = try learned.map { entry in
            let strategy = try StrategyGuideDetails.describe(abilityID:entry.abilityID,profile:profile,terrainNames:terrainNames)
            return CanvasSheet.Row(label:(entry.learned ? "✓ " : "")+entry.name,
                            value:"Lv.\(entry.requiredLevel) · MP\(entry.mpCost)",
                            detail:.init(heading:entry.name,
                                body:entry.learned ? "습득 완료" : "습득 예정 · \(entry.remainingLevels)레벨 남음",
                                facts:[("습득 레벨","Lv.\(entry.requiredLevel)"),("필요 MP","\(entry.mpCost)"),("현재 레벨","Lv.\(person.level)")],
                                strategy:strategy))
        }
        if rows.isEmpty {
            rows = [.init(label:"습득할 책략 없음",detail:.init(heading:person.name,
                body:"현재 병과에서 배울 수 있는 책략이 없습니다.\n전직하면 습득표가 바뀝니다.",
                facts:[("현재 병과",className),("현재 레벨","Lv.\(person.level)")],portrait:portrait))]
        }
        // A portrait in the header would leave fewer than eight row heights
        // in the battle viewport. Keep it in the detail pane instead.
        return CanvasSheet(portrait:nil,speaker:"\(person.name) · 책략 습득표",
            line:"\(className) · Lv.\(person.level) · 현재 병과 기준",badge:("습득 완료","\(count) / \(learned.count)"),
            rows:rows,selected:min(max(0,selected),rows.count-1),mode:.list,
            hint:"↑↓ · 휠로 보기 · esc 돌아가기 · 전직 시 습득표 변경",fullCanvas:true,onChoose:onChoose)
    }
    #endif
}
