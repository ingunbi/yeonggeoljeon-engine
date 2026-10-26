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
    original.advance(microseconds:1000)
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
    print("Native resume self-tests passed: \(checks)")
}
