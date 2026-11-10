// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Maps the 640×400 source canvas into a view: fitted and centred. MAIN draws
/// that canvas in VGA mode 12h (GRPDRV 0x23DD) from line 40 of 480 (mouse y − 40
/// at MAIN0x149C5), so its pixels are square on a 4:3 screen.
struct CanvasGeometry {
    var scale:CGFloat
    var origin:CGPoint
    /// Device pixels per point of the screen the game window is on.
    static var backingScale:CGFloat = NSScreen.main?.backingScaleFactor ?? 2
    static let scalingChanged = Notification.Name("CanvasScalingChanged")
    private static let fillKey = "fillsWindow"
    /// Off by default: each source pixel covers a whole number of device
    /// pixels, so dithered art stays even. On, the canvas fills the window.
    static var fillsWindow:Bool {
        get { UserDefaults.standard.bool(forKey:fillKey) }
        set { UserDefaults.standard.set(newValue,forKey:fillKey);NotificationCenter.default.post(name:scalingChanged,object:nil) }
    }
    /// Canvas units one source pixel covers on the screen now shown: 1.25 for
    /// the engine field, whose 512×320 map fills the canvas, else 1.
    static var sourcePixel:CGFloat = 1
    init(bounds:CGRect) { self.init(bounds:bounds,whole:!Self.fillsWindow,backing:Self.backingScale,sourcePixel:Self.sourcePixel) }
    init(bounds:CGRect,whole:Bool,backing:CGFloat,sourcePixel:CGFloat = 1) {
        let fit = max(0.1,min(bounds.width/640,bounds.height/400)),pixels = fit*backing*sourcePixel
        scale = whole && pixels >= 1 ? floor(pixels+0.001)/(backing*sourcePixel) : fit
        // The corner lands on a device pixel too.
        origin = CGPoint(x:((bounds.width-640*scale)/2*backing).rounded()/backing,y:((bounds.height-400*scale)/2*backing).rounded()/backing)
    }
    var rect:CGRect { CGRect(x:origin.x,y:origin.y,width:640*scale,height:400*scale) }
    func canvas(_ point:CGPoint) -> CGPoint { CGPoint(x:(point.x-origin.x)/scale,y:(point.y-origin.y)/scale) }
}

/// Which screen surrounds the map. Replays and research views stay on the
/// original frames; the app starts on the modern layout.
enum CanvasPresentation {
    case modern,original
    static let changed = Notification.Name("CanvasPresentationChanged")
    private static let key = "showsOriginalFrames"
    static var current:CanvasPresentation {
        get { UserDefaults.standard.bool(forKey:key) ? .original : .modern }
        set {
            UserDefaults.standard.set(newValue == .original,forKey:key)
            NotificationCenter.default.post(name:changed,object:nil)
        }
    }
}

/// In the modern layout the 512×320 map window fills the 640×400 canvas.
enum CanvasFieldMap {
    static let viewport = CGRect(x:16,y:16,width:512,height:320)
    static func mapPoint(canvas point:CGPoint) -> CGPoint {
        CGPoint(x:viewport.minX+point.x*viewport.width/640,y:viewport.minY+point.y*viewport.height/400)
    }
    static func canvasPoint(map point:CGPoint) -> CGPoint {
        CGPoint(x:(point.x-viewport.minX)*640/viewport.width,y:(point.y-viewport.minY)*400/viewport.height)
    }
}

