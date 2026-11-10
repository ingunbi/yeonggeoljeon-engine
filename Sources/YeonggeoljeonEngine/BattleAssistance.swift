// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Presentation-only queries. These never move a live unit, advance an
/// operation, consume the session RNG or write a campaign checkpoint.
enum BattleAssistance {
    enum StrategyReason:Equatable {
        case mp(shortfall:Int), rain
        var text:String {
            switch self {
            case .mp(let n):return "MP \(n) 부족"
            case .rain:return "비로 사용 불가"
            }
        }
    }
    static func strategyReasons(ability:Int,cost:Int,mp:UInt8,rain:Bool) -> [StrategyReason] {
        var reasons:[StrategyReason] = []
        if cost > Int(mp) { reasons.append(.mp(shortfall:cost-Int(mp))) }
        if (0..<5).contains(ability),rain { reasons.append(.rain) }
        return reasons
    }

    struct ConditionDetail:Equatable { var title:String; var body:String; var facts:[Fact] = [] }
    struct Fact:Equatable { var label:String; var value:String }
    static func conditions(in session:OriginalBattleSession,slot:Int) throws -> [ConditionDetail] {
        guard let unit = session.units[slot],!unit.enemy || unit.scriptFlags&0x20 != 0 else {
            throw BattleError.illegalAction("공개된 부대만 확인할 수 있습니다.")
        }
        guard unit.status == 2 else {
            return [.init(title:"전선 이탈",body:"현재 전투의 전선에서 이탈했습니다.\n이동·공격·책략·도구 사용 대상이 아닙니다.\n혼란과 달리 회복 책략으로 전선에 복귀하지 않습니다.")]
        }
        var rows:[ConditionDetail] = []
        if unit.scriptFlags&2 != 0 {
            let stats = try session.people.stats(unit.person,morale:unit.morale)
            // Only the source threshold is inspected. This fixed, private RNG
            // is unrelated to the live game's next draw; recovered is ignored.
            var probe = OriginalRNG(state:0)
            let recovery = try OriginalCombat.recoverCondition2(stats:stats,unitStatus:unit.status,
                conditionFlags:Int(unit.scriptFlags),rng:&probe)
            let chance = min(100,max(0,recovery.threshold ?? 0))
            rows.append(.init(title:"혼란",body:"이동·행동과 반격이 제한됩니다.\n진영의 상태 회복 처리에서 해제 판정을 받습니다.\n사기를 회복하는 책략·도구·지형 효과도 해제 판정을 일으킬 수 있습니다. 병력만 회복하는 효과는 혼란 해제를 보장하지 않습니다.\n고정된 남은 턴은 없습니다. 사기가 바뀌면 확률도 달라집니다.",
                facts:[.init(label:"현재 상태의 1회 해제 확률",value:"\(chance)%"),.init(label:"현재 사기",value:"\(unit.morale)")]))
        }
        if unit.scriptFlags&0x80 != 0 {
            rows.append(.init(title:"행동 완료",body:"이번 차례의 행동을 마쳤습니다.\n혼란과는 다르며, 회복 책략으로 행동 횟수가 돌아오지 않습니다."))
        } else if unit.scriptFlags&0x40 != 0 {
            rows.append(.init(title:"이동 완료 · 행동 선택 중",body:"현재 위치에서 공격·책략·도구·대기를 선택할 수 있습니다.\n아직 행동을 확정하지 않았다면 명령창의 Esc로 이동을 취소할 수 있습니다."))
        }
        if unit.scriptFlags&0x20 == 0 {
            rows.append(.init(title:"매복",body:"매복 상태의 전용 명령을 사용합니다.\n일반 이동과 일반 명령은 매복 해제 후 확인하세요. 혼란 해제와는 다른 상태입니다."))
        }
        if !unit.enemy,unit.orderMode != 7 || unit.scriptFlags&4 != 0 {
            rows.append(.init(title:"직접 지휘 불가",body:"현재 명령 모드 또는 시나리오 상태에 따라 직접 지휘할 수 없습니다.\n이 안내를 열어도 시나리오의 지휘 조건은 바뀌지 않습니다."))
        }
        if rows.isEmpty { rows.append(.init(title:"특이 상태 없음",body:"현재 혼란이나 행동 완료 상태가 아닙니다.\n이동·행동 가능 여부는 차례와 지휘 조건에 따라 정해집니다.")) }
        return rows
    }

