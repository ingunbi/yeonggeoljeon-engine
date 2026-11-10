// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Engine reference UI. Grids use the same decoded offsets as targeting;
/// the origin marker remains separate from the coloured included cells.
enum CanvasStrategyDetail {
    private static func style(_ size:CGFloat,_ color:NSColor = CanvasTheme.muted) -> [NSAttributedString.Key:Any] {CanvasTheme.attributes(CanvasTheme.font(size),color)}
    private static func height(_ text:String,width:CGFloat,size:CGFloat) -> CGFloat {
        guard !text.isEmpty else {return 0}
        return ceil((text as NSString).boundingRect(with:CGSize(width:max(1,width),height:100_000),options:[.usesLineFragmentOrigin],attributes:style(size)).height)+2
    }
    private static func status(_ detail:CanvasSheet.Detail) -> String {
        let level = detail.facts.first {$0.label == "습득 레벨"}?.value ?? "",mp = detail.facts.first {$0.label == "필요 MP"}?.value ?? ""
        return detail.body+"  ·  \(level) / MP\(mp)"
    }
    private static func cardHeight(text:String,width:CGFloat) -> CGFloat {max(115*CanvasTheme.textScale,32*CanvasTheme.textScale+height(text,width:width-88,size:11)+12)}
    static func requiredHeight(_ detail:CanvasSheet.Detail,strategy:StrategyGuideDetails.Description,width:CGFloat) -> CGFloat {
        let columns = CanvasTheme.textScale == 1 && width >= 270 ? 2 : 1,cardWidth = columns == 2 ? (width-8)/2 : width
        let cards = [cardHeight(text:strategy.range,width:cardWidth),cardHeight(text:strategy.area,width:cardWidth)]
        return height(detail.heading,width:width,size:16)+height(status(detail),width:width,size:11.5)+height(strategy.effect,width:width,size:13)+height("대상: "+strategy.target,width:width,size:11.5)+height(strategy.conditions.joined(separator:"\n"),width:width,size:11.5)+40+(columns == 2 ? cards.max()! : cards.reduce(0,+)+8)
    }
    static func draw(_ detail:CanvasSheet.Detail,strategy:StrategyGuideDetails.Description,in rect:CGRect,context:CGContext) {
        var y = rect.minY
        func text(_ string:String,size:CGFloat,color:NSColor) {
            guard !string.isEmpty else {return}
            let h = height(string,width:rect.width,size:size)
            (string as NSString).draw(with:CGRect(x:rect.minX,y:y,width:rect.width,height:h),options:[.usesLineFragmentOrigin],attributes:style(size,color));y += h+6
        }
        text(detail.heading,size:16,color:CanvasTheme.text)
        text(status(detail),size:11.5,color:CanvasTheme.accent)
        text(strategy.effect,size:13,color:CanvasTheme.text)
        text("대상: "+strategy.target,size:11.5,color:CanvasTheme.text)
        text(strategy.conditions.joined(separator:"\n"),size:11.5,color:CanvasTheme.muted)
        let sideBySide = CanvasTheme.textScale == 1 && rect.width >= 270,width = sideBySide ? (rect.width-8)/2 : rect.width
        let firstHeight = cardHeight(text:strategy.range,width:width),secondHeight = cardHeight(text:strategy.area,width:width)
        card(title:"사거리",text:strategy.range,offsets:strategy.targetOffsets,origin:"시전자",color:CGColor(red:0.38,green:0.72,blue:0.95,alpha:1),rect:CGRect(x:rect.minX,y:y,width:width,height:firstHeight),context:context)
        card(title:"적용 범위",text:strategy.area,offsets:strategy.effectOffsets,origin:strategy.effectOrigin == .caster ? "시전자" : "선택 대상",color:CanvasTheme.accentFill,
            rect:CGRect(x:sideBySide ? rect.minX+width+8 : rect.minX,y:sideBySide ? y : y+firstHeight+8,width:width,height:secondHeight),context:context)
    }
    private static func card(title:String,text:String,offsets:[OriginalAIOffset],origin:String,color:CGColor,rect:CGRect,context:CGContext) {
        CanvasTheme.card(rect,radius:6,in:context)
        let top = rect.minY+28*CanvasTheme.textScale
        (title as NSString).draw(in:CGRect(x:rect.minX+8,y:rect.minY+7,width:rect.width-16,height:18*CanvasTheme.textScale),withAttributes:CanvasTheme.attributes(CanvasTheme.font(11,.semibold),CanvasTheme.text))
        let radius = max(2,offsets.map {max(abs($0.dx),abs($0.dy))}.max() ?? 0),side = radius*2+1
        let grid = CGRect(x:rect.minX+8,y:top,width:62,height:62),step = grid.width/CGFloat(side),points = Set(offsets.map {GridPoint(x:$0.dx,y:$0.dy)})
        for dy in -radius...radius {for dx in -radius...radius {
            let box = CGRect(x:grid.minX+CGFloat(dx+radius)*step,y:grid.minY+CGFloat(dy+radius)*step,width:step-1.5,height:step-1.5)
            CanvasTheme.fill(box,points.contains(GridPoint(x:dx,y:dy)) ? color : CGColor(gray:1,alpha:0.09),radius:1,in:context)
        }}
        let center = CGPoint(x:grid.midX-0.75,y:grid.midY-0.75)
        context.setFillColor(CGColor(gray:1,alpha:1));context.fillEllipse(in:CGRect(x:center.x-2,y:center.y-2,width:4,height:4))
        ("● "+origin as NSString).draw(with:CGRect(x:rect.minX+4,y:grid.maxY+5,width:72,height:30*CanvasTheme.textScale),options:[.usesLineFragmentOrigin],attributes:CanvasTheme.attributes(CanvasTheme.font(9),CanvasTheme.muted,alignment:.center))
        (text as NSString).draw(with:CGRect(x:grid.maxX+8,y:top,width:rect.maxX-grid.maxX-16,height:height(text,width:rect.width-88,size:11)),options:[.usesLineFragmentOrigin],attributes:style(11))
    }
}
