// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Source frame selection belongs to the sprite catalog. This adapter only
/// owns contained PNG loading and AppKit bitmap validation/cache lifetime.
final class OriginalBattleSpriteRenderer {
    let root:URL
    let catalog:OriginalBattleSprites
    private var images:[String:CGImage] = [:]
    init(root:URL) throws {
        self.root = root
        catalog = try OriginalBattleSprites.load(from:root.appendingPathComponent("battle-sprites.json"))
    }
    func image(unit:OriginalLiveUnit,classID:Int,phase:UInt8 = 0) throws -> CGImage {
        try picture(try catalog.standing(person:unit.person,classID:classID,enemy:unit.enemy,
            flags:unit.scriptFlags,animationPhase:phase))
    }
    /// The walking frame at `stepPixels` into a cell (MAIN2CCD5).
    func image(unit:OriginalLiveUnit,classID:Int,direction:Int,stepPixels:Int) throws -> CGImage {
        try picture(try catalog.moving(person:unit.person,classID:classID,enemy:unit.enemy,
            flags:unit.scriptFlags,direction:direction,stepPixels:stepPixels))
    }
    func effectImage(_ frame:Int) throws -> CGImage? {
        guard let paths = catalog.effects?.frames,paths.indices.contains(frame) else { return nil }
        return try loaded(paths[frame],size:32)
    }
    func shotImage(_ frame:Int) throws -> CGImage? {
        guard let paths = catalog.effects?.shots,paths.indices.contains(frame) else { return nil }
        return try loaded(paths[frame],size:16)
    }
    private func loaded(_ path:String,size:Int) throws -> CGImage {
        if let image = images[path] { return image }
        let url = try containedResource(root:root,relative:path)
        guard let picture = NSBitmapImageRep(data:try Data(contentsOf:url))?.cgImage,
              picture.width == size,picture.height == size else { throw EngineError.invalid("Original battle effect bitmap has the wrong size") }
        images[path] = picture;return picture
    }
    private func picture(_ selection:OriginalBattleSpriteSelection) throws -> CGImage {
        if let image = images[selection.image] { return image }
        let url = try containedResource(root:root,relative:selection.image)
        guard let picture = NSBitmapImageRep(data:try Data(contentsOf:url))?.cgImage,
              picture.width == 32,picture.height == 32 else { throw EngineError.invalid("Original battle sprite bitmap is not32×32") }
        images[selection.image] = picture;return picture
    }
    func duelImage(_ duel:OriginalScriptDuel,side:Int) throws -> CGImage {
        guard (0..<2).contains(side) else { throw EngineError.invalid("Original duel source catalog/side is unavailable") }
        return try duelImage(person:duel.people[side],loadMode:Int(duel.loadModes[side]),frame:Int(duel.frames[side]))
    }
    func duelImage(person:Int,loadMode:Int,frame:Int) throws -> CGImage {
        guard let catalog = catalog.duel else { throw EngineError.invalid("Original duel source catalog/side is unavailable") }
        let selection = try catalog.select(person:person,loadMode:loadMode,frame:frame)
        if let image = images[selection.image] { return image }
        let url = try containedResource(root:root,relative:selection.image)
        guard let picture = NSBitmapImageRep(data:try Data(contentsOf:url))?.cgImage,picture.width == 96,picture.height == 96 else {
            throw EngineError.invalid("Original duel bitmap is not96×96")
        }
        images[selection.image] = picture;return picture
    }
}