    static func rosterRows(in session:OriginalBattleSession,slots:[Int],options:BattleRosterOptions) throws -> [Int] {
        struct Row { var unit:OriginalLiveUnit; var person:OriginalPersonDefinition; var maximum:Int; var index:Int }
        var rows:[Row] = []
        for (index,slot) in slots.enumerated() {
            guard let unit = session.units[slot],!unit.enemy || unit.scriptFlags&0x20 != 0 else { continue }
            let person = try session.people.person(unit.person)
            let ready = unit.status == 2 && OriginalBattleCommand.denial(unit) == nil && (try? session.requireManualUnit(slot)) != nil
            let maximum = try OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:session.combat)
            if options.filters.contains(.ready),!ready { continue }
            if options.filters.contains(.wounded),!(unit.status == 2 && maximum > 0 && person.rawTroops*2 <= maximum) { continue }
            if options.filters.contains(.confused),!(unit.status == 2 && unit.scriptFlags&2 != 0) { continue }
            if options.filters.contains(.healer) {
                guard ready,person.classID != 17,
                      let abilities = try? session.movement.availableStrategies(classID:person.classID,level:person.level,mp:unit.mp),
                      abilities.contains(where:{(21..<36).contains($0)}) else { continue }
            }
            rows.append(Row(unit:unit,person:person,maximum:maximum,index:index))
        }
        rows.sort { a,b in
            let comparison:Int
            switch options.sort {
            case .source:comparison = 0
            case .name:
                let result = a.person.name.compare(b.person.name,options:[.caseInsensitive,.numeric])
                comparison = result == .orderedSame ? 0 : result == .orderedAscending ? -1 : 1
            case .level:comparison = a.person.level-b.person.level
            case .troops:comparison = a.person.rawTroops-b.person.rawTroops
            case .ratio:comparison = a.person.rawTroops*max(1,b.maximum)-b.person.rawTroops*max(1,a.maximum)
            }
            if comparison == 0 { return a.index < b.index }
            return options.descending ? comparison > 0 : comparison < 0
        }
        return rows.map { $0.unit.slot }
    }

    enum MoveReason:Equatable {
        case outside,confused,acted,moved,terrain,occupied,enemy,control,budget(required:Int,available:Int),blocked,unavailable
        var text:String {
            switch self {
            case .outside:return "지도 밖은 이동할 수 없습니다."
            case .confused:return "혼란 상태에서는 이동할 수 없습니다."
            case .acted:return "이번 차례의 행동을 이미 마쳤습니다."
            case .moved:return "이동을 이미 마쳤습니다. 명령을 취소하면 이동 전 위치로 돌아갑니다."
            case .terrain:return "현재 병과가 통과할 수 없는 지형입니다."
            case .occupied:return "아군이 있는 칸에는 멈출 수 없습니다. 통과 가능한 경로와는 별개입니다."
            case .enemy:return "공개된 적 부대가 차지한 칸입니다."
            case .control:return "공개된 적의 인접 구역 때문에 더 나아갈 수 없습니다."
            case let .budget(required,available):return "이동력 부족 · 필요한 경로 비용 \(required), 현재 \(available)"
            case .blocked:return "현재 이동 규칙과 공개된 지형·배치에서 경로를 확인할 수 없습니다."
            case .unavailable:return "현재 이동할 수 없는 칸입니다."
            }
        }
    }
    struct MovementDetail:Equatable {
        var terrain:Int?
        var entryCost:Int?
        var budget:Int
        var route:[GridPoint]
        var totalCost:Int?
        var reason:MoveReason?
        var remaining:Int? { totalCost.map { budget-$0 } }
    }
    static func movement(in session:OriginalBattleSession,slot:Int,to point:GridPoint) throws -> MovementDetail {
        let board = try session.board(),unit = try session.live(slot),budget = try session.movementBudget(slot)
        guard let actor = board.actors.first(where:{$0.runtimeSlot == slot}) else { throw BattleError.invalid("Movement actor is absent") }
        var result = MovementDetail(terrain:nil,entryCost:nil,budget:Int(budget),route:[],totalCost:nil,reason:nil)
        guard board.contains(point) else { result.reason = .outside;return result }
        let terrain = Int(board.terrain[board.index(point)])
        result.terrain = terrain;result.entryCost = try session.movement.cost(classID:actor.classID,terrain:terrain)
        if unit.scriptFlags&2 != 0 { result.reason = .confused;return result }
        if unit.scriptFlags&0x80 != 0 { result.reason = .acted;return result }
        if unit.scriptFlags&0x40 != 0,point != unit.position { result.reason = .moved;return result }
        if let path = try? OriginalMovement.route(profile:session.movement,board:board,moving:actor,to:point,budget:budget) {
            let costs = try path.dropFirst().map { try session.movement.cost(classID:actor.classID,terrain:Int(board.terrain[board.index($0)])) }
            result.route = path;result.totalCost = costs.reduce(0,+);return result
        }
        // Explain only constraints that can be proven from already visible
        // facts. Hidden occupancy and ZOC never contribute an identity/heading.
        var publicBoard = board
        publicBoard.actors.removeAll { actor in
            guard let unit = session.units[actor.runtimeSlot] else { return true }
            return unit.enemy && unit.scriptFlags&0x20 == 0
        }
        if result.entryCost == 255 { result.reason = .terrain;return result }
        if let occupant = publicBoard.occupant(point),point != actor.position {
            result.reason = occupant.sourceFaction == actor.sourceFaction ? .occupied : .enemy;return result
        }
        let broad = try OriginalMovement.distanceField(profile:session.movement,board:publicBoard,moving:actor,seed:actor.position,limit:254)
        if broad.value(point) != 255 {
            let cost = Int(broad.value(point))
            // A source distance may have a descending-path limitation. Do not
            // label an otherwise affordable route as a budget failure.
            result.reason = cost > Int(budget) ? .budget(required:cost,available:Int(budget)) : .unavailable
            return result
        }
        let unrestricted = try OriginalMovement.distanceField(profile:session.movement,board:publicBoard,moving:actor,seed:actor.position,limit:254,ignoreZOC:true)
        result.reason = unrestricted.value(point) != 255 ? .control : .blocked
        return result
    }
}

struct BattleRosterOptions:Codable,Equatable {
    enum Filter:String,Codable,CaseIterable {
        case ready,wounded,confused,healer
        var title:String {
            switch self { case .ready:return "미행동";case .wounded:return "병력 50% 이하";case .confused:return "혼란";case .healer:return "회복 책략 사용 자격" }
        }
    }
    enum Sort:String,Codable,CaseIterable {
        case source,name,level,troops,ratio
        var title:String {
            switch self {case .source:return "기본 순서";case .name:return "이름";case .level:return "레벨";case .troops:return "현재 병력";case .ratio:return "병력 비율"}
        }
    }
    var filters:Set<Filter> = []
    var sort:Sort = .source
    var descending = false
    var summary:String { filters.isEmpty ? "전체 · \(sort.title)" : Filter.allCases.filter {filters.contains($0)}.map(\.title).joined(separator:" · ") }
    static var current:Self {
        get { UserDefaults.standard.data(forKey:"battleRosterOptions").flatMap {try? JSONDecoder().decode(Self.self,from:$0)} ?? Self() }
        set { if let data = try? JSONEncoder().encode(newValue) {UserDefaults.standard.set(data,forKey:"battleRosterOptions")} }
    }
}
