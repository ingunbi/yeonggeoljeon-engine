// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Typed slot facts from tools/prepare_saves.py. The engine never opens an
/// MSAVEn or ESAVEn file: it reads the local export and writes nothing back.
struct OriginalSaveCatalog:Codable {
    struct Stamp:Codable,Equatable { var year:Int; var month:Int; var day:Int; var hour:Int; var minute:Int }
    struct Player:Codable { var money:Int; var inputEnable:Int; var music:Int; var city:Int; var chapter:Int }
    struct Place:Codable {
        var x:Int; var y:Int; var city:Int; var kind:Int; var index:Int
        var packedMap:Int { kind<<12|index }
    }
    struct Actor:Codable { var index:Int; var word:Int; var x:Int; var y:Int; var flags:Int; var facing:Int }
    struct Person:Codable {
        var flags:Int; var role:Int; var context2:Int; var context3:Int; var personal:Int; var troops:Int
        var classID:Int; var level:Int; var experience:Int; var itemIDs:[Int]
    }
    struct Setup:Codable {
        var person:Int; var x:Int; var y:Int; var flags:Int; var rawMode:Int; var parameter:Int; var classID:Int; var level:Int
    }
    struct Script:Codable {
        var chapter:Int; var member:Int; var block:Int; var groupBase:Int
        var cacheCity:Int; var cacheMap:Int; var cache:[OriginalCampaignCachedActor]
        var cursor:Int; var busy:Int; var cacheDirty:Int; var music:Int
        var setup:[Setup]; var flags:[Int]; var sourceList:[Int]; var objective:String?
        var turnLimit:Int; var sourceByte2:Int
    }
    struct Slot:Codable {
        var slot:Int; var date:Stamp; var title:String; var player:Player
        var game:Place; var returnPlace:Place; var actors:[Actor]; var people:[Person]
        var cityFlags:[Int]; var script:Script
    }
    struct Refusal:Codable { var slot:Int; var reason:String }
    var format:Int; var slots:[Slot]; var refused:[Refusal]

    /// A folder without slots exports none, and older GameData has no file.
    static func load(root:URL) throws -> Self {
        let url = root.appendingPathComponent("saves.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return Self(format:1,slots:[],refused:[]) }
        let value = try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
        guard value.format == 1 else { throw EngineError.invalid("Original save export has an unsupported format") }
        return value
    }
}

/// What a slot does not store, from the loaded program, catalogs and map.
struct OriginalSaveFacts {
    var program:OriginalCampaignProgram
    /// BAKDATA rows; a slot stores only person state, not constants.
    var people:[OriginalPersonDefinition]
    var maxTroops:(_ classID:Int,_ level:Int) throws -> Int
    var cityCount:Int
    /// Town and palace slots below this hold props and a marker (MAIN24694..2476C).
    var firstActorSlot:Int
    /// World size in cells, for the camera the source rebuilds on entry.
    var worldCells:(width:Int,height:Int)?
    var rng:OriginalRNG
}

extension OriginalSaveCatalog.Slot {
    /// DS:38D8 maps a saved town facing index to a placement facing index.
    private static let townFacings = [2,3,1,0]

