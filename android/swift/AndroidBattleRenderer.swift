// SPDX-License-Identifier: GPL-3.0-only
// The battle map as one picture, 32 pixels a cell: the original backdrop, any
// terrain the story changed, unit sprites, range cells and the action that is
// playing. The Android app only scales and pans it. Mirrors the iPad drawing.
#if os(Android)
import Foundation

private struct AtlasCatalog:Decodable {
    struct Atlas:Decodable {var id:String;var image:String;var tileCount:Int;var columns:Int;var sha256:String}
    var format:Int;var tileSize:Int;var atlases:[Atlas];var mapImages:[String:String]
}

final class AndroidBattleRenderer {
    private var key:String?
    private var backdrop:CGImage?
    private var baseline:[UInt8] = []
    private var tiles:[Int:CGImage] = [:]
    private var sprites:OriginalBattleSpriteRenderer?
    private var font:OriginalFont?
    private let cell = 32

    private func load(_ data:DataSet,_ path:String) throws -> CGImage {
        let bytes = try Data(contentsOf:data.containedFile(path))
        guard let image = PNGReader.decode(bytes) else {throw EngineError.invalid("전장 그림을 읽을 수 없습니다: "+path)}
        return image
    }
    private func prepare(session:OriginalBattleSession,data:DataSet) {
        key = data.root.path+"/"+session.definition.id
        backdrop = nil;tiles = [:];sprites = nil
        baseline = (session.definition.pictureTiles ?? []).compactMap(UInt8.init(exactly:))
        font = OriginalFont.load(data)
        if let path = session.definition.image,let image = try? load(data,path) {
            backdrop = image
            if let list = try? Data(contentsOf:data.containedFile("battle-tile-atlases.json")),
               let catalog = try? JSONDecoder().decode(AtlasCatalog.self,from:list),catalog.format == 1,catalog.tileSize == 16,
               let id = catalog.mapImages[path],let atlas = catalog.atlases.first(where:{$0.id == id}),
               let full = try? load(data,atlas.image),(1...16).contains(atlas.columns) {
                for index in 0..<atlas.tileCount {
                    tiles[index] = full.cropping(to:CGRect(x:(index%atlas.columns)*16,y:(index/atlas.columns)*16,width:16,height:16))
                }
            }
        }
        sprites = try? OriginalBattleSpriteRenderer(root:data.root)
    }

