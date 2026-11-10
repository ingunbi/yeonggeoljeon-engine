// SPDX-License-Identifier: GPL-3.0-only
import AppKit

func strategyLearningGuideSelfTests() throws {
    var checks = 0
    func check(_ condition:@autoclosure() throws -> Bool,_ message:String) throws {
        guard try condition() else { throw EngineError.invalid("Strategy learning guide regression: \(message)") }
        checks += 1
    }
    func rejected(_ body:() throws -> Void) -> Bool { do { try body();return false } catch { return true } }
    var levels = Array(repeating:Array(repeating:255,count:19),count:36)
    let costs = (0..<36).map { $0%12 },names = (0..<36).map { "책략 \($0)" }
    levels[7][2] = 6;levels[3][2] = 6;levels[11][2] = 12;levels[14][2] = 99
    levels[25][2] = 100;levels[26][2] = 254
    levels[0][3] = 0;levels[1][17] = 1
    let beforeLevels = levels,beforeCosts = costs,beforeNames = names
    let first = try StrategyLearningGuide.entries(classID:2,level:1,levels:levels,costs:costs,names:names)
    try check(first.map(\.abilityID) == [3,7,11,14],"all attainable future abilities are shown by level and source-ID tie order")
    try check(first.allSatisfy { !$0.learned } && first.map(\.remainingLevels) == [5,5,11,98],"unlearned rows retain the exact levels still needed")
    try check(first[0].name == names[3] && first[0].mpCost == costs[3],"names and costs stay attached to their source ability after sorting")
    let threshold = try StrategyLearningGuide.entries(classID:2,level:6,levels:levels,costs:costs,names:names)
    try check(threshold.map(\.learned) == [true,true,false,false] && threshold[0].remainingLevels == 0,"the exact required level counts as learned")
    let highest = try StrategyLearningGuide.entries(classID:2,level:99,levels:levels,costs:costs,names:names)
    try check(highest.count == 4 && highest.allSatisfy(\.learned),"level 99 is attainable but source values above it never promise a future ability")
    let otherClass = try StrategyLearningGuide.entries(classID:3,level:0,levels:levels,costs:costs,names:names)
    try check(otherClass.map(\.abilityID) == [0] && otherClass[0].learned,"changing class selects a different original column, including level zero")
    try check(try StrategyLearningGuide.entries(classID:17,level:99,levels:levels,costs:costs,names:names).isEmpty,"the source class-17 exclusion wins over a table row")
    try check(rejected { _ = try StrategyLearningGuide.entries(classID:-1,level:1,levels:levels,costs:costs,names:names) },"a negative class is rejected before table access")
    try check(rejected { _ = try StrategyLearningGuide.entries(classID:19,level:1,levels:levels,costs:costs,names:names) },"an unavailable class is rejected before table access")
    try check(rejected { _ = try StrategyLearningGuide.entries(classID:2,level:100,levels:levels,costs:costs,names:names) },"levels above the game cap are not silently accepted")
    var badLevels = levels;badLevels[3].removeLast()
    try check(rejected { _ = try StrategyLearningGuide.entries(classID:2,level:1,levels:badLevels,costs:costs,names:names) },"truncated source rows fail explicitly")
    badLevels = levels;badLevels[3][2] = 256
    try check(rejected { _ = try StrategyLearningGuide.entries(classID:2,level:1,levels:badLevels,costs:costs,names:names) },"out-of-byte table values fail explicitly")
    var badCosts = costs;badCosts[0] = -1
    try check(rejected { _ = try StrategyLearningGuide.entries(classID:2,level:1,levels:levels,costs:badCosts,names:names) },"negative MP costs fail explicitly")
    var badNames = names;badNames[2] = " "
    try check(rejected { _ = try StrategyLearningGuide.entries(classID:2,level:1,levels:levels,costs:costs,names:badNames) },"a missing source name is not replaced with invented content")
    var person = OriginalPersonDefinition(id:0,name:"검증 장수",classID:2,level:1,experience:13,rawTroops:100,
        defenseScalar:20,attackScalar:30,intellectScalar:40,personality:0,personalScalar:0,itemIDs:Array(repeating:255,count:8),
        sourceFlags:0x80,sourceRole:2,sourceContext2:0,sourceContext3:0,source:nil)
    let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
    let beforePerson = try encoder.encode(person)
    let cardinal = [OriginalAIOffset(dx:0,dy:-1),.init(dx:1,dy:0),.init(dx:0,dy:1),.init(dx:-1,dy:0)]
    let diagonal = [OriginalAIOffset(dx:-1,dy:-1),.init(dx:1,dy:-1),.init(dx:1,dy:1),.init(dx:-1,dy:1)]
    let profile = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),
        classMovementBudgets:Array(repeating:3,count:19),attackRangeCodes:Array(repeating:0,count:19),
        movementCosts:Array(repeating:Array(repeating:1,count:256),count:4),cardinalOffsets:cardinal,
        diagonalOffsets:diagonal,extendedOffsets:cardinal,strategyLevelRequirements:levels,strategyMPCosts:costs,
        strategyCategories:(0..<36).map { $0 >= 30 ? 3 : $0%3 },strategyTerrainEligibility:Array(repeating:[0,1,2,3],count:3))
    var choices:[Int?] = []
    let sheet = try StrategyLearningGuide.sheet(person:person,levels:levels,costs:costs,names:names,profile:profile,className:"검증 병과",portrait:nil,selected:999) { choices.append($0) }
    try check(sheet.rows.count == 4 && sheet.rows.allSatisfy(\.enabled),"future abilities remain inspectable rather than disabled as if executing them")
    try check(sheet.selected == 3 && sheet.rows.allSatisfy { $0.checked == nil },"selection is bounded and reading status is not represented as an editable checkbox")
    try check(sheet.badge.value == "0 / 4" && sheet.rows[0].detail?.facts.contains(where:{$0.label == "필요 MP" && $0.value == "3"}) == true,
              "the guide distinguishes learned count and MP requirement")
    try check(sheet.rows[0].detail?.body.contains("5레벨 남음") == true && sheet.line.contains("현재 병과 기준"),"requirements and the class scope are readable before learning")
    try check(sheet.rows[0].detail?.strategy?.kind == .damage(family:0) && sheet.rows[0].detail?.strategy?.effectOffsets.count == 5,
              "a future learned row carries its actual effect and target-centered splash geometry")
    try check(sheet.rows[3].detail?.strategy?.targetOffsets.count == 20 && sheet.fullCanvas,
              "the full canvas guide carries the far-range geometry for its selected ability")
    sheet.onChoose(2);try check(choices == [2],"row choices are handed back without granting the ability")
    sheet.onChoose(nil);try check(choices.count == 2 && choices[1] == nil,"Escape can return to the owner without selecting an ability")
    try check(try encoder.encode(person) == beforePerson && levels == beforeLevels && costs == beforeCosts && names == beforeNames,
              "building and browsing the guide leaves the character and original tables unchanged")
    person.level = 6
    let learnedSheet = try StrategyLearningGuide.sheet(person:person,levels:levels,costs:costs,names:names,profile:profile,className:"검증 병과",portrait:nil) { _ in }
    try check(learnedSheet.rows[0].label.hasPrefix("✓ ") && !learnedSheet.rows[2].label.hasPrefix("✓ "),"learned and future rows are visibly distinguished")
    person.classID = 17
    let empty = try StrategyLearningGuide.sheet(person:person,levels:levels,costs:costs,names:names,profile:profile,className:"검증 병과",portrait:nil) { _ in }
    try check(empty.badge.value == "0 / 0" && empty.rows.count == 1 && empty.rows[0].detail?.body.contains("배울 수 있는 책략이 없습니다") == true,
              "a class with no strategies has an explicit readable empty state")
    person.classID = 2;person.level = 1
    let allLevels = (0..<36).map { ability in Array(repeating:ability+1,count:19) }
    let longSheet = try StrategyLearningGuide.sheet(person:person,levels:allLevels,costs:costs,names:names,profile:profile,className:"검증 병과",portrait:nil,selected:35) { _ in }
    let overlay = CanvasOverlayView(frame:CGRect(x:0,y:0,width:640,height:400))
    overlay.viewport = CGRect(x:0,y:48,width:480,height:320);overlay.show(longSheet)
    try check(longSheet.rows.count == 36 && overlay.sheetRowRect(35) != nil && overlay.sheetRowRect(0) == nil,
              "the last ability remains reachable through the scrollable sheet")
    try check(overlay.sheetRowRect(35).map { overlay.bounds.contains($0) } == true && longSheet.portrait == nil && longSheet.fullCanvas,
              "the guide's full canvas keeps its final visible row inside the canvas even beside a small battle viewport")
    print("Strategy learning guide self-tests passed: \(checks)")
}
