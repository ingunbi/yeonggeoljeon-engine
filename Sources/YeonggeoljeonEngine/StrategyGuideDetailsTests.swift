// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func strategyGuideDetailsSelfTests() throws {
    var checks = 0
    func check(_ condition:@autoclosure() throws -> Bool,_ reason:String) throws {
        guard try condition() else { throw EngineError.invalid("Strategy guide detail regression: \(reason)") };checks += 1
    }
    func rejected(_ body:() throws -> Void)->Bool { do { try body();return false } catch { return true } }
    let cardinal = [OriginalAIOffset(dx:0,dy:-1),OriginalAIOffset(dx:1,dy:0),OriginalAIOffset(dx:0,dy:1),OriginalAIOffset(dx:-1,dy:0)]
    let diagonal = [OriginalAIOffset(dx:-1,dy:-1),OriginalAIOffset(dx:1,dy:-1),OriginalAIOffset(dx:1,dy:1),OriginalAIOffset(dx:-1,dy:1)]
    let profile = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),
        classMovementBudgets:Array(repeating:3,count:19),attackRangeCodes:Array(repeating:0,count:19),
        movementCosts:Array(repeating:Array(repeating:1,count:256),count:4),cardinalOffsets:cardinal,
        diagonalOffsets:diagonal,extendedOffsets:cardinal,
        strategyLevelRequirements:Array(repeating:Array(repeating:1,count:19),count:36),
        strategyMPCosts:Array(repeating:1,count:36),strategyCategories:(0..<36).map { $0 >= 30 ? 3 : $0%3 },
        strategyTerrainEligibility:[[0,1,2,3],[0,1,255,255],[2,3,255,255]])
    let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
    let before = try encoder.encode(profile)
    let descriptions = try (0..<36).map { try StrategyGuideDetails.describe(abilityID:$0,profile:profile) }

    // Compare the guide's whole relative shape with the actual target selector,
    // placing one target at every possible nearby cell. This catches friendly
    // self-selection and aggregate category semantics, not merely label text.
    let origin = GridPoint(x:4,y:4)
    let actor = OriginalMovementActor(runtimeSlot:0,position:origin,classID:0,scriptFlags:0,active:true)
    for ability in 0..<36 {
        let details = descriptions[ability],friendly = ability >= 21
        var targets:Set<GridPoint> = []
        for dx in -3...3 { for dy in -3...3 {
            var actors = [actor]
            let slot = friendly ? 1 : 15
            if dx != 0 || dy != 0 {
                actors.append(OriginalMovementActor(runtimeSlot:slot,position:GridPoint(x:origin.x+dx,y:origin.y+dy),
                    classID:0,scriptFlags:0,active:true))
            }
            let board = OriginalMovementBoard(width:9,height:9,terrain:Array(repeating:0,count:81),actors:actors)
            let selected = try OriginalAI.strategyTargetSlots(profile:profile,board:board,actor:actor,abilityID:ability)
            if selected.contains(dx == 0 && dy == 0 ? 0 : slot) { targets.insert(GridPoint(x:dx,y:dy)) }
        } }
        try check(targets == Set(details.targetOffsets.map { GridPoint(x:$0.dx,y:$0.dy) }),
                  "ability \(ability) guide target shape matches actual source target selection")
    }
    try check(descriptions[0].targetOffsets.count == 8 && descriptions[1].targetOffsets.count == 12 && descriptions[2].targetOffsets.count == 20,
              "the three source range patterns have 8, 12 and 20 surrounding cells")
    try check(descriptions[0].range.contains("대각 포함") && descriptions[1].range.contains("직선 2칸") && descriptions[2].range.contains("네 모서리 제외"),
              "range text distinguishes diagonal reach and the absent outer corners")
    try check(descriptions[21].targetOffsets.first == OriginalAIOffset(dx:0,dy:0) && descriptions[21].effectOffsets.count == 1,
              "single recovery may select self but affects only one selected target")
    try check(descriptions[0].kind == .damage(family:0) && descriptions[5].kind == .damage(family:1) && descriptions[10].kind == .damage(family:2),
              "damage families keep distinct effect descriptions")
    try check(descriptions[0].effectOffsets.count == 1 && descriptions[3].effectOffsets == [OriginalAIOffset(dx:0,dy:0)]+cardinal && descriptions[3].effectOrigin == .selectedTarget,
              "splash damage is centered on the selected enemy, not the caster")
    try check(descriptions[15].kind == .confusion && descriptions[16].effectOffsets.count == 1 && descriptions[17].effectOffsets.count == 5,
              "the last confusion row alone spreads to the four target neighbors")
    try check(descriptions[18].kind == .lowerMorale && descriptions[20].effectOffsets.count == 1,
              "morale reduction remains single-target at every range tier")
    try check(descriptions[21].kind == .recoverMorale && descriptions[24].kind == .recoverTroops && descriptions[27].kind == .recoverBoth,
              "single support identifies morale, troops and combined restoration")
    try check(descriptions[30].kind == .recoverMorale && descriptions[33].kind == .recoverTroops,
              "area support separates morale from troop restoration")
    try check(descriptions[30].effectOffsets.count == 9 && descriptions[31].effectOffsets.count == 13 && descriptions[32].effectOffsets.count == 21,
              "aggregate support includes the caster and every source-range cell")
    try check(descriptions[35].effectOrigin == .caster && descriptions[35].effectOffsets == descriptions[35].targetOffsets,
              "area support is centered on the caster without a separately chosen target")
    try check(descriptions[0].conditions.contains(where:{$0.contains("비가 오면")}) && !descriptions[5].conditions.contains(where:{$0.contains("비가 오면")}),
              "rain blocks only the fire family")
    try check(descriptions[21].conditions.contains(where:{$0.contains("일정 확률")}) && !descriptions[24].conditions.contains(where:{$0.contains("혼란")}),
              "morale healing describes probabilistic confusion recovery without promising troop-only cures")
    let terrainNames = ["검증지형 가","검증지형 나","검증지형 다","검증지형 라"]
    let terrain = try StrategyGuideDetails.describe(abilityID:0,profile:profile,terrainNames:terrainNames)
    try check(terrain.conditions.last == "사용 지형: 검증지형 가 · 검증지형 나 · 검증지형 다 · 검증지형 라",
              "terrain requirements use the caller's decoded names")
    let partial = try StrategyGuideDetails.describe(abilityID:5,profile:profile,terrainNames:terrainNames)
    try check(partial.conditions.last == "주요 사용 지형: 검증지형 가 · 검증지형 나" && !partial.conditions.joined().contains("255"),
              "unnamed raw terrain is not invented, leaked as a player-facing ID, or silently described as an exhaustive named list")
    try check(try encoder.encode(profile) == before,"all descriptions leave the original tables untouched")
    try check(rejected { _ = try StrategyGuideDetails.describe(abilityID:-1,profile:profile) } &&
              rejected { _ = try StrategyGuideDetails.describe(abilityID:36,profile:profile) },"out-of-range ability identities fail explicitly")
    var missing = profile;missing.strategyCategories = nil
    try check(rejected { _ = try StrategyGuideDetails.describe(abilityID:0,profile:missing) },"missing source categories are rejected")
    var unsupported = profile;unsupported.strategyCategories?[30] = 0
    try check(rejected { _ = try StrategyGuideDetails.describe(abilityID:30,profile:unsupported) },"unsupported source row/category combinations are not guessed")
    var noTerrain = profile;noTerrain.strategyTerrainEligibility = nil
    try check(rejected { _ = try StrategyGuideDetails.describe(abilityID:0,profile:noTerrain) },"damage descriptions require the source terrain gate")
    try check(try StrategyGuideDetails.describe(abilityID:24,profile:noTerrain).kind == .recoverTroops,"support descriptions do not demand an unrelated terrain table")
    var alternate = profile;alternate.extendedOffsets = diagonal
    let unusual = try StrategyGuideDetails.describe(abilityID:1,profile:alternate)
    try check(unusual.range.contains("도형 참조") && !unusual.range.contains("직선 2칸"),"a valid alternative offset profile never receives a false canonical range label")
    print("Strategy guide detail self-tests passed: \(checks)")
}
