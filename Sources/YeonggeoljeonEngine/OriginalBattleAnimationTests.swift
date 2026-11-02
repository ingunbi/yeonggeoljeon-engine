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
    // The enlarged view: a synthetic catalog with identity-sized tables.
    func entry(_ value:Int) -> [Int] { Array(repeating:value,count:19) }
    var classes = OriginalCombatCatalog.Classes(prep:entry(255),run:entry(1),swing:entry(4),attack:entry(6),total:entry(8),shot:entry(255))
    classes.prep[3] = 1;classes.run[3] = 255;classes.swing[3] = 255;classes.shot[3] = 0;classes.attack[3] = 4;classes.total[3] = 6
    let blank = Data(repeating:0,count:256).base64EncodedString()
    let catalog = OriginalCombatCatalog(format:1,palette:Array(repeating:[0,0,0],count:16),background:blank,tiles:"",
        frameTiles:Array(repeating:16,count:169)+Array(repeating:9,count:12),backs:[],grounds:[],classes:classes,classNames:Array(repeating:"",count:19),
        slots:[[[10,4],[8,8],[6,6],[4,4],[2,8]],[[14,4],[12,8],[16,6],[20,4],[18,8]]],
        terrainBack:Array(repeating:4,count:20),terrainGround:Array(repeating:7,count:20),strategySounds:[28,27,29],weathers:["sun","cloud","rain"],
        texts:.init(ambushFriendly:"go",ambushEnemy:"oh",strategyFailed:"%s no",levelUp:"%s L%w",learned:"%s!",strategyUsed:"%s used %s",strategyCry:"%s cry",attackIntent:"%s go",
                    confuseIntent:"ci",moraleIntent:"mi",healIntent:"%s up",moraleDown:"%s down",healed:"%s %s %s",healVerb:"heal",raiseVerb:"raise",
                    stillConfused:"%s still",confused:"%s dazed",moreConfused:"%s worse",strategyMissed:"miss",recovered:"%s clear",turn:"T%u %s",
                    closingBonus:"B%w",delayRetreat:"late",failed:"%s failed",noLoss:"%s none",loss:"%s(%4u)",moraleLoss:"m%2u",experience:"%s e%2u",counterFriendly:"c",counterEnemy:"C",
                    level:"Lv%2u %s",attack:"a",defense:"d",troops:"t",morale:"m",exp:"e",terrain:"g",percent:"+%2u%%"),source:nil,limitations:nil)
    func combat(attacker:Int = 0,target:Int = 20,attackerClass:Int = 0,targetClass:Int = 0,kind:Int = 1,subtype:Int = 0,troops:Int = 700,damage:Int = 250) -> OriginalCombatSnapshot {
        OriginalCombatSnapshot(kind:kind,subtype:subtype,attackerSlot:attacker,targetSlot:target,attackerPerson:0,targetPerson:1,attackerClass:attackerClass,
            targetClass:targetClass,attackerLevel:3,targetLevel:4,attackerTroops:1300,targetTroops:troops,attackerMaxTroops:1500,targetMaxTroops:1000,
            attackerMorale:90,targetMorale:80,attackValue:300,defenseValue:200,terrain:0,terrainPercent:20,damage:damage,moraleLoss:7,experience:12,
            experienceGain:9,counter:false)
    }
    var melee = try OriginalCombatScene(catalog:catalog,snapshot:combat())
    melee.addResults(attackerName:"가",targetName:"나")
    let holds = melee.frames.filter { !$0.layers.isEmpty }
    try check(holds.first?.ticks == 60 && holds.first?.skippable == true,"a scene opens on a second of stillness that a click ends")
    try check(melee.frames.flatMap(\.sounds).first == 18 && melee.frames.contains { $0.stopsSound },"infantry runs on sound eighteen until the run ends")
    let picturedTicks = melee.frames.filter { $0.page == nil }.map(\.ticks).reduce(0,+)
    try check(picturedTicks == 60+41+0+24+2,"begin, run, swing and a shove of two hundred troops")
    try check(melee.frames.filter { $0.page != nil }.map(\.ticks).reduce(0,+) == 240,"a friendly hit holds four result pages")
    try check(melee.frames.first { $0.page != nil }?.page?.lines.first?.text == "나( 250)","the loss line fills the source format")
    try check(melee.frames.last?.page?.gauges == [.init(y:164,value:21,maximum:100)],"experience ends on the raised value")
    // Soldier counts follow the snapshot: 1300 troops is three, 700 is two.
    let first = holds[0].layers
    func stamped(_ x:Int,_ y:Int) -> Bool { first[3*13*26+y*26+x] >= 0 }
    try check(stamped(10,4) && stamped(8,8) && stamped(6,6) && !stamped(4,4),"the attacker stands three soldiers")
    let lethal = try OriginalCombatScene(catalog:catalog,snapshot:combat(troops:400,damage:400))
    let shoved = lethal.frames.filter { $0.ticks == 1 }.count-41
    try check(shoved == 13,"a kill shoves thirteen cells")
    var archers = try OriginalCombatScene(catalog:catalog,snapshot:combat(attackerClass:3,damage:0))
    archers.addResults(attackerName:"가",targetName:"나")
    try check(archers.frames.flatMap(\.sounds) == [19,21],"archers shoot and hit, with no run")
    try check(archers.frames.contains { $0.waitsForSound } && !archers.frames.contains { $0.stopsSound },"the bow waits for its sound")
    try check(archers.frames.filter { $0.page != nil }.count == 3,"a miss has one page, then experience")
    var fire = try OriginalCombatScene(catalog:catalog,snapshot:combat(attacker:20,target:0,kind:2,subtype:0x01,damage:0))
    fire.addResults(attackerName:"가",targetName:"나")
    try check(fire.frames.flatMap(\.sounds) == [28,20],"a strategy pans under its family sound and the default hit")
    try check(fire.frames.first { $0.page != nil }?.page?.lines.first?.text == "가 failed","a failed strategy names its caster")
    try check(fire.frames.filter { $0.page != nil }.count == 2,"an enemy attacker has no experience pages")
    do { _ = try OriginalCombatScene(catalog:catalog,snapshot:{ var s = combat();s.terrain = 20;return s }())
         throw EngineError.invalid("A terrain past the tables opened a scene") }
    catch EngineError.invalid(let text) where text.hasPrefix("Original combat view has no") { checks += 1 }
    try check(originalFormat("%s(%4u) +%2u%%",["가","7","5"]) == "가(   7) + 5%","the printf subset pads and escapes")
    var player = OriginalCombatPlayer(scene:melee)
    try check(player.advance(0,soundBusy:false).isEmpty && player.index == 0,"a scene starts on its first frame")
    player.skip()
    _ = player.advance(0.001,soundBusy:false)
    try check(player.index == 1,"a click ends a skippable hold")
    player.finish()
    try check(player.finished && player.frame == nil,"a scene can be cut short")
    func noticeText(_ notice:OriginalBattleNotice) -> String { catalog.text(notice,person:{ "p\($0)" },strategy:{ "s\($0)" }) }
    try check(noticeText(.ambush(friendly:true)) == "go" && noticeText(.ambush(friendly:false)) == "oh","each side has its ambush line")
    try check(noticeText(.strategyFailed(person:4)) == "p4 no" && noticeText(.level(person:4,level:9)) == "p4 L9","notices fill the source formats")
    try check(noticeText(.learned(abilities:[1,2])) == "s1s2!","names join with no separator, as CF5:46D4 appends them")
    try check(noticeText(.strategyUsed(person:2,ability:3)) == "p2 used s3" && noticeText(.strategyCry(ability:3)) == "s3 cry","a caster's lines name the strategy")
    try check(noticeText(.confused(person:1,again:false)) == "p1 dazed" && noticeText(.confused(person:1,again:true)) == "p1 worse","confusion has two lines")
    try check(noticeText(.turn(round:3,weather:2)) == "T3 rain" && noticeText(.turn(round:3,weather:9)) == "T3 ","the banner names its weather")
    try check(noticeText(.closingBonus(points:40)) == "B40" && noticeText(.delayRetreat) == "late" && noticeText(.strategyMissed) == "miss","bare notices")
    try check(catalog.text(.healed(person:1,kind:2,raises:true),person:{ "p\($0)" },strategy:{ _ in "" },kind:{ "k\($0)" }) == "p1 k2 raise","a healed line names its kind")
    try check(OriginalBattleNotice.delayRetreat.waitsForInput && OriginalBattleNotice.closingBonus(points:1).waitsForInput && !OriginalBattleNotice.strategyMissed.waitsForInput,"mode one lines wait")
    var notices = OriginalBattleAnimator()
    notices.play([.notice(.level(person:0,level:2)),.notice(.learned(abilities:[1])),.notice(.ambush(friendly:true))])
    try check(notices.advance(0) == [7],"a level notice sounds seven")
    try check(notices.notice == .level(person:0,level:2),"a notice shows first in its queue")
    _ = notices.advance(OriginalBattleAnimator.noticeSeconds-0.1)
    try check(notices.notice == .level(person:0,level:2),"mode zero holds until its timeout")
    try check(notices.advance(0.2) == [7],"a learned notice sounds seven")
    _ = notices.advance(100)
    try check(notices.notice == .learned(abilities:[1]),"mode one waits for input")
    notices.dismissNotice()
    try check(notices.notice == .learned(abilities:[1]),"a dismissal lands on the next advance")
    try check(notices.advance(0).isEmpty && notices.notice == .ambush(friendly:true),"an ambush line is silent")
    notices.dismissNotice();_ = notices.advance(0)
    try check(notices.isIdle,"input closes mode zero early")
    try check(OriginalBattleCue.notice(.ambush(friendly:true)).isPresentation && !OriginalBattleCue.shot(from:GridPoint(x:0,y:0),to:GridPoint(x:1,y:0),stone:false).isPresentation,"notices open before the next map step")
    // The screen player: a synthetic program on the source's canvas and buffers.
    let names = OriginalScreenCatalog.operations
    func op(_ name:String,_ values:Int...) -> [Int] { [names.firstIndex(of:name)!]+values }
    let red = (0..<48).map { $0%3 == 1 ? 15 : 0 }
    let art:[UInt8] = [0x80,0,0,0,0,0,0,0]                    // leftmost pixel of two groups: colour one
    var program:[[Int]] = [op("load",0,0,0),op("put",4,2,16,1,0,0),op("clock",100)]
    program += [op("wait",10),op("mode",4),op("put",4,3,16,1,0,0),op("get",4,2,8,2,1,0),op("music",1,0,1)]
    program += [[names.firstIndex(of:"fade")!]+red,op("inputwait"),op("musicstop",8),op("clear")]
    let screen = OriginalScreenPlayer(ops:program,assets:[[0,8]],data:art)
    var screenActions = screen.advance(centiseconds:0)
    try check(screen.pc == 4 && screenActions.isEmpty,"a clock op sets the deadline and the first wait holds")
    screenActions = screen.advance(centiseconds:9)
    try check(screen.pc == 4,"a wait holds until its absolute deadline")
    screenActions = screen.advance(centiseconds:3)
    try check(screenActions == [.music(bank:1,member:0,loop:true)],"music is an action for the window")
    try check(screen.palette[1] == 1,"a fade moves each channel one step")
    screen.advance(centiseconds:15*4*OriginalScreenPlayer.tick+1)
    try check(screen.palette[1] == 15 && !screen.finished && screen.waitingForInput,"a fade takes four ticks a step, then the input wait holds")
    screen.acceptInput()
    try check(screen.advance(centiseconds:1) == [.stopMusic(8)] && screen.finished,"a click answers the final button loop")
    try check(OriginalScreenPlayer.colors(red)[1]&0xFFFFFF == 0xFF,"stored channels are 4-bit, red in the second byte")
    print("Original battle animation self-tests passed: \(checks)")
}
