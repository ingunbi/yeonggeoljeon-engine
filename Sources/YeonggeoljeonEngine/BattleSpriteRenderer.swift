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
        let selection = try catalog.standing(person:unit.person,classID:classID,enemy:unit.enemy,
            flags:unit.scriptFlags,animationPhase:phase)
        if let image = images[selection.image] { return image }
        let url = try containedResource(root:root,relative:selection.image)
        guard let picture = NSBitmapImageRep(data:try Data(contentsOf:url))?.cgImage,
              picture.width == 32,picture.height == 32 else { throw EngineError.invalid("Original battle sprite bitmap is not32×32") }
        images[selection.image] = picture;return picture
    }
    func duelImage(_ duel:OriginalScriptDuel,side:Int) throws -> CGImage {
        guard let catalog = catalog.duel,(0..<2).contains(side) else { throw EngineError.invalid("Original duel source catalog/side is unavailable") }
        let selection = try catalog.select(person:duel.people[side],loadMode:Int(duel.loadModes[side]),frame:Int(duel.frames[side]))
        if let image = images[selection.image] { return image }
        let url = try containedResource(root:root,relative:selection.image)
        guard let picture = NSBitmapImageRep(data:try Data(contentsOf:url))?.cgImage,picture.width == 96,picture.height == 96 else {
            throw EngineError.invalid("Original duel bitmap is not96×96")
        }
        images[selection.image] = picture;return picture
    }
}
