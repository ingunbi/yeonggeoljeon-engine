// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Two exact source range shapes. Origin marks are independent of inclusion.
enum CanvasRangeComparison {
    struct Model:Equatable {
        var leftName:String;var left:[OriginalAIOffset]
        var rightName:String;var right:[OriginalAIOffset]
    }
    static func draw(_ detail:CanvasSheet.Detail,model:Model,in rect:CGRect,context:CGContext) {
        let heading = CanvasTheme.attributes(CanvasTheme.font(14,.semibold),CanvasTheme.text)
        (detail.heading as NSString).draw(in:CGRect(x:rect.minX,y:rect.minY,width:rect.width,height:28),withAttributes:heading)
        let style = CanvasTheme.attributes(CanvasTheme.font(11),CanvasTheme.muted)
        let bodyHeight = ceil((detail.body as NSString).boundingRect(with:CGSize(width:rect.width,height:200),options:[.usesLineFragmentOrigin],attributes:style).height)
        (detail.body as NSString).draw(with:CGRect(x:rect.minX,y:rect.minY+30,width:rect.width,height:bodyHeight+2),options:[.usesLineFragmentOrigin],attributes:style)
        let top = rect.minY+bodyHeight+40,width = (rect.width-10)/2,height = max(110,rect.maxY-top)
        for (index,entry) in [(model.leftName,model.left),(model.rightName,model.right)].enumerated() {
            let card = CGRect(x:rect.minX+CGFloat(index)*(width+10),y:top,width:width,height:height)
            CanvasTheme.card(card,radius:6,in:context)
            (entry.0 as NSString).draw(in:card.insetBy(dx:7,dy:7),withAttributes:CanvasTheme.attributes(CanvasTheme.font(12,.semibold),CanvasTheme.text,alignment:.center))
            let radius = max(2,entry.1.map {max(abs($0.dx),abs($0.dy))}.max() ?? 0),side = radius*2+1
            let extent = min(width-16,height-64),grid = CGRect(x:card.midX-extent/2,y:card.minY+32,width:extent,height:extent)
            let step = extent/CGFloat(side),points = Set(entry.1.map {GridPoint(x:$0.dx,y:$0.dy)})
            for y in -radius...radius {for x in -radius...radius {
                let cell = CGRect(x:grid.minX+CGFloat(x+radius)*step,y:grid.minY+CGFloat(y+radius)*step,width:step-1.5,height:step-1.5)
                let selected = points.contains(.init(x:x,y:y))
                CanvasTheme.fill(cell,selected ? (index == 0 ? CGColor(red:0.38,green:0.72,blue:0.95,alpha:1) : CanvasTheme.accentFill) : CGColor(gray:1,alpha:0.09),radius:1,in:context)
            }}
            let center = CGPoint(x:grid.midX-0.75,y:grid.midY-0.75)
            context.setFillColor(CGColor(gray:1,alpha:1));context.fillEllipse(in:CGRect(x:center.x-2.5,y:center.y-2.5,width:5,height:5))
            ("● 장수 위치 · \(points.count)칸" as NSString).draw(with:CGRect(x:card.minX+4,y:grid.maxY+6,width:width-8,height:44*CanvasTheme.textScale),options:[.usesLineFragmentOrigin],attributes:CanvasTheme.attributes(CanvasTheme.font(10),CanvasTheme.muted,alignment:.center))
        }
    }
}