/// The look of every window the engine draws itself. Original art is drawn
/// unchanged; these colors and shapes are engine presentation, not source facts.
enum CanvasTheme {
    static let surface = CGColor(red:0.075,green:0.088,blue:0.125,alpha:0.97)
    static let surfaceTop = CGColor(red:0.115,green:0.135,blue:0.195,alpha:0.96)
    static let surfaceBottom = CGColor(red:0.055,green:0.065,blue:0.098,alpha:0.98)
    static let background = CGColor(red:0.062,green:0.070,blue:0.096,alpha:1)
    static let inset = CGColor(red:0.04,green:0.05,blue:0.08,alpha:0.65)
    static let hairline = CGColor(gray:1,alpha:0.15)
    static let accentBorder = CGColor(red:0.88,green:0.74,blue:0.44,alpha:0.42)
    static let selection = CGColor(red:0.91,green:0.75,blue:0.40,alpha:0.24)
    static let accentFill = CGColor(red:0.91,green:0.75,blue:0.40,alpha:1)
    static let accentTop = CGColor(red:0.97,green:0.84,blue:0.52,alpha:1)
    static let accentBottom = CGColor(red:0.82,green:0.64,blue:0.28,alpha:1)
    static let accent = NSColor(red:0.95,green:0.81,blue:0.48,alpha:1)
    static let text = NSColor(white:0.97,alpha:1)
    static let muted = NSColor(red:0.68,green:0.72,blue:0.80,alpha:1)
    static let disabled = NSColor(white:0.42,alpha:1)
    static let danger = NSColor(red:0.96,green:0.52,blue:0.45,alpha:1)
    static let onAccent = NSColor(red:0.10,green:0.08,blue:0.04,alpha:1)
    static let radius:CGFloat = 9
    static let rowRadius:CGFloat = 6

