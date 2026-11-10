// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Read-only presentation of the implemented source dispatcher (MAIN
/// 0x2E836..0x2EE1C), healing producer (0x2EE20..0x2F052), and target-range
/// enumerator (0x2F578). Category bytes and offsets remain caller-owned data
/// from MAIN DS:44C8, 4D1C, 4CFC and 4D0C; no original table is embedded here.
enum StrategyGuideDetails {
    enum Effect:Equatable {
        case damage(family:Int), confusion, lowerMorale, recoverMorale, recoverTroops, recoverBoth
    }
    enum Origin:Equatable { case caster, selectedTarget }
    struct Description:Equatable {
        var kind:Effect
        var effect:String
        var target:String
        var range:String
        var area:String
        var conditions:[String]
        /// Legal target positions relative to the caster on an unbounded map.
        /// Friendly strategies include the caster's own cell.
        var targetOffsets:[OriginalAIOffset]
        /// Affected cells relative to effectOrigin. Occupancy, allegiance and
        /// terrain still filter the units actually affected during execution.
        var effectOffsets:[OriginalAIOffset]
        var effectOrigin:Origin
    }

    static func describe(abilityID:Int,profile:OriginalMovementProfile,terrainNames:[String]? = nil) throws -> Description {
        try profile.validate()
        guard (0..<36).contains(abilityID),let categories = profile.strategyCategories,categories.count == 36 else {
            throw EngineError.invalid("Strategy guide needs a valid ability and source categories")
        }
        let category = categories[abilityID],aggregate = abilityID >= 30
        // The examined dispatcher uses categories 0...2 for targeted effects
        // and category 3 for IDs30...35. A different profile needs research,
        // rather than an apparently valid description of an unsupported row.
        guard aggregate ? category == 3 : (0...2).contains(category) else {
            throw BattleError.unsupported("Strategy guide cannot describe this source ability/category combination")
        }
        let friendly = abilityID >= 21,rangeCategory = aggregate ? (abilityID-30)%3 : category
        let origin = GridPoint(x:4,y:4)
        let board = OriginalMovementBoard(width:9,height:9,terrain:Array(repeating:0,count:81),actors:[])
        var cells = try OriginalAI.rangeCells(profile:profile,board:board,point:origin,raw:rangeCategory|0x80)
            .map { OriginalAIOffset(dx:$0.x-origin.x,dy:$0.y-origin.y) }
        if friendly { cells.insert(OriginalAIOffset(dx:0,dy:0),at:0) }
        let center = OriginalAIOffset(dx:0,dy:0)
        let splash = abilityID < 15 && abilityID%5 >= 3 || abilityID == 17
        let affected = aggregate ? cells : splash ? [center]+profile.cardinalOffsets : [center]
        var result = Description(kind:.confusion,effect:"",target:friendly ? "아군 · 자신 포함" : "적군",
            range:rangeLabel(cells,includesSelf:friendly),
            area:aggregate ? "시전자 중심 \(Set(cells.map { GridPoint(x:$0.dx,y:$0.dy) }).count)칸의 아군 전체" :
                splash ? splashLabel(profile.cardinalOffsets) : "선택한 \(friendly ? "아군" : "적") 1부대",
            conditions:[],targetOffsets:cells,effectOffsets:affected,
            effectOrigin:aggregate ? .caster : .selectedTarget)
        switch abilityID {
        case 0..<15:
            let family = abilityID/5
            result.kind = .damage(family:family)
            result.effect = ["화계로", "물로", "낙석으로"][family]+" 적의 병력과 사기를 줄입니다."
            result.conditions.append("피해와 성공 여부는 지력·레벨 등에 따라 달라집니다.")
            if family == 0 { result.conditions.append("비가 오면 사용할 수 없습니다.") }
            result.conditions.append(try terrainCondition(family:family,profile:profile,names:terrainNames))
        case 15...17:
            result.kind = .confusion
            result.effect = "적을 혼란에 빠뜨려 행동과 반격을 막습니다."
            result.conditions = ["지력·레벨에 따라 실패할 수 있습니다."]
        case 18...20:
            result.kind = .lowerMorale
            result.effect = "적의 사기를 낮춥니다."
            result.conditions = ["지력·레벨에 따라 실패할 수 있습니다.","사기가 30 미만으로 낮아지면 혼란에 빠질 수 있습니다."]
        case 21...23,30...32:
            result.kind = .recoverMorale
            result.effect = "아군의 사기를 회복합니다."
            result.conditions = ["혼란도 일정 확률로 해제합니다.","회복량은 책략 단계·시전자 레벨에 따라 달라집니다."]
        case 24...26,33...35:
            result.kind = .recoverTroops
            result.effect = "아군의 병력을 회복합니다."
            result.conditions = ["회복량은 책략 단계·시전자 지력과 레벨에 따라 달라집니다."]
        case 27...29:
            result.kind = .recoverBoth
            result.effect = "아군의 병력과 사기를 함께 회복합니다."
            result.conditions = ["혼란도 일정 확률로 해제합니다.","회복량은 책략 단계·시전자 지력과 레벨에 따라 달라집니다."]
        default:throw BattleError.unsupported("Strategy guide has no source effect branch")
        }
        return result
    }

