// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func originalBattleAnimationSelfTests() throws {
    var checks = 0
    func check(_ value:Bool,_ text:String) throws {
        guard value else { throw EngineError.invalid("Original battle animation regression: \(text)") };checks += 1
    }
    let tick = OriginalBattleAnimator.tick
    try check(abs(tick*6-0.099488) < 0.0001,"six ticks match the traced town step")
    var walker = OriginalBattleAnimator()
    walker.play([.walk(slot:3,path:[GridPoint(x:1,y:1),GridPoint(x:2,y:1),GridPoint(x:2,y:0)])])
    try check(abs(walker.cellSeconds-16*tick) < 0.000001,"the slowest step waits one tick per two pixels")
    try check(walker.advance(8*tick).isEmpty,"walking is silent")
    var place = walker.walker
    try check(place?.slot == 3 && place?.direction == 1 && abs((place?.x ?? 0)-1.5) < 0.001,"half a cell east")
    try check(place?.stepPixels == 16,"the step counter runs to thirty-two pixels")
    _ = walker.advance(16*tick)
    place = walker.walker
    try check(place?.direction == 0 && abs((place?.y ?? 0)-0.5) < 0.001,"the next step turns north")
    _ = walker.advance(16*tick)
    try check(walker.isIdle && walker.walker == nil,"the walk ends at its last cell")
    var fast = OriginalBattleAnimator()
    fast.play([.walk(slot:0,path:[GridPoint(x:0,y:0),GridPoint(x:1,y:0)])],options:0x34)
    try check(abs(fast.cellSeconds-tick) < 0.000001,"the option low nibble picks the pixel step")
    var effect = OriginalBattleAnimator()
    effect.effectSounds = [28,27,29,30,31,34,32,33]
    effect.play([.effect(1,halfX:6,halfY:4),.effect(8,halfX:7,halfY:4),.effect(9,halfX:2,halfY:2)])
    try check(effect.advance(0) == [27],"an effect plays its table sound once")
    try check(effect.effect?.frame == 2 && effect.effect?.halfX == 6,"effect one starts at frame two")
    _ = effect.advance(12*tick)
    try check(effect.effect?.frame == 3,"each frame holds twelve ticks")
    _ = effect.advance(12*tick)
    try check(effect.effect?.frame == 2,"two passes repeat the frames")
    try check(effect.advance(24*tick) == [41],"the clash sounds forty-one")
    try check(effect.effect?.frame == 16,"the clash uses effect eight")
    try check(effect.advance(24*tick) == [37],"effect nine sounds thirty-seven")
    try check(effect.effect?.frame == 0,"effect nine reuses effect zero's art")
    _ = effect.advance(48*tick)
    try check(effect.isIdle,"the queue empties")
    var shot = OriginalBattleAnimator()
    shot.play([.shot(from:GridPoint(x:4,y:4),to:GridPoint(x:2,y:4),stone:false),
               .shot(from:GridPoint(x:0,y:0),to:GridPoint(x:0,y:3),stone:false),
               .shot(from:GridPoint(x:0,y:0),to:GridPoint(x:1,y:0),stone:true)])
    try check(shot.advance(0) == [19],"a shot sounds nineteen")
    try check(shot.shot?.frame == 3,"a west arrow")
    _ = shot.advance(8*tick)
    try check(abs((shot.shot?.x ?? 0)-3) < 0.01,"four pixels a tick")
    _ = shot.advance(8*tick+0.0001)
    try check(shot.shot?.frame == 2,"a south arrow")
    _ = shot.advance(24*tick)
    try check(shot.shot?.frame == 4,"the catapult throws the stone frame")
    var settings = OriginalSettings()
    try check(settings.speed == 2 && settings.timeScale == 1 && settings.battleWord == 0,"source defaults change nothing")
    settings.speed = 1;settings.moveSpeed = 4;settings.unitCombat = 1;settings.enemyMove = true
    try check(settings.timeScale == 2 && settings.battleWord == 0x1014,"options pack as the source word")
    settings.speed = 3
    try check(abs(settings.timeScale-2.0/3) < 0.001,"the slowest step takes nine ticks instead of six")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
    defer { try? FileManager.default.removeItem(at:folder) }
    let slots = OriginalSaveSlots(directory:folder)
    try check(slots.entries().allSatisfy { $0 == nil } && slots.entries().count == 5,"five empty slots")
    let when = Date(timeIntervalSince1970:1000)
    try slots.write(["a":1],title:"첫째",slot:2,date:when)
    try check(slots.entries()[2] == OriginalSaveSlots.Entry(title:"첫째",date:when) && slots.entries()[1] == nil,"a slot keeps its title and date")
    try slots.write(["a":2],title:"둘째",slot:2,date:when)
    try check(slots.entries()[2]?.title == "둘째","a slot can be overwritten")
    do { try slots.write(["a":1],title:"",slot:5);throw EngineError.invalid("Slot five was accepted") }
    catch EngineError.invalid(let text) where text.hasPrefix("Save slot") { checks += 1 }
    print("Original battle animation self-tests passed: \(checks)")
}
