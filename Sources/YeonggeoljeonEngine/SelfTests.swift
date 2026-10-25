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
    try check(persistent.hostWaiting && persistent.termination == nil,"VM stage suspends at a batch boundary")
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
    do { _ = try fixture.containedFile("../escape.png"); throw EngineError.invalid("Traversal test did not reject") }
    catch EngineError.invalid(let message) { try check(message.contains("contained"),"path traversal is rejected") }
    resources.title = "/absolute.png"
    do { _ = try data(commands); throw EngineError.invalid("Absolute path test did not reject") }
    catch EngineError.invalid(let message) { try check(message.contains("contained"),"absolute resource path is rejected") }
    print("Self-tests passed: \(assertions)")
}
