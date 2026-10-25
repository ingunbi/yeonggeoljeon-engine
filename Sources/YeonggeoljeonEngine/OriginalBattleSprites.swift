// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private func validateNativeSpritePaths(_ values:[String]) throws {
    var paths = Set<String>()
    for path in values {
        guard !path.isEmpty,!path.hasPrefix("/"),!path.contains(":"),!path.contains("\\"),
              path.split(separator:"/",omittingEmptySubsequences:false).allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}),
              paths.insert(path).inserted else {throw EngineError.invalid("Original sprite path is not a unique contained relative path")}
    }
}

struct OriginalBattleSpriteFrame:Codable {
    var member:Int
    var frame:Int
    var image:String
    var flippedImage:String
    var indexedPixelSha256:String?
    var source:JSONValue?
}
struct OriginalBattleSpriteSelection:Equatable {
    var member:Int
    var frame:Int
    var flipped:Bool
    /// Contained relative path of an already oriented image. Pixel zero
    /// has source-mask alpha0; the renderer must preserve nearest-neighbor pixels.
    var image:String
}
struct OriginalBattleSprites:Codable {
    var format:Int
    var width:Int
    var height:Int
    var memberCount:Int
    var paletteSlot:Int
    var frames:[OriginalBattleSpriteFrame]
    var duel:OriginalDuelSprites? = nil
    var source:JSONValue?
    var limitations:[String]?

    static func load(from url:URL) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
        guard let size = attributes[.size] as? NSNumber,(1...2*1024*1024).contains(size.intValue) else {
            throw EngineError.invalid("Original battle sprite catalog exceeds its source resource budget")
        }
        let value = try JSONDecoder().decode(Self.self,from:Data(contentsOf:url));try value.validate();return value
    }
    func validate() throws {
        guard format == 1,width == 32,height == 32,memberCount == 47,paletteSlot == 3,frames.count == memberCount*2 else {
            throw EngineError.invalid("Original battle sprite catalog dimensions/cardinality/palette are invalid")
        }
        var identities = Set<Int>()
        for frame in frames {
            guard (0..<memberCount).contains(frame.member),(0..<2).contains(frame.frame),
                  identities.insert(frame.member*2+frame.frame).inserted else {
                throw EngineError.invalid("Original battle sprite frame identity is absent or repeated")
            }
        }
        try validateNativeSpritePaths(frames.flatMap{[$0.image,$0.flippedImage]})
        try duel?.validate()
    }
    /// MAIN2B7C4: condition2 takes precedence over person-specific sprites;
    /// native faction derives from the runtime slot, not the shared person flags.
    func select(person:Int,classID:Int,enemy:Bool,flags:UInt8,frame:Int) throws -> OriginalBattleSpriteSelection {
        guard (0...65535).contains(person),(0..<19).contains(classID),(0..<2).contains(frame) else {
            throw BattleError.invalid("Original battle sprite person/class/frame operand is outside its source domain")
        }
        let member:Int
        if flags&2 != 0 {member = 43+(enemy ? 1 : 0)}
        else if person == 0 {member = 38+classID}
        else if person == 4 {member = 45}
        else if person == 8 {member = 46}
        else {member = classID*2+(enemy ? 1 : 0)}
        guard (0..<memberCount).contains(member),let picture = frames.first(where:{$0.member == member && $0.frame == frame}) else {
            throw BattleError.unsupported("Original native sprite selection references an unavailable archive member")
        }
        let flipped = flags&0x10 != 0
        return OriginalBattleSpriteSelection(member:member,frame:frame,flipped:flipped,image:flipped ? picture.flippedImage : picture.image)
    }
    /// MAIN2A0E0 uses battle object byte5 and live acted flag80. The phase is
    /// explicit: wall-clock timing must not be invented in the pixel selector.
    func standing(person:Int,classID:Int,enemy:Bool,flags:UInt8,animationPhase:UInt8) throws -> OriginalBattleSpriteSelection {
        try select(person:person,classID:classID,enemy:enemy,flags:flags,frame:animationPhase == 0 && flags&0x80 == 0 ? 0 : 1)
    }
    /// MAIN2C79A/2C7A1 and2CCD5/2CEB4. Source directions are the movement
    /// owner's ordered N/E/S/W, not four independent graphic directions.
    static func movementFlags(_ flags:UInt8,direction:Int) throws -> UInt8 {
        guard (0..<4).contains(direction) else {throw BattleError.invalid("Original battle sprite movement direction is outside0...3")}
        if direction == 1 {return flags & ~UInt8(0x10)}
        if direction == 3 {return flags | 0x10}
        return flags
    }
    func moving(person:Int,classID:Int,enemy:Bool,flags:UInt8,direction:Int,stepPixels:Int) throws -> OriginalBattleSpriteSelection {
        guard (0...32).contains(stepPixels) else {throw BattleError.invalid("Original battle sprite movement step is outside its32-pixel source cell")}
        return try select(person:person,classID:classID,enemy:enemy,flags:Self.movementFlags(flags,direction:direction),frame:stepPixels&15 < 8 ? 0 : 1)
    }
}

