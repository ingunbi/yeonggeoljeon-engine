// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Maps the 640×400 source canvas into a view: fitted and centred.
struct CanvasGeometry {
    var scale:CGFloat
    var origin:CGPoint
    init(bounds:CGRect) {
        scale = max(0.1,min(bounds.width/640,bounds.height/400))
        origin = CGPoint(x:(bounds.width-640*scale)/2,y:(bounds.height-400*scale)/2)
    }
    var rect:CGRect { CGRect(x:origin.x,y:origin.y,width:640*scale,height:400*scale) }
    func canvas(_ point:CGPoint) -> CGPoint { CGPoint(x:(point.x-origin.x)/scale,y:(point.y-origin.y)/scale) }
}

/// The look of every window the engine draws itself. Original art is drawn
/// unchanged; these colors and shapes are engine presentation, not source facts.
enum CanvasTheme {
    static let surface = CGColor(red:0.070,green:0.078,blue:0.106,alpha:0.97)
    static let inset = CGColor(gray:1,alpha:0.05)
    static let hairline = CGColor(gray:1,alpha:0.16)
    static let selection = CGColor(red:0.91,green:0.75,blue:0.40,alpha:0.22)
    static let accentFill = CGColor(red:0.91,green:0.75,blue:0.40,alpha:1)
    static let accent = NSColor(red:0.95,green:0.80,blue:0.48,alpha:1)
    static let text = NSColor(white:0.96,alpha:1)
    static let muted = NSColor(white:0.68,alpha:1)
    static let disabled = NSColor(white:0.42,alpha:1)
    static let danger = NSColor(red:0.96,green:0.52,blue:0.45,alpha:1)
    static let onAccent = NSColor(red:0.12,green:0.10,blue:0.06,alpha:1)
    static let radius:CGFloat = 8
    static let rowRadius:CGFloat = 5

    static func font(_ size:CGFloat,_ weight:NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize:size,weight:weight) }
    static func number(_ size:CGFloat,_ weight:NSFont.Weight = .regular) -> NSFont { .monospacedDigitSystemFont(ofSize:size,weight:weight) }
    static func attributes(_ font:NSFont,_ color:NSColor,alignment:NSTextAlignment = .left) -> [NSAttributedString.Key:Any] {
        let paragraph = NSMutableParagraphStyle();paragraph.lineBreakMode = .byWordWrapping;paragraph.alignment = alignment
        paragraph.lineBreakStrategy = .hangulWordPriority
        return [.font:font,.foregroundColor:color,.paragraphStyle:paragraph]
    }
    static func rounded(_ rect:CGRect,_ radius:CGFloat,in context:CGContext) {
        context.addPath(CGPath(roundedRect:rect,cornerWidth:radius,cornerHeight:radius,transform:nil))
    }
    static func fill(_ rect:CGRect,_ color:CGColor,radius:CGFloat = rowRadius,in context:CGContext) {
        rounded(rect,radius,in:context);context.setFillColor(color);context.fillPath()
    }
    static func stroke(_ rect:CGRect,_ color:CGColor = hairline,radius:CGFloat = rowRadius,in context:CGContext) {
        rounded(rect.insetBy(dx:0.5,dy:0.5),radius,in:context);context.setStrokeColor(color);context.setLineWidth(1);context.strokePath()
    }
    /// A floating card with a soft shadow.
    static func panel(_ rect:CGRect,in context:CGContext) {
        context.saveGState()
        context.setShadow(offset:CGSize(width:0,height:3),blur:14,color:CGColor(gray:0,alpha:0.55))
        fill(rect,surface,radius:radius,in:context)
        context.restoreGState()
        stroke(rect,radius:radius,in:context)
    }
    static func divider(from a:CGPoint,to b:CGPoint,in context:CGContext) {
        context.setStrokeColor(hairline);context.setLineWidth(1)
        context.move(to:a);context.addLine(to:b);context.strokePath()
    }
    /// A short status line floating over the picture. Width follows the
    /// text; the point is the chip's vertical centre and its left or middle.
    static func chip(_ text:String,at point:CGPoint,centered:Bool = true,maximumWidth:CGFloat,color:NSColor = CanvasTheme.text,in context:CGContext) {
        let style = attributes(font(12,.medium),color,alignment:.center)
        let size = (text as NSString).boundingRect(with:CGSize(width:maximumWidth-24,height:120),options:[.usesLineFragmentOrigin],attributes:style).size
        let width = ceil(size.width)+24,height = ceil(size.height)+10
        let rect = CGRect(x:centered ? point.x-width/2 : point.x,y:point.y-height/2,width:width,height:height).integral
        panel(rect,in:context)
        (text as NSString).draw(with:rect.insetBy(dx:12,dy:5),options:[.usesLineFragmentOrigin],attributes:style)
    }
    /// The small corner mark that says a line waits for input.
    static func continueMark(at point:CGPoint,in context:CGContext) {
        context.setFillColor(accentFill)
        context.move(to:CGPoint(x:point.x-5,y:point.y-3));context.addLine(to:CGPoint(x:point.x+5,y:point.y-3))
        context.addLine(to:CGPoint(x:point.x,y:point.y+3));context.closePath();context.fillPath()
    }
}
