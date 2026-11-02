// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Synthetic checks for the slot importer. Real slots are checked locally, and
/// nothing here compares against a running original.
func originalSaveImportSelfTests() throws {
    var checks = 0
    func check(_ condition:@autoclosure()throws->Bool,_ message:String)throws {
        guard try condition() else { throw EngineError.invalid("Original save import regression: \(message)") };checks += 1
    }
    func rejected(_ operation:()throws->Void)->Bool { do { try operation();return false } catch { return true } }
    typealias Catalog = OriginalSaveCatalog
    let row = Catalog.Person(flags:0x81,role:4,context2:1,context3:2,personal:120,troops:9000,classID:6,level:12,experience:33,itemIDs:[1,2,3,4,5,6,7,8])
    var people = Array(repeating:row,count:384)
    people[9].flags = 1
    let blankSetup = Catalog.Setup(person:0,x:0,y:0,flags:0,rawMode:0,parameter:0,classID:0,level:0)
    let script = Catalog.Script(chapter:2,member:1,block:6,groupBase:20,cacheCity:7,cacheMap:0x2004,
        cache:Array(repeating:OriginalCampaignCachedActor(),count:62),cursor:50,busy:0,cacheDirty:0,music:11,
        setup:Array(repeating:blankSetup,count:45),flags:Array(repeating:0,count:32),sourceList:[40],objective:"goal",turnLimit:0,sourceByte2:0)
    let actors = [Catalog.Actor(index:0,word:0x205,x:12,y:3,flags:4,facing:0),Catalog.Actor(index:3,word:0x201,x:4,y:5,flags:0x15,facing:0),
                  Catalog.Actor(index:4,word:0x209,x:4,y:6,flags:0x15,facing:1),Catalog.Actor(index:6,word:0x403,x:6,y:7,flags:5,facing:3)]
    let slot = Catalog.Slot(slot:0,date:.init(year:99,month:7,day:25,hour:13,minute:8),title:"t",
        player:.init(money:1234,inputEnable:1,music:0xFFFF,city:5,chapter:2),game:.init(x:11,y:13,city:7,kind:2,index:4),
        returnPlace:.init(x:8,y:15,city:3,kind:0,index:9),actors:actors,people:people,
        cityFlags:(0..<32).map { $0 == 2 ? 3 : 1 },script:script)
    let prompt = OriginalCampaignInstruction(opcode:0x3D,offset:40,kind:"save-prompt",arguments:[1],commands:[])
    let next = OriginalCampaignInstruction(opcode:0xFF,offset:50,kind:"end-record",arguments:[],commands:[])
    let other = OriginalCampaignInstruction(opcode:0x17,offset:60,kind:"host",arguments:[1],commands:[])
    let record = OriginalCampaignRecord(id:"r",chapter:2,member:1,block:6,ordinal:0,kind:0,inverted:false,rawKind:0,words:[0,0,0],
        group:OriginalCampaignGroup(base:20,count:1,repeating:false),instructions:[prompt,next,other,next])
    let base = (0..<384).map {
        OriginalPersonDefinition(id:$0,name:"p\($0)",classID:0,level:1,experience:0,rawTroops:0,defenseScalar:50,attackScalar:60,
            intellectScalar:70,personality:3,personalScalar:0,itemIDs:Array(repeating:255,count:8),sourceFlags:0,sourceRole:0,
            sourceContext2:0,sourceContext3:0,source:nil)
    }
    let facts = OriginalSaveFacts(program:OriginalCampaignProgram(format:1,records:[record]),people:base,
        maxTroops:{ _,_ in 5000 },cityCount:4,firstActorSlot:3,worldCells:nil,rng:OriginalRNG(state:7))

    let idle = try slot.resume(facts:facts),state = idle.checkpoint.vm
    try check(idle.saveOffset == nil && idle.controllerIdle && !idle.controllerInvocationPending && state.pending == nil,"a clear busy word rejoins the idle field")
    try check(state.currentRecordID == nil && state.instructionIndex == 0 && state.invocationActive == nil,"an idle slot holds no cursor")
    try check(state.packedMap == 0x2004 && state.city == 7 && state.gameCity == 7 && state.currentCity == 5,"map context comes from the game block")
    try check(state.chapter == 2 && state.member == 1 && state.block == 6 && state.groupBase == 20,"script position comes from the context")
    try check(state.cityFlags == [1,1,3,1] && state.cityFlagsChapter == 2,"only the chapter's cities are read")
    try check(state.returnContext == OriginalCampaignReturnContext(packedMap:9,x:8,y:15),"the return block keeps its real cell")
    try check(state.currentMusic == nil && state.music == 11 && state.automatic,"music words and the input enable stay separate")
    try check(state.sourceList == [40] && state.objectiveText == "goal" && !state.actorCacheDirty,"script lists survive")
    try check(idle.checkpoint.money == 1234 && idle.checkpoint.rng == OriginalRNG(state:7),"money is saved and the RNG comes from the caller")
    let person = idle.checkpoint.people[1]
    try check(person.sourceRole == 6 && person.sourceFlags == 0x81 && person.sourceContext2 == 1 && person.sourceContext3 == 2,"person state uses the constructed domain")
    try check(person.attackScalar == 60 && person.defenseScalar == 50 && person.intellectScalar == 70 && person.name == "p1","constants stay with the catalog")
    try check(person.rawTroops == 5000 && person.personalScalar == 100,"the constructor clamps apply")
    try check(person.itemIDs == [1,2,3,4,5,6,7,8] && person.level == 12 && person.experience == 33 && person.classID == 6,"progress is restored")

    let placed = idle.checkpoint.stage
    try check(placed.actors.map(\.person) == [1,OriginalCitizenCatalog.firstActor+3],"props, unjoined people and tags are resolved")
    try check(placed.actors.map(\.registration) == [0,1],"slot gaps close")
    try check(placed.actors.map(\.facing) == [2,0],"town facings pass through DS:38D8")
    try check(placed.camera == [0,0] && placed.followPerson == nil && placed.palette == 2 && placed.map == 0x2004 && placed.visible,"a palace enters at the origin")

    var world = slot;world.game = .init(x:11,y:13,city:0,kind:1,index:3);world.player.city = 12
    world.actors = [.init(index:0,word:0x205,x:40,y:84,flags:0x15,facing:6),.init(index:1,word:0x229,x:58,y:54,flags:0x15,facing:5)]
    world.people[0x29].flags = 0x80
    var worldFacts = facts;worldFacts.firstActorSlot = 0;worldFacts.worldCells = (128,128)
    let open = try world.resume(facts:worldFacts).checkpoint.stage
    try check(open.actors.map(\.position) == [GridPoint(x:40,y:84),GridPoint(x:58,y:54)] && open.actors.map(\.facing) == [6,5],"world actors keep the doubled pair and facing")
    try check(open.followPerson == 5 && open.camera == [25*16,74*16],"the camera follows the first actor")
    try check(try world.resume(facts:worldFacts).checkpoint.vm.currentCity == 12,"the world keeps the player's city")

    var busy = slot;busy.script.busy = 1
    let continuing = try busy.resume(facts:facts),waiting = continuing.checkpoint.vm
    try check(continuing.saveOffset == 40 && continuing.controllerInvocationPending && !continuing.controllerIdle,"a busy slot resumes after its prompt")
    try check(waiting.currentRecordID == "r" && waiting.instructionIndex == 1 && waiting.pending?.kind == "host" && waiting.pending?.opcode == 0x3D && waiting.pending?.offset == 40,"the cursor resolves to the prompt")
    try check(waiting.invocationActive == true && waiting.invocationNormalStatus == 1,"the invocation is open again")

    var stale = busy;stale.script.cursor = 60
    try check(rejected { _ = try stale.resume(facts:facts) },"a busy cursor away from a prompt is refused")
    stale.script.cursor = 51
    try check(rejected { _ = try stale.resume(facts:facts) },"an unresolved cursor is refused")
    var movement = slot;movement.script.busy = 2
    try check(rejected { _ = try movement.resume(facts:facts) },"a movement wait is refused")
    var battle = slot;battle.game.kind = 3
    try check(rejected { _ = try battle.resume(facts:facts) },"a battle slot is refused")
    var chapter = slot;chapter.player.chapter = 3
    try check(rejected { _ = try chapter.resume(facts:facts) },"disagreeing chapters are refused")
    var rich = slot;rich.player.money = 10001
    try check(rejected { _ = try rich.resume(facts:facts) },"money above the setter's clamp is refused")
    var tagged = slot;tagged.actors = [.init(index:3,word:0x601,x:1,y:1,flags:4,facing:0)]
    try check(rejected { _ = try tagged.resume(facts:facts) },"an unknown actor tag is refused")
    var facing = slot;facing.actors = [.init(index:3,word:0x201,x:1,y:1,flags:4,facing:4)]
    try check(rejected { _ = try facing.resume(facts:facts) },"a facing outside DS:38D8 is refused")

    var dirty = slot;dirty.script.cacheDirty = 1;dirty.player.music = 5
    dirty.script.cache[1] = OriginalCampaignCachedActor(person:1,x:9,y:9,flags:0,sourceFacing:6)
    dirty.script.cache[2] = OriginalCampaignCachedActor(person:7,x:8,y:8,flags:0,sourceFacing:4)
    let replayed = try dirty.resume(facts:facts).checkpoint
    try check(!replayed.vm.actorCacheDirty && replayed.vm.currentMusic == 11,"a dirty owned cache selects its music")
    try check(replayed.stage.actors.first(where:{$0.person == 1})?.position == GridPoint(x:9,y:9) && replayed.stage.actors.first(where:{$0.person == 1})?.facing == 3,"cached actors move")
    try check(replayed.stage.actors.first(where:{$0.person == 7})?.registration == 2,"cached actors are added last")
    var foreign = dirty;foreign.script.cacheDirty = 0;foreign.script.cacheMap = 0x2005
    let unowned = try foreign.resume(facts:facts).checkpoint
    try check(unowned.vm.actorCacheDirty && unowned.vm.currentMusic == 5 && unowned.stage.actors.count == 2,"a foreign cache only becomes dirty")

    try check(idle.checkpoint.roster.header == nil && idle.checkpoint.roster.slots.count == 45,"a slot before any setup has no header")
    var armed = slot;armed.script.turnLimit = 30;armed.script.sourceByte2 = 1
    armed.script.setup[0] = .init(person:0x123,x:4,y:5,flags:1,rawMode:2,parameter:0x1234,classID:6,level:8)
    let roster = try armed.resume(facts:facts).checkpoint.roster
    try check(roster.header?.turnLimit == 30 && roster.header?.sourceByte2 == 1 && roster.header?.preserveFriendlySlots == false,"the saved header survives")
    try check(roster.header?.objectives == [OriginalObjective(eventKind:7,enabled:false,person:0),OriginalObjective(eventKind:8,enabled:false,person:0)],"objective persons have no slot storage")
    try check(roster.slots[0] == OriginalPlacement(ordinal:-1,person:0x123,x:4,y:5,selector:255,flag:255,flags:1,rawMode:2,parameter:0x1234,classID:6,level:8),"setup rows stay literal")
    print("Original save import self-tests passed: \(checks) checks")
}
