// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Synthetic checks for the battle screen's scroll, list and gauge rules.
func originalBattleScreenSelfTests() throws {
    var checks = 0
    func check(_ condition:Bool,_ message:String) throws {
        guard condition else { throw EngineError.invalid("Original battle screen regression: \(message)") }
        checks += 1
    }
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
    print("Original battle screen self-tests passed: \(checks)")
}
