// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreGraphics

struct ActorRenderProof: Codable {
    var person: Int; var frame: Int; var flip: Bool
    var rect: [Int]; var position: GridPoint
    var drawn: Bool; var opaqueSourcePixels: Int
}
struct RenderedFrame {
    var image: CGImage; var checksum: String; var actors: [ActorRenderProof]
    func writePNG(_ path: URL) throws {
        let rep = NSBitmapImageRep(cgImage:image)
        guard let bytes = rep.representation(using:.png,properties:[:]) else { throw EngineError.invalid("PNG encoding failed") }
        try bytes.write(to:path,options:.atomic)
    }
}

final class Renderer {
    let data: DataSet
    private var images: [String: CGImage] = [:]
    private var frames: [String: CGImage] = [:]
    private let font = NSFont(name:"Apple SD Gothic Neo",size:14) ?? NSFont.systemFont(ofSize:14)
    init(_ data: DataSet) throws {
        self.data = data
        if let path = data.resources.title {
            let title = try load(path)
            guard title.width == 640 && title.height == 400 else { throw EngineError.invalid("Title must be640x400 source pixels") }
        }
        for map in data.resources.maps.values {
            let image = try load(map.image)
            guard image.width == map.width && image.height == map.height else { throw EngineError.invalid("Map bitmap/metadata dimensions disagree") }
            for object in map.objects ?? [] {
                let image = try load(object.image)
                guard image.width == object.width, image.height == object.height,
                      object.width > 0, object.height > 0 else { throw EngineError.invalid("Prop bitmap/metadata dimensions disagree") }
            }
        }
        for actor in data.resources.actors.values {
            let image = try load(actor.image)
            guard image.width == actor.frameWidth*actor.frames && image.height == actor.frameHeight else {
                throw EngineError.invalid("Actor sheet/metadata dimensions disagree")
            }
        }
        for value in data.resources.portraits?.values ?? [:].values {
            if let path = portraitPath(value) { _ = try load(path) }
        }
    }
    private func portraitPath(_ value: JSONValue,palette:Int = 2) -> String? {
        switch value {
        case .string(let value): return value
        case .object(let object):
            if case .object(let variants)? = object["imagesByPalette"],case .string(let path)? = variants[String(palette)] { return path }
            if case .string(let path)? = object["image"] { return path }; return nil
        default: return nil
        }
    }
    private func load(_ path: String) throws -> CGImage {
        if let image = images[path] { return image }
        let url = try data.containedFile(path)
        guard let image = NSBitmapImageRep(data:try Data(contentsOf:url))?.cgImage else {
            throw EngineError.invalid("Cannot decode image: \(path)")
        }
        images[path] = image; return image
    }
    /// The canvas uses top-left coordinates. Flip only image drawing, preserving
    /// original PNG row order independently from AppKit's text coordinate system.
    static func image(_ image: CGImage, in rect: CGRect, context: CGContext, flip: Bool = false) {
        context.saveGState(); context.interpolationQuality = .none
        context.translateBy(x:rect.minX + (flip ? rect.width : 0),y:rect.maxY)
        context.scaleBy(x:flip ? -1 : 1,y:-1)
        context.draw(image,in:CGRect(x:0,y:0,width:rect.width,height:rect.height))
        context.restoreGState()
    }
    private func text(_ text: String, rect: CGRect, size: CGFloat = 14, color: NSColor = .white) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        let selected = size == 14 ? font : (NSFont(name:font.fontName,size:size) ?? NSFont.systemFont(ofSize:size))
        (text as NSString).draw(in:rect,withAttributes:[.font:selected,.foregroundColor:color,.paragraphStyle:paragraph])
    }
    private func opaquePixels(_ image: CGImage) -> Int {
        let row = image.width*4
        guard let c = CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:row,
                                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),
              let memory = c.data else { return 0 }
        c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        let bytes = memory.assumingMemoryBound(to:UInt8.self)
        return (0..<(image.width*image.height)).reduce(0) { $0 + (bytes[$1*4+3] > 0 ? 1 : 0) }
    }
    func render(_ runtime: Runtime, evidence: Bool = false) throws -> RenderedFrame {
        guard let context = CGContext(data:nil,width:640,height:400,bitsPerComponent:8,bytesPerRow:640*4,
                                      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data else { throw EngineError.invalid("Canvas allocation failed") }
        context.setFillColor(CGColor(gray:0,alpha:1)); context.fill(CGRect(x:0,y:0,width:640,height:400))
        context.translateBy(x:0,y:400); context.scaleBy(x:1,y:-1)
        context.setShouldAntialias(false); context.interpolationQuality = .none
        var proof: [ActorRenderProof] = []
        if runtime.mode == "title", let path = data.resources.title {
            Self.image(try load(path),in:CGRect(x:0,y:0,width:640,height:400),context:context)
        } else if runtime.visible, let map = runtime.currentMap {
            let v = runtime.viewport
            guard v.count == 4, v[0] >= 0, v[1] >= 0, v[2] > 0, v[3] > 0,
                  v[0]+v[2] <= 640, v[1]+v[3] <= 400 else { throw EngineError.invalid("Viewport outside source canvas") }
            let viewport = CGRect(x:v[0],y:v[1],width:v[2],height:v[3])
            context.saveGState(); context.clip(to:viewport)
            let picture = try load(map.image)
            guard picture.width == map.width,picture.height == map.height else { throw EngineError.invalid("Host map bitmap/metadata dimensions disagree") }
            Self.image(picture,in:CGRect(x:v[0]-runtime.camera[0],y:v[1]-runtime.camera[1],width:map.width,height:map.height),context:context)
            struct DrawItem { var depth: Int; var registration: Int; var person: Int?; var object: MapObject? }
            var items = (map.objects ?? []).enumerated().map { DrawItem(depth:16*$0.element.y,registration:$0.offset,person:nil,object:$0.element) }
            let propCount = items.count
            items += runtime.actors.values.map { DrawItem(depth:16*($0.position.y+(map.geometry == "world" ? 0 : ($0.position.x&1))),registration:propCount+$0.registration,person:$0.person,object:nil) }
            items.sort { $0.depth == $1.depth ? $0.registration < $1.registration : $0.depth < $1.depth }
            for item in items {
                if let object = item.object {
                    let rect = CGRect(x:v[0]+16*object.x-object.anchorX-runtime.camera[0],y:v[1]+16*object.y-object.anchorY-runtime.camera[1],width:object.width,height:object.height)
                    Self.image(try load(object.image),in:rect,context:context)
                } else if let person = item.person, let actor = runtime.actors[person], let meta = runtime.actorResource(person), let directions = meta.directions {
                    guard directions.indices.contains(actor.facing) else { throw EngineError.invalid("Source actor direction is unavailable") }
                    let direction = directions[actor.facing], frameIndex = direction.frame + actor.phase
                    let key = meta.image + "#\(frameIndex)"
                    let frame: CGImage
                    if let cached = frames[key] { frame = cached }
                    else {
                        let sheet = try load(meta.image)
                        guard sheet.width == meta.frameWidth*meta.frames,sheet.height == meta.frameHeight,
                              let crop = sheet.cropping(to:CGRect(x:frameIndex*meta.frameWidth,y:0,width:meta.frameWidth,height:meta.frameHeight)) else {
                            throw EngineError.invalid("Actor frame crop failed")
                        }
                        frame = crop; frames[key] = crop
                    }
                    let x = v[0]+16*actor.position.x-meta.anchorX-runtime.camera[0]
                    let y = v[1]+16*actor.position.y+(map.geometry == "world" ? 0 : 8*(actor.position.x&1))-meta.anchorY-runtime.camera[1]
                    let rect = CGRect(x:x,y:y,width:meta.frameWidth,height:meta.frameHeight)
                    let visible = rect.intersects(viewport)
                    if visible { Self.image(frame,in:rect,context:context,flip:direction.flip) }
                    if evidence {
                        proof.append(ActorRenderProof(person:person,frame:frameIndex,flip:direction.flip,
                                                      rect:[x,y,meta.frameWidth,meta.frameHeight],position:actor.position,
                                                      drawn:visible,opaqueSourcePixels:opaquePixels(frame)))
                    }
                }
            }
            context.restoreGState()
        }
        let graphics = NSGraphicsContext(cgContext:context,flipped:true)
        if let panel = runtime.storyPanel {
            let picture = try load(panel.image)
            guard picture.width == 224,picture.height == 144 else { throw EngineError.invalid("Original story figure does not match the source panel dimensions") }
            Self.image(picture,in:CGRect(x:160,y:40,width:224,height:144),context:context)
        }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        if runtime.mode != "title", let caption = runtime.caption {
            text(caption,rect:CGRect(x:28,y:24,width:380,height:25),size:14)
        }
        if runtime.mode == "title" && data.resources.title == nil {
            text("영걸전 연구 엔진",rect:CGRect(x:90,y:135,width:470,height:40),size:28)
            text("원작 타이틀 자료를 읽을 수 없습니다.\nEnter 또는 클릭으로 복원된 첫 장면을 시작합니다.",rect:CGRect(x:90,y:195,width:470,height:90),size:16)
        } else if let dialogue = runtime.dialogue {
            context.setFillColor(CGColor(gray:0.055,alpha:1)); context.fill(CGRect(x:16,y:337,width:608,height:63))
            context.setStrokeColor(CGColor(gray:0.65,alpha:1)); context.setLineWidth(1)
            context.stroke(CGRect(x:16.5,y:337.5,width:607,height:62))
            text(dialogue.text,rect:CGRect(x:26,y:344,width:588,height:52))
            text(dialogue.speaker,rect:CGRect(x:536,y:111,width:100,height:48),size:15)
            if let person = dialogue.person, let value = data.resources.portraits?[String(person)], let path = portraitPath(value,palette:runtime.palette) {
                let portrait = try load(path)
                Self.image(portrait,in:CGRect(x:544,y:24,width:portrait.width,height:portrait.height),context:context)
            }
        } else if runtime.mode == "ended" {
            context.setFillColor(CGColor(gray:0.04,alpha:1)); context.fill(CGRect(x:16,y:340,width:608,height:60))
            let message: String
            switch runtime.termination {
            case .runtimeFailure, .unexpectedEOF: message = "이 장면을 재생할 수 없습니다. 연구 로그에 오류를 기록했습니다."
            case .unsupportedBoundary: message = "아직 복원되지 않은 다음 연출에 도달했습니다."
            default: message = "현재 복원된 장면은 여기까지입니다."
            }
            text(message,rect:CGRect(x:28,y:350,width:580,height:40))
        }
        NSGraphicsContext.restoreGraphicsState()
        if runtime.blackAlpha > 0 {
            context.setFillColor(CGColor(gray:0,alpha:runtime.blackAlpha)); context.fill(CGRect(x:0,y:0,width:640,height:400))
        }
        guard let image = context.makeImage() else { throw EngineError.invalid("Canvas image creation failed") }
        let bytes = pixels.assumingMemoryBound(to:UInt8.self)
        var checksum: UInt64 = 14695981039346656037
        if evidence {
            for i in 0..<(640*400*4) { checksum = (checksum ^ UInt64(bytes[i])) &* 1099511628211 }
        }
        return RenderedFrame(image:image,checksum:evidence ? String(checksum,radix:16) : "",actors:proof)
    }
}
