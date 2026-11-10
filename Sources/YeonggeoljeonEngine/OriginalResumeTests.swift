// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Synthetic checks for native resume state. Real-data resume parity is a
/// separate local replay comparison.
func originalResumeSelfTests() throws {
    var checks = 0
    func check(_ condition:@autoclosure()throws->Bool,_ message:String)throws {
        guard try condition() else { throw EngineError.invalid("Native resume regression: \(message)") };checks += 1
    }
    func rejected(_ operation:()throws->Void)->Bool { do { try operation();return false } catch { return true } }
    let even = [Neighbor(dx:-1,dy:0,direction:2),Neighbor(dx:-1,dy:-1,direction:3),Neighbor(dx:1,dy:0,direction:1),Neighbor(dx:1,dy:-1,direction:0)]
    let odd = [Neighbor(dx:-1,dy:1,direction:2),Neighbor(dx:-1,dy:0,direction:3),Neighbor(dx:1,dy:1,direction:1),Neighbor(dx:1,dy:0,direction:0)]
    let data = try DataSet(resources:Resources(format:1,maps:[:],actors:[:]),scene:Scene(format:1,id:"synthetic-resume",name:"synthetic",width:640,height:400,coordinateSystem:"town",commands:[]))
    let resource = MapResource(image:"map.png",width:512,height:320,viewport:[16,16,512,320],walkWidth:5,walkHeight:5,
        walkGrid:Array(repeating:".....",count:5),walkBytes:Array(repeating:127,count:25),neighborsEven:even,neighborsOdd:odd,
        geometry:nil,stepMicroseconds:10,placementDirections:nil)
    let actor = ActorResource(image:"actor.png",frameWidth:32,frameHeight:40,frames:8,anchorX:0,anchorY:24,
        directions:(0..<4).map{Direction(frame:$0*2,flip:false)})
    let banks = ["0":actor,"1":actor]
    let packed = 0x2001
    let original = Runtime(data,hostDriven:true);original.acknowledge()
    try original.configureMap(packed,resource:resource,actors:banks);try original.setPalette(2)
    try original.enqueue([Command("map",map:packed),Command("place",person:0,x:1,y:1,facing:1),
                          Command("place",person:1,x:3,y:3,facing:2),Command("show")])
    original.advance(microseconds:2*Runtime.screenFadeMicroseconds)  // fade out, then the show fades in
    let saved = original.snapshot()
    try check(original.hostWaiting && saved.actors.count == 2 && saved.visible, "synthetic stage settles before the save point")
    func fresh() throws -> Runtime {
        let stage = Runtime(data,hostDriven:true);try stage.configureMap(packed,resource:resource,actors:banks);return stage
    }
    let restored = try fresh();try restored.restoreIdle(saved)
    var expected = saved;expected.nextCommand = 0
    try check(restored.snapshot() == expected, "idle restore keeps map, actors, camera, palette, visibility and clock")
    try check(restored.hostWaiting && (try restored.sourceRoute(person:0,to:GridPoint(x:2,y:1))).last?.position == GridPoint(x:2,y:1),
              "restored stage accepts the next native route")
    try check(rejected { try original.restoreIdle(saved) }, "a running stage cannot be overwritten by a resume")
    var talking = saved;talking.dialogue = CommandSnapshot(person:0,speaker:"s",text:"t",source:nil,textSource:nil)
    try check(rejected { try fresh().restoreIdle(talking) }, "a pending dialogue is not a resumable idle scene")
    var duplicate = saved;duplicate.actors[1].person = 0
    try check(rejected { try fresh().restoreIdle(duplicate) }, "duplicate actor identities are rejected")
    var outside = saved;outside.actors[0].position = GridPoint(x:9,y:0)
    try check(rejected { try fresh().restoreIdle(outside) }, "actors outside the walk grid are rejected")
    var follow = saved;follow.followPerson = 7
    try check(rejected { try fresh().restoreIdle(follow) }, "an absent follow target is rejected")
    try check(rejected { try Runtime(data,hostDriven:true).restoreIdle(saved) }, "an unconfigured map resource is rejected")
    // Suspension keeps the displayed line and the queue after it, rather
    // than replaying commands that have already changed actors or the clock.
    try original.enqueue([Command("say",person:0,text:"first"),Command("say",person:1,text:"second")])
    let dialogueSaved = original.snapshot()
    let dialogueContinuation = try JSONDecoder().decode(RuntimeSuspension.self,from:JSONEncoder().encode(original.suspension()!))
    let dialogueRestored = try fresh();try dialogueRestored.restoreSuspension(dialogueSaved,state:dialogueContinuation)
    try check(dialogueRestored.dialogue == original.dialogue && dialogueRestored.dialogue?.text == "first",
              "suspension retains the current dialogue without acknowledging it")
    original.acknowledge();dialogueRestored.acknowledge()
    try check(dialogueRestored.dialogue == original.dialogue && dialogueRestored.dialogue?.text == "second",
              "resumed dialogue continues exactly once into the remaining command queue")
    original.acknowledge();dialogueRestored.acknowledge()
    try check(original.hostWaiting && dialogueRestored.hostWaiting,"both dialogue paths reach the same idle boundary")
    try original.enqueue([Command("say",text:"timed",seconds:0.2)])
    original.advance(microseconds:50_000)
    let timedRestored = try fresh();try timedRestored.restoreSuspension(original.snapshot(),state:original.suspension()!)
    original.advance(microseconds:149_999);timedRestored.advance(microseconds:149_999)
    try check(original.dialogue != nil && timedRestored.dialogue != nil,"timed dialogue keeps its remaining deadline")
    original.advance(microseconds:1);timedRestored.advance(microseconds:1)
    try check(original.hostWaiting && timedRestored.hostWaiting && original.clock == timedRestored.clock,
              "timed dialogue resumes at the same fixed-step clock")
    try original.enqueue([Command("move",person:0,x:2,y:1)])
    try check(original.suspension() == nil,"in-flight movement waits for a stable boundary")
    // Shared person values are replaced only as one complete population.
    let tables = OriginalCombatTables(format:1,attackBase:Array(repeating:10,count:19),defenseBase:Array(repeating:10,count:19),
        troopBase:Array(repeating:10,count:19),troopGrowth:Array(repeating:0,count:19),physicalSubtypeByClass:Array(repeating:0,count:19),
        terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),
        items:(0..<64).map{OriginalItemEffect(id:$0,category:15,value:0)})
    let rows = (0..<384).map { id in
        OriginalPersonDefinition(id:id,name:"p\(id)",classID:0,level:1,experience:0,rawTroops:10,defenseScalar:1,attackScalar:1,
            intellectScalar:1,personality:0,personalScalar:0,itemIDs:Array(repeating:255,count:8),sourceFlags:0,sourceRole:0,
            sourceContext2:0,sourceContext3:0)
    }
    let people = try OriginalPeople(catalog:OriginalPersonCatalog(format:1,people:rows),tables:tables)
    var changed = rows;changed[5].level = 7;changed[5].sourceRole = 6
    try people.restore(changed)
    try check(try people.person(5).level == 7 && people.person(5).sourceRole == 6, "restore keeps constructed field2B values verbatim")
    try check(rejected { try people.restore(Array(changed.dropLast())) } && (try people.person(5).level == 7),
              "an incomplete population is rejected without partial replacement")
    // Resume files are bounded and typed.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:folder) }
    let wrong = folder.appendingPathComponent("wrong.json")
    try Data(#"{"format":1,"kind":"other"}"#.utf8).write(to:wrong)
    try check(rejected { _ = try OriginalCampaignResume.read(from:wrong) }, "a file of another kind is not a native resume")
    let empty = folder.appendingPathComponent("empty.json");try Data().write(to:empty)
    try check(rejected { _ = try OriginalCampaignResume.read(from:empty) }, "an empty file is rejected before decoding")
    // Source36 restart restores only named persons and the script context.
    try people.restore(rows)
    var later = rows;later[5].level = 9;later[6].level = 9
    try people.restore(people:[5],from:later)
    try check(try people.person(5).level == 9 && people.person(6).level == 1, "battle restart restores only setup-named persons")
    try check(rejected { try people.restore(people:[999],from:later) }, "an unknown named person is rejected")
    let instruction = OriginalCampaignInstruction(opcode:0xFF,offset:0,kind:"end-record",arguments:[],commands:[])
    let record = OriginalCampaignRecord(id:"r",chapter:0,member:0,block:0,ordinal:0,kind:0,inverted:false,rawKind:0,
        words:[0,0,0],group:OriginalCampaignGroup(base:0,count:1,repeating:false),instructions:[instruction])
    let program = OriginalCampaignProgram(format:1,records:[record],sourceDigest:"synthetic")
    var boundedRecord = record
    boundedRecord.instructions = [OriginalCampaignInstruction(opcode:5,offset:0,kind:"commands",arguments:[],commands:[Command("show")]),
        OriginalCampaignInstruction(opcode:0xFF,offset:1,kind:"end-record",arguments:[],commands:[])]
    let boundedVM = try CampaignVM(program:OriginalCampaignProgram(format:1,records:[boundedRecord],sourceDigest:"synthetic-bounded"))
    _ = try boundedVM.queryInvocation(event:.automatic)
    try check(!OriginalCampaignSuspension.canResumeWaiting(boundedVM.state),"an active source invocation is not a waiting suspension")
    _ = try boundedVM.advance();_ = try boundedVM.takeInvocationReturn()
    let returnedVM = try JSONDecoder().decode(OriginalCampaignState.self,from:JSONEncoder().encode(boundedVM.state))
    try check(returnedVM.currentRecordID != nil && OriginalCampaignSuspension.canResumeWaiting(returnedVM),
              "a nonterminal show return retains its resumable source cursor at a waiting suspension")
    var current = OriginalCampaignState();current.gameCity = 4;current.cityFlags = [3,2];current.cityFlagsChapter = 0
    current.returnContext = OriginalCampaignReturnContext(packedMap:0,x:5,y:6);current.currentMusic = 9;current.completedRecords = 40
    current.currentCity = 4;try current.setFlag(3,true)
    let vm = try CampaignVM(program:program,state:current)
    var context = vm.state;context.currentCity = 2;context.completedRecords = 7;context.currentMusic = 1;context.gameCity = 1
    try context.setFlag(3,false);context.returnContext = nil;context.cityFlags = [3,3]
    try vm.restoreRetryContext(context)
    try check(vm.state.currentCity == 2 && (try !vm.state.flag(3)) && vm.state.gameCity == 4 && vm.state.cityFlags == [3,2] &&
              vm.state.returnContext?.x == 5 && vm.state.currentMusic == 9 && vm.state.completedRecords == 40,
              "restart restores script context and player city but keeps game, city, 7A76 and device state")
    var foreign = context;foreign.programDigest = "other"
    try check(rejected { try vm.restoreRetryContext(foreign) }, "a checkpoint from another source program is rejected")
    // Battle-start snapshots preserve scripted setup and start the same turn
    // stream, but cannot be used as arbitrary live-battle save files.
    let offsets = [OriginalAIOffset(dx:0,dy:-1),OriginalAIOffset(dx:1,dy:0),OriginalAIOffset(dx:0,dy:1),OriginalAIOffset(dx:-1,dy:0)]
    let profile = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),classMovementBudgets:Array(repeating:3,count:19),
        attackRangeCodes:Array(repeating:0,count:19),movementCosts:Array(repeating:Array(repeating:1,count:256),count:4),
        cardinalOffsets:offsets,diagonalOffsets:offsets,extendedOffsets:offsets,setupOrderModes:Array(repeating:2,count:256),
        strategyLevelRequirements:Array(repeating:Array(repeating:255,count:19),count:36),strategyMPCosts:Array(repeating:255,count:36),strategyCategories:Array(repeating:0,count:36))
    var battleRoster = OriginalRoster()
    battleRoster.header = OriginalBattleHeader(preserveFriendlySlots:false,turnLimit:20,sourceByte2:0,discardedBytes:[0,0],objectives:[])
    battleRoster.slots[0] = OriginalPlacement(ordinal:0,person:0,x:1,y:1,selector:0,flag:0,flags:0,rawMode:255,parameter:65535,classID:255,level:255)
    battleRoster.slots[1] = OriginalPlacement(ordinal:1,person:1,x:3,y:3,selector:0,flag:0,flags:1,rawMode:0,parameter:0,classID:0,level:1)
    let battleDefinition = BattleDefinition(id:"synthetic-start",width:5,height:5,coordinateSystem:"orthogonal",tiles:Array(repeating:0,count:25))
    let initial = try OriginalBattleSession(definition:battleDefinition,roster:&battleRoster,people:people,combat:tables,movement:profile,rng:OriginalRNG(state:71))
    initial.units[0]!.mp = 3;initial.units[0]!.morale = 70;initial.units[0]!.position = GridPoint(x:2,y:1)
    initial.units[15]!.preferredTarget = 0;initial.units[15]!.goal = GridPoint(x:2,y:2)
    initial.turns.roundIndex = 2;initial.turns.weatherIndex = 3;initial.scriptValue24 = 9
    initial.terrain[12] = 8
    initial.pictureTiles = Array(repeating:4,count:100)
    initial.scriptActions.environment = [.init(point:GridPoint(x:2,y:2),encodedType:0,priorTerrain:0)]
    initial.scriptActions.markers = [GridPoint(x:2,y:2):45]
    try people.update(0) { $0.rawTroops = 7 }
    initial.sourceOptionsWord = 0x1014
    let starting = try OriginalBattleStartResume.capture(initial)
    var battleStage = saved;battleStage.palette = 3
    var battleState = vm.state;battleState.packedMap = 0x3000
    let state = OriginalCampaignCheckpoint(vm:battleState,people:people.values.values.sorted{$0.id < $1.id},roster:battleRoster,
        rng:initial.rng,money:500,stage:battleStage,liveUnits:initial.units.values.sorted{$0.slot < $1.slot},turns:initial.turns,battleValue24:9)
    let rebuiltPeople = try OriginalPeople(catalog:OriginalPersonCatalog(format:1,people:rows),tables:tables)
    var rebuiltRoster = battleRoster
    let rebuilt = try OriginalBattleSession(definition:battleDefinition,roster:&rebuiltRoster,people:rebuiltPeople,combat:tables,movement:profile,rng:OriginalRNG(state:0))
    try rebuiltPeople.restore(state.people)
    let startBytes = try JSONEncoder().encode(starting)
    let decodedStart = try JSONDecoder().decode(OriginalBattleStartResume.self,from:startBytes)
    try decodedStart.restore(state,in:rebuilt)
    try check(rebuilt.sourceOptionsWord == initial.sourceOptionsWord && rebuilt.restoredSourceOptions && rebuilt.resultLog.attemptID == initial.resultLog.attemptID,"battle-start resume preserves source option RNG policy and attempt identity")
    try check(rebuilt.units == initial.units && rebuilt.turns == initial.turns && rebuilt.rng == initial.rng,
              "battle-start roundtrip keeps positions, resources, orders, weather and RNG")
    try check(rebuilt.terrain == initial.terrain && rebuilt.pictureTiles == initial.pictureTiles && rebuilt.scriptActions == initial.scriptActions && rebuilt.scriptValue24 == 9,
              "battle-start roundtrip keeps scripted terrain, markers and battle value")
    try check(try rebuiltPeople.person(0).rawTroops == 7,"restoring people after construction preserves opening-script HP changes")
    var malformed = state;malformed.turns!.stage = .manualFriendly
    try check(rejected { try starting.restore(malformed,in:rebuilt) },"live manual-turn state cannot masquerade as a battle-start save")
    malformed = state;malformed.liveUnits!.append(malformed.liveUnits![0])
    try check(rejected { try starting.restore(malformed,in:rebuilt) },"duplicate battle slots are rejected")
    malformed = state;malformed.liveUnits![0].position = GridPoint(x:5,y:1)
    try check(rejected { try starting.restore(malformed,in:rebuilt) },"active units outside the battle map are rejected")
    malformed = state;malformed.battleValue24 = 256
    try check(rejected { try starting.restore(malformed,in:rebuilt) },"battle value width is validated before conversion")
    var loadSite = record
    loadSite.instructions = [OriginalCampaignInstruction(opcode:9,offset:12,kind:"load-map",arguments:[0x3000],commands:[],battleID:"synthetic-start")]
    let loadProgram = OriginalCampaignProgram(format:1,records:[loadSite],sourceDigest:"synthetic")
    var loadState = OriginalCampaignState();loadState.packedMap = 0x3000
    try check(starting.matchesSource(program:loadProgram,state:loadState),"battle identity must bind to a source load instruction")
    loadState.packedMap = 0x3001
    try check(!starting.matchesSource(program:loadProgram,state:loadState),"a different source map cannot share the saved battle identity")
    loadState.packedMap = 0x3000;loadState.block = 1
    try check(!starting.matchesSource(program:loadProgram,state:loadState),"a battle from another campaign block is rejected")
    var badStart = starting;badStart.terrain.removeLast()
    try check(rejected { try badStart.restore(state,in:rebuilt) },"incomplete battle terrain is rejected")
    badStart = starting;badStart.scriptActions.duel = OriginalScriptDuel(people:[0,1])
    try check(rejected { try badStart.restore(state,in:rebuilt) },"an active duel cannot be restored without its host continuation")
    let firstHook = try initial.beginRound(),restoredHook = try rebuilt.beginRound()
    try check(firstHook == restoredHook && initial.rng == rebuilt.rng && initial.turns == rebuilt.turns,
              "restored battle starts the same numbered turn and random-weather stream")
    try check(rejected { _ = try OriginalBattleStartResume.capture(initial) },"capture refuses a battle after its turn flow has started")
    let resume = OriginalCampaignResume(checkpoint:state,saveOffset:nil,controllerInvocationPending:false,controllerIdle:true,
        controllerAfterInvocationFacings:[],currentEventPerson:nil,carryover:nil,retryCheckpoint:nil,retryHost:nil,
        uncertainReturnContext:nil,limitations:[],battleStart:starting)
    let resumeBytes = try JSONEncoder().encode(resume)
    let decodedResume = try JSONDecoder().decode(OriginalCampaignResume.self,from:resumeBytes)
    try check(decodedResume.battleStart?.battleID == starting.battleID,"battle checkpoint discriminator survives save encoding")
    var legacy = try JSONSerialization.jsonObject(with:resumeBytes) as! [String:Any];legacy.removeValue(forKey:"battleStart")
    let legacyDecoded = try JSONDecoder().decode(OriginalCampaignResume.self,from:JSONSerialization.data(withJSONObject:legacy))
    try check(legacyDecoded.battleStart == nil,"legacy native save files decode without the optional battle-start section")
    try check(legacyDecoded.suspension == nil,"legacy native save files decode without a suspension section")
    // A provisional move, acted flags, turn and RNG all survive a mid-battle
    // suspension. Cancelling afterwards must still return to the saved origin.
    initial.turns.stage = .manualFriendly;initial.units[0]!.orderMode = 7
    initial.units[0]!.status = 2;initial.units[0]!.scriptFlags &= ~UInt8(0xC0)
    let flow = OriginalBattleFlow(session:initial)
    try check(flow.canSuspendCheckpoint,"an action-free manual turn is a resumable boundary")
    let moveOrigin = initial.units[0]!.position
    _ = try initial.move(0,to:GridPoint(x:2,y:0))
    let mid = initial.suspensionState()
    var midCheckpoint = state;midCheckpoint.liveUnits = initial.units.values.sorted{$0.slot < $1.slot}
    midCheckpoint.turns = initial.turns;midCheckpoint.rng = initial.rng
    try rebuilt.restoreSuspension(midCheckpoint,state:try JSONDecoder().decode(OriginalBattleSuspension.self,from:JSONEncoder().encode(mid)))
    try check(rebuilt.units == initial.units && rebuilt.turns == initial.turns && rebuilt.rng == initial.rng && rebuilt.pendingMovementSlots == [0],
              "mid-battle suspension preserves moved units, pending undo, turn and RNG")
    try rebuilt.cancelMove(0);try initial.cancelMove(0)
    try check(rebuilt.units == initial.units && rebuilt.units[0]!.position == moveOrigin && rebuilt.pendingMovementSlots.isEmpty,
              "move cancellation after resume returns to the exact prior square without consuming the action")
    // Once an atomic operation owns state, capture must wait for its tail.
    initial.units[15]!.position = GridPoint(x:2,y:2);initial.units[15]!.status = 2
    try people.update(1) { $0.rawTroops = 1 }
    _ = try flow.beginManualAttack(0,target:15)
    try check(!flow.canSuspendCheckpoint,"a half-completed attack cannot be captured as a player boundary")
    _ = try flow.finishManualOperation()
    try check(flow.canSuspendCheckpoint,"a completed attack returns to a resumable boundary")
    try check(!initial.retirements.isEmpty,"the completed synthetic attack delivers a retirement before suspension")
    var completed = midCheckpoint;completed.liveUnits = initial.units.values.sorted{$0.slot < $1.slot}
    completed.turns = initial.turns;completed.rng = initial.rng;completed.people = people.values.values.sorted{$0.id < $1.id}
    try rebuiltPeople.restore(completed.people);try rebuilt.restoreSuspension(completed,state:initial.suspensionState())
    let resumedFlow = OriginalBattleFlow(session:rebuilt)
    try check(resumedFlow.canSuspendCheckpoint && rebuilt.exchanges.count == initial.exchanges.count && rebuilt.retirements == initial.retirements,
              "resumed flow retains action history without re-delivering completed retirement events")
    try check(rejected { _ = try rebuilt.move(0,to:GridPoint(x:1,y:1)) },"a completed unit cannot gain another action by resuming")
    print("Native resume self-tests passed: \(checks)")
}
