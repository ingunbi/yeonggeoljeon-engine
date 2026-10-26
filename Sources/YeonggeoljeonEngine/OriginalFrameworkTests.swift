// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Synthetic checks for the outer framework and battle-exit boundaries.
func originalFrameworkSelfTests() throws {
    var checks = 0
    func check(_ condition:Bool,_ message:String) throws {
        guard condition else { throw EngineError.invalid("Original framework regression: \(message)") }
        checks += 1
    }
    // MAIN1E31C..1E344 raw battle results.
    try check(OriginalBattleExit.decide(result:1,contextMap:0x1000,selectionMaps:[0x1000]) == .restoreCheckpoint,
              "result one selects checkpoint restoration, not map entry")
    try check(OriginalBattleExit.decide(result:3,contextMap:0x1000,selectionMaps:[0x1000]) == .framework(mask:0x20),
              "result three adds framework mask20 even with a selected map")
    try check(OriginalBattleExit.decide(result:4,contextMap:0x1000,selectionMaps:[]) == .framework(mask:0x40),
              "result four adds framework mask40")
    try check(OriginalBattleExit.decide(result:2,contextMap:0x1000,selectionMaps:[0x1000]) == .enterMap(selectionIndex:0),
              "victory enters source11's context+0A without a source09")
    try check(OriginalBattleExit.decide(result:2,contextMap:0x1000,selectionMaps:[0x2004,0x1000]) == .enterMap(selectionIndex:1),
              "the latest producer agreeing with context+0A owns the entry")
    try check(OriginalBattleExit.decide(result:5,contextMap:0x2004,selectionMaps:[0x2004]) == .enterMap(selectionIndex:0),
              "other nonzero results also call C86C")
    if case .unsupported = OriginalBattleExit.decide(result:2,contextMap:0x3001,selectionMaps:[0x3001]) { checks += 1 }
    else { throw EngineError.invalid("Original framework regression: battle re-entry through C86C was accepted") }
    if case .unsupported = OriginalBattleExit.decide(result:2,contextMap:0x1000,selectionMaps:[0x2004]) { checks += 1 }
    else { throw EngineError.invalid("Original framework regression: context+0A without a restored producer was accepted") }
    if case .unsupported = OriginalBattleExit.decide(result:0,contextMap:0x1000,selectionMaps:[0x1000]) { checks += 1 }
    else { throw EngineError.invalid("Original framework regression: an unfinished battle produced an exit") }
    // Interpreter statuses and main's selector.
    try check(OriginalFrameworkReturn.mask(interpreterStatus:7) == 0x20 && OriginalFrameworkReturn.mask(interpreterStatus:8) == 4 &&
              OriginalFrameworkReturn.mask(interpreterStatus:2) == nil, "interpreter statuses translate only seven and eight")
    try check(OriginalFrameworkReturn(mask:0x20,producer:"t").asksRetry && OriginalFrameworkReturn(mask:0x40,producer:"t").asksRetry,
              "masks20 and40 reach the retry selector")
    try check(!OriginalFrameworkReturn(mask:0x24,producer:"t").asksRetry && !OriginalFrameworkReturn(mask:8,producer:"t").asksRetry,
              "the ending mask is tested before the retry selector")
    var restart = OriginalFrameworkReturn(mask:0x20,producer:"t");try restart.answer(1)
    var quit = OriginalFrameworkReturn(mask:0x40,producer:"t");try quit.answer(0)
    try check(restart.outcome == .restart && quit.outcome == .quit, "Yes returns exit code four and No exits")
    for (value,result) in [(restart,1),(OriginalFrameworkReturn(mask:4,producer:"t"),1),(OriginalFrameworkReturn(mask:0x20,producer:"t"),2)] {
        var copy = value
        do { try copy.answer(result) } catch { checks += 1;continue }
        throw EngineError.invalid("Original framework regression: an invalid retry answer was accepted")
    }
    // Program facts exported from MAIN DS:2A2E.
    func program(_ prompt:OriginalFrameworkText?) -> OriginalCampaignProgram {
        let instruction = OriginalCampaignInstruction(opcode:0xFF,offset:0,kind:"end-record",arguments:[],commands:[])
        let record = OriginalCampaignRecord(id:"r",chapter:0,member:0,block:0,ordinal:0,kind:0,inverted:false,rawKind:0,
            words:[0,0,0],group:OriginalCampaignGroup(base:0,count:1,repeating:false),instructions:[instruction])
        return OriginalCampaignProgram(format:1,records:[record],framework:OriginalFrameworkPrompts(retryPrompt:prompt))
    }
    try program(OriginalFrameworkText(text:"synthetic retry",yesResult:1,noResult:0,presentationOrder:[1,0])).validate();checks += 1
    for prompt in [OriginalFrameworkText(text:""),OriginalFrameworkText(text:"x",yesResult:0),
                   OriginalFrameworkText(text:"x",presentationOrder:[0,1])] {
        do { try program(prompt).validate() } catch { checks += 1;continue }
        throw EngineError.invalid("Original framework regression: invalid retry prompt facts were accepted")
    }
    // MAIN2028E..202D7 with the fixed32-object city array.
    let vm = try CampaignVM(program:program(nil))
    try vm.setCityFlags(chapter:0,flags:[3,3,3])
    try vm.applyCityAvailability(clearFirst:false,cities:[1,5,31])
    try check(vm.state.cityFlags == [3,2,3], "unconstructed city slots below0x20 do not change constructed cities")
    do { try vm.applyCityAvailability(clearFirst:false,cities:[32]);throw EngineError.invalid("null city object accepted") }
    catch EngineError.invalid(let message) where message.contains("null object") { checks += 1 }
    // MAIN1AAEE..1AAF3 person field2B construction.
    let tables = OriginalCombatTables(format:1,attackBase:Array(repeating:10,count:19),defenseBase:Array(repeating:10,count:19),
        troopBase:Array(repeating:10,count:19),troopGrowth:Array(repeating:0,count:19),physicalSubtypeByClass:Array(repeating:0,count:19),
        terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),
        items:(0..<64).map{OriginalItemEffect(id:$0,category:15,value:0)})
    let catalog = OriginalPersonCatalog(format:1,people:(0..<384).map{id in
        OriginalPersonDefinition(id:id,name:"p\(id)",classID:0,level:1,experience:0,rawTroops:10,defenseScalar:1,attackScalar:1,
            intellectScalar:1,personality:0,personalScalar:0,itemIDs:Array(repeating:255,count:8),sourceFlags:0,
            sourceRole:id == 1 ? 4 : id == 2 ? 255 : 0,sourceContext2:0,sourceContext3:0)
    })
    let people = try OriginalPeople(catalog:catalog,tables:tables)
    try check(try people.person(0).sourceRole == 2 && people.person(1).sourceRole == 6 && people.person(2).sourceRole == 1,
              "person field2B is state byte one plus two within its byte")
    try check(try catalog.person(1).sourceRole == 4, "catalog keeps the raw BAKDATA state byte")
    print("Original framework self-tests passed: \(checks)")
}
