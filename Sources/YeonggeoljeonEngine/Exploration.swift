// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct OriginalExplorationMap:Codable {
    var key:String; var kind:String; var sourceIndex:Int
    var image:String; var width:Int; var height:Int
    var walkWidth:Int; var walkHeight:Int; var walkBytes:[Int]; var walkGrid:[String]
    var viewport:[Int]; var objects:[MapObject]
    var neighborsEven:[Neighbor]?; var neighborsOdd:[Neighbor]?
    var source:JSONValue?
}
struct OriginalChapterMapping:Codable {
    var chapter:Int; var cityGroup:Int; var cityCount:Int; var cityBase:Int; var worldMapKey:String
}
struct OriginalCity:Codable {
    var chapter:Int; var id:Int; var name:String; var worldX:Int?; var worldY:Int?
    var worldPositionKnown:Bool; var worldMapKey:String; var townMapKey:String
    var sourceCityType:Int? = nil
}
struct OriginalExplorationCatalog:Codable {
    var format:Int; var maps:[OriginalExplorationMap]; var chapterMappings:[OriginalChapterMapping]
    var cities:[OriginalCity]; var actorBanks:[String:[String:ActorResource]]
    var worldNeighbors:[Neighbor]; var worldDirectionFrames:[Int]
    var worldPlacementDirections:[Int]? = nil
    /// Format2 keys world banks by the constructed person field2B, which is
    /// the SSCCHR1 member the source allocator loads (MAIN1FC24..18448).
    var worldBankKey:String?
    var source:JSONValue?; var limitations:[String]?
    static func load(from url:URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
        guard value.format == 2,value.worldBankKey == "person-field-2B" else {
            throw EngineError.invalid("Original exploration data predates person-field world banks; rebuild local GameData")
        }
        guard value.maps.count <= 256,Set(value.maps.map(\.key)).count == value.maps.count,
              value.worldNeighbors.count == 8,value.worldDirectionFrames.count == 8,
              value.worldDirectionFrames.allSatisfy({[0,2,4,6].contains($0)}),
              Set(value.chapterMappings.map(\.chapter)).count == value.chapterMappings.count else {
            throw EngineError.invalid("Original exploration catalog identities/directions are invalid")
        }
        for map in value.maps {
            guard ["town","world"].contains(map.kind),(1...4096).contains(map.width),(1...4096).contains(map.height),
                  map.walkWidth > 0,map.walkHeight > 0,map.walkWidth*map.walkHeight <= 65536,
                  map.walkGrid.count == map.walkHeight,map.walkGrid.allSatisfy({$0.count == map.walkWidth && $0.allSatisfy({$0 == "." || $0 == "#"})}) else {
                throw EngineError.invalid("Original exploration map dimensions/walk representation are invalid")
            }
        }
        return value
    }
    func map(packed:Int,chapter:Int) throws -> OriginalExplorationMap {
        let key:String
        if packed>>12 == 0 {
            guard let city = cities.first(where:{$0.chapter == chapter && $0.id == packed&0xFFF}) else {
                throw EngineError.invalid("Source city has no town-map selection")
            }
            key = city.townMapKey
        } else if packed>>12 == 1 {
            guard let mapping = chapterMappings.first(where:{$0.chapter == chapter}) else {
                throw EngineError.invalid("Source chapter has no world-map selection")
            }
            key = mapping.worldMapKey
        } else { throw EngineError.invalid("Source map kind is not exploration") }
        guard let map = maps.first(where:{$0.key == key}) else { throw EngineError.invalid("Original exploration map key is unavailable") }
        return map
    }
    func configure(stage:Runtime,packed:Int,chapter:Int,people:OriginalPeople) throws {
        let map = try self.map(packed:packed,chapter:chapter)
        let world = map.kind == "world"
        var resource = MapResource(image:map.image,width:map.width,height:map.height,viewport:map.viewport,
            walkWidth:map.walkWidth,walkHeight:map.walkHeight,walkGrid:map.walkGrid,walkBytes:map.walkBytes,
            neighborsEven:world ? worldNeighbors : map.neighborsEven,neighborsOdd:world ? worldNeighbors : map.neighborsOdd,objects:map.objects)
        resource.geometry = world ? "world" : nil
        // Source world movers execute each route nibble twice, at the traced
        // integer halfstep interval. Original DOS frame timing is unobserved.
        resource.stepMicroseconds = world ? 298_462 : nil
        if world {
            guard let directions = worldPlacementDirections,directions.count == 8,Set(directions) == Set(0..<8) else {
                throw EngineError.invalid("Original world placement direction producer is absent")
            }
            resource.placementDirections = directions
        }
        var actors = actorBanks["town"] ?? [:]
        if world {
            actors = [:]
            for person in people.values.values {
                guard var actor = actorBanks["world"]?[String(person.sourceRole)] else {
                    throw EngineError.invalid("Original world actor bank \(person.sourceRole) (person field2B) is not an exported SSCCHR1 world bank")
                }
                actor.directions = worldDirectionFrames.map { Direction(frame:$0,flip:false) }
                actors[String(person.id)] = actor
            }
        }
        try stage.configureMap(packed,resource:resource,actors:actors)
    }
}