    func render(session:OriginalBattleSession,data:DataSet,selectedSlot:Int?,highlighted:Set<GridPoint>,animation:OriginalBattleAnimator,idlePhase:UInt8 = 0) -> CGImage? {
        if key != data.root.path+"/"+session.definition.id {prepare(session:session,data:data)}
        let width = session.width*cell,height = session.height*cell
        guard width > 0,height > 0,let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                                                            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return nil}
        // Top-left coordinates: flip once, then every picture is drawn upright.
        context.translateBy(x:0,y:CGFloat(height));context.scaleBy(x:1,y:-1)
        context.setFillColor(CGColor(gray:0.06,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height))
        func place(_ image:CGImage,_ rect:CGRect) {
            context.saveGState()
            context.translateBy(x:rect.minX,y:rect.maxY);context.scaleBy(x:1,y:-1)
            context.draw(image,in:CGRect(x:0,y:0,width:rect.width,height:rect.height))
            context.restoreGState()
        }
        if let backdrop {place(backdrop,CGRect(x:0,y:0,width:width,height:height))}
        let pictures = session.pictureTiles ?? baseline,columns = session.width*2
        if pictures.count == session.width*session.height*4 {
            for (index,id) in pictures.enumerated() where !baseline.indices.contains(index) || baseline[index] != id {
                let box = CGRect(x:(index%columns)*16,y:(index/columns)*16,width:16,height:16)
                if let tile = tiles[Int(id)] {place(tile,box)}
            }
        }
        for point in highlighted where point.x >= 0 && point.y >= 0 && point.x < session.width && point.y < session.height {
            let box = CGRect(x:point.x*cell,y:point.y*cell,width:cell,height:cell).insetBy(dx:1,dy:1)
            context.setFillColor(CGColor(red:0.2,green:0.8,blue:0.9,alpha:0.28));context.fill(box)
            context.setStrokeColor(CGColor(red:0.2,green:0.8,blue:0.9,alpha:0.8));context.setLineWidth(1);context.stroke(box)
        }
        let walker = animation.walker
        for unit in session.units.values.sorted(by:{$0.slot < $1.slot}) {
            guard unit.status == 2,!unit.enemy || unit.scriptFlags&0x20 != 0,
                  let person = try? session.people.person(unit.person),
                  let maximum = try? OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:session.combat) else {continue}
            var box = CGRect(x:unit.position.x*cell,y:unit.position.y*cell,width:cell,height:cell)
            var picture = try? sprites?.image(unit:unit,classID:person.classID,phase:idlePhase)
            if let walker,walker.slot == unit.slot {
                box = CGRect(x:Int(walker.x*Double(cell)),y:Int(walker.y*Double(cell)),width:cell,height:cell)
                picture = (try? sprites?.image(unit:unit,classID:person.classID,direction:walker.direction,stepPixels:walker.stepPixels)) ?? picture
            }
            if let picture {
                context.saveGState();if unit.scriptFlags&0x80 != 0 {context.setAlpha(0.58)}
                place(picture,box);context.restoreGState()
            }
            // A slim bar under the unit, only once it is hurt or while it is selected, so full-strength units stay clean.
            let share = min(1,max(0,Double(person.rawTroops)/Double(max(1,maximum))))
            if share < 1 || unit.slot == selectedSlot {
                let bar = CGRect(x:box.minX+box.width*0.2,y:box.maxY-4,width:box.width*0.6,height:3)
                context.setFillColor(CGColor(gray:0,alpha:0.55));context.fill(bar.insetBy(dx:-1,dy:-1))
                context.setFillColor(unit.enemy ? CGColor(red:1,green:0.3,blue:0.3,alpha:1) : CGColor(red:0.3,green:0.9,blue:0.7,alpha:1))
                context.fill(CGRect(x:bar.minX,y:bar.minY,width:bar.width*share,height:bar.height))
            }
            if unit.slot == selectedSlot {
                context.setStrokeColor(CGColor(red:1,green:0.85,blue:0.1,alpha:1));context.setLineWidth(3);context.stroke(box.insetBy(dx:2,dy:2))
            }
        }
        if let effect = animation.effect,let image = (try? sprites?.effectImage(effect.frame)) ?? nil {
            place(image,CGRect(x:effect.halfX*cell/2,y:effect.halfY*cell/2,width:cell,height:cell))
        }
        if let shot = animation.shot,let image = (try? sprites?.shotImage(shot.frame)) ?? nil {
            let quarter = cell/4
            place(image,CGRect(x:Int(shot.x*Double(cell))+quarter,y:Int(shot.y*Double(cell))+quarter,width:quarter*2,height:quarter*2))
        }
        if let number = animation.number,number.visible,let unit = session.units[number.slot] {
            let text = String(number.value)
            let color:(UInt8,UInt8,UInt8) = number.color == 15 ? (120,240,200) : (255,220,112)
            let badge = CGRect(x:unit.position.x*cell+cell/2-26,y:unit.position.y*cell+cell/2-10,width:52,height:20)
            context.setFillColor(CGColor(red:0.06,green:0.07,blue:0.11,alpha:0.92));context.fill(badge)
            if let picture = font?.picture(text,red:color.0,green:color.1,blue:color.2) {
                place(picture,CGRect(x:Int(badge.midX)-picture.width/2,y:Int(badge.midY)-picture.height/2,width:picture.width,height:picture.height))
            }
        }
        return context.makeImage()
    }
}
#endif
