// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct OriginalStoryAsset:Codable {
    var id:Int; var image:String; var width:Int; var height:Int
    var imagesByPalette:[String:String]; var source:JSONValue?
}
struct OriginalStoryLayout:Codable {
    var mode:Int; var clearRect:[Int]?; var panelRect:[Int]; var pictureRect:[Int]
    var source:JSONValue?
}
struct OriginalStoryCatalog:Codable {
    var format:Int; var assets:[OriginalStoryAsset]; var layouts:[OriginalStoryLayout]
    var source:JSONValue?; var limitations:[String]?
    static func load(from url:URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
        guard value.format == 1,value.assets.count <= 256,Set(value.assets.map(\.id)).count == value.assets.count,
              value.layouts.allSatisfy({[0,1].contains($0.mode) && $0.panelRect == [152,32,240,160] && $0.pictureRect == [160,40,224,144]}) else {
            throw EngineError.invalid("Original story asset/layout contract is invalid")
        }
        return value
    }
    func picture(_ id:Int,mode:Int,palette:Int) throws -> String {
        guard layouts.contains(where:{$0.mode == mode}),let asset = assets.first(where:{$0.id == id}),
              asset.width == 224,asset.height == 144,let image = asset.imagesByPalette[String(palette)] else {
            throw EngineError.invalid("Original story figure/layout/palette is not supported by its source image")
        }
        return image
    }
}
