// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if !os(Android)
import CoreGraphics
#else
import Foundation
#endif

enum BattleMapViewMode:String,Codable,CaseIterable {
    case standard,large,overview
    var label:String {switch self {case .standard:return "기본 보기";case .large:return "확대 보기";case .overview:return "전체 전장"}}
}
enum BattleMapViewport {
    /// Fixed surrounding controls; the map alone changes its integer cell size.
    /// Full-map letterboxing keeps drawing and hit tests on the same rectangle.
    static func layout(source:OriginalBattleLayout,width:Int,height:Int,mode:BattleMapViewMode,textScale:CGFloat = 1)->OriginalBattleLayout {
        var result = source.modern(mapWidth:width,mapHeight:height)
        let cell = mode == .overview ? max(1,min(480/max(1,width),320/max(1,height))) : mode == .large ? 40 : 32
        let columns = min(width,480/cell),rows = min(height,320/cell)
        result.cell = cell
        result.viewport = [(480-columns*cell)/2,48+(320-rows*cell)/2,columns*cell,rows*cell]
        result.list.rowHeight = textScale > 1 ? max(40,Int(ceil(28*textScale))) : 20
        result.list.rect[3] = textScale > 1 ? 112 : 140
        result.list.rows = max(1,result.list.rect[3]/result.list.rowHeight)
        result.list.track[3] = result.list.rect[3]
        return result
    }
}