    private static func rangeLabel(_ offsets:[OriginalAIOffset],includesSelf:Bool) -> String {
        let points = Set(offsets.filter { $0.dx != 0 || $0.dy != 0 }.map { GridPoint(x:$0.dx,y:$0.dy) })
        let nearby = Set((-1...1).flatMap { x in (-1...1).compactMap { y in x == 0 && y == 0 ? nil : GridPoint(x:x,y:y) } })
        let middle = nearby.union([GridPoint(x:0,y:-2),GridPoint(x:2,y:0),GridPoint(x:0,y:2),GridPoint(x:-2,y:0)])
        let wide = Set((-2...2).flatMap { x in (-2...2).compactMap { y in
            (x == 0 && y == 0) || (abs(x) == 2 && abs(y) == 2) ? nil : GridPoint(x:x,y:y)
        } })
        let label:String
        if points == nearby { label = "주변 1칸 · 대각 포함" }
        else if points == middle { label = "직선 2칸 · 대각 1칸" }
        else if points == wide { label = "주변 2칸 · 네 모서리 제외" }
        else { label = "\(points.count)칸 · 도형 참조" }
        return "시전자 기준 "+label+(includesSelf ? " · 자신 포함" : "")
    }
    private static func splashLabel(_ offsets:[OriginalAIOffset]) -> String {
        let points = Set(offsets.map { GridPoint(x:$0.dx,y:$0.dy) })
        let cardinal:Set<GridPoint> = [GridPoint(x:0,y:-1),GridPoint(x:1,y:0),GridPoint(x:0,y:1),GridPoint(x:-1,y:0)]
        return points == cardinal ? "선택 적 + 상하좌우 · 최대 5부대" : "선택 적 중심 \(points.count+1)칸의 적"
    }
    private static func terrainCondition(family:Int,profile:OriginalMovementProfile,names:[String]?) throws -> String {
        guard let rows = profile.strategyTerrainEligibility,rows.count == 3,rows.allSatisfy({$0.count == 4}) else {
            throw EngineError.invalid("Strategy guide needs source terrain eligibility for damage abilities")
        }
        guard let names else { return "대상 지형에 따라 사용할 수 없는 경우가 있습니다." }
        // Source A392 compares every byte, including raw FF. A source terrain
        // without a named entry cannot be silently turned into a named one.
        let row = rows[family],known = row.filter { names.indices.contains($0) && !names[$0].isEmpty }
        var labels:[String] = []
        for id in known where !labels.contains(names[id]) { labels.append(names[id]) }
        guard !labels.isEmpty else { return "대상 지형에 따라 사용할 수 없는 경우가 있습니다." }
        let prefix = known.count == row.count ? "사용 지형: " : "주요 사용 지형: "
        return prefix+labels.joined(separator:" · ")
    }
}
