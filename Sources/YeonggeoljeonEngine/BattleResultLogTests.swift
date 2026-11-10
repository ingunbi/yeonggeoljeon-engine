// SPDX-License-Identifier: GPL-3.0-only
import AppKit

func battleResultLogSelfTests() throws {
    var checks = 0
    func check(_ condition:@autoclosure() throws -> Bool,_ reason:String) throws {
        guard try condition() else { throw EngineError.invalid("Battle result log regression: \(reason)") };checks += 1
    }
    func rejected(_ body:() throws -> Void)->Bool { do { try body();return false } catch { return true } }
    let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
    func makeSession(environment:Int = 0) throws -> OriginalBattleSession {
        var table = OriginalCombatTables(format:1,attackBase:Array(repeating:10,count:19),
            defenseBase:Array(repeating:10,count:19),troopBase:Array(repeating:10,count:19),troopGrowth:Array(repeating:0,count:19),
            physicalSubtypeByClass:Array(repeating:0,count:19),terrainDefensePercent:Array(repeating:0,count:256),
            strategyEnvironmentLookup:Array(repeating:0,count:256),items:(0..<64).map{OriginalItemEffect(id:$0,category:15,value:0)})
        table.strategyEnvironmentLookup[1] = environment
        let people = try OriginalPeople(catalog:OriginalPersonCatalog(format:1,people:(0..<384).map{id in
            OriginalPersonDefinition(id:id,name:"synthetic \(id)",classID:0,level:10,experience:0,rawTroops:1000,
                defenseScalar:100,attackScalar:100,intellectScalar:id == 0 ? 100 : 0,personality:0,personalScalar:0,
                itemIDs:Array(repeating:255,count:8),sourceFlags:id == 0 ? 0 : 1,sourceRole:0,sourceContext2:0,sourceContext3:0)
        }),tables:table)
        let cardinal = [OriginalAIOffset(dx:0,dy:-1),OriginalAIOffset(dx:1,dy:0),OriginalAIOffset(dx:0,dy:1),OriginalAIOffset(dx:-1,dy:0)]
        let diagonal = [OriginalAIOffset(dx:-1,dy:-1),OriginalAIOffset(dx:1,dy:-1),OriginalAIOffset(dx:1,dy:1),OriginalAIOffset(dx:-1,dy:1)]
        var categories = Array(repeating:0,count:36);for id in 30..<36 {categories[id] = 3}
        let movement = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),
            classMovementBudgets:Array(repeating:3,count:19),attackRangeCodes:Array(repeating:0,count:19),
            movementCosts:Array(repeating:Array(repeating:1,count:256),count:4),cardinalOffsets:cardinal,
            diagonalOffsets:diagonal,extendedOffsets:cardinal,setupOrderModes:Array(repeating:2,count:256),
            strategyLevelRequirements:Array(repeating:Array(repeating:0,count:19),count:36),
            strategyMPCosts:Array(repeating:1,count:36),strategyCategories:categories,
            strategyTerrainEligibility:Array(repeating:[0,1,255,255],count:3))
        var roster = OriginalRoster();roster.header = OriginalBattleHeader(preserveFriendlySlots:false,turnLimit:10,sourceByte2:0,discardedBytes:[],objectives:[])
        let coordinates = [(1,1),(1,0),(2,1),(2,0),(3,1),(2,2)]
        for (id,coordinate) in coordinates.enumerated() {
            roster.slots[id] = OriginalPlacement(ordinal:id,person:id,x:coordinate.0,y:coordinate.1,selector:0,flag:0,
                flags:id >= 2 ? 1 : 0,rawMode:0,parameter:0,classID:0,level:10)
        }
        return try OriginalBattleSession(definition:BattleDefinition(id:"synthetic-result-log",width:5,height:5,tiles:Array(repeating:0,count:25)),
            roster:&roster,people:people,combat:table,movement:movement,rng:OriginalRNG(state:2))
    }
    var bounded = BattleResultLog()
    for i in 0..<505 { bounded.append(round:i,actorPerson:0,actorEnemy:false,targetPerson:1,action:.attack(counter:false),result:.init(damage:i)) }
    try bounded.validate()
    try check(bounded.entries.count == 500 && bounded.discarded == 5 && bounded.entries.first?.sequence == 5 && bounded.entries.last?.sequence == 504,"recent results are bounded while retaining stable order")
    try check(try JSONDecoder().decode(BattleResultLog.self,from:encoder.encode(bounded)) == bounded,"bounded journal survives a Codable round trip")
    var invalid = BattleResultLog();invalid.append(round:0,actorPerson:0,actorEnemy:false,targetPerson:1,action:.strategy(99),result:.init())
    try check(rejected { try invalid.validate() },"corrupt action IDs are rejected before UI name lookup")

    let attack = try makeSession()
    var operation = try OriginalAttackOperation.begin(in:attack,attackerSlot:0,targetSlot:15)
    var exchange:OriginalStrikeExchange?
    for _ in 0..<20 {
        switch try operation.advance(in:attack) {
        case .context:break
        case .retirement(let notice):try operation.resumeRetirement(notice)
        case .finished(let result):exchange = result
        }
        if exchange != nil { break }
    }
    guard let exchange else { throw EngineError.invalid("Journal fixture attack did not complete") }
    let blows = attack.resultLog.entries.filter { if case .attack = $0.action { return true };return false }
    try check(blows.count == (exchange.counter == nil ? 1 : 2) && blows.first?.result.damage == exchange.strike.damage,"attack and any actual counter are logged at commit with exact damage")
    if let counter = exchange.counter { try check(blows.last?.action == .attack(counter:true) && blows.last?.result.damage == counter.damage,"counter has its own action and result") }
    let finishedLog = attack.resultLog
    _ = try operation.advance(in:attack);_ = try operation.advance(in:attack)
    try check(attack.resultLog == finishedLog,"re-reading a completed operation cannot duplicate results")

    let splash = try makeSession()
    let cast = try splash.castStrategy(0,abilityID:3,target:15)
    try check(splash.resultLog.entries.count == cast.targets.count && splash.resultLog.entries.map(\.targetPerson) == cast.targets.map { Optional($0.person) },"each committed area target is recorded once in execution order")
    try check(splash.resultLog.entries.map { $0.result.damage } == cast.targets.map { $0.damage?.damage },"area damage uses actual producer quantities")
    let continued = try makeSession()
    var partial = try OriginalStrategyOperation.begin(in:continued,casterSlot:0,abilityID:3,target:15)
    _ = try partial.advance(in:continued)
    try check(continued.resultLog.entries.count == 1,"the first effect is retained before an operation checkpoint")
    var resumed = try JSONDecoder().decode(OriginalStrategyOperation.self,from:encoder.encode(partial))
    for _ in 0..<20 {
        switch try resumed.advance(in:continued) {
        case .target:break
        case .retirement(let notice):try resumed.resumeRetirement(notice)
        case .finished:break
        }
        if resumed.execution != nil { break }
    }
    try check(continued.resultLog.entries.count == resumed.execution?.targets.count && continued.resultLog.entries.map(\.targetPerson) == splash.resultLog.entries.map(\.targetPerson),"resuming an operation preserves earlier results and appends remaining targets exactly once")
    let lethal = try makeSession();try lethal.people.update(2) { $0.rawTroops = 1 }
    let killed = try lethal.castStrategy(0,abilityID:0,target:15)
    try check(killed.targets.first?.retiredPerson != nil && lethal.resultLog.entries.first?.result.retired == true,"actual target retirement is retained with its committed strategy result")
    let weather = try makeSession(environment:2)
    _ = try weather.castStrategy(0,abilityID:0,target:15)
    try check(weather.resultLog.entries.isEmpty,"preflight refusals are not invented as executed results")
    let failure = try makeSession();try failure.people.update(0) { $0.intellectScalar = 0 };try failure.people.update(2) { $0.intellectScalar = 100 }
    let miss = try failure.castStrategy(0,abilityID:15,target:15)
    try check(miss.targets.first?.success?.success == false && failure.resultLog.entries.first?.result.success == false && failure.resultLog.entries.first?.result.confused == false,"failed confusion is recorded as failure without falsely claiming confusion")
    let morale = try makeSession(),moraleBefore = 100
    let lowered = try morale.castStrategy(0,abilityID:18,target:15)
    try check(lowered.targets.first?.moraleChange == morale.units[15]!.morale-moraleBefore && morale.resultLog.entries.first?.result.moraleChange == -20,"pure morale strategies retain the actual signed decrease as well as remaining morale")
    let heal = try makeSession();heal.units[0]!.morale = 30;heal.units[1]!.morale = 40
    let recovery = try heal.castStrategy(0,abilityID:30)
    try check(heal.resultLog.entries.count == recovery.targets.count && heal.resultLog.entries.map { $0.result.moraleChange } == recovery.targets.map { $0.healing?.moraleDelta },"area recovery records each actual recovery quantity")
    let overcap = try makeSession();try overcap.people.update(0) { $0.rawTroops = 1500 }
    let capped = try overcap.castStrategy(0,abilityID:24,target:0)
    try overcap.resultLog.validate()
    let cappedLog = try JSONDecoder().decode(BattleResultLog.self,from:encoder.encode(overcap.resultLog))
    try cappedLog.validate()
    try check(capped.targets.first?.healing?.troopsDelta == -500 && cappedLog.entries.first?.result.troopsRecovered == -500,
              "source over-cap healing remains a valid signed result across save encoding")
    let cappedSheet = BattleResultLogSheet.sheet(cappedLog,personName:{ "장수\($0)" },strategyName:{ "책략\($0)" },itemName:{ "도구\($0)" },className:{ "병과\($0)" }) { _ in }
    try check(cappedSheet.rows[0].value == "조정 -500" && cappedSheet.rows[0].detail?.facts.contains(where:{$0.label == "병력 조정" && $0.value == "-500"}) == true,
              "a negative source healing adjustment is not described as gained troops")
    let item = try makeSession();try item.people.update(0) { $0.itemIDs[0] = 0x1E;$0.rawTroops = 500 }
    var itemOperation = try OriginalItemOperation.begin(in:item,userSlot:0,item:0x1E,target:0)
    for _ in 0..<10 {
        switch try itemOperation.advance(in:item) {
        case .target:break
        case .retirement(let notice):try itemOperation.resumeRetirement(notice)
        case .finished:break
        }
        if itemOperation.execution != nil { break }
    }
    try check(itemOperation.execution?.completed == true && item.resultLog.entries.count == 1 && item.resultLog.entries[0].action == .item(0x1E),"consumed recovery item has one committed target result")
    let itemLog = item.resultLog;_ = try itemOperation.advance(in:item)
    try check(item.resultLog == itemLog,"re-reading a completed item cannot duplicate results")

    let saved = try JSONDecoder().decode(OriginalBattleSuspension.self,from:encoder.encode(splash.suspensionState()))
    try check(saved.resultLog == splash.resultLog,"suspension carries the journal with exact entry identities")
    var old = try JSONSerialization.jsonObject(with:encoder.encode(saved)) as! [String:Any];old.removeValue(forKey:"resultLog")
    let legacy = try JSONDecoder().decode(OriginalBattleSuspension.self,from:JSONSerialization.data(withJSONObject:old))
    try check(legacy.resultLog == nil,"older suspensions without a journal remain decodable")
    let beforeUnits = splash.units,beforeTurns = splash.turns,beforeRNG = splash.rng,beforePeople = try encoder.encode(splash.people.values)
    var choices:[Int?] = []
    let sheet = BattleResultLogSheet.sheet(splash.resultLog,personName:{ "장수\($0)" },strategyName:{ "책략\($0)" },itemName:{ "도구\($0)" },className:{ "병과\($0)" }) { choices.append($0) }
    sheet.onChoose(0);sheet.onChoose(nil)
    try check(sheet.rows.count == splash.resultLog.entries.count && sheet.rows[0].detail?.heading.contains("장수") == true && choices.count == 2,"journal rows have readable identities and return controls")
    try check(splash.units == beforeUnits && splash.turns == beforeTurns && splash.rng == beforeRNG && (try encoder.encode(splash.people.values)) == beforePeople,"reading and closing the journal changes no game state or RNG")
    let empty = BattleResultLogSheet.sheet(BattleResultLog(),personName:{ _ in "" },strategyName:{ _ in "" },itemName:{ _ in "" },className:{ _ in "" }) { _ in }
    try check(empty.rows.count == 1 && empty.rows[0].label == "아직 기록 없음","empty journal explains when records become available")
    let long = BattleResultLogSheet.sheet(bounded,selected:499,personName:{ "장수\($0)" },strategyName:{ "책략\($0)" },itemName:{ "도구\($0)" },className:{ "병과\($0)" }) { _ in }
    let overlay = CanvasOverlayView(frame:CGRect(x:0,y:0,width:640,height:400));overlay.show(long)
    try check(overlay.sheetRowRect(499).map { overlay.bounds.contains($0) } == true,"the oldest retained record remains reachable at the end of the scrollable list")
    print("Battle result log self-tests passed: \(checks)")
}