    /// CF5:B34E, then the first pass of CF5:A88C(1). A busy slot continues
    /// after its 3D 01; every other slot rejoins the idle field, which is what
    /// makes the tail of a 3D 00 record unreachable after a load. No RNG, live
    /// unit, retry buffer or preserve byte exists in the files.
    func resume(facts:OriginalSaveFacts) throws -> OriginalCampaignResume {
        guard [0,1,2].contains(game.kind) else { throw EngineError.invalid("Original slot was not taken outside battle") }
        guard (0...1).contains(script.busy) else { throw EngineError.invalid("Original slot holds a movement wait") }
        guard player.chapter == script.chapter else { throw EngineError.invalid("Original slot chapters disagree") }
        guard (0...10000).contains(player.money) else { throw EngineError.invalid("Original slot money is outside its source range") }
        guard people.count == 384,facts.people.count == 384,script.setup.count == 45,script.flags.count == 32,
              (1...cityFlags.count).contains(facts.cityCount) else {
            throw EngineError.invalid("Original slot tables differ from the examined sizes")
        }
        let packed = game.packedMap,world = game.kind == 1
        var vm = OriginalCampaignState()
        vm.chapter = script.chapter;vm.member = script.member;vm.block = script.block;vm.groupBase = script.groupBase
        vm.packedMap = packed;vm.city = game.city;vm.currentCity = player.city;vm.gameCity = game.city
        vm.cityFlags = cityFlags.prefix(facts.cityCount).map { UInt8($0&255) };vm.cityFlagsChapter = script.chapter
        vm.returnContext = OriginalCampaignReturnContext(packedMap:returnPlace.packedMap,x:returnPlace.x,y:returnPlace.y)
        vm.flags = script.flags.map { UInt8($0&255) }
        vm.automatic = player.inputEnable != 0
        vm.music = script.music == 0xFFFF ? nil : script.music
        vm.currentMusic = player.music == 0xFFFF ? nil : player.music
        vm.objectiveText = script.objective;vm.sourceList = script.sourceList
        vm.actorCache = script.cache;vm.actorCacheCity = script.cacheCity;vm.actorCacheMap = script.cacheMap
        vm.actorCacheDirty = script.cacheDirty != 0
        var saveOffset:Int?
        if script.busy == 1 {
            let found = facts.program.records.lazy.filter {
                $0.chapter == script.chapter && $0.member == script.member && $0.block == script.block
            }.compactMap { record -> (OriginalCampaignRecord,Int)? in
                guard let index = record.instructions.firstIndex(where:{$0.offset == script.cursor}),index > 0,
                      record.instructions[index-1].opcode == 0x3D,record.instructions[index-1].kind == "save-prompt" else { return nil }
                return (record,index)
            }.first
            guard let (record,index) = found else { throw EngineError.invalid("Original busy slot does not continue after a save prompt") }
            let offset = record.instructions[index-1].offset
            vm.currentRecordID = record.id;vm.instructionIndex = index
            vm.pending = CampaignVMPending(kind:"host",recordID:record.id,offset:offset,opcode:0x3D,choice:nil)
            vm.invocationActive = true;vm.invocationNormalStatus = 1
            saveOffset = offset
        }
        let constructed = try restoredPeople(facts:facts)
        var actors = try restoredActors(people:constructed,facts:facts)
        if !world {
            let replay = CampaignVM.settlementCacheReplay(&vm)
            for row in replay.actors {
                guard (1..<384).contains(row.person),(0..<8).contains(row.sourceFacing) else {
                    throw EngineError.invalid("Original slot cached actor has unsupported placement fields")
                }
                let position = GridPoint(x:row.x,y:row.y),facing = row.sourceFacing>>1
                if let at = actors.firstIndex(where:{$0.person == row.person}) { actors[at].position = position;actors[at].facing = facing }
                else { actors.append(ActorState(person:row.person,position:position,facing:facing,phase:0,registration:actors.count,walking:false)) }
            }
            if let music = replay.music { vm.currentMusic = music }
        }
        var camera = [0,0]
        if world,let first = actors.first,let cells = facts.worldCells {
            camera = Runtime.worldCameraOrigin(first.position,width:cells.width,height:cells.height)
        }
        let stage = Snapshot(mode:"scene",microseconds:0,nextCommand:0,map:packed,camera:camera,blackAlpha:0,actors:actors,dialogue:nil,
            // CF5:B34E reads the slot title back into the HUD caption DS:DB4C (0x1ED38).
            batch:nil,endReason:nil,inputCount:0,visible:true,caption:title.isEmpty ? nil : title,termination:nil,followPerson:world ? actors.first?.person : nil,
            storyPanel:nil,palette:game.kind)
        let checkpoint = OriginalCampaignCheckpoint(vm:vm,people:constructed,roster:restoredRoster(),rng:facts.rng,money:player.money,
            stage:stage,liveUnits:nil,turns:nil,battleValue24:nil)
        return OriginalCampaignResume(checkpoint:checkpoint,saveOffset:saveOffset,controllerInvocationPending:script.busy == 1,
            controllerIdle:script.busy == 0,controllerAfterInvocationFacings:[],currentEventPerson:nil,carryover:nil,
            retryCheckpoint:nil,retryHost:nil,uncertainReturnContext:nil,
            limitations:["Imported read-only from an original slot; RNG, live units, the retry buffer and the preserve byte have no slot storage."])
    }
    /// CF5:A9CA rebuilds a person from BAKDATA constants plus the slot state.
    private func restoredPeople(facts:OriginalSaveFacts) throws -> [OriginalPersonDefinition] {
        try zip(facts.people.sorted { $0.id < $1.id },people).map { base,saved in
            var person = base
            person.sourceFlags = saved.flags;person.sourceRole = (saved.role+2)&0xFF
            person.sourceContext2 = saved.context2;person.sourceContext3 = saved.context3
            person.personalScalar = min(saved.personal,100)
            person.classID = saved.classID;person.level = saved.level;person.experience = saved.experience
            person.rawTroops = min(saved.troops,try facts.maxTroops(saved.classID,saved.level))
            person.itemIDs = saved.itemIDs
            return person
        }
    }
    /// MAIN20E5E and MAIN24AA4 respawn saved actors in slot order, so slot
    /// gaps close. A person whose joined bit is clear does not spawn (CF5:EED2).
    private func restoredActors(people:[OriginalPersonDefinition],facts:OriginalSaveFacts) throws -> [ActorState] {
        var result:[ActorState] = []
        for row in actors where row.index >= facts.firstActorSlot {
            let id = row.word&0x1FF,person:Int
            switch row.word&0xE00 {
            case 0x200:
                guard people.indices.contains(id) else { throw EngineError.invalid("Original slot actor names an unknown person") }
                guard people[id].sourceFlags&0x80 != 0 else { continue }
                person = id
            case 0x400:person = OriginalCitizenCatalog.firstActor+id
            default:throw EngineError.invalid("Original slot actor has an unsupported tag")
            }
            let facing:Int
            if game.kind == 1 {
                guard (0..<8).contains(row.facing) else { throw EngineError.invalid("Original slot world facing is outside its table") }
                facing = row.facing
            } else {
                guard Self.townFacings.indices.contains(row.facing) else { throw EngineError.invalid("Original slot town facing is outside DS:38D8") }
                facing = Self.townFacings[row.facing]
            }
            result.append(ActorState(person:person,position:GridPoint(x:row.x,y:row.y),facing:facing,phase:0,registration:result.count,walking:false))
        }
        return result
    }
    /// A title load leaves context+1CB and the objective pairs zero, so a
    /// header restored here cannot preserve slots or enable an objective.
    private func restoredRoster() -> OriginalRoster {
        var roster = OriginalRoster()
        roster.slots = script.setup.map {
            OriginalPlacement(ordinal:-1,person:$0.person,x:$0.x,y:$0.y,selector:255,flag:255,flags:$0.flags,
                              rawMode:$0.rawMode,parameter:$0.parameter,classID:$0.classID,level:$0.level)
        }
        let blank = script.setup.allSatisfy {
            [$0.person,$0.x,$0.y,$0.flags,$0.rawMode,$0.parameter,$0.classID,$0.level].allSatisfy { $0 == 0 }
        }
        if !blank || script.turnLimit != 0 || script.sourceByte2 != 0 {
            roster.header = OriginalBattleHeader(preserveFriendlySlots:false,turnLimit:script.turnLimit,sourceByte2:script.sourceByte2,
                discardedBytes:[0,0],objectives:[7,8].map { OriginalObjective(eventKind:$0,enabled:false,person:0) })
        }
        return roster
    }
}
