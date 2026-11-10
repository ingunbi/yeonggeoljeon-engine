// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func selfTests() throws {
    var assertions = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw EngineError.invalid("Self-test failed: \(name)") }; assertions += 1
    }
    let even = [Neighbor(dx:-1,dy:0,direction:2),Neighbor(dx:-1,dy:-1,direction:3),Neighbor(dx:1,dy:0,direction:1),Neighbor(dx:1,dy:-1,direction:0)]
    let odd = [Neighbor(dx:-1,dy:1,direction:2),Neighbor(dx:-1,dy:0,direction:3),Neighbor(dx:1,dy:1,direction:1),Neighbor(dx:1,dy:0,direction:0)]
    let map = MapResource(image:"map.png",width:512,height:320,viewport:[16,16,512,320],walkWidth:7,walkHeight:7,
                          walkGrid:Array(repeating:".......",count:7),neighborsEven:even,neighborsOdd:odd)
    let actor = ActorResource(image:"actor.png",frameWidth:32,frameHeight:40,frames:4,anchorX:0,anchorY:24,
                              directions:[Direction(frame:2,flip:true),Direction(frame:0,flip:true),Direction(frame:0,flip:false),Direction(frame:2,flip:false)])
    var resources = Resources(format:1,title:nil,maps:["8192":map],actors:["1":actor,"2":actor])
    let commands = [Command("map",map:8192),Command("place",person:1,x:2,y:1),Command("place",person:2,x:4,y:1),
                    Command("move",person:1,x:2,y:3),Command("move",person:2,x:4,y:3),Command("say",text:"synthetic"),
                    Command("remove",person:1),Command("end")]
    func data(_ commands: [Command]) throws -> DataSet {
        try DataSet(resources:resources,scene:Scene(format:1,id:"synthetic",name:"synthetic",width:640,height:400,
              coordinateSystem:"town",timing:Timing(stepMicroseconds:99_488,terminalMicroseconds:99_488),commands:commands))
    }
    let fixture = try data(commands), a = Runtime(fixture), b = Runtime(fixture)
    let persistent = Runtime(fixture,hostDriven:true)
    persistent.acknowledge()
    try persistent.enqueue(Array(commands.prefix(3)))
    // A host-driven map change first fades the shown screen to black (CAD8(0)).
    try check(!persistent.hostWaiting && persistent.leaving && persistent.currentMap != nil,"a host map change applies at once and then fades the old screen out")
    persistent.advance(microseconds:Runtime.screenFadeMicroseconds)
    try check(persistent.hostWaiting && persistent.termination == nil && persistent.blackAlpha == 1,"VM stage suspends at a batch boundary")
    try persistent.enqueue([Command("show")])
    persistent.advance(microseconds:Runtime.screenFadeMicroseconds/2)
    try check(persistent.visible && abs(persistent.blackAlpha-0.5) < 0.01 && !persistent.hostWaiting,"source 05 fades the new map in")
    persistent.advance(microseconds:Runtime.screenFadeMicroseconds)
    try check(persistent.blackAlpha == 0 && persistent.hostWaiting,"the fade in ends at the shown map")
    try persistent.enqueue([Command("say",text:"first batch")])
    persistent.acknowledge()
    try check(persistent.actors.count == 2 && persistent.hostWaiting,"VM dialogue completion retains the same actors")
    try persistent.enqueue([Command("move",person:1,x:2,y:3)])
    persistent.advance(microseconds:2_000_000)
    try check(persistent.actors[1]?.position == GridPoint(x:2,y:3) && persistent.hostWaiting,"later VM batch moves an earlier actor")
    let overlapping = Runtime(try data([Command("map",map:8192),Command("place",person:1,x:2,y:1),Command("place",person:2,x:4,y:1),Command("move",person:1,x:4,y:1),Command("end")]))
    overlapping.acknowledge();overlapping.advance(microseconds:2_000_000)
    try check(overlapping.verifiedBoundary && overlapping.actors[1]?.position == overlapping.actors[2]?.position,"town source bit80 walk gate does not treat another actor as an obstacle")
    var failedMove = Command("move",person:2,x:99,y:1)
    failedMove.source = .string("synthetic-second-move-origin")
    let badBatch = Runtime(try data([Command("map",map:8192),Command("place",person:1,x:2,y:1),Command("place",person:2,x:4,y:1),Command("move",person:1,x:2,y:3),failedMove,Command("end")]))
    badBatch.acknowledge()
    try check(badBatch.termination == .runtimeFailure && badBatch.trace.last?.source == failedMove.source,"batch failure retains the failing second command's source identity")
    a.acknowledge(); b.acknowledge()
    try check(a.batch?.motions.count == 2,"consecutive moves form one simultaneous batch")
    a.acknowledge(); try check(a.inputCount == 1,"movement ignores input")
    a.advance(microseconds:2_000_000)
    for _ in 0..<200 { b.advance(microseconds:10_000) }
    try check(a.snapshot() == b.snapshot(),"frame-step partition determinism")
    try check(a.dialogue != nil && a.batch == nil,"say waits for every movement")
    try check(a.actors[1]?.position == GridPoint(x:2,y:3) && a.actors[2]?.position == GridPoint(x:4,y:3),"both source targets are reached")
    let before = a.snapshot(); a.advance(microseconds:5_000_000)
    try check(before == a.snapshot(),"dialogue blocks simulation time")
    a.acknowledge(); try check(a.actors[1] == nil && a.mode == "ended","remove followed by explicit end")
    let unknown = Runtime(try data([Command("unrecognized")])); unknown.acknowledge()
    try check(unknown.mode == "ended" && unknown.endReason?.contains("Unsupported") == true,"unknown command is an explicit boundary")
    try check(!unknown.verifiedBoundary && unknown.termination == .runtimeFailure,"unknown command cannot pass verification")
    let corrupt = Runtime(try data([Command("map",map:8192),Command("place",person:1,x:-1,y:2)])); corrupt.acknowledge()
    try check(corrupt.mode == "ended" && corrupt.actors.isEmpty,"corrupt source coordinate is rejected")
    try check(!corrupt.verifiedBoundary,"corrupt source coordinate cannot pass verification")
    let broken = Runtime(try data([Command("map",map:8192),Command("move",person:1,x:2,y:2)])); broken.acknowledge()
    try check(broken.mode == "ended" && broken.endReason?.contains("missing") == true,"missing actor cannot move")
    try check(!broken.verifiedBoundary,"missing actor cannot pass verification")
    var unsupportedEnd = Command("end"); unsupportedEnd.boundary = "unsupported"
    let declared = Runtime(try data([unsupportedEnd])); declared.acknowledge()
    try check(declared.verifiedBoundary && declared.termination == .unsupportedBoundary,"declared source unsupported boundary is distinguished")
    let eof = Runtime(try data([])); eof.acknowledge()
    try check(!eof.verifiedBoundary && eof.termination == .unexpectedEOF,"missing explicit end cannot pass verification")
    var wall = map
    wall.walkGrid = [".......",".......","#######",".......",".......",".......","......."]
    resources.maps["8192"] = wall
    let noRoute = Runtime(try data([Command("map",map:8192),Command("place",person:1,x:2,y:1),Command("move",person:1,x:2,y:3),Command("end")]))
    noRoute.acknowledge()
    try check(!noRoute.verifiedBoundary && noRoute.termination == .runtimeFailure,"unreachable route cannot pass verification")
    resources.maps["8192"] = map
    var fade = Command("fade",seconds:0.2); fade.to = "black"
    var camera = Command("camera",x:16,y:0); camera.coordinateUnits = "pixels"
    var caption = Command("caption",text:"synthetic caption")
    caption.textSource = .object(["offset":.number(0)])
    let fading = Runtime(try data([Command("map",map:8192),Command("show"),caption,camera,fade,Command("end")]))
    fading.acknowledge(); fading.acknowledge(); fading.advance(microseconds:100_000)
    try check(fading.inputCount == 1 && fading.blackAlpha == 0.5,"fade timing and input barrier")
    try check(fading.visible && fading.caption == "synthetic caption" && fading.camera == [16,0],"show caption and explicit camera units")
    try check(fading.trace.contains { $0.operation == "caption" && $0.textSource != nil },"caption provenance survives the runtime")
    fading.advance(microseconds:100_000)
    try check(fading.verifiedBoundary && fading.blackAlpha == 1,"fade completes at the exact boundary")
    // seg0:4F8E moves the world view by the scroll step and clamps it to the map.
    var world = map
    world.width = 1024;world.height = 640;world.geometry = "world"
    world.walkWidth = 32;world.walkHeight = 20;world.walkGrid = Array(repeating:String(repeating:".",count:32),count:20)
    world.neighborsEven = [Neighbor(dx:0,dy:-1,direction:0),.init(dx:1,dy:-1,direction:1),.init(dx:1,dy:0,direction:2),.init(dx:1,dy:1,direction:3),
                           .init(dx:0,dy:1,direction:4),.init(dx:-1,dy:1,direction:5),.init(dx:-1,dy:0,direction:6),.init(dx:-1,dy:-1,direction:7)]
    world.neighborsOdd = world.neighborsEven;world.placementDirections = Array(0..<8)
    let scrolling = Runtime(try data([]),hostDriven:true)
    scrolling.acknowledge()
    try scrolling.configureMap(4097,resource:world,actors:nil)
    try check(!scrolling.scrollWorld(dx:1,dy:0,step:1),"a stage without a world map does not scroll")
    try scrolling.enqueue([Command("map",map:4097)])
    scrolling.advance(microseconds:Runtime.screenFadeMicroseconds)
    try check(scrolling.scrollWorld(dx:1,dy:1,step:8) && scrolling.camera == [128,128],"a step moves the view that many tiles")
    try check(scrolling.scrollWorld(dx:1,dy:1,step:64) && scrolling.camera == [512,320],"the view stops at the map's far edge")
    try check(!scrolling.scrollWorld(dx:1,dy:0,step:1) && scrolling.scrollWorld(dx:-1,dy:-1,step:64) && scrolling.camera == [0,0],
              "a clamped step reports no move, and the near edge clamps too")
    try scrolling.enqueue([Command("place",person:1,x:2,y:2),Command("place",person:2,x:20,y:15)])
    try check(scrolling.snapshot().followPerson == 1,"MAIN20DFE..20F64 follows the first actor placed on a world map by default")
    try scrolling.enqueue([Command("move",person:1,x:25,y:15)])
    scrolling.advance(microseconds:10_000_000)
    try check(scrolling.camera == [512,320],"default slot-zero world follow scrolls the camera with a march to a battlefield")
    try scrolling.worldCamera(x:0,y:0,source:nil)
    try check(scrolling.snapshot().followPerson == nil && scrolling.camera == [0,0],"3B world-camera clears followPerson")
    try scrolling.enqueue([Command("move",person:2,x:24,y:15)])
    scrolling.advance(microseconds:10_000_000)
    try check(scrolling.camera == [512,320],"a world-map NPC march scrolls into view even when followPerson was cleared or points elsewhere")
    // MAIN257AC..2591F: citizens keep wandering while the player walks and avoid occupied cells.
    var townWalk = map;townWalk.walkBytes = Array(repeating:0x7F,count:49)
    let townStage = Runtime(try data([]),hostDriven:true);townStage.acknowledge()
    try townStage.configureMap(1,resource:townWalk,actors:nil)
    try townStage.enqueue([Command("map",map:1),Command("place",person:1,x:0,y:2),Command("place",person:2,x:2,y:2),Command("show")])
    townStage.advance(microseconds:Runtime.screenFadeMicroseconds*2)
    let playerRoute = try townStage.sourceRoute(person:1,to:GridPoint(x:6,y:2))
    try townStage.enqueueSourceRoute(person:1,route:playerRoute,finalFacing:playerRoute.last!.facing)
    townStage.wander(person:2,direction:1) { _ in true }
    try check(!townStage.hostWaiting && townStage.actors[2]?.position != GridPoint(x:2,y:2),
              "a citizen wanders while the player's own walk route is active")
    let older = try JSONDecoder().decode(OriginalSettings.self,from:Data(#"{"speed":3,"monochrome":true}"#.utf8))
    let stepped = try JSONDecoder().decode(OriginalSettings.self,from:Data(#"{"scroll":4}"#.utf8))
    let uneven = try JSONDecoder().decode(OriginalSettings.self,from:Data(#"{"scroll":3}"#.utf8))
    try check(older.speed == 3 && older.monochrome && older.scroll == 1 && stepped.scroll == 4 && uneven.scroll == 1,
              "stored settings without a scroll step keep their values; only 1, 2, 4 and 8 are steps")
    let chosen = try JSONDecoder().decode(OriginalSettings.self,from:Data(#"{"enemyMove":false,"revision":1}"#.utf8))
    try check(older.enemyMove && !chosen.enemyMove,"settings from before revision 1 follow enemy moves once; a later 안 본다 stays")
    let paced = try JSONDecoder().decode(OriginalSettings.self,from:Data(#"{"battlePace":3}"#.utf8))
    let overPaced = try JSONDecoder().decode(OriginalSettings.self,from:Data(#"{"battlePace":9}"#.utf8))
    try check(older.battleRate == 1 && paced.battleRate == 3 && overPaced.battlePace == 0,"battle pace defaults to the source speed and keeps only listed rates")
    try check(abs(OriginalBattleView.idleSeconds-24*OriginalBattleAnimator.tick) < 1e-9 && abs(OriginalBattleView.idleSeconds-0.398) < 0.002,
              "a waiting unit flips its frame every four units of six ticks")
    let twenty = String(repeating:"가",count:20),long = String(repeating:"가",count:400)
    try check(!older.autoAdvance && older.autoSpeed == 1 && abs(DialoguePace.readingSeconds(twenty)-0.8) < 0.001 &&
              DialoguePace.readingSeconds(String(repeating:"가",count:50)) == 1.4 && DialoguePace.readingSeconds(long) == 2.5,
              "auto advance is off by default and 보통 reads a line for 0.8 to 2.5 seconds")
    try check(abs(DialoguePace.readingSeconds(twenty,speed:0)-1.6) < 0.001 && abs(DialoguePace.readingSeconds(twenty,speed:2)-0.4) < 0.001 &&
              DialoguePace.readingSeconds(long,speed:2) == 1.5,"느리게 and 빠르게 bracket 보통")
    // MAIN24BD6 places the merchant by palace room type (DS:3838), not by index.
    var merchant = OriginalShopCatalog.Merchant(person:374,x:15,y:11,sourceFacing:4,music:15)
    try check(!merchant.hosts(palaceIndex:10),"without the type table no room hosts the merchant")
    merchant.roomType = 7;merchant.roomTypes = [0,0,1,1,1,1,3,3,5,5,7,7,8]
    try check(merchant.hosts(palaceIndex:10) && merchant.hosts(palaceIndex:11) && !merchant.hosts(palaceIndex:7) && !merchant.hosts(palaceIndex:40),
              "type seven rooms host the merchant, room seven does not")
    // MAIN's glyphs (CF5:0A2E, 0D44): a syllable is two columns of 14 rows, a byte one of 16.
    var hangul = Data(count:3478*30),ascii = Data(count:96*16)
    hangul[1128*30+2] = 0x80;hangul[1128*30+3] = 0x01
    ascii[33*16] = 0x80
    let font = try OriginalFont(hangul:hangul,ascii:ascii)
    try check(OriginalFont.bytes("가A") == [0xB0,0xA1,0x41],"text becomes the CP949 bytes MAIN keeps")
    let cells = OriginalFont.cells([0xB0,0xA1,0x41,0x0A,0xCA,0xD0])
    try check(cells.map(\.column) == [0,2,3,4] && cells.map(\.code) == [0xB0A1,0x41,0xCA,0xD0],"leads A1..C8 pair, others print alone, controls vanish")
    try check(font.rows(0xB0A1)[0] == 0x8001 && font.rows(0xB0A1).count == 14 && font.rows(0x41) == [0x8000]+Array(repeating:0,count:15),"glyph rows come from the record after its identity")
    try check(OriginalFont.columns("가A") == 3 && font.picture("가A",red:255,green:255,blue:255)?.width == 24,"a picture is eight pixels a column")
    // Source 0B/0E boxes (MAIN3C5E mode0) close by themselves; narration waits.
    let boxes = Runtime(try data([Command("map",map:8192),Command("say",text:"box",seconds:0.5),Command("say",text:"line"),
                                  Command("say",text:"again",seconds:0.5),Command("end")]))
    boxes.acknowledge(); boxes.advance(microseconds:400_000)
    try check(boxes.dialogue?.text == "box" && boxes.dialogue?.closesAfter == 0.5,"a timed box holds until its time")
    boxes.advance(microseconds:200_000)
    try check(boxes.dialogue?.text == "line" && boxes.inputCount == 1,"a timed box closes without input")
    boxes.advance(microseconds:5_000_000)
    try check(boxes.dialogue?.text == "line","narration waits for input")
    boxes.acknowledge(); boxes.acknowledge()
    try check(boxes.verifiedBoundary && boxes.inputCount == 3,"input closes a timed box early")
    do { _ = try fixture.containedFile("../escape.png"); throw EngineError.invalid("Traversal test did not reject") }
    catch EngineError.invalid(let message) { try check(message.contains("contained"),"path traversal is rejected") }
    resources.title = "/absolute.png"
    do { _ = try data(commands); throw EngineError.invalid("Absolute path test did not reject") }
    catch EngineError.invalid(let message) { try check(message.contains("contained"),"absolute resource path is rejected") }
    print("Self-tests passed: \(assertions)")
}
