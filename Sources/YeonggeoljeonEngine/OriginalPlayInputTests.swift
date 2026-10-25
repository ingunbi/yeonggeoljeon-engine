// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func originalPlayInputSelfTests() throws {
    var checks = 0
    func accepted(_ text: String) throws -> OriginalPlayInputs {
        try OriginalPlayInputs.decode(Data(text.utf8))
    }
    func rejected(_ text: String) throws {
        do { _ = try accepted(text) }
        catch { checks += 1; return }
        throw EngineError.invalid("Original play input regression: malformed input was accepted")
    }
    let valid = try accepted("""
    {"format":1,"seed":4,"fixedStepMicroseconds":10000,"inputs":[
      {"kind":"talk","person":3},{"kind":"choice","index":1},
      {"kind":"save-skip"},{"kind":"world-city","city":2},
      {"kind":"town-marker","marker":4},{"kind":"expect-battle"}]}
    """)
    guard valid.inputs.count == 6, valid.seed == 4 else { throw EngineError.invalid("Original play input lost caller order/seed") }
    checks += 1
    try rejected("{\"format\":1,\"inputs\":[{\"kind\":\"win-battle\"}]}")
    try rejected("{\"format\":1,\"inputs\":[{\"kind\":\"talk\"}]}")
    try rejected("{\"format\":1,\"inputs\":[{\"kind\":\"talk\",\"person\":3,\"city\":2}]}")
    try rejected("{\"format\":1,\"inputs\":[{\"kind\":\"talk\",\"person\":384}]}")
    try rejected("{\"format\":1,\"inputs\":[{\"kind\":\"choice\",\"index\":-1}]}")
    try rejected("{\"format\":1,\"inputs\":[{\"kind\":\"save-skip\",\"unknown\":true}]}")
    try rejected("{\"format\":1,\"fixedStepMicroseconds\":0,\"inputs\":[]}")
    try rejected("{\"format\":1,\"maximumTicksPerInput\":0,\"inputs\":[]}")
    let readerDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:readerDirectory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:readerDirectory)}
    let readerURL = readerDirectory.appendingPathComponent("synthetic-input.json"),smallInput = Data(#"{"format":1,"inputs":[]}"#.utf8)
    try smallInput.write(to:readerURL)
    guard try OriginalPlayInputs.readData(from:readerURL) == smallInput else {throw EngineError.invalid("Original play bounded reader changed caller bytes")};checks += 1
    let oversized = try FileHandle(forWritingTo:readerURL);try oversized.truncate(atOffset:UInt64(OriginalPlayInputs.maximumBytes+1));try oversized.close()
    var readerRejected = false
    do {_ = try OriginalPlayInputs.readData(from:readerURL)} catch EngineError.invalid {readerRejected = true}
    guard readerRejected else {throw EngineError.invalid("Original play reader loaded an oversized file before enforcing its input bound")};checks += 1
    let battle = try accepted("""
    {"format":1,"inputs":[{"kind":"battle-move","slot":0,"x":2,"y":3},
      {"kind":"battle-attack","slot":0,"target":16},
      {"kind":"battle-strategy","slot":1,"ability":35},
      {"kind":"battle-strategy","slot":2,"ability":0,"target":15},
      {"kind":"battle-wait","slot":2},{"kind":"battle-end-turn"}]}
    """)
    guard battle.inputs.map(\.kind) == [.battleMove,.battleAttack,.battleStrategy,.battleStrategy,.battleWait,.battleEndTurn],
          battle.inputs[0].x == 2,battle.inputs[1].target == 16,battle.inputs[2].target == nil,
          battle.inputs[3].ability == 0,battle.inputs[3].target == 15 else {
        throw EngineError.invalid("Original play battle inputs lost caller order, target omission or identity")
    };checks += 1
    for row in [
        #"{"kind":"battle-move","slot":0,"x":2}"#,
        #"{"kind":"battle-move","slot":0,"x":2,"y":3,"target":15}"#,
        #"{"kind":"battle-move","slot":45,"x":2,"y":3}"#,
        #"{"kind":"battle-move","slot":0,"x":-1,"y":3}"#,
        #"{"kind":"battle-move","slot":0,"x":2,"y":256}"#,
        #"{"kind":"battle-attack","slot":0}"#,
        #"{"kind":"battle-attack","slot":0,"target":45}"#,
        #"{"kind":"battle-strategy","slot":0,"ability":36}"#,
        #"{"kind":"battle-strategy","slot":0,"ability":1,"target":null}"#,
        #"{"kind":"battle-strategy","slot":0,"target":15}"#,
        #"{"kind":"battle-wait","slot":0,"ability":1}"#,
        #"{"kind":"battle-end-turn","slot":0}"#,
        #"{"kind":"battle-end-turn","result":1}"#,
        #"{"kind":"save-skip","person":null}"#,
        #"{"kind":"battle-teleport","slot":0,"x":2,"y":3}"#
    ] {try rejected("{\"format\":1,\"inputs\":[\(row)]}")}
    func primitive(_ row:String)throws->OriginalPlayInput {try accepted("{\"format\":1,\"inputs\":[\(row)]}").inputs[0]}
    func rejectedAction(_ action:()throws->Void)throws {
        do {try action()} catch BattleError.illegalAction {checks += 1;return}
        throw EngineError.invalid("Original play battle primitive bypassed a manual source gate")
    }
    let tables = OriginalCombatTables(format:1,attackBase:Array(repeating:10,count:19),defenseBase:Array(repeating:10,count:19),
        troopBase:Array(repeating:10,count:19),troopGrowth:Array(repeating:0,count:19),physicalSubtypeByClass:Array(repeating:0,count:19),
        terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),
        items:(0..<64).map{OriginalItemEffect(id:$0,category:15,value:0)})
    let catalog = OriginalPersonCatalog(format:1,people:(0..<384).map{id in
        OriginalPersonDefinition(id:id,name:"synthetic\(id)",classID:0,level:10,experience:0,rawTroops:1000,
            defenseScalar:100,attackScalar:100,intellectScalar:100,personality:0,personalScalar:0,itemIDs:Array(repeating:255,count:8),
            sourceFlags:id == 2 ? 1 : 0,sourceRole:0,sourceContext2:0,sourceContext3:0)
    })
    let cardinal = [OriginalAIOffset(dx:0,dy:-1),.init(dx:1,dy:0),.init(dx:0,dy:1),.init(dx:-1,dy:0)]
    var requirements = Array(repeating:Array(repeating:255,count:19),count:36);requirements[3][0] = 0
    var costs = Array(repeating:255,count:36);costs[3] = 2
    let movement = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),classMovementBudgets:Array(repeating:3,count:19),
        attackRangeCodes:Array(repeating:0,count:19),movementCosts:Array(repeating:Array(repeating:1,count:256),count:4),
        cardinalOffsets:cardinal,diagonalOffsets:cardinal,extendedOffsets:cardinal,setupOrderModes:Array(repeating:2,count:256),
        strategyLevelRequirements:requirements,strategyMPCosts:costs,strategyCategories:Array(repeating:0,count:36),
        strategyTerrainEligibility:Array(repeating:[0,253,254,255],count:3))
    func battleFlow()throws->OriginalBattleFlow {
        let people = try OriginalPeople(catalog:catalog,tables:tables)
        var roster = OriginalRoster();roster.header = OriginalBattleHeader(preserveFriendlySlots:false,turnLimit:3,sourceByte2:0,discardedBytes:[],objectives:[])
        for (index,entry) in [(0,0,1,1,0),(1,1,1,2,0),(2,2,3,1,1)].enumerated() {
            roster.slots[index] = OriginalPlacement(ordinal:index,person:entry.1,x:entry.2,y:entry.3,selector:0,flag:0,flags:entry.4,
                rawMode:0,parameter:0,classID:0,level:10)
        }
        return OriginalBattleFlow(session:try OriginalBattleSession(definition:BattleDefinition(id:"synthetic-driver",width:5,height:5,
            coordinateSystem:"orthogonal",tiles:Array(repeating:0,count:25)),roster:&roster,people:people,combat:tables,movement:movement,rng:OriginalRNG(state:9)))
    }
    let flow = try battleFlow(),move = try primitive(#"{"kind":"battle-move","slot":0,"x":2,"y":1}"#)
    try rejectedAction {try move.performBattle(in:flow,enabled:true)}
    try flow.start()
    let before = flow.session.units[0]!.position,seedBefore = flow.session.rng
    try rejectedAction {try move.performBattle(in:flow,enabled:false)}
    guard flow.session.units[0]!.position == before,flow.session.rng == seedBefore else {throw EngineError.invalid("Rejected play battle input mutated source position/RNG")};checks += 1
    try rejectedAction {try primitive(#"{"kind":"battle-move","slot":15,"x":4,"y":1}"#).performBattle(in:flow,enabled:true)}
    try move.performBattle(in:flow,enabled:true)
    try primitive(#"{"kind":"battle-attack","slot":0,"target":15}"#).performBattle(in:flow,enabled:true)
    guard flow.session.units[0]!.position == GridPoint(x:2,y:1),flow.session.units[0]!.scriptFlags&128 != 0,
          try flow.session.people.person(2).rawTroops < 1000 else {throw EngineError.invalid("Play move/attack did not use source route, damage and acted flag")};checks += 1
    try rejectedAction {try move.performBattle(in:flow,enabled:true)}
    try primitive(#"{"kind":"battle-wait","slot":1}"#).performBattle(in:flow,enabled:true)
    guard flow.session.units[1]!.scriptFlags&128 != 0 else {throw EngineError.invalid("Play wait bypassed source acted flag")};checks += 1
    let roundBefore = flow.session.turns.roundIndex
    try primitive(#"{"kind":"battle-end-turn"}"#).performBattle(in:flow,enabled:true)
    guard flow.session.turns.roundIndex == roundBefore+1,flow.acceptsManualInput else {throw EngineError.invalid("Play end-turn did not return through source native phases")};checks += 1
    let strategyFlow = try battleFlow();try strategyFlow.start()
    let mp = strategyFlow.session.units[0]!.mp
    try move.performBattle(in:strategyFlow,enabled:true)
    try primitive(#"{"kind":"battle-strategy","slot":0,"ability":3,"target":15}"#).performBattle(in:strategyFlow,enabled:true)
    guard strategyFlow.lastStrategy != nil,strategyFlow.session.units[0]!.mp < mp else {throw EngineError.invalid("Play strategy did not use source flow and MP mutation")};checks += 1
    print("Original play input self-tests: \(checks) assertions passed")
}
