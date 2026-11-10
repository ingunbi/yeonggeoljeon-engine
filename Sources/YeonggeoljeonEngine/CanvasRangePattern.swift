// SPDX-License-Identifier: GPL-3.0-only
import AppKit

enum CanvasRangePattern {
    enum Kind:CaseIterable {case movement,attack,support,threat
        var label:String {switch self {case .movement:return "이동 · 끊긴 테두리";case .attack:return "공격 · 사선";case .support:return "지원 · 점";case .threat:return "위협 · 격자"}}
    }
    static func draw(kind:Kind,in rect:CGRect,context:CGContext) {
        guard AppControlRuntime.current.patternedRanges,rect.width > 2,rect.height > 2 else {return}
        context.saveGState();defer {context.restoreGState()}
        context.clip(to:rect.insetBy(dx:1,dy:1));context.setStrokeColor(CGColor(gray:1,alpha:0.88));context.setFillColor(CGColor(gray:1,alpha:0.9));context.setLineWidth(1)
        switch kind {
        case .movement:
            context.setLineDash(phase:0,lengths:[3,2]);context.stroke(rect.insetBy(dx:2,dy:2))
        case .attack:
            for offset in stride(from:-rect.height,through:rect.width,by:7) {
                context.move(to:.init(x:rect.minX+offset,y:rect.maxY));context.addLine(to:.init(x:rect.minX+offset+rect.height,y:rect.minY));context.strokePath()
            }
        case .support:
            for y in stride(from:rect.minY+4,to:rect.maxY,by:7) {for x in stride(from:rect.minX+4,to:rect.maxX,by:7) {context.fillEllipse(in:.init(x:x-1,y:y-1,width:2,height:2))}}
        case .threat:
            for x in stride(from:rect.minX+4,to:rect.maxX,by:8) {context.move(to:.init(x:x,y:rect.minY));context.addLine(to:.init(x:x,y:rect.maxY));context.strokePath()}
            for y in stride(from:rect.minY+4,to:rect.maxY,by:8) {context.move(to:.init(x:rect.minX,y:y));context.addLine(to:.init(x:rect.maxX,y:y));context.strokePath()}
        }
    }
}
