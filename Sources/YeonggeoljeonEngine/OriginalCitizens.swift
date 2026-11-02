// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Town and room citizens, exported by tools/prepare_citizens.py. A citizen is
/// actor class 0x400; the runtime keeps them on ids from `firstActor` so they
/// cannot collide with the 384 people.
/// One citizen's wander state (MAIN25801..258CF). The source draws from the
/// shared generator once per frame in town, so its dice depend on time spent
/// there; this draws from its own generator so battles and replays stay exact.
struct OriginalCitizenWander:Equatable {
    var home:GridPoint
    var direction = 0
    var counter = 0
    var standing = false
    /// Advances one frame. A true `step` result asks to try that neighbor.
    mutating func tick(draw:(Int) -> Int) -> Bool {
        if counter == 0 {
            standing.toggle()
            var value:Int
            if !standing { direction = draw(4);value = draw(16)+1 } else { value = draw(2) }
            if value&1 == 0 || value == 0 { value += 1 }
            counter = value
        }
        counter -= 1
        return !standing
    }
    /// A blocked step ends the walk; three cells from home is as far as it goes.
    mutating func blocked() { counter = 0 }
    func allows(_ cell:GridPoint) -> Bool { abs(cell.x-home.x) <= 3 && abs(cell.y-home.y) <= 3 }
}

struct OriginalCitizenCatalog:Codable {
    struct Person:Codable { var name:String; var sprite:Int }
    struct Placement:Codable { var key:Int; var ids:[Int] }
    struct Group:Codable {
        var cityCount:Int
        var cities:[String:[Placement]]
        var lines:[String:String]
    }
    static let firstActor = 1024
    var format:Int
    var people:[Person]
    var groups:[Group]
    var source:JSONValue?
    var limitations:[String]?
    static func load(from url:URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
        guard value.format == 1,value.people.count == 256,value.groups.count == 4 else {
            throw EngineError.invalid("Original citizen catalog does not match its examined shape")
        }
        return value
    }
    /// One actor resource per citizen id, from the same town sprite sheets as people.
    func actors(sprites:[String]) -> [String:ActorResource] {
        var result:[String:ActorResource] = [:]
        for (id,person) in people.enumerated() where sprites.indices.contains(person.sprite) {
            result[String(Self.firstActor+id)] = ActorResource(image:sprites[person.sprite],frameWidth:32,frameHeight:40,frames:4,anchorX:0,anchorY:24,
                directions:[.init(frame:2,flip:true),.init(frame:0,flip:true),.init(frame:0,flip:false),.init(frame:2,flip:false)])
        }
        return result
    }
    /// MAIN2638B..263FA: each listed citizen takes a random even cell of plain
    /// ground, then a facing, then the placement's standing and speed draws.
    func placements(group:Int,city:Int,key:Int,width:Int,walk:[Int],rng:inout OriginalRNG) throws -> [Command] {
        guard groups.indices.contains(group),let row = groups[group].cities[String(city)]?.first(where:{$0.key == key}) else { return [] }
        guard walk.contains(127) else { return [] }
        var commands:[Command] = []
        for id in row.ids {
            var x = 0,y = 0
            repeat {
                x = try rng.next(bound:0x1F);if x&1 != 0 { x += 1 }
                y = try rng.next(bound:0x13);if y&1 != 0 { y += 1 }
            } while y*width+x >= walk.count || walk[y*width+x] != 127
            let facing = try rng.next(bound:4)
            _ = try rng.next(bound:16);_ = try rng.next(bound:3)
            commands.append(Command("place",person:Self.firstActor+id,x:x,y:y,sourcePlacementFacing:facing))
        }
        return commands
    }
    /// MAIN1FE97..1FF1E: the citizen's line for this city group.
    func say(group:Int,citizen id:Int) -> Command? {
        guard groups.indices.contains(group),people.indices.contains(id),let text = groups[group].lines[String(id)] else { return nil }
        var command = Command("say",text:text)
        command.speaker = people[id].name
        return command
    }
}
