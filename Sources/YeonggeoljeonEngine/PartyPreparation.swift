// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Advisory preparation and preset planning. Neither path confirms deployment,
/// changes the shared people catalog nor invokes the campaign interpreter.
enum PartyPreparation {
    enum IssueKind:Equatable {case favoriteMissing,favoriteUnavailable,fullInventory,noTroopRecovery,learningUnavailable}
    struct Issue:Equatable {var kind:IssueKind;var personID:Int?;var title:String;var explanation:String}
    struct Report:Equatable {
        var selectedPeople:[Int];var fixedPeople:[Int];var capacity:Int
        var names:[Int:String];var troopRecoveryPeople:[Int];var issues:[Issue]
    }
    enum OmissionReason:String {case unavailable = "현재 참가 불가",duplicate = "중복 장수",capacity = "출전 정원 초과",invalid = "잘못된 장수 ID"}
    struct Omission:Equatable {var personID:Int;var reason:OmissionReason}
    struct Plan {
        var selection:OriginalPartySelection
        var omitted:[Omission]
        var preservedFixedPeople:[Int]
    }
    static func review(selection:OriginalPartySelection,people:[OriginalPersonDefinition],combat:OriginalCombatTables,
                       movement:OriginalMovementProfile,extras:CampaignExtras = .init()) throws -> Report {
        try validate(selection);try combat.validate();try movement.validate();try extras.validate()
        guard Set(people.map(\.id)).count == people.count else {throw EngineError.invalid("Party preparation has duplicate people")}
        var records:[Int:OriginalPersonDefinition] = [:]
        for person in people {try OfficerComparison.validatePerson(person);records[person.id] = person}
        let selected = Array(selection.selectedSlots.prefix(selection.capacity).filter {$0 != 65535})
        let fixed = Array(selection.selectedSlots.prefix(selection.fixedCount).filter {$0 != 65535})
        guard selected.allSatisfy({records[$0] != nil}) else {throw EngineError.invalid("Party preparation is missing a selected person")}
        var issues:[Issue] = [],healers:[Int] = []
        for id in extras.favoritePeople where !selected.contains(id) {
            let available = selection.candidates.contains(id),name = records[id]?.name ?? "장수 \(id)"
            issues.append(.init(kind:available ? .favoriteMissing : .favoriteUnavailable,personID:id,
                title:name+(available ? " · 주력 장수 미선택" : " · 주력 장수 참가 불가"),
                explanation:available ? "이번 편성 후보에 있는 주력 장수입니다. 필요하면 선택을 바꿀 수 있습니다." : "현재 원본 편성 후보에 없습니다. 다른 장수로 자동 대체하지 않습니다."))
        }
        for id in selected {
            guard let person = records[id] else {continue}
            if !person.itemIDs.contains(255) {
                issues.append(.init(kind:.fullInventory,personID:id,title:person.name+" · 소지품 8칸 사용",
                    explanation:"추가 물품을 받을 빈칸이 없습니다. 현재 편성으로 출전할 수 있습니다."))
            }
            let itemRecovery = person.itemIDs.contains {id in
                switch OriginalItemUse.of(id) {case .recovery(let kind,_),.areaRecovery(let kind,_):return kind&1 != 0;default:return false}
            }
            let skillRecovery:Bool
            if let levels = movement.strategyLevelRequirements,person.classID != 17 {
                // MAIN's healing dispatcher:24...29 and33...35 include troops.
                skillRecovery = (Array(24...29)+Array(33...35)).contains {levels[$0][person.classID] <= person.level}
            } else {skillRecovery = false}
            if itemRecovery || skillRecovery {healers.append(id)}
        }
        if !selected.isEmpty && healers.isEmpty {
            if movement.strategyLevelRequirements == nil {
                issues.append(.init(kind:.learningUnavailable,personID:nil,title:"병력 회복 책략 · 자료 없음",
                    explanation:"병력 회복 도구는 없습니다. 원본 습득표가 없어 책략 보유 여부를 확인할 수 없습니다."))
            } else {
                issues.append(.init(kind:.noTroopRecovery,personID:nil,title:"병력 회복 수단 없음",
                    explanation:"선택 장수에게 배운 병력 회복 책략이나 병력 회복 도구가 없습니다. 사기 회복과 구분한 권고이며 출전을 막지 않습니다."))
            }
        }
        return Report(selectedPeople:selected,fixedPeople:fixed,capacity:selection.capacity,names:records.mapValues(\.name),troopRecoveryPeople:healers,issues:issues)
    }
    static func applying(preset:CampaignExtras.PartyPreset,to selection:OriginalPartySelection) throws -> Plan {
        try validate(selection)
        var next = selection,omitted:[Omission] = []
        let fixed = Array(selection.selectedSlots.prefix(selection.fixedCount).filter {$0 != 65535})
        for id in selection.selectedSlots.prefix(selection.capacity).dropFirst(selection.fixedCount) where id != 65535 {
            // Keep original toggle semantics and capacity accounting, including
            // the source's initial default-person selection behavior.
            try next.toggle(person:id)
        }
        var requested = Set<Int>()
        for id in preset.people {
            guard (0..<384).contains(id) else {omitted.append(.init(personID:id,reason:.invalid));continue}
            guard requested.insert(id).inserted else {omitted.append(.init(personID:id,reason:.duplicate));continue}
            if fixed.contains(id) {continue}
            guard next.candidates.contains(id) else {omitted.append(.init(personID:id,reason:.unavailable));continue}
            guard next.remaining > 0,next.selectedSlots.prefix(next.capacity).contains(65535) else {omitted.append(.init(personID:id,reason:.capacity));continue}
            try next.toggle(person:id)
        }
        try validate(next)
        return Plan(selection:next,omitted:omitted,preservedFixedPeople:fixed)
    }
    static func validate(_ selection:OriginalPartySelection) throws {
        guard selection.selectedSlots.count == 15,selection.preparedRoster.slots.count == 45,(0...15).contains(selection.capacity),
              (0...selection.capacity).contains(selection.fixedCount),(0...65535).contains(selection.remaining),
              selection.candidates.allSatisfy({(0..<384).contains($0)}),Set(selection.candidates).count == selection.candidates.count,
              selection.selectedSlots.allSatisfy({$0 == 65535 || (0..<384).contains($0)}) else {
            throw EngineError.invalid("Party preparation selection is invalid")
        }
        let selected = selection.selectedSlots.prefix(selection.capacity).filter {$0 != 65535}
        guard Set(selected).count == selected.count else {throw EngineError.invalid("Party selection repeats a person")}
    }
    #if canImport(AppKit)
    static func sheet(_ report:Report,selected:Int = 0,onChoose:@escaping(Int?)->Void) -> CanvasSheet {
        var rows:[CanvasSheet.Row] = report.issues.map {issue in
            .init(label:issue.title,value:"권고",warns:true,
                detail:.init(heading:issue.title,body:issue.explanation+"\n점검만으로 편성이나 출전 상태가 바뀌지 않습니다."))
        }
        if rows.isEmpty {rows.append(.init(label:"추가 권고 없음",detail:.init(heading:"출전 준비 점검",body:"현재 선택에서 표시할 권고가 없습니다. 전투의 성공을 보장하는 평가는 아닙니다.")))}
        let healers = report.troopRecoveryPeople.map {report.names[$0] ?? "장수 \($0)"}
        rows.append(.init(label:"병력 회복 수단 보유",value:"\(healers.count)명",detail:.init(heading:"병력 회복 수단 보유",
            body:"배운 책략 또는 도구 기준입니다. 실제 사용 가능 여부는 전투의 책략치·상태·대상 조건에 따라 달라집니다.",list:healers)))
        rows.append(.init(label:"강제 출전",value:"\(report.fixedPeople.count)명",detail:.init(heading:"강제 출전",
            body:"원본 시나리오가 지정한 고정 선택입니다. 프리셋으로 해제하지 않습니다.",list:report.fixedPeople.map {report.names[$0] ?? "장수 \($0)"})))
        return CanvasSheet(portrait:nil,speaker:"출전 준비 점검",line:"권고를 확인하고 편성으로 돌아갈 수 있습니다.",badge:("선택","\(report.selectedPeople.count)/\(report.capacity)"),
            rows:rows,selected:min(max(selected,0),rows.count-1),mode:.list,hint:"↑↓ 점검 · Esc 편성으로",fullCanvas:true,onChoose:onChoose)
    }
    #endif
}