struct OriginalDuelSpriteFrame:Codable {
    var member:Int
    var image:String
    var flippedImage:String
    var indexedPixelSha256:String?
    var source:JSONValue?
}
struct OriginalDuelSprites:Codable {
    var width:Int
    var height:Int
    var memberCount:Int
    var frames:[OriginalDuelSpriteFrame]
    var specialPersonBanks:[Int]
    var source:JSONValue?
    /// MAIN2A324..2A415 draws26x13 tiles at DOS pixel(16,32).
    static let sourceViewport = CGRect(x:16,y:32,width:416,height:208)
    /// Source0:7002 composites tile layers0 then1;34216 stores participant1
    /// in layer0 and participant0 in layer1. Participant0 appears in front.
    static let sourceDrawOrder = [1,0]
    static func sourceRect(duel:OriginalScriptDuel,side:Int) throws -> CGRect {
        guard (0..<2).contains(side),duel.positions.count == 2,duel.rows.count == 2 else {
            throw BattleError.invalid("Original duel presentation position/side shape")
        }
        // Positions are already shifted by the source camera producer. The
        // camera byte scrolls the background and must not be subtracted again.
        return CGRect(x:16+Int(duel.positions[side])*16,y:32+Int(duel.rows[side])*16,width:96,height:96)
    }
    func validate() throws {
        guard width == 96,height == 96,memberCount == 78,frames.count == memberCount,
              Set(frames.map(\.member)) == Set(0..<memberCount),specialPersonBanks.count == 5,
              specialPersonBanks.allSatisfy({(0...255).contains($0)}) else {
            throw EngineError.invalid("Original duel sprite catalog geometry/member identity is invalid")
        }
        try validateNativeSpritePaths(frames.flatMap{[$0.image,$0.flippedImage]})
    }
    /// MAIN3431C mode selects the participant bank, loaded frame span and flip.
    /// Modes2/3 replace participant1's buffer with death/flee graphic sequences;
    /// a pose index alone cannot identify the original picture after that load.
    func select(person:Int,loadMode:Int,frame:Int) throws -> OriginalBattleSpriteSelection {
        guard (0...65535).contains(person),(0...3).contains(loadMode) else {throw BattleError.invalid("Original duel sprite person/load mode is invalid")}
        let side = loadMode == 0 ? 0 : 1,count = loadMode == 2 ? 5 : loadMode == 3 ? 3 : 10
        guard (0..<count).contains(frame) else {throw BattleError.invalid("Original duel frame is outside its loaded source span")}
        let base:Int
        if person < 5,specialPersonBanks[person] != 255 {base = specialPersonBanks[person]*15}
        else if person == 372 {base = 30}
        else if person == 373 {base = 45}
        else {base = side*15}
        let member = base+(loadMode == 2 ? 10 : loadMode == 3 ? 1 : 0)+frame
        guard let picture = frames.first(where:{$0.member == member}) else {throw BattleError.unsupported("Original duel source bank references an unavailable graphic")}
        let flipped = loadMode == 1 || loadMode == 2
        return OriginalBattleSpriteSelection(member:member,frame:frame,flipped:flipped,image:flipped ? picture.flippedImage : picture.image)
    }
}
