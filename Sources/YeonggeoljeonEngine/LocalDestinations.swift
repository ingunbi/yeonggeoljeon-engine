// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum LocalDestinations {
    struct Entry:Equatable {
        var packedMap:Int;var person:Int?;var point:GridPoint;var marker:Int?;var name:String;var walking:Bool
    }
    static func entries(packedMap:Int,visible:Bool,map:MapResource,actors:[ActorState],names:[Int:String]) throws -> [Entry] {
        guard [0,2].contains(packedMap>>12),visible else {return []}
        guard let width = map.walkWidth,let height = map.walkHeight,let bytes = map.walkBytes,
              width > 0,height > 0,width <= 1024,height <= 1024,bytes.count == width*height else {
            throw EngineError.invalid("Nearby destinations need the current map's source walk markers")
        }
        var result = actors.filter {$0.person != 0}.sorted {$0.registration < $1.registration}.map {actor in
            Entry(packedMap:packedMap,person:actor.person,point:actor.position,marker:nil,
                name:names[actor.person] ?? "인물 \(actor.person)",walking:actor.walking)
        }
        for (index,marker) in bytes.enumerated() where marker >= 0 && marker < 126 {
            let title = marker == 124 ? "세계지도로 나가는 출구" : marker == 125 ? "돌아가는 출구" : "입구"
            // Every entrance cell stays explicit. Two cells with the same
            // marker must not silently become one guessed nearest doorway.
            result.append(.init(packedMap:packedMap,person:nil,point:.init(x:index%width,y:index/width),marker:marker,name:title,walking:false))
        }
        return result
    }
}
