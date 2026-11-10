// SPDX-License-Identifier: GPL-3.0-only
import AppKit

func promotionPreviewSelfTests() throws {
    var checks = 0
    func check(_ condition:@autoclosure() throws -> Bool,_ message:String) throws {
        guard try condition() else {throw EngineError.invalid("Promotion preview regression: \(message)")};checks += 1
    }
    func rejects(_ operation:() throws -> Void)->Bool {do {try operation();return false} catch {return true}}
    let classes = (0..<19).map{"병과 \($0)"},strategies = (0..<36).map{"책략 \($0)"},terrain = ["평지","숲","산지"]
    func fixture(item:Int = 0x13,classID:Int = 0,level:Int = 20) throws -> OriginalBattleSession {
        var bases = Array(repeating:10,count:19);bases[1] = 15;bases[15] = 1
        var growth = Array(repeating:10,count:19);growth[1] = 15;growth[15] = 0
        let items = (0..<64).map { id in OriginalItemEffect(id:id,category:id == 4 ? 0 : id == 5 ? 5 : id == 6 ? 4 : 15,
            value:id == 4 ? 20 : id == 5 ? 30 : id == 6 ? 2 : 0,name:"도구 \(id)") }
        let combat = OriginalCombatTables(format:1,attackBase:(0..<19).map{$0+10},defenseBase:(0..<19).map{$0+12},
            troopBase:bases,troopGrowth:growth,physicalSubtypeByClass:Array(repeating:0,count:19),
            terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),items:items)
        let catalog = OriginalPersonCatalog(format:1,people:(0..<384).map { id in
            OriginalPersonDefinition(id:id,name:"검증 장수 \(id)",classID:id == 1 ? classID : 0,level:id == 1 ? level : 10,
                experience:13,rawTroops:1000,defenseScalar:60,attackScalar:70,intellectScalar:50,personality:0,personalScalar:0,
                itemIDs:id == 1 ? [item,4,5,6,255,255,255,255] : Array(repeating:255,count:8),sourceFlags:0,sourceRole:0,sourceContext2:0,sourceContext3:0)
        })
        let cardinal = [OriginalAIOffset(dx:0,dy:-1),.init(dx:1,dy:0),.init(dx:0,dy:1),.init(dx:-1,dy:0)]
        let diagonal = [OriginalAIOffset(dx:-1,dy:-1),.init(dx:1,dy:-1),.init(dx:1,dy:1),.init(dx:-1,dy:1)]
        var movementTypes = Array(repeating:0,count:19);movementTypes[1] = 1;movementTypes[15] = 2
        var movementPoints = Array(repeating:4,count:19);movementPoints[1] = 5
        var ranges = Array(repeating:0,count:19);ranges[1] = 1
        var costs = Array(repeating:Array(repeating:1,count:256),count:4);costs[0][2] = 255;costs[1][1] = 2
        var levels = Array(repeating:Array(repeating:255,count:19),count:36)
        levels[0][0] = 5;levels[0][1] = 6;levels[1][0] = 3;levels[2][1] = 30
        let movement = OriginalMovementProfile(format:1,classMovementTypes:movementTypes,classMovementBudgets:movementPoints,
            attackRangeCodes:ranges,movementCosts:costs,cardinalOffsets:cardinal,diagonalOffsets:diagonal,extendedOffsets:cardinal,
            strategyLevelRequirements:levels,strategyMPCosts:Array(repeating:4,count:36),strategyCategories:Array(repeating:0,count:36))
        var roster = OriginalRoster();roster.header = OriginalBattleHeader(preserveFriendlySlots:false,turnLimit:10,sourceByte2:0,discardedBytes:[],objectives:[])
        roster.slots[0] = OriginalPlacement(ordinal:0,person:1,x:2,y:2,selector:0,flag:0,flags:0,rawMode:0,parameter:0,classID:classID,level:level)
        let session = try OriginalBattleSession(definition:BattleDefinition(id:"promotion-preview-synthetic",width:5,height:5,tiles:Array(repeating:0,count:25)),
            roster:&roster,people:OriginalPeople(catalog:catalog,tables:combat),combat:combat,movement:movement,rng:OriginalRNG(state:7))
        // Source battle setup fills friendly HP. Apply this synthetic wound
        // after setup so the no-healing/clamping cases start at 1,000 troops.
        try session.people.update(1) { $0.rawTroops = 1000 }
        session.units[0]!.morale = 73
        return session
    }
    func preview(_ session:OriginalBattleSession,item:Int) throws -> PromotionPreview.Comparison {
        try PromotionPreview.build(person:session.people.person(1),morale:session.live(0).morale,item:item,combat:session.combat,
            movement:session.movement,classNames:classes,strategyNames:strategies,terrainNames:terrain)
    }
    func use(_ session:OriginalBattleSession,item:Int) throws {
        var operation = try OriginalItemOperation.begin(in:session,userSlot:0,item:item)
        for _ in 0..<8 {
            if case .finished(let result) = try operation.advance(in:session) {
                guard result.completed else {throw EngineError.invalid("Synthetic promotion was refused")};return
            }
        }
        throw EngineError.invalid("Synthetic promotion did not finish")
    }
    let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
    let session = try fixture(),beforePerson = try encoder.encode(session.people.person(1)),beforeState = try encoder.encode(session.suspensionState())
    let expected = try preview(session,item:0x13)
    try check(expected.before.classID == 0 && expected.after.classID == 1,"promotion selects the next source tier")
    try check(expected.before.attack < expected.after.attack && expected.before.defense < expected.after.defense,"same-level attack and defense reflect the different class bases")
    try check(expected.before.movement == 6 && expected.after.movement == 7,"the same movement equipment bonus is retained")
    try check(expected.before.maximumMP == expected.after.maximumMP,"class changes alone do not change the source intellect/level MP cap")
    try check(expected.before.troops == expected.after.troops && expected.after.maximumTroops > expected.before.maximumTroops,"a higher cap does not promise free healing")
    try check(expected.before.attackOffsets.count == 4 && expected.after.attackOffsets.count == 8,"normal attack uses the exact source range enumerator")
    try check(expected.terrainChanges.contains(.init(name:"산지",before:255,after:1)) && expected.terrainChanges.contains(.init(name:"숲",before:1,after:2)),"passability and terrain cost changes are both surfaced")
    try check(expected.strategyChanges == [.init(abilityID:0,name:"책략 0",beforeLevel:5,afterLevel:6),
        .init(abilityID:1,name:"책략 1",beforeLevel:3,afterLevel:nil),.init(abilityID:2,name:"책략 2",beforeLevel:nil,afterLevel:30)],
        "changed learning levels, lost access and future new strategies remain distinct")
    var chosen:[Int?] = [],buttons:[Int] = []
    let sheet = PromotionPreview.sheet(expected,onChoose:{chosen.append($0)},onButton:{buttons.append($0)})
    sheet.onChoose(0);sheet.onChoose(nil);sheet.onButton?(1)
    try check(chosen.count == 2 && chosen[0] == 0 && chosen[1] == nil && buttons == [1],"browsing and cancelling have separate callbacks from confirming")
    try check(sheet.fullCanvas && sheet.buttons == ["전직","취소"] && sheet.rows.contains(where:{$0.label == "책략 2" && $0.detail?.body.contains("10레벨 남음") == true}),"confirmation stays available while future learning changes can be inspected")
    try check(try encoder.encode(session.people.person(1)) == beforePerson && encoder.encode(session.suspensionState()) == beforeState,"building, browsing and cancelling leave character, item, action, turn and RNG untouched")
    try use(session,item:0x13)
    let actual = try session.people.stats(1,morale:session.live(0).morale)
    try check(try OriginalCombat.attackStat(actual,tables:session.combat) == expected.after.attack && OriginalCombat.defenseStat(actual,tables:session.combat) == expected.after.defense,"the executed promotion matches the previewed equipped attack and defense")
    try check(try OriginalCombat.maxTroops(classID:actual.classID,level:actual.level,tables:session.combat) == expected.after.maximumTroops && OriginalCombat.maxMP(stats:actual) == expected.after.maximumMP,"executed maximum troops and MP match the forecast")
    try check(try Int(session.movementBudget(0)) == expected.after.movement && session.people.person(1).rawTroops == expected.after.troops,"executed movement and current troops match the forecast")
    try check(!actual.itemIDs.contains(0x13) && session.units[0]!.scriptFlags&0x80 != 0,"only the real confirmation consumes the tool and action")
    let change = try fixture(item:0),lower = try preview(change,item:0)
    try check(lower.after.classID == 15 && lower.after.troops == 100 && lower.before.troops == 1000,"cross-family class change forecasts source troop clamping")
    try use(change,item:0)
    try check(try change.people.person(1).rawTroops == lower.after.troops,"the real class-change clamp agrees with the preview")
    let low = try fixture(level:14)
    try check(rejects {_ = try preview(low,item:0x13)},"an ineligible promotion level is never presented as usable")
    try check(rejects {_ = try preview(session,item:0x13)},"a consumed or absent tool cannot produce a new preview")
    try check(PromotionPreview.rangeText([]) == "일반 공격 없음" && PromotionPreview.rangeText(expected.before.attackOffsets) == "상하좌우 1칸","empty and close attack patterns are described explicitly")
    print("Promotion preview self-tests passed: \(checks)")
}
