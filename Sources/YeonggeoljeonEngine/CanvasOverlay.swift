// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Native in-game selector drawn over the 640×400 source canvas. The window
/// is engine presentation; original selector window primitives are not
/// restored. Yes/No may carry the original MARK button pictures.
struct CanvasMenu {
    struct Option {
        var label:String
        var enabled = true
        var image:CGImage? = nil
        /// Non-nil draws a check box (multi-selection rows such as the party list).
        var checked:Bool? = nil
    }
    var title:String
    var options:[Option]
    var selected = 0
    var horizontal = false
    /// Escape or a secondary click chooses nil when cancellation is allowed.
    var cancellable = false
    /// A status line under the options (remaining capacity, a refusal).
    var footer = ""
    var onChoose:(Int?) -> Void
}

/// A line of text that waits for one input (battle dialogue, retirement).
struct CanvasNotice {
    var speaker:String
    var text:String
    var portrait:CGImage?
    var onDismiss:() -> Void
}

final class CanvasOverlayView:NSView {
    private(set) var selector:CanvasMenu?
    private(set) var notice:CanvasNotice?
    /// First vertical row shown when a list is taller than the viewport.
    private var firstVisible = 0
    /// Called after the overlay closes so the owner can restore focus.
    var restoreFocus:(() -> Void)?
    var active:Bool { selector != nil || notice != nil }
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { active }
    override func hitTest(_ point:NSPoint) -> NSView? { active ? super.hitTest(point) : nil }
    private let font = NSFont(name:"Apple SD Gothic Neo",size:14) ?? NSFont.systemFont(ofSize:14)

    /// keepScroll preserves the list position when a menu is shown again
    /// after one of its rows changed (party toggles).
    func show(_ value:CanvasMenu,keepScroll:Bool = false) {
        var value = value
        if !value.options.indices.contains(value.selected) || !value.options[value.selected].enabled {
            value.selected = value.options.firstIndex(where:\.enabled) ?? 0
        }
        if !keepScroll { firstVisible = 0 }
        selector = value;notice = nil;revealSelection();present()
    }
    func show(_ value:CanvasNotice) { notice = value;selector = nil;present() }
    private func present() {
        isHidden = false;needsDisplay = true
        window?.makeFirstResponder(self)
    }
    private func close() {
        selector = nil;notice = nil;needsDisplay = true
        restoreFocus?()
    }
    private func choose(_ index:Int?) {
        guard let value = selector else { return }
        if let index = index,!(value.options.indices.contains(index) && value.options[index].enabled) { NSSound.beep();return }
        close();value.onChoose(index)
    }
    private func dismissNotice() {
        guard let value = notice else { return }
        close();value.onDismiss()
    }

