// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Synthetic checks for the battle screen's scroll, list and gauge rules.
func originalBattleScreenSelfTests() throws {
    try AppControlRuntime.withPreferences(AppControlPreferences()) {try originalBattleScreenChecks()}
}
private func originalBattleScreenChecks() throws {
    var checks = 0
    func check(_ condition:Bool,_ message:String) throws {
        guard condition else { throw EngineError.invalid("Original battle screen regression: \(message)") }
        checks += 1
    }
    // The canvas fits the window and centres; a click maps back through the same numbers.
    let sideBands = CanvasGeometry(bounds:CGRect(x:0,y:0,width:1200,height:600),whole:false,backing:2)
    try check(sideBands.scale == 1.5 && sideBands.origin == CGPoint(x:120,y:0),"a wide window bands the sides")
    let endBands = CanvasGeometry(bounds:CGRect(x:0,y:0,width:640,height:600),whole:false,backing:2)
    try check(endBands.scale == 1 && endBands.origin == CGPoint(x:0,y:100),"a tall window bands the top and bottom")
    try check(sideBands.canvas(CGPoint(x:270,y:150)) == CGPoint(x:100,y:100),"a view point maps to its canvas point")
    // Whole-pixel scaling: 1024×640 points on a 2× screen gives three device pixels a source pixel.
    let whole = CanvasGeometry(bounds:CGRect(x:0,y:0,width:1024,height:640),whole:true,backing:2)
    try check(whole.scale == 1.5 && whole.origin == CGPoint(x:32,y:20),"whole scaling rounds down to device pixels and centres")
    try check(CanvasGeometry(bounds:CGRect(x:0,y:0,width:1024,height:640),whole:true,backing:1).scale == 1,"a 1× screen keeps one pixel a pixel")
    try check(CanvasGeometry(bounds:CGRect(x:0,y:0,width:500,height:300),whole:true,backing:2).scale == 0.5,"a small window still gets whole device pixels")
    try check(CanvasGeometry(bounds:CGRect(x:0,y:0,width:200,height:100),whole:true,backing:1).scale == 0.25,"below one device pixel it falls back to fitting")
    // The engine field draws its 512×320 map over the canvas, 1.25 canvas units a map pixel.
    try check(CanvasGeometry(bounds:CGRect(x:0,y:0,width:1024,height:640),whole:true,backing:2,sourcePixel:1.25).scale == 1.6,"the engine field gets four device pixels a map pixel")
    // The modern arrangement keeps every part on the canvas and off the map.
    let modern = OriginalBattleLayout.source.modern()
    let canvas = CGRect(x:0,y:0,width:640,height:400),modernMap = modern.viewportRect
    try check(modern.columns == 15 && modern.rows == 10,"the modern map reserves readable controls around fifteen by ten cells")
    try check(modernMap.width == CGFloat(modern.columns*modern.cell) && modernMap.height == CGFloat(modern.rows*modern.cell),"the modern map holds whole cells")
    let parts = [OriginalBattleLayout.rect(modern.list.rect),OriginalBattleLayout.rect(modern.minimap.panel)]+modern.sideButtons.map(OriginalBattleLayout.rect)
    try check(parts.allSatisfy{canvas.contains($0) && !$0.intersects(modernMap)},"sidebar parts stay on the canvas and beside the map")
    try check(OriginalBattleLayout.rect(modern.list.rect).maxY <= OriginalBattleLayout.rect(modern.minimap.panel).minY,"the unit list ends above the small map")
    let largest = modern.minimapOrigin(width:40,height:24),smallest = modern.minimapOrigin(width:20,height:12)
    try check(OriginalBattleLayout.rect(modern.minimap.panel).contains(CGRect(x:largest.x,y:largest.y,width:120,height:72)),"the largest small map fits its panel")
    try check(OriginalBattleLayout.rect(modern.minimap.panel).contains(CGRect(x:smallest.x,y:smallest.y,width:60,height:36)),"a smaller one is centred inside it")
    var modernCamera = OriginalBattleCamera(width:40,height:24,layout:modern)
    modernCamera.center(on:GridPoint(x:39,y:23))
    try check(modernCamera.rect(of:GridPoint(x:39,y:23),in:modernMap,size:32) == CGRect(x:448,y:336,width:32,height:32),"the last cell ends in the map corner")
    try check(modernCamera.cell(at:CGPoint(x:479,y:367),in:modernMap,size:32) == GridPoint(x:39,y:23),"a corner click reaches the last cell")
    let headerButtons = ModernBattleControls.top.map { $0.rect }
    try check(headerButtons.allSatisfy { ModernBattleControls.header.contains($0) && $0.height >= 20 && !$0.intersects(modernMap) },
              "header hit targets have a readable height and stay outside map input")
    for (index,button) in headerButtons.enumerated() {
        try check(headerButtons.dropFirst(index+1).allSatisfy { !$0.intersects(button) },"header buttons do not overlap")
    }
    try check([ModernBattleControls.command,ModernBattleControls.wait,ModernBattleControls.confirm,ModernBattleControls.cancel].allSatisfy {
        ModernBattleControls.footer.contains($0) && $0.height >= 24 && !$0.intersects(modernMap)
    },"context buttons fit below the map with distinct hit targets")
    try check(!ModernBattleControls.command.intersects(ModernBattleControls.wait) && !ModernBattleControls.wait.intersects(ModernBattleControls.cancel),
              "movement controls cannot activate each other")
    try check(ModernBattleControls.cinematicViewport.contains(CGRect(x:32,y:48,width:416,height:352)) &&
              !ModernBattleControls.cinematicViewport.intersects(ModernBattleControls.header),
              "unscaled combat and duel panels fit below the header through the inactive action bar")
    // The modern field stretches the map window over the canvas.
    let center = CGPoint(x:320,y:200)
    try check(CanvasFieldMap.mapPoint(canvas:center) == CGPoint(x:272,y:176),"the canvas centre is the map window's centre")
    try check(CanvasFieldMap.canvasPoint(map:CanvasFieldMap.mapPoint(canvas:CGPoint(x:64,y:40))) == CGPoint(x:64,y:40),"the two field mappings invert")
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

    // MAIN33747..33827 speaker focus and MAIN27D65/27F55 turn-end confirmation.
    let cardinal = [OriginalAIOffset(dx:0,dy:-1),.init(dx:1,dy:0),.init(dx:0,dy:1),.init(dx:-1,dy:0)]
    var uiLevels = Array(repeating:Array(repeating:255,count:19),count:36);uiLevels[30][0] = 0;uiLevels[0][0] = 12
    var uiCosts = Array(repeating:255,count:36);uiCosts[30] = 1;uiCosts[0] = 4
    var uiCategories = Array(repeating:0,count:36);uiCategories[30] = 3
    let movement = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),classMovementBudgets:Array(repeating:3,count:19),
        attackRangeCodes:Array(repeating:0,count:19),movementCosts:Array(repeating:Array(repeating:1,count:256),count:4),
        cardinalOffsets:cardinal,diagonalOffsets:cardinal,extendedOffsets:cardinal,setupOrderModes:Array(repeating:7,count:256),
        strategyLevelRequirements:uiLevels,strategyMPCosts:uiCosts,
        strategyCategories:uiCategories,strategyTerrainEligibility:Array(repeating:[0,253,254,255],count:3))
    var roster = OriginalRoster()
    roster.header = OriginalBattleHeader(preserveFriendlySlots:false,turnLimit:10,sourceByte2:0,discardedBytes:[],objectives:[])
    roster.slots[0] = OriginalPlacement(ordinal:0,person:0,x:2,y:2,selector:0,flag:0,flags:0,rawMode:0,parameter:0,classID:0,level:10)
    roster.slots[1] = OriginalPlacement(ordinal:1,person:20,x:22,y:14,selector:0,flag:0,flags:1,rawMode:0,parameter:0,classID:0,level:10)
    let session = try OriginalBattleSession(definition:BattleDefinition(id:"synthetic-screen-view",width:28,height:16,
        coordinateSystem:"orthogonal",tiles:Array(repeating:0,count:28*16)),roster:&roster,
        people:try OriginalPeople(catalog:catalog,tables:tables),combat:tables,movement:movement,rng:OriginalRNG(state:5))
    let view = try OriginalBattleView(session:session,background:nil,sprites:nil,style:OriginalBattleStyle())
    view.confirmsTurnEnd = true
    try check(view.focusSpeaker(20),"focusing an active enemy speaker locates its slot")
    try check(view.speakerInLowerHalf,"an enemy near the bottom edge places the dialogue box at the top")
    try check(view.focusSpeaker(0),"focusing an active friendly speaker near the top locates its slot")
    try check(!view.speakerInLowerHalf,"a speaker near the top keeps the dialogue box at the bottom")
    view.clearSpeakerFocus()
    try check(!view.speakerInLowerHalf,"clearing speaker focus resets placement")
    func key(_ code:UInt16) -> NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,
                        characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
    }
    func point(_ rect:CGRect) -> CGPoint { CGPoint(x:rect.midX,y:rect.midY) }
    view.presentation = .modern
    try view.start()
    try check(!view.asksPlayer,"with an unacted friendly unit ready, auto turn-end confirmation does not open")
    let initialRound = session.turns.roundIndex
    let menuOverlay = view.subviews.compactMap { $0 as? CanvasOverlayView }.first!
    let beforeLoad = (units:session.units,turns:session.turns,rng:session.rng)
    var loadRequests = 0
    view.onLoad = { loadRequests += 1 }
    view.keyDown(with:key(53))
    let loadRow = menuOverlay.selector?.options.firstIndex(where:{ $0.label == "불러오기" })
    try check(loadRow != nil,"the campaign battle menu exposes the shared load selector")
    if let loadRow = loadRow {
        for _ in 0..<loadRow { menuOverlay.keyDown(with:key(125)) }
        menuOverlay.keyDown(with:key(36))
    }
    try check(loadRequests == 1 && !menuOverlay.active,"load menu invokes its owner exactly once")
    try check(session.units == beforeLoad.units && session.turns == beforeLoad.turns && session.rng == beforeLoad.rng,
              "opening the load selector does not consume a battle action or RNG")
    view.onLoad = nil
    view.keyDown(with:key(53))
    try check(menuOverlay.selector?.options.contains(where:{ $0.label == "불러오기" }) == false,
              "an isolated battle without a campaign owner does not offer an inert load action")
    menuOverlay.keyDown(with:key(53))
    view.keyDown(with:key(36))
    try check(view.playerControls.contains { $0.action == .command && $0.enabled } && session.turns.roundIndex == initialRound && session.turns.stage == .manualFriendly,
              "Return at idle selects a ready unit instead of ending the turn")
    view.keyDown(with:key(36))
    try check(view.asksPlayer,"Return for a selected unit opens its current-position command menu")
    let uiOverlay = view.subviews.compactMap { $0 as? CanvasOverlayView }.first!
    uiOverlay.keyDown(with:key(53))
    try check(!view.asksPlayer && session.units[0]!.scriptFlags&0x80 == 0,"cancelling commands preserves the unit action")
    let listRect = OriginalBattleLayout.rect(view.layoutFacts.list.rect)
    try check(view.clickPanel(CGPoint(x:listRect.midX,y:listRect.minY+8)),"a roster row is a handled panel input")
    try check(view.playerControls.contains { $0.action == .command && $0.enabled },"a ready friendly roster row selects that unit for movement")
    let enabledBefore = view.playerControls.filter { $0.enabled }.map { $0.action }
    try view.performPlayerAction(.endTurn)
    try check(view.playerControls.filter { $0.enabled }.map { $0.action } == enabledBefore && session.turns.roundIndex == initialRound,
              "turn-end routing refuses while a movement choice is active")
    view.keyDown(with:key(49))
    try check(session.units[0]!.scriptFlags&0x80 != 0,"Space for a selected unit dispatches the existing wait action")
    view.advanceAnimation(0)
    try check(view.asksPlayer,"once all controllable friendly units have acted, the turn-end confirmation opens automatically")

    // A resumed provisional move reopens commands in a newly constructed view.
    // The key events exercise the same selector callbacks as live input, without OS delivery.
    var resumedRoster = roster
    let resumedSession = try OriginalBattleSession(definition:session.definition,roster:&resumedRoster,
        people:try OriginalPeople(catalog:catalog,tables:tables),combat:tables,movement:movement,rng:OriginalRNG(state:17))
    try OriginalBattleFlow(session:resumedSession).start()
    let moveOrigin = resumedSession.units[0]!.position,moveDestination = GridPoint(x:3,y:2)
    _ = try resumedSession.move(0,to:moveDestination)
    let resumedRNG = resumedSession.rng
    let resumedView = try OriginalBattleView(session:resumedSession,background:nil)
    resumedView.presentation = .modern
    resumedView.restorePendingMovementCommand()
    let resumedOverlay = resumedView.subviews.compactMap { $0 as? CanvasOverlayView }.first!
    try check(resumedView.asksPlayer && resumedSession.units[0]!.position == moveDestination,
              "a restored provisional move opens its command menu at the saved destination")
    try check(resumedSession.pendingMovementSlots == [0] && resumedSession.units[0]!.scriptFlags&0xC0 == 0x40,
              "opening restored commands preserves the provisional move without consuming the action")
    let guideUnits = resumedSession.units,guideTurns = resumedSession.turns
    for _ in 0..<4 { resumedOverlay.keyDown(with:key(125)) }
    resumedOverlay.keyDown(with:key(36))
    try check(resumedOverlay.sheet?.rows.count == 2 && resumedOverlay.sheet?.rows.allSatisfy(\.enabled) == true,
              "the command guide lists learned and future strategies as readable rows")
    resumedOverlay.keyDown(with:key(125));resumedOverlay.keyDown(with:key(36))
    try check(resumedOverlay.sheet?.selected == 1 && resumedSession.units == guideUnits && resumedSession.turns == guideTurns && resumedSession.rng == resumedRNG,
              "selecting a future strategy keeps the guide open without casting or spending state")
    resumedOverlay.keyDown(with:key(53))
    try check(resumedOverlay.selector?.options.count == 6 && resumedOverlay.selector?.options.last?.label == "상태 안내" && resumedSession.pendingMovementSlots == [0],
              "closing the guide restores commands and the provisional movement origin")
    resumedOverlay.keyDown(with:key(53))
    try check(!resumedView.asksPlayer && resumedSession.units[0]!.position == moveOrigin && resumedSession.pendingMovementSlots.isEmpty,
              "Escape in restored commands returns the unit to its saved movement origin")
    try check(resumedSession.units[0]!.scriptFlags&0xC0 == 0 && resumedSession.rng == resumedRNG,
              "cancelling a restored move spends neither the unit action nor randomness")
    resumedView.restorePendingMovementCommand()
    try check(!resumedView.asksPlayer,"a cancelled movement command cannot reopen as a stale resume")
    _ = try resumedSession.move(0,to:moveDestination)
    let resumedWaitView = try OriginalBattleView(session:resumedSession,background:nil)
    resumedWaitView.restorePendingMovementCommand()
    let resumedWaitOverlay = resumedWaitView.subviews.compactMap { $0 as? CanvasOverlayView }.first!
    for _ in 0..<3 { resumedWaitOverlay.keyDown(with:key(125)) }
    resumedWaitOverlay.keyDown(with:key(36))
    try check(resumedSession.units[0]!.position == moveDestination && resumedSession.units[0]!.scriptFlags&0x80 != 0 &&
              resumedSession.pendingMovementSlots.isEmpty,
              "choosing Wait after resume commits the saved move and consumes the unit action")
    let actedUnits = resumedSession.units,actedRNG = resumedSession.rng
    try resumedWaitView.performPlayerAction(.menu)
    if let index = resumedWaitOverlay.selector?.options.firstIndex(where:{$0.label == "책략 습득표"}) {
        for _ in 0..<index {resumedWaitOverlay.keyDown(with:key(125))}
    }
    resumedWaitOverlay.keyDown(with:key(36))
    try check(resumedWaitOverlay.sheet?.rows.count == 1,"the battle guide officer picker contains friendly officers only")
    resumedWaitOverlay.keyDown(with:key(36))
    try check(resumedWaitOverlay.sheet?.rows.count == 2 && resumedSession.units == actedUnits && resumedSession.rng == actedRNG,
              "an already-acted officer can inspect the learning guide without receiving another action")
    resumedWaitOverlay.keyDown(with:key(53))
    try check(resumedWaitOverlay.sheet?.selected == 0,"closing a guide returns to the same officer in the picker")
    resumedWaitOverlay.keyDown(with:key(53));resumedWaitOverlay.keyDown(with:key(53))

    // A complete area-strategy path through menus and the clickable footer.
    // The same dispatch is used by real mouse events; this is not an OS-input test.
    var areaRoster = roster
    let areaSession = try OriginalBattleSession(definition:session.definition,roster:&areaRoster,
        people:try OriginalPeople(catalog:catalog,tables:tables),combat:tables,movement:movement,rng:OriginalRNG(state:5))
    let areaView = try OriginalBattleView(session:areaSession,background:nil)
    areaView.presentation = .modern
    try areaView.start()
    areaSession.units[0]!.mp = 5;areaSession.units[0]!.morale = 80
    let areaOverlay = areaView.subviews.compactMap { $0 as? CanvasOverlayView }.first!
    func chooseAreaStrategy() {
        areaOverlay.keyDown(with:key(125))  // command row 1: strategy
        areaOverlay.keyDown(with:key(36))
        areaOverlay.keyDown(with:key(36))   // only synthetic ability 30 is available
    }
    try areaView.performPlayerAction(.nextUnit)
    try areaView.performPlayerAction(.command)
    areaOverlay.keyDown(with:key(125));areaOverlay.keyDown(with:key(36))
    areaOverlay.keyDown(with:key(125));areaOverlay.keyDown(with:key(125));areaOverlay.keyDown(with:key(36))
    try check(areaOverlay.sheet?.rows.count == 2,"the learned-strategy picker also opens the complete learning guide")
    areaOverlay.keyDown(with:key(53))
    try check(areaOverlay.selector?.options.count == 3,"closing that guide returns to strategies, availability help and the guide")
    areaOverlay.keyDown(with:key(53))
    chooseAreaStrategy()
    let beforeCancelRNG = areaSession.rng
    try check(areaView.playerControls.contains { $0.action == .confirmStrategy && $0.enabled },"an area strategy exposes a clickable execution control")
    try check(areaView.clickPanel(point(ModernBattleControls.cancel)),"the area-strategy cancel button accepts a click")
    try check(areaSession.units[0]!.mp == 5 && areaSession.units[0]!.scriptFlags&0x80 == 0 && areaSession.rng == beforeCancelRNG && areaView.asksPlayer,
              "cancelling area selection returns to commands without MP, action or RNG consumption")
    chooseAreaStrategy()
    try check(areaView.clickPanel(point(ModernBattleControls.confirm)),"the area-strategy execute button accepts a click")
    try check(areaSession.units[0]!.mp == 4 && areaSession.units[0]!.scriptFlags&0x80 != 0,
              "clicking execute runs the restored strategy and spends its single cost")
    let afterExecuteRNG = areaSession.rng
    _ = areaView.clickPanel(point(ModernBattleControls.confirm))
    try check(areaSession.units[0]!.mp == 4 && areaSession.rng == afterExecuteRNG,"a repeated click cannot execute a stale strategy again")
    areaView.presentation = .original
    try check(areaView.playerControls.isEmpty && areaView.layoutFacts.viewport == OriginalBattleLayout.source.viewport,
              "switching to original frames restores the source geometry without modern hit targets")
    var favoriteRoster = roster
    let favoriteSession = try OriginalBattleSession(definition:session.definition,roster:&favoriteRoster,
        people:try OriginalPeople(catalog:catalog,tables:tables),combat:tables,movement:movement,rng:OriginalRNG(state:5))
    let favoriteView = try OriginalBattleView(session:favoriteSession,background:nil)
    var favoriteCommands:[BattleFavoriteAction] = [.strategy(30)]
    favoriteView.favoriteCommands = {_ in favoriteCommands}
    favoriteView.onFavoriteCommandsChanged = {_,commands in favoriteCommands = commands}
    favoriteView.presentation = .modern;try favoriteView.start()
    favoriteSession.units[0]!.mp = 5;favoriteSession.units[0]!.morale = 80
    let favoriteOverlay = favoriteView.subviews.compactMap {$0 as? CanvasOverlayView}.first!
    try favoriteView.performPlayerAction(.nextUnit);try favoriteView.performPlayerAction(.command)
    try check(favoriteOverlay.selector?.options.first?.label.hasPrefix("★ ") == true,"favorite commands appear before normal commands with stable action identity")
    let favoriteBeforeRNG = favoriteSession.rng
    favoriteOverlay.keyDown(with:key(36))
    try check(favoriteView.playerControls.contains {$0.action == .confirmStrategy && $0.enabled} && favoriteSession.units[0]!.mp == 5 && favoriteSession.rng == favoriteBeforeRNG,
        "favorite area strategy still waits for the ordinary explicit confirmation")
    try favoriteView.performPlayerAction(.cancel)
    if let waitIndex = favoriteOverlay.selector?.options.firstIndex(where:{$0.label == "Wait"}) {
        for _ in 0..<waitIndex {favoriteOverlay.keyDown(with:key(125))}
        favoriteOverlay.keyDown(with:key(36))
    }
    try check(favoriteSession.units[0]!.scriptFlags&0x80 != 0 && favoriteSession.units[0]!.mp == 5,
        "favorite-prefix insertion does not shift the original Wait command into another action")
    favoriteSession.units[0]!.scriptFlags = 0x20;favoriteSession.units[0]!.mp = 0
    try favoriteView.performPlayerAction(.nextUnit);try favoriteView.performPlayerAction(.command)
    try check(favoriteOverlay.selector?.options.first?.enabled == false && favoriteOverlay.selector?.options.first?.help.contains("MP") == true,
        "an exhausted favorite remains visible with its MP refusal")
    favoriteOverlay.keyDown(with:key(53))
    favoriteSession.units[0]!.mp = 5
    try favoriteView.performPlayerAction(.nextUnit)
    let helperUnits = favoriteSession.units,helperRNG = favoriteSession.rng,helperTurns = favoriteSession.turns
    favoriteView.favoriteCommandsSourceIssue = {"이전 자료의 즐겨찾기입니다"}
    try favoriteView.performPlayerAction(.command)
    try check(favoriteOverlay.selector?.options.first?.enabled == false && favoriteOverlay.selector?.options.first?.help.contains("이전 자료") == true,"source-mismatched favorites remain visible but cannot execute a same-number command")
    favoriteOverlay.keyDown(with:key(53));favoriteView.favoriteCommandsSourceIssue = nil
    var rememberedModes:[BattleMapViewMode] = []
    favoriteView.onMapViewPreferenceChanged = {rememberedModes.append($0)}
    favoriteView.keyDown(with:key(6))
    try check(favoriteView.layoutFacts.cell == 40,"map zoom changes only the viewport cell scale")
    favoriteView.keyDown(with:key(6))
    try check(favoriteView.layoutFacts.columns == favoriteSession.width && favoriteView.layoutFacts.rows == favoriteSession.height,"full-map mode fits all cells")
    try check(rememberedModes == [.large],"overview does not overwrite the default tactical map scale")
    favoriteView.keyDown(with:key(49));favoriteView.keyDown(with:key(36))
    for action:BattlePlayerAction in [.wait,.command,.confirmStrategy,.endTurn,.nextUnit] {try favoriteView.performPlayerAction(action)}
    try check(favoriteSession.units == helperUnits && favoriteSession.rng == helperRNG && favoriteSession.turns == helperTurns && !favoriteOverlay.active,
        "overview Space/Return and footer action dispatch cannot wait, move, attack or consume a turn from a selected unit")
    try check(favoriteView.playerControls.filter(\.enabled).allSatisfy {[BattlePlayerAction.menu,.conditions,.threat,.pace,.cancel].contains($0.action)},
        "overview exposes only inspection, menu and return controls")
    favoriteView.keyDown(with:key(6))
    try check(favoriteView.layoutFacts.cell == 40 && favoriteSession.units == helperUnits && favoriteSession.rng == helperRNG,"leaving overview restores the previous map scale without a gameplay command")
    var preferredControls = AppControlPreferences();preferredControls.battleMapMode = .large
    let preferredView = try AppControlRuntime.withPreferences(preferredControls) {try OriginalBattleView(session:favoriteSession,background:nil)}
    preferredView.presentation = .modern
    try check(preferredView.layoutFacts.cell == 40,"a newly created battle view restores the stored tactical scale")
    var savedAnnotations = BattleAnnotations(battleID:favoriteSession.definition.id,attemptID:favoriteSession.resultLog.attemptID,width:favoriteSession.width,height:favoriteSession.height)
    favoriteView.annotations = {savedAnnotations};favoriteView.onAnnotationsChanged = {savedAnnotations = $0}
    favoriteView.keyDown(with:key(45));favoriteOverlay.keyDown(with:key(36))
    try check(!favoriteOverlay.active && favoriteView.playerControls.filter(\.enabled).allSatisfy {$0.action == .cancel},"annotation coordinate selection blocks normal battle actions")
    favoriteView.keyDown(with:key(53))
    try check(savedAnnotations.entries.isEmpty && favoriteSession.units == helperUnits && favoriteSession.rng == helperRNG,"cancelling an annotation draft writes no metadata or gameplay state")
    favoriteView.keyDown(with:key(6))
    favoriteView.keyDown(with:key(45));favoriteOverlay.keyDown(with:key(36))
    let draftButtons = favoriteView.playerControls.filter(\.enabled)
    try check(draftButtons.count == 1 && draftButtons.first?.action == .cancel && draftButtons.first?.label.hasPrefix("메모 취소") == true,
        "annotation draft takes input and label priority over overview return controls")
    try favoriteView.performPlayerAction(.cancel)
    try check(favoriteView.layoutFacts.columns == favoriteSession.width && favoriteSession.units == helperUnits && favoriteSession.rng == helperRNG,
        "overview annotation cancel discards only the draft and preserves the overview and gameplay")
    favoriteView.keyDown(with:key(6))
    try favoriteView.performPlayerAction(.nextUnit)
    favoriteView.keyDown(with:key(17));favoriteOverlay.keyDown(with:key(36))
    try check(favoriteOverlay.sheet?.speaker == "범위 책략 위치 추천" && favoriteSession.units == helperUnits && favoriteSession.rng == helperRNG,"area advice opens as a read-only sheet from its keyboard action")
    favoriteOverlay.keyDown(with:key(53))
    favoriteView.showTutorialLibrary()
    try check(favoriteOverlay.sheet?.speaker == "상황별 초보 안내" && favoriteSession.units == helperUnits && favoriteSession.rng == helperRNG,"tutorial library preserves the pending source command and RNG")
    favoriteOverlay.keyDown(with:key(53))
    var accepted:[OriginalPlayInput] = [],boundaries = 0
    favoriteView.onAcceptedInput = {accepted.append($0)};favoriteView.onRecordingBoundary = {boundaries += 1}
    try favoriteView.performPlayerAction(.wait)
    favoriteView.advanceAnimation(0);favoriteView.advanceAnimation(0)
    try check(accepted.map(\.kind) == [.battleWait] && boundaries == 1,"immediate wait records one accepted command and one settled boundary, not one per frame")
    print("Original battle screen self-tests passed: \(checks)")
}
