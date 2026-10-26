// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func originalExplorationInputSelfTests() throws {
    var checks = 0
    func check(_ condition:@autoclosure()throws->Bool,_ message:String)throws {
        guard try condition() else {throw EngineError.invalid("Original exploration input regression: \(message)")};checks += 1
    }
    func rejected(_ operation:()throws->Void)throws->Bool {do {try operation();return false} catch EngineError.invalid {return true}}
    let even = [Neighbor(dx:-1,dy:0,direction:2),Neighbor(dx:-1,dy:-1,direction:3),Neighbor(dx:1,dy:0,direction:1),Neighbor(dx:1,dy:-1,direction:0)]
    let odd = [Neighbor(dx:-1,dy:1,direction:2),Neighbor(dx:-1,dy:0,direction:3),Neighbor(dx:1,dy:1,direction:1),Neighbor(dx:1,dy:0,direction:0)]
    let world = [Neighbor(dx:0,dy:-1,direction:0),.init(dx:1,dy:-1,direction:1),.init(dx:1,dy:0,direction:2),.init(dx:1,dy:1,direction:3),
                 .init(dx:0,dy:1,direction:4),.init(dx:-1,dy:1,direction:5),.init(dx:-1,dy:0,direction:6),.init(dx:-1,dy:-1,direction:7)]
    var walk = Array(repeating:127,count:25);walk[24] = 123;walk[19] = 124
    let townMap = OriginalExplorationMap(key:"town:0",kind:"town",sourceIndex:0,image:"map.png",width:512,height:320,
        walkWidth:5,walkHeight:5,walkBytes:walk,walkGrid:Array(repeating:".....",count:5),viewport:[16,16,512,320],objects:[],neighborsEven:even,neighborsOdd:odd)
    let worldMap = OriginalExplorationMap(key:"world:0",kind:"world",sourceIndex:0,image:"map.png",width:512,height:320,
        walkWidth:5,walkHeight:5,walkBytes:Array(repeating:0,count:25),walkGrid:Array(repeating:".....",count:5),viewport:[16,16,512,320],objects:[])
    let cities = [OriginalCity(chapter:0,id:0,name:"syntheticA",worldX:1,worldY:1,worldPositionKnown:true,worldMapKey:"world:0",townMapKey:"town:0"),
        OriginalCity(chapter:0,id:1,name:"syntheticB",worldX:3,worldY:3,worldPositionKnown:true,worldMapKey:"world:0",townMapKey:"town:0"),
        OriginalCity(chapter:0,id:2,name:"syntheticUnplaced",worldPositionKnown:false,worldMapKey:"world:0",townMapKey:"town:0")]
    let catalog = OriginalExplorationCatalog(format:2,maps:[townMap,worldMap],chapterMappings:[OriginalChapterMapping(chapter:0,cityGroup:0,cityCount:3,cityBase:0,worldMapKey:"world:0")],
        cities:cities,actorBanks:[:],worldNeighbors:world,worldDirectionFrames:[0,0,2,2,4,4,6,6],worldPlacementDirections:Array(0..<8))
    let data = try DataSet(resources:Resources(format:1,maps:[:],actors:[:]),scene:Scene(format:1,id:"synthetic-input",name:"synthetic",width:640,height:400,coordinateSystem:"town",commands:[]))
    func runtime(_ map:OriginalExplorationMap,packed:Int)throws->Runtime {
        let stage = Runtime(data,hostDriven:true);stage.acknowledge()
        let resource = MapResource(image:"map.png",width:512,height:320,viewport:[16,16,512,320],walkWidth:5,walkHeight:5,
            walkGrid:map.walkGrid,walkBytes:map.walkBytes,neighborsEven:map.kind == "world" ? world : even,
            neighborsOdd:map.kind == "world" ? world : odd,geometry:map.kind == "world" ? "world" : nil,
            stepMicroseconds:10,placementDirections:map.kind == "world" ? Array(0..<8) : nil)
        let actor = ActorResource(image:"actor.png",frameWidth:32,frameHeight:40,frames:8,anchorX:0,anchorY:24,
            directions:(0..<8).map{Direction(frame:($0/2)*2,flip:false)})
        try stage.configureMap(packed,resource:resource,actors:["0":actor,"1":actor,"2":actor]);try stage.enqueue([Command("map",map:packed)])
        return stage
    }
    var state = OriginalCampaignState();state.packedMap = 0x1000;state.currentCity = 0;state.cityFlags = [3,3,3];state.cityFlagsChapter = 0
    state.actorCacheMap = state.packedMap;state.actorCacheCity = state.city;state.actorCacheDirty = true
    state.actorCache[0] = OriginalCampaignCachedActor(person:0,x:4,y:4,flags:0,sourceFacing:2)
    state.actorCache[1] = OriginalCampaignCachedActor(person:1,x:2,y:2,flags:0,sourceFacing:3)
    state.returnContext = OriginalCampaignReturnContext(packedMap:0x1000,x:4,y:2)
    let bootstrap = try OriginalExplorationInput.worldBootstrap(catalog:catalog,state:state,entry:.nativeCityDefault,rng:OriginalRNG(state:7))
    try check(bootstrap.commands.map(\.person) == [0] && bootstrap.commands[0].x == 1 && bootstrap.commands[0].sourcePlacementFacing == 4,
        "native world entry places only default player0 and never replays the settlement cache")
    try check(bootstrap.retainedReturnContext == state.returnContext,"saved return context remains separate from visible default spawn")
    var expected = OriginalRNG(state:7);let periods = [(try expected.next(bound:16)+2) & ~1]
    try check(bootstrap.rngAfter == expected && bootstrap.placementPeriods == periods,"world placement consumes one source RNG16 per actual actor placement")
    var townPlacementRNG = OriginalRNG(state:7),townExpected = OriginalRNG(state:7)
    let townStanding = (try townExpected.next(bound:16)+2) & ~1
    let townAutonomous = try townExpected.next(bound:3)+1
    let effects = try OriginalExplorationInput.placementEffects(packedMap:0x200E,person:1,rng:&townPlacementRNG)
    try check(effects == OriginalExplorationPlacementEffects(standingPeriod:townStanding,autonomousPeriod:townAutonomous) && townPlacementRNG == townExpected,"settlement NPC placement consumes RNG16 then RNG3 at the owning producer")
    var playerPlacementRNG = OriginalRNG(state:7),playerExpected = OriginalRNG(state:7)
    _ = try playerExpected.next(bound:16)
    let playerEffects = try OriginalExplorationInput.placementEffects(packedMap:0,person:0,rng:&playerPlacementRNG)
    try check(playerEffects.autonomousPeriod == nil && playerPlacementRNG == playerExpected,"settlement player0 placement skips the NPC behavior draw")
    let worldScript = try OriginalExplorationInput.worldBootstrap(catalog:catalog,state:state,entry:.script,rng:OriginalRNG(state:7))
    try check(worldScript.commands.isEmpty && worldScript.rngAfter == OriginalRNG(state:7),"script world entry adds neither default spawn nor cache replay nor RNG")
    let parsedReplay = OriginalSettlementCacheReplay(actors:[state.actorCache[1]],music:nil,restored:true)
    let replay = try OriginalExplorationInput.settlementCacheReplay(replay:parsedReplay,packedMap:0x200E,rng:OriginalRNG(state:7))
    try check(replay.commands.map(\.person) == [1] && replay.commands[0].sourcePlacementFacing == 3 && replay.rngAfter == townExpected,"settlement replay consumes VM-owned ordered rows into generic-facing placement and both NPC draws")
    let emptyReplay = OriginalSettlementCacheReplay(actors:[],music:nil,restored:false)
    let emptyPlacements = try OriginalExplorationInput.settlementCacheReplay(replay:emptyReplay,packedMap:0x200E,rng:OriginalRNG(state:7))
    try check(emptyPlacements.commands.isEmpty && emptyPlacements.rngAfter == OriginalRNG(state:7),"empty VM-owned settlement replay adds no placement or RNG")
    let stage = try runtime(worldMap,packed:state.packedMap);try stage.enqueue(bootstrap.commands)
    try stage.enqueue([Command("place",person:1,x:2,y:2,sourcePlacementFacing:3)])
    try check(stage.actors[1]?.facing == 3,"generic cached world placement preserves odd raw8 direction instead of treating it as a script byte")
    try stage.enqueue([Command("place",person:2,x:1,y:2,facing:1)])
    try check(stage.actors[2]?.facing == 2,"world script facing is expanded once at its producer before the generic lookup")
    let plan = try OriginalExplorationInput.worldCity(catalog:catalog,state:state,stage:stage,cityID:1,enabled:true)
    try check(plan.route.first?.position == GridPoint(x:2,y:2) && plan.route.last?.position == GridPoint(x:6,y:6),"world plans retain native halfstep route coordinates")
    try check(try rejected{_ = try OriginalExplorationInput.arrive(plan,catalog:catalog,state:state,stage:stage)},"city event cannot dispatch before route completion")
    try stage.enqueueSourceRoute(person:0,route:plan.route,finalFacing:plan.route.last!.facing);stage.advance(microseconds:100_000)
    let arrived = try OriginalExplorationInput.arrive(plan,catalog:catalog,state:state,stage:stage)
    try check(arrived.event == .worldDestination(currentCity:1) && arrived.currentCity == 1 && state.returnContext?.x == 4,"completed city arrival supplies exact event/city without rewriting the saved7A76 return context")
    var hidden = state;hidden.cityFlags![1] = 2
    try check(try rejected{_ = try OriginalExplorationInput.worldCity(catalog:catalog,state:hidden,stage:stage,cityID:1,enabled:true)},"source city low flags gate selection")
    try check(try rejected{_ = try OriginalExplorationInput.worldCity(catalog:catalog,state:state,stage:stage,cityID:2,enabled:true)},"unplaced source city remains unsupported")
    try check(try rejected{_ = try OriginalExplorationInput.worldCity(catalog:catalog,state:state,stage:stage,cityID:1,enabled:false)},"host source input gate cannot be bypassed")
    var townState = OriginalCampaignState();townState.currentCity = 0;townState.gameCity = 9
    let town = try runtime(townMap,packed:0);try town.enqueue([Command("place",person:0,x:0,y:2),Command("place",person:1,x:3,y:2)])
    try town.enqueue([Command("place",person:2,x:2,y:0,sourcePlacementFacing:5)])
    try check(town.actors[2]?.facing == 2,"settlement generic raw directions retain the source even-pair canonical facing")
    let full = try town.sourceRoute(person:0,to:town.actors[1]!.position)
    let talk = try OriginalExplorationInput.townActor(state:townState,stage:town,person:1,enabled:true)
    try check(talk.route == Array(full.dropLast()),"talk planner trims the exact source target route rather than recomputing another adjacent route")
    try town.enqueueSourceRoute(person:0,route:talk.route,finalFacing:talk.route.last!.facing);town.advance(microseconds:100_000)
    let spoken = try OriginalExplorationInput.arrive(talk,catalog:catalog,state:townState,stage:town)
    try check(spoken.event == .townActor(person:1) && spoken.facings.count == 2,"talk arrival rechecks adjacency then supplies both native facings before kind3")
    try check(spoken.afterInvocationFacings == [.init(person:1,nativeDirection:town.actors[1]!.facing)],"town invocation restores only the target's saved facing after the source callback")
    try town.enqueue([Command("place",person:1,x:0,y:0)])
    try check(try rejected{_ = try OriginalExplorationInput.arrive(talk,catalog:catalog,state:townState,stage:town)},"moved talk target cannot receive a stale interaction event")
    let marker = try OriginalExplorationInput.townCell(catalog:catalog,state:townState,stage:town,point:GridPoint(x:4,y:4),enabled:true)
    try town.enqueueSourceRoute(person:0,route:marker.route,finalFacing:marker.route.last!.facing);town.advance(microseconds:100_000)
    try check(try OriginalExplorationInput.arrive(marker,catalog:catalog,state:townState,stage:town).event == .townDestination(marker:123,currentCity:9),"town marker event uses source gameCity even when player city differs")
    let ground = try OriginalExplorationInput.townCell(catalog:catalog,state:townState,stage:town,point:GridPoint(x:3,y:4),enabled:true)
    try town.enqueueSourceRoute(person:0,route:ground.route,finalFacing:ground.route.last!.facing);town.advance(microseconds:100_000)
    try check(try OriginalExplorationInput.arrive(ground,catalog:catalog,state:townState,stage:town).event == nil,"ordinary7F ground does not invent an arrival event")
    var palaceState = townState;palaceState.packedMap = 0x200E
    let palace = try runtime(townMap,packed:palaceState.packedMap)
    try palace.enqueue([Command("place",person:0,x:0,y:2),Command("place",person:1,x:3,y:2)])
    let palaceTalk = try OriginalExplorationInput.townActor(state:palaceState,stage:palace,person:1,enabled:true)
    try palace.enqueueSourceRoute(person:0,route:palaceTalk.route,finalFacing:palaceTalk.route.last!.facing);palace.advance(microseconds:100_000)
    try check(try OriginalExplorationInput.arrive(palaceTalk,catalog:catalog,state:palaceState,stage:palace).event == .townActor(person:1),"palace kind2 shares the native settlement actor input controller")
    let palaceMarker = try OriginalExplorationInput.townCell(catalog:catalog,state:palaceState,stage:palace,point:GridPoint(x:4,y:3),enabled:true)
    try palace.enqueueSourceRoute(person:0,route:palaceMarker.route,finalFacing:palaceMarker.route.last!.facing);palace.advance(microseconds:100_000)
    let palaceArrival = try OriginalExplorationInput.arrive(palaceMarker,catalog:catalog,state:palaceState,stage:palace)
    try check(palaceArrival.event == .townDestination(marker:124,currentCity:9) && palaceArrival.builtin == .worldExit,"palace marker uses active PMAP walk facts and retains its unmatched built-in fallback")
    try check(OriginalSettlementBuiltin.forMarker(125) == .returnToContext && OriginalSettlementBuiltin.forMarker(126) == nil &&
              OriginalSettlementBuiltin.forMarker(2) == .roomEntry(marker:2) && OriginalSettlementBuiltin.forMarker(0x81) == nil,
              "settlement fallback follows the source marker switch")
    print("Original exploration input self-tests passed: \(checks)")
}