    // Canvas mapping matches the campaign view: fit 640×400 above a 40pt status bar.
    private var scale:CGFloat { max(0.1,min(bounds.width/640,(bounds.height-40)/400)) }
    private var origin:CGPoint { CGPoint(x:(bounds.width-640*scale)/2,y:0) }
    private func canvasPoint(_ event:NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow,from:nil)
        return CGPoint(x:(p.x-origin.x)/scale,y:(p.y-origin.y)/scale)
    }
    private func attributes(_ color:NSColor = .white,size:CGFloat = 14) -> [NSAttributedString.Key:Any] {
        let paragraph = NSMutableParagraphStyle();paragraph.lineBreakMode = .byWordWrapping
        return [.font:NSFont(name:font.fontName,size:size) ?? font,.foregroundColor:color,.paragraphStyle:paragraph]
    }
    private func textHeight(_ text:String,width:CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).boundingRect(with:CGSize(width:width,height:400),options:[.usesLineFragmentOrigin],
                                                    attributes:attributes()).height)
    }
    private struct Layout {
        var panel:CGRect; var title:CGRect; var options:[(index:Int,rect:CGRect)]; var footer:CGRect
        var moreAbove:Bool; var moreBelow:Bool
    }
    private static let row:CGFloat = 24
    /// Panel width, text heights and how many vertical rows fit in the
    /// 512×320 viewport (the panel stays at most 312 tall).
    private func metrics(_ value:CanvasMenu) -> (width:CGFloat,title:CGFloat,footer:CGFloat,shown:Int) {
        let check:CGFloat = value.options.contains(where:{ $0.checked != nil }) ? 20 : 0
        let labelWidth = value.options.map { ceil(($0.label as NSString).size(withAttributes:attributes()).width) }.max() ?? 0
        let width:CGFloat = value.horizontal ? 280 : min(420,max(240,labelWidth+56+check))
        let title = textHeight(value.title,width:width-32),footer = textHeight(value.footer,width:width-32)
        let chrome = 26+(title > 0 ? title+10 : 0)+(footer > 0 ? footer+8 : 0)
        let shown = value.horizontal ? value.options.count : min(value.options.count,max(1,Int((312-chrome)/Self.row)))
        return (width,title,footer,shown)
    }
    private func revealSelection() {
        guard let value = selector,!value.horizontal else { firstVisible = 0;return }
        let shown = metrics(value).shown
        if value.selected < firstVisible { firstVisible = value.selected }
        if value.selected >= firstVisible+shown { firstVisible = value.selected-shown+1 }
        firstVisible = min(max(0,firstVisible),max(0,value.options.count-shown))
    }
    private func layout(_ value:CanvasMenu) -> Layout {
        let m = metrics(value),width = m.width
        let rows:CGFloat = value.horizontal ? 28 : CGFloat(m.shown)*Self.row
        let height = 26+(m.title > 0 ? m.title+10 : 0)+rows+(m.footer > 0 ? m.footer+8 : 0)
        let panel = CGRect(x:16+(512-width)/2,y:max(20,16+(320-height)/2),width:width,height:height).integral
        let title = CGRect(x:panel.minX+16,y:panel.minY+14,width:width-32,height:m.title)
        let top = m.title > 0 ? title.maxY+10 : panel.minY+14
        var options:[(index:Int,rect:CGRect)] = []
        let first = value.horizontal ? 0 : min(firstVisible,max(0,value.options.count-m.shown))
        if value.horizontal {
            let button = CGSize(width:64,height:24),gap:CGFloat = 32
            let total = CGFloat(value.options.count)*button.width+CGFloat(max(0,value.options.count-1))*gap
            for index in value.options.indices {
                options.append((index,CGRect(x:panel.midX-total/2+CGFloat(index)*(button.width+gap),y:top,width:button.width,height:button.height)))
            }
        } else {
            for index in first..<first+m.shown {
                options.append((index,CGRect(x:panel.minX+12,y:top+CGFloat(index-first)*Self.row,width:width-24,height:Self.row-2)))
            }
        }
        let footer = CGRect(x:panel.minX+16,y:top+rows+8,width:width-32,height:m.footer)
        return Layout(panel:panel,title:title,options:options,footer:footer,
                      moreAbove:first > 0,moreBelow:first+m.shown < value.options.count)
    }
    private func panel(_ rect:CGRect,in context:CGContext) {
        context.setFillColor(CGColor(red:0.03,green:0.04,blue:0.16,alpha:0.95));context.fill(rect)
        context.setStrokeColor(CGColor(gray:0.8,alpha:1));context.setLineWidth(1);context.stroke(rect.insetBy(dx:0.5,dy:0.5))
    }
    override func draw(_ dirtyRect:NSRect) {
        guard active,let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x:origin.x,y:origin.y);context.scaleBy(x:scale,y:scale)
        context.interpolationQuality = .none
        if let value = selector {
            let shape = layout(value)
            panel(shape.panel,in:context)
            (value.title as NSString).draw(with:shape.title,options:[.usesLineFragmentOrigin],attributes:attributes())
            for (index,rect) in shape.options {
                let option = value.options[index]
                if index == value.selected {
                    context.setFillColor(CGColor(red:0.25,green:0.35,blue:0.7,alpha:1));context.fill(rect.insetBy(dx:-3,dy:-2))
                }
                if let image = option.image {
                    let picture = CGRect(x:rect.midX-24,y:rect.midY-10,width:48,height:20)
                    Renderer.image(image,in:picture,context:context)
                } else {
                    let color:NSColor = option.enabled ? .white : NSColor(white:0.5,alpha:1)
                    var inset = value.horizontal ? rect : rect.insetBy(dx:8,dy:2)
                    if let checked = option.checked {
                        let box = CGRect(x:inset.minX,y:rect.midY-6,width:12,height:12)
                        context.setStrokeColor(color.cgColor);context.setLineWidth(1);context.stroke(box.insetBy(dx:0.5,dy:0.5))
                        if checked { context.setFillColor(color.cgColor);context.fill(box.insetBy(dx:3,dy:3)) }
                        inset = inset.offsetBy(dx:20,dy:0)
                    }
                    let paragraph = NSMutableParagraphStyle();paragraph.alignment = value.horizontal ? .center : .left
                    var style = attributes(color);style[.paragraphStyle] = paragraph
                    (option.label as NSString).draw(in:inset,withAttributes:style)
                }
            }
            if !value.footer.isEmpty {
                (value.footer as NSString).draw(with:shape.footer,options:[.usesLineFragmentOrigin],
                                                attributes:attributes(NSColor(red:1,green:0.85,blue:0.45,alpha:1)))
            }
            context.setFillColor(CGColor(gray:0.8,alpha:1))
            for (more,y,dy) in [(shape.moreAbove,shape.options.first?.rect.minY ?? 0,CGFloat(-5)),
                                (shape.moreBelow,shape.options.last?.rect.maxY ?? 0,CGFloat(5))] where more {
                let x = shape.panel.maxX-14,base = y+(dy < 0 ? 4 : -4)
                context.move(to:CGPoint(x:x-5,y:base));context.addLine(to:CGPoint(x:x+5,y:base))
                context.addLine(to:CGPoint(x:x,y:base+dy));context.closePath();context.fillPath()
            }
        } else if let value = notice {
            let rect = CGRect(x:24,y:232,width:496,height:96)
            panel(rect,in:context)
            var textX:CGFloat = 36
            if let portrait = value.portrait {
                Renderer.image(portrait,in:CGRect(x:32,y:240,width:min(CGFloat(portrait.width),64),height:min(CGFloat(portrait.height),80)),context:context)
                textX = 108
            }
            if !value.speaker.isEmpty {
                (value.speaker as NSString).draw(in:CGRect(x:textX,y:238,width:400,height:20),
                    withAttributes:attributes(NSColor(red:1,green:0.85,blue:0.45,alpha:1)))
            }
            (value.text as NSString).draw(with:CGRect(x:textX,y:value.speaker.isEmpty ? 240 : 258,width:512-textX,height:value.speaker.isEmpty ? 84 : 66),
                                          options:[.usesLineFragmentOrigin],attributes:attributes())
        }
        context.restoreGState()
    }
    override func keyDown(with event:NSEvent) {
        if notice != nil {
            if [36,49,76,53].contains(event.keyCode),!event.isARepeat { dismissNotice() }
            return
        }
        guard var value = selector else { super.keyDown(with:event);return }
        func step(_ delta:Int) {
            guard !value.options.isEmpty else { return }
            var index = value.selected
            for _ in value.options.indices {
                index = (index+delta+value.options.count)%value.options.count
                if value.options[index].enabled { break }
            }
            value.selected = index;selector = value;revealSelection();needsDisplay = true
        }
        switch event.keyCode {
        case 125,124: step(1)          // down, right
        case 126,123: step(-1)         // up, left
        case 36,49,76: if !event.isARepeat { choose(value.selected) }
        case 53: if value.cancellable { choose(nil) }
        default: break
        }
    }
    override func mouseDown(with event:NSEvent) {
        if notice != nil { dismissNotice();return }
        guard let value = selector else { return }
        let point = canvasPoint(event),shape = layout(value)
        if let hit = shape.options.first(where:{ $0.rect.insetBy(dx:-3,dy:-2).contains(point) }) { choose(hit.index) }
        else if value.cancellable,!shape.panel.contains(point) { choose(nil) }
    }
    override func scrollWheel(with event:NSEvent) {
        guard var value = selector,!value.horizontal,event.scrollingDeltaY != 0 else { return }
        let shown = metrics(value).shown,limit = max(0,value.options.count-shown)
        firstVisible = min(max(0,firstVisible+(event.scrollingDeltaY < 0 ? 1 : -1)),limit)
        if value.selected < firstVisible || value.selected >= firstVisible+shown,
           let index = (firstVisible..<firstVisible+shown).first(where:{ value.options[$0].enabled }) {
            value.selected = index;selector = value
        }
        needsDisplay = true
    }
    override func rightMouseDown(with event:NSEvent) {
        if let value = selector,value.cancellable { choose(nil) } else if notice != nil { dismissNotice() }
    }
}