    static var textScale:CGFloat {CGFloat(AppControlRuntime.current.textPercent)/100}
    static func font(_ size:CGFloat,_ weight:NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize:size*textScale,weight:weight) }
    static func number(_ size:CGFloat,_ weight:NSFont.Weight = .regular) -> NSFont { .monospacedDigitSystemFont(ofSize:size*textScale,weight:weight) }
    static func attributes(_ font:NSFont,_ color:NSColor,alignment:NSTextAlignment = .left) -> [NSAttributedString.Key:Any] {
        let paragraph = NSMutableParagraphStyle();paragraph.lineBreakMode = .byWordWrapping;paragraph.alignment = alignment
        paragraph.lineBreakStrategy = .hangulWordPriority
        return [.font:font,.foregroundColor:color,.paragraphStyle:paragraph]
    }
    /// A row's two fields own disjoint boxes. Ellipsis is intentional and is
    /// clipped to that box; a long title can never paint over its value.
    static func singleLineAttributes(_ font:NSFont,_ color:NSColor,alignment:NSTextAlignment = .left) -> [NSAttributedString.Key:Any] {
        let paragraph = NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail;paragraph.alignment = alignment
        return [.font:font,.foregroundColor:color,.paragraphStyle:paragraph]
    }
    static func lineHeight(_ font:NSFont) -> CGFloat {ceil(font.ascender-font.descender+font.leading)+2}
    static func textWidth(_ text:String,font:NSFont) -> CGFloat {ceil((text as NSString).size(withAttributes:[.font:font]).width)}
    static func drawSingleLine(_ text:String,in rect:CGRect,font:NSFont,color:NSColor,alignment:NSTextAlignment = .left,context:CGContext) {
        guard !text.isEmpty,rect.width > 0,rect.height > 0 else {return}
        context.saveGState();context.clip(to:rect)
        let height = lineHeight(font),box = CGRect(x:rect.minX,y:rect.midY-height/2,width:rect.width,height:height)
        (text as NSString).draw(with:box,options:[.usesLineFragmentOrigin,.usesFontLeading,.truncatesLastVisibleLine],attributes:singleLineAttributes(font,color,alignment:alignment))
        context.restoreGState()
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
    static func gradient(_ rect:CGRect,top:CGColor,bottom:CGColor,radius:CGFloat = radius,vertical:Bool = true,in context:CGContext) {
        guard let grad = CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[top,bottom] as CFArray,locations:[0,1]) else {
            fill(rect,top,radius:radius,in:context);return
        }
        context.saveGState()
        rounded(rect,radius,in:context);context.clip()
        context.drawLinearGradient(grad,start:CGPoint(x:rect.minX,y:rect.minY),
                                   end:vertical ? CGPoint(x:rect.minX,y:rect.maxY) : CGPoint(x:rect.maxX,y:rect.minY),options:[])
        context.restoreGState()
    }
    /// A floating tactical RPG card with a gradient surface, inner bevel and warm accent border.
    static func panel(_ rect:CGRect,in context:CGContext) {
        context.saveGState()
        context.setShadow(offset:CGSize(width:0,height:4),blur:16,color:CGColor(gray:0,alpha:0.65))
        fill(rect,surfaceBottom,radius:radius,in:context)
        context.restoreGState()
        gradient(rect,top:surfaceTop,bottom:surfaceBottom,radius:radius,in:context)
        stroke(rect.insetBy(dx:1,dy:1),CGColor(gray:1,alpha:0.08),radius:max(1,radius-1),in:context)
        stroke(rect,accentBorder,radius:radius,in:context)
    }
    /// A recessed dark-glass subcard inside a panel or sidebar.
    static func card(_ rect:CGRect,radius:CGFloat = 7,in context:CGContext) {
        gradient(rect,top:CGColor(red:0.05,green:0.06,blue:0.095,alpha:0.78),
                 bottom:CGColor(red:0.035,green:0.042,blue:0.07,alpha:0.86),radius:radius,in:context)
        stroke(rect,CGColor(gray:1,alpha:0.11),radius:radius,in:context)
    }
    /// A capsule button or badge with gradient fill and crisp border.
    static func pill(_ rect:CGRect,active:Bool = false,danger:Bool = false,in context:CGContext) {
        let r = min(rect.height/2,8)
        if active {
            context.saveGState()
            context.setShadow(offset:CGSize(width:0,height:2),blur:8,color:CGColor(red:0.91,green:0.75,blue:0.40,alpha:0.35))
            gradient(rect,top:danger ? CGColor(red:0.96,green:0.46,blue:0.40,alpha:1) : accentTop,
                     bottom:danger ? CGColor(red:0.78,green:0.28,blue:0.24,alpha:1) : accentBottom,radius:r,in:context)
            context.restoreGState()
            stroke(rect,CGColor(gray:1,alpha:0.35),radius:r,in:context)
        } else {
            gradient(rect,top:CGColor(red:0.14,green:0.165,blue:0.235,alpha:0.94),
                     bottom:CGColor(red:0.085,green:0.10,blue:0.15,alpha:0.96),radius:r,in:context)
            stroke(rect,danger ? CGColor(red:0.96,green:0.52,blue:0.45,alpha:0.45) : accentBorder,radius:r,in:context)
        }
    }
    static func divider(from a:CGPoint,to b:CGPoint,in context:CGContext) {
        context.setStrokeColor(hairline);context.setLineWidth(1)
        context.move(to:a);context.addLine(to:b);context.strokePath()
    }
    /// A short status line floating over the picture. Width follows the
    /// text; the point is the chip's vertical centre and its left or middle.
    static func chip(_ text:String,at point:CGPoint,centered:Bool = true,maximumWidth:CGFloat,color:NSColor = CanvasTheme.text,in context:CGContext) {
        let style = attributes(font(11.5,.semibold),color,alignment:.center)
        let size = (text as NSString).boundingRect(with:CGSize(width:maximumWidth-26,height:120),options:[.usesLineFragmentOrigin],attributes:style).size
        let width = ceil(size.width)+26,height = ceil(size.height)+10
        let rect = CGRect(x:centered ? point.x-width/2 : point.x,y:point.y-height/2,width:width,height:height).integral
        let r = min(height/2,11)
        context.saveGState()
        context.setShadow(offset:CGSize(width:0,height:3),blur:10,color:CGColor(gray:0,alpha:0.6))
        gradient(rect,top:surfaceTop,bottom:surfaceBottom,radius:r,in:context)
        context.restoreGState()
        stroke(rect,accentBorder,radius:r,in:context)
        (text as NSString).draw(with:rect.insetBy(dx:13,dy:5),options:[.usesLineFragmentOrigin],attributes:style)
    }
    /// The small corner mark that says a line waits for input.
    static func continueMark(at point:CGPoint,in context:CGContext) {
        context.setFillColor(accentFill)
        context.move(to:CGPoint(x:point.x-5.5,y:point.y-3.5));context.addLine(to:CGPoint(x:point.x+5.5,y:point.y-3.5))
        context.addLine(to:CGPoint(x:point.x,y:point.y+3));context.closePath();context.fillPath()
        context.setStrokeColor(accentBorder);context.setLineWidth(1.2)
        context.move(to:CGPoint(x:point.x-4.5,y:point.y-6));context.addLine(to:CGPoint(x:point.x+4.5,y:point.y-6));context.strokePath()
    }
}
