// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Synthetic checks for the battle screen's scroll, list and gauge rules.
func originalBattleScreenSelfTests() throws {
    var checks = 0
    func check(_ condition:Bool,_ message:String) throws {
        guard condition else { throw EngineError.invalid("Original battle screen regression: \(message)") }
        checks += 1
    }
    // The canvas fits the window and centres; a click maps back through the same numbers.
    let sideBands = CanvasGeometry(bounds:CGRect(x:0,y:0,width:1200,height:600))
    try check(sideBands.scale == 1.5 && sideBands.origin == CGPoint(x:120,y:0),"a wide window bands the sides")
    let endBands = CanvasGeometry(bounds:CGRect(x:0,y:0,width:640,height:600))
    try check(endBands.scale == 1 && endBands.origin == CGPoint(x:0,y:100),"a tall window bands the top and bottom")
    try check(sideBands.canvas(CGPoint(x:270,y:150)) == CGPoint(x:100,y:100),"a view point maps to its canvas point")
    let layout = OriginalBattleLayout.source
    try check(layout.columns == 13 && layout.rows == 11,"the map window shows thirteen by eleven cells")
    // MAIN2898C..289C5 centres in eight-pixel steps.
    try check(layout.minimapOrigin(width:28,height:16) == CGPoint(x:480,y:296),"a smaller map is centred in the panel")
    try check(layout.minimapOrigin(width:40,height:24) == CGPoint(x:456,y:280),"the largest map starts at the panel base")
    try check(layout.minimapOrigin(width:29,height:15) == CGPoint(x:472,y:296),"centring rounds down to eight pixels")

    var camera = OriginalBattleCamera(width:28,height:16)
    camera.center(on:GridPoint(x:0,y:0))
    try check(camera.x == 0 && camera.y == 0,"centring near the corner clamps at zero")
    camera.center(on:GridPoint(x:27,y:15))
    try check(camera.x == 30 && camera.y == 10,"centring near the far corner clamps to the last window")
    camera.center(halfX:29,halfY:17)
    try check(camera.x == 16 && camera.y == 6,"half-cell input stays aligned to whole cells")
    camera.move(columns:-100,rows:100)
    try check(camera.x == 0 && camera.y == 10,"manual scrolling stays inside the map")

    var small = OriginalBattleCamera(width:16,height:11)
    small.center(on:GridPoint(x:15,y:10))
    try check(small.y == 0 && small.x == 6,"a map as tall as the window never scrolls vertically")

    var follow = OriginalBattleCamera(width:28,height:16)
    follow.center(on:GridPoint(x:14,y:8))
    let centred = follow
    follow.follow(GridPoint(x:15,y:9),margin:layout.followMargin)
    try check(follow == centred,"a unit within the margin does not scroll the map")
    follow.follow(GridPoint(x:17,y:8),margin:layout.followMargin)
    try check(follow.x == centred.x+6,"a unit at the margin recentres the map")
    follow.follow(GridPoint(x:1,y:1),margin:layout.followMargin)
    try check(follow.x == 0 && follow.y == 0,"a unit near the edge scrolls to the edge")
    follow.follow(GridPoint(x:27,y:15),margin:layout.followMargin)
    try check(follow.x == 30 && follow.y == 10,"the far edge clamps to the last window")

    var hit = OriginalBattleCamera(width:28,height:16)
    hit.center(on:GridPoint(x:14,y:8))
    let viewport = layout.viewportRect
    let box = hit.rect(of:GridPoint(x:14,y:8),in:viewport,size:32)
    let expectedX:Int = 16+(14-hit.x/2)*32,expectedY:Int = 32+(8-hit.y/2)*32
    try check(Int(box.minX) == expectedX && Int(box.minY) == expectedY,"a cell maps to scrolled canvas pixels")
    try check(hit.cell(at:CGPoint(x:box.midX,y:box.midY),in:viewport,size:32) == GridPoint(x:14,y:8),"a canvas point maps back to its cell")
    try check(hit.cell(at:CGPoint(x:8,y:100),in:viewport,size:32) == nil,"a click outside the window is not a cell")
    var edge = OriginalBattleCamera(width:16,height:11)
    edge.center(on:GridPoint(x:0,y:0))
    try check(edge.cell(at:CGPoint(x:17,y:33),in:viewport,size:32) == GridPoint(x:0,y:0),"the first pixel is cell zero")

    func unit(_ slot:Int,status:Int = 2,flags:UInt8 = 0x20,mode:UInt8 = 0) -> OriginalLiveUnit {
        OriginalLiveUnit(slot:slot,person:slot,position:GridPoint(x:0,y:0),status:status,scriptFlags:flags,orderMode:mode,mp:0)
    }
    let units = [0:unit(0),1:unit(1,status:3),2:unit(2),3:unit(3),15:unit(15),16:unit(16),17:unit(17,status:4),18:unit(18,status:1)]
    let force:(OriginalLiveUnit) -> Int = { $0.slot == 2 || $0.slot == 15 ? 0 : 4 }
    try check(OriginalBattleRoster.rows(side:0,units:units,force:force) == [2,0,3,1],"own force lists first, retired units last")
    try check(OriginalBattleRoster.rows(side:1,units:units,force:force) == [16,17],"the enemy list drops live force zero and unfielded units")
    try check(OriginalBattleRoster.nameColor(unit(0,mode:7)) == 7 && OriginalBattleRoster.nameColor(unit(0,flags:0xA0,mode:7)) == 5,"a player unit dims after it acts")
    try check(OriginalBattleRoster.nameColor(unit(1,mode:1)) == 6,"an allied AI unit has its own colour")
    try check(OriginalBattleRoster.nameColor(unit(15)) == 15,"an enemy name is white")
    try check(OriginalBattleRoster.nameColor(unit(0,flags:0x22,mode:7)) == 3 && OriginalBattleRoster.nameColor(unit(0,status:3)) == 2,"state colours outrank side colours")
    try check(OriginalBattleRoster.markColor(unit(0)) == 2 && OriginalBattleRoster.markColor(unit(15)) == 1,"minimap marks separate the sides")

    try check(OriginalBattleGauge(current:500,maximum:500,width:88) == OriginalBattleGauge(current:700,maximum:700,width:88),"a full bar is independent of troop scale")
    let full = OriginalBattleGauge(current:500,maximum:500,width:88)
    try check(full.fill == 88 && full.tile == "high","a full gauge is high")
    let seven = OriginalBattleGauge(current:70,maximum:100,width:88)
    try check(seven.fill == 61 && seven.tile == "high","seven tenths is still high")
    let middle = OriginalBattleGauge(current:69,maximum:100,width:88)
    try check(middle.tile == "middle","below seven tenths is middle")
    try check(OriginalBattleGauge(current:30,maximum:100,width:88).tile == "middle","three tenths is middle")
    try check(OriginalBattleGauge(current:29,maximum:100,width:88).tile == "low","below three tenths is low")
    let none = OriginalBattleGauge(current:5,maximum:0,width:88)
    try check(none.fill == 0 && none.tile == "low","a zero maximum draws an empty low gauge")
    try check(OriginalBattleGauge(current:900,maximum:100,width:88).fill == 88,"an overfull value stays inside the bar")

    // MAIN30EF1..30F4E refusals come in source order.
    try check(OriginalBattleCommand.denial(unit(15,mode:7)) == "notOurs","an enemy unit is refused first")
    try check(OriginalBattleCommand.denial(unit(1,mode:1)) == "cannotControl","an allied AI unit cannot be ordered")
    try check(OriginalBattleCommand.denial(unit(1,flags:0x24,mode:7)) == "cannotControl","mask four blocks orders")
    try check(OriginalBattleCommand.denial(unit(1,flags:0x22,mode:7)) == "confused","confusion is reported before acted")
    try check(OriginalBattleCommand.denial(unit(1,flags:0xA2,mode:7)) == "confused","confusion outranks the acted flag")
    try check(OriginalBattleCommand.denial(unit(1,flags:0xA0,mode:7)) == "finished","an acted unit is finished")
    try check(OriginalBattleCommand.denial(unit(1,mode:7)) == nil,"a ready player unit opens commands")

    // MAIN2AA26..2AAC4 window placement.
    let corner = OriginalBattleCamera(width:28,height:16)
    let first = OriginalBattleCommand.window(cell:GridPoint(x:0,y:0),camera:corner)
    try check(first.origin == CGPoint(x:48,y:32) && first.step == CGPoint(x:16,y:16),"the window opens one cell right of the unit")
    let right = OriginalBattleCommand.window(cell:GridPoint(x:5,y:0),camera:corner)
    try check(right.origin.x == 208 && right.step.x == 16,"the last column that stays right of the unit")
    let flipped = OriginalBattleCommand.window(cell:GridPoint(x:6,y:0),camera:corner)
    try check(flipped.origin.x == 80 && flipped.step.x == -16,"past column 224 the window moves left by 160")
    let upper = OriginalBattleCommand.window(cell:GridPoint(x:0,y:7),camera:corner)
    try check(upper.origin.y == 256 && upper.step.y == 16,"the last row that keeps its height")
    let lower = OriginalBattleCommand.window(cell:GridPoint(x:0,y:10),camera:corner)
    try check(lower.origin.y == 272 && lower.step.y == -16,"lower rows stop at 272 and step upward")
    var scrolled = OriginalBattleCamera(width:28,height:16)
    scrolled.center(on:GridPoint(x:14,y:8))
    let shifted = OriginalBattleCommand.window(cell:GridPoint(x:scrolled.x/2,y:scrolled.y/2),camera:scrolled)
    try check(shifted.origin == CGPoint(x:48,y:32),"placement follows the scrolled window")

    // MAIN2DC83..2DD10 strategy rows.
    var levels = Array(repeating:Array(repeating:99,count:19),count:36)
    levels[0][2] = 1;levels[6][2] = 5;levels[7][2] = 6
    var costs = Array(repeating:4,count:36)
    costs[6] = 9
    let rows = OriginalBattleCommand.strategyRows(classID:2,level:5,mp:8,rain:false,levels:levels,costs:costs)
    try check(rows.map(\.ability) == [0,6],"the level gate decides which rows exist")
    try check(rows.map(\.enabled) == [true,false],"a row the unit cannot pay for stays listed and disabled")
    let wet = OriginalBattleCommand.strategyRows(classID:2,level:6,mp:20,rain:true,levels:levels,costs:costs)
    try check(wet.map(\.enabled) == [false,true,true],"rain disables only the five fire rows")
    try check(OriginalBattleCommand.strategyRows(classID:17,level:99,mp:99,rain:false,levels:levels,costs:costs).isEmpty,"class 17 has no strategy list")

    // MAIN2DF95..2E05C inventory moves.
    let tables = OriginalCombatTables(format:1,attackBase:Array(repeating:10,count:19),defenseBase:Array(repeating:10,count:19),
        troopBase:Array(repeating:10,count:19),troopGrowth:Array(repeating:0,count:19),physicalSubtypeByClass:Array(repeating:0,count:19),
        terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),
        items:(0..<64).map{OriginalItemEffect(id:$0,category:15,value:0)})
    let catalog = OriginalPersonCatalog(format:1,people:(0..<384).map{id in
        OriginalPersonDefinition(id:id,name:"p\(id)",classID:0,level:1,experience:0,rawTroops:10,defenseScalar:1,attackScalar:1,
            intellectScalar:1,personality:0,personalScalar:0,itemIDs:id == 2 ? Array(1...8) : [7,9,7,255,255,255,255,255],sourceFlags:0,
            sourceRole:0,sourceContext2:0,sourceContext3:0)
    })
    let people = try OriginalPeople(catalog:catalog,tables:tables)
    try people.discardItem(person:0,item:7)
    try check(try people.person(0).itemIDs == [255,9,7,255,255,255,255,255],"a discard clears the first matching slot and leaves a hole")
    try check(try people.giveItem(from:0,to:1,item:9),"a free receiver accepts the gift")
    let giver = try people.person(0).itemIDs,receiver = try people.person(1).itemIDs
    try check(giver == [255,255,7,255,255,255,255,255] && receiver[3] == 9,"the receiver fills its first empty slot")
    try check(try !people.giveItem(from:0,to:2,item:7),"a full receiver refuses")
    try check(try people.person(0).itemIDs.contains(7),"a refused gift keeps the item")

    // MAIN1610..161B2 line filling and the window's two text rows.
    let conditions = layout.conditions
    let rowsAvailable = (conditions.lineEnd-conditions.textY)/conditions.lineStep
    try check(rowsAvailable == 2,"the window fits two text rows above row 216")
    try check(OriginalBattleConditions.lines("short",width:34,count:2) == ["short"],"a short text keeps one line")
    let wide = String(repeating:"\u{AC00}",count:18)
    let wrapped = OriginalBattleConditions.lines(wide,width:34,count:2)
    try check(wrapped.map(\.count) == [17,1],"a double-byte run breaks at width without splitting")
    let narrow = OriginalBattleConditions.lines(String(repeating:"a",count:36),width:34,count:2)
    try check(narrow.map(\.count) == [35,1],"the single-byte test allows one column past the width")
    try check(OriginalBattleConditions.lines("a\nb\nc",width:34,count:2) == ["a","b"],"line feeds break and a third row is dropped")
    try check(OriginalBattleConditions.lines("a\r\nb",width:34,count:2) == ["a","b"],"carriage returns do not add rows")
    try check(OriginalBattleConditions.lines("",width:34,count:2).isEmpty,"an empty objective has no rows")
    try check(OriginalBattleConditions.numbered("T  %2u/%2u",[3,30]) == "T   3/30","the width pads numbers")
    try check(OriginalBattleConditions.numbered("L  %2w",[9]) == "L   9","%w formats like %u")
    try check(OriginalBattleConditions.numbered("%2u",[120]) == "120","a wider number is not cut")
    try check(OriginalBattleConditions.title("%s-%s",chapter:"a",name:"b") == "a-b","the title takes chapter then name")

    // MAIN2A6A0..2A8C3 terrain window.
    let flat = OriginalBattleCamera(width:28,height:16)
    try check(OriginalBattleTerrain.windowOrigin(cell:GridPoint(x:0,y:0),camera:flat) == CGPoint(x:48,y:32),"the window opens two units right of the cell")
    try check(OriginalBattleTerrain.windowOrigin(cell:GridPoint(x:6,y:0),camera:flat) == CGPoint(x:240,y:32),"column 13 still opens to the right")
    try check(OriginalBattleTerrain.windowOrigin(cell:GridPoint(x:7,y:0),camera:flat) == CGPoint(x:112,y:32),"column 15 opens to the left")
    try check(OriginalBattleTerrain.windowOrigin(cell:GridPoint(x:0,y:4),camera:flat) == CGPoint(x:48,y:160),"row 10 keeps its height")
    try check(OriginalBattleTerrain.windowOrigin(cell:GridPoint(x:0,y:5),camera:flat) == CGPoint(x:48,y:144),"row 12 moves up three units")
    var moved = OriginalBattleCamera(width:28,height:16)
    moved.center(on:GridPoint(x:14,y:8))
    let same = OriginalBattleTerrain.windowOrigin(cell:GridPoint(x:moved.x/2,y:moved.y/2),camera:moved)
    try check(same == CGPoint(x:48,y:32),"placement follows the scrolled window")
    try check(OriginalBattleTerrain.defenseText(20,none:"x",percent:"%") == "20%" && OriginalBattleTerrain.defenseText(255,none:"x",percent:"%") == "x%","a 255 entry prints the fallback")
    try check(OriginalBattleTerrain.recovers(terrain:8) && OriginalBattleTerrain.recovers(terrain:13) && OriginalBattleTerrain.recovers(terrain:14) && !OriginalBattleTerrain.recovers(terrain:7),"three terrains recover")
    print("Original battle screen self-tests passed: \(checks)")
}
