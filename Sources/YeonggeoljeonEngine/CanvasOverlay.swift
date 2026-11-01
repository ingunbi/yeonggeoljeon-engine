// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Native in-game selector drawn over the 640×400 source canvas. The window
/// is engine presentation; original selector window primitives are not
/// restored.
struct CanvasMenu {
    struct Option {
        var label:String
        var enabled = true
        /// A right-aligned column, such as a cost or a level.
        var value = ""
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
    /// Top-left corner for a window that opens beside a map cell. The panel
    /// keeps a compact width and stays inside the viewport.
    var anchor:CGPoint? = nil
    var onChoose:(Int?) -> Void
}

/// A line of text that waits for one input (battle dialogue, retirement).
struct CanvasNotice {
    var speaker:String
    var text:String
    var portrait:CGImage?
    /// Seconds before a source timed message closes by itself; input closes
    /// it sooner. Nil waits for input.
    var timeout:TimeInterval? = nil
    var onDismiss:() -> Void
}

/// One window that holds a whole counter visit: who speaks, a list, a detail
/// pane for the highlighted row, and the answers along the bottom.
struct CanvasSheet {
    struct Detail {
        var heading = ""
        var body = ""
        var list:[String] = []
        var facts:[(label:String,value:String)] = []
    }
    struct Row {
        var label:String
        var value = ""
        /// Draws the value as a warning; the row can still be chosen.
        var warns = false
        var detail:Detail? = nil
    }
    enum Mode { case list,buttons,timed }
    var portrait:CGImage?
    var speaker:String
    var line:String
    var badge:(label:String,value:String)
    var rows:[Row]
    var selected = 0
    var mode:Mode
    /// Replaces the highlighted row's detail while the list is frozen.
    var detail:Detail? = nil
    var buttons:[String] = []
    var hint = ""
    /// A list row or button index, nil for cancel, zero when a timed line ends.
    var onChoose:(Int?) -> Void
}

/// The terrain window of one map cell, placed by source coordinates.
struct CanvasTerrain {
    var layout:OriginalBattleLayout.Terrain
    var origin:CGPoint
    var tile:CGImage?
    var name:String
    var heading:String
    var percent:String
    var recovery:String?
    var onDismiss:() -> Void
}

/// The victory conditions window, placed by source coordinates.
struct CanvasBrief {
    var layout:OriginalBattleLayout.Conditions
    var title:String
    var heading:String
    var lines:[String]
    var turns:String
    var button:CGImage?
    var onDismiss:() -> Void
}

final class CanvasOverlayView:NSView {
    private(set) var selector:CanvasMenu?
    private(set) var notice:CanvasNotice?
    private(set) var brief:CanvasBrief?
    private(set) var terrain:CanvasTerrain?
    private(set) var sheet:CanvasSheet?
    private var noticeTimer:Timer?
    /// Parent windows still on screen behind the active selector.
    private var parents:[CanvasMenu] = []
    private var sheetButton = 0
    /// First vertical row shown when a list is taller than the viewport.
    private var firstVisible = 0
    /// The canvas area panels stay inside: the field map window by default,
    /// the battle map window while a battle screen is up.
    static let fieldViewport = CGRect(x:16,y:16,width:512,height:320)
    var viewport = fieldViewport
    private func noticeRect(_ value:CanvasNotice) -> CGRect {
        guard value.portrait == nil,value.speaker.isEmpty else {
            return CGRect(x:viewport.minX+8,y:viewport.maxY-112,width:viewport.width-16,height:104)
        }
        // A plain refusal is a small card in the middle of the map window.
        let style = CanvasTheme.attributes(font,CanvasTheme.text)
        let limit = viewport.width-48
        let width = min(limit,ceil((value.text as NSString).size(withAttributes:style).width))+40
        let height = textHeight(value.text,width:width-40)+28
        return CGRect(x:viewport.midX-width/2,y:viewport.midY-height/2,width:width,height:height).integral
    }
    /// Called after the overlay closes so the owner can restore focus.
    var restoreFocus:(() -> Void)?
    var active:Bool { selector != nil || notice != nil || brief != nil || terrain != nil || sheet != nil }
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { active }
    override func hitTest(_ point:NSPoint) -> NSView? { active ? super.hitTest(point) : nil }
    private let font = CanvasTheme.font(14)
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseMoved,.activeInKeyWindow],owner:self))
    }

    /// keepScroll preserves the list position when a menu is shown again
    /// after one of its rows changed (party toggles).
    func show(_ value:CanvasMenu,keepScroll:Bool = false,behind:[CanvasMenu] = []) {
        var value = value
        if !value.options.indices.contains(value.selected) || !value.options[value.selected].enabled {
            value.selected = value.options.firstIndex(where:\.enabled) ?? 0
        }
        if !keepScroll { firstVisible = 0 }
        clear();parents = behind;selector = value;revealSelection();present()
    }
    func show(_ value:CanvasNotice) {
        clear();notice = value;present()
        guard let timeout = value.timeout else { return }
        noticeTimer = Timer.scheduledTimer(withTimeInterval:timeout,repeats:false) { [weak self] _ in self?.dismissNotice() }
    }
    func show(_ value:CanvasBrief) { clear();brief = value;present() }
    func show(_ value:CanvasTerrain) { clear();terrain = value;present() }
    /// The next step of a visit keeps the list position of the last one.
    func show(_ value:CanvasSheet) {
        clear();sheet = value;sheetButton = 0;revealSheetRow();present()
        guard value.mode == .timed else { return }
        noticeTimer = Timer.scheduledTimer(withTimeInterval:2,repeats:false) { [weak self] _ in self?.finishSheet(0) }
    }
    private func clear() { selector = nil;notice = nil;brief = nil;terrain = nil;sheet = nil;parents = [] }
    private func present() {
        noticeTimer?.invalidate();noticeTimer = nil
        isHidden = false;needsDisplay = true
        window?.makeFirstResponder(self)
    }
    private func close() {
        noticeTimer?.invalidate();noticeTimer = nil
        clear();needsDisplay = true
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
    private func dismissBrief() {
        guard let value = brief else { return }
        close();value.onDismiss()
    }
    private func dismissTerrain() {
        guard let value = terrain else { return }
        close();value.onDismiss()
    }
    private func finishSheet(_ answer:Int?) {
        guard let value = sheet else { return }
        close();value.onChoose(answer)
    }

    private var geometry:CanvasGeometry { CanvasGeometry(bounds:bounds) }
    private func canvasPoint(_ event:NSEvent) -> CGPoint { geometry.canvas(convert(event.locationInWindow,from:nil)) }
    private func attributes(_ color:NSColor = CanvasTheme.text,size:CGFloat = 14) -> [NSAttributedString.Key:Any] {
        CanvasTheme.attributes(CanvasTheme.font(size),color)
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
    private static let row:CGFloat = 26
    /// Panel width, text heights and how many vertical rows fit in the
    /// viewport (the panel stays eight pixels shorter than it).
    private func metrics(_ value:CanvasMenu) -> (width:CGFloat,title:CGFloat,footer:CGFloat,shown:Int) {
        let check:CGFloat = value.options.contains(where:{ $0.checked != nil }) ? 22 : 0
        let labelWidth = value.options.map { ceil(($0.label as NSString).size(withAttributes:attributes()).width) }.max() ?? 0
        let valueWidth = value.options.map { ceil(($0.value as NSString).size(withAttributes:attributes()).width) }.max() ?? 0
        let column = valueWidth > 0 ? valueWidth+20 : 0
        let width:CGFloat = value.horizontal ? 300 : value.anchor != nil ? min(viewport.width-16,max(96,labelWidth+column+44+check)) :
            min(viewport.width-16,max(240,labelWidth+column+64+check))
        let title = textHeight(value.title,width:width-40),footer = textHeight(value.footer,width:width-40)
        let chrome = 24+(title > 0 ? title+12 : 0)+(footer > 0 ? footer+10 : 0)
        let shown = value.horizontal ? value.options.count : min(value.options.count,max(1,Int((viewport.height-8-chrome)/Self.row)))
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
        let rows:CGFloat = value.horizontal ? 32 : CGFloat(m.shown)*Self.row
        let height = 24+(m.title > 0 ? m.title+12 : 0)+rows+(m.footer > 0 ? m.footer+10 : 0)
        var panel = CGRect(x:viewport.minX+(viewport.width-width)/2,y:max(viewport.minY+4,viewport.minY+(viewport.height-height)/2),width:width,height:height).integral
        if let anchor = value.anchor {
            panel.origin = CGPoint(x:min(max(anchor.x,viewport.minX+4),viewport.maxX-width-4),y:min(max(anchor.y,viewport.minY+4),viewport.maxY-height-4))
        }
        let title = CGRect(x:panel.minX+20,y:panel.minY+14,width:width-40,height:m.title)
        let top = m.title > 0 ? title.maxY+12 : panel.minY+12
        var options:[(index:Int,rect:CGRect)] = []
        let first = value.horizontal ? 0 : min(firstVisible,max(0,value.options.count-m.shown))
        if value.horizontal {
            // Buttons sit at the card's lower right, the first on the left.
            let button = CGSize(width:76,height:30),gap:CGFloat = 8
            let total = CGFloat(value.options.count)*button.width+CGFloat(max(0,value.options.count-1))*gap
            for index in value.options.indices {
                options.append((index,CGRect(x:panel.maxX-16-total+CGFloat(index)*(button.width+gap),y:top,width:button.width,height:button.height)))
            }
        } else {
            for index in first..<first+m.shown {
                options.append((index,CGRect(x:panel.minX+8,y:top+CGFloat(index-first)*Self.row,width:width-16,height:Self.row-2)))
            }
        }
        let footer = CGRect(x:panel.minX+20,y:top+rows+8,width:width-40,height:m.footer)
        return Layout(panel:panel,title:title,options:options,footer:footer,
                      moreAbove:first > 0,moreBelow:first+m.shown < value.options.count)
    }
    private func drawButton(_ label:String,in rect:CGRect,focused:Bool,context:CGContext) {
        if focused { CanvasTheme.fill(rect,CanvasTheme.accentFill,radius:6,in:context) } else { CanvasTheme.stroke(rect,radius:6,in:context) }
        let style = CanvasTheme.attributes(CanvasTheme.font(13,.semibold),focused ? CanvasTheme.onAccent : CanvasTheme.text,alignment:.center)
        (label as NSString).draw(in:CGRect(x:rect.minX,y:rect.midY-9,width:rect.width,height:20),withAttributes:style)
    }
    private func drawMore(_ more:(above:Bool,below:Bool),x:CGFloat,top:CGFloat,bottom:CGFloat,in context:CGContext) {
        context.setFillColor(CanvasTheme.muted.cgColor)
        for (shown,y,dy) in [(more.above,top+5,CGFloat(-4)),(more.below,bottom-5,CGFloat(4))] where shown {
            context.move(to:CGPoint(x:x-4,y:y));context.addLine(to:CGPoint(x:x+4,y:y))
            context.addLine(to:CGPoint(x:x,y:y+dy));context.closePath();context.fillPath()
        }
    }
    private func drawMenu(_ value:CanvasMenu,in context:CGContext) {
        let shape = layout(value)
        CanvasTheme.panel(shape.panel,in:context)
        (value.title as NSString).draw(with:shape.title,options:[.usesLineFragmentOrigin],attributes:attributes())
        for (index,rect) in shape.options {
            let option = value.options[index]
            if value.horizontal { drawButton(option.label,in:rect,focused:index == value.selected,context:context);continue }
            if index == value.selected { CanvasTheme.fill(rect,CanvasTheme.selection,in:context) }
            let color = option.enabled ? CanvasTheme.text : CanvasTheme.disabled
            var inset = rect.insetBy(dx:10,dy:3)
            if let checked = option.checked {
                let box = CGRect(x:inset.minX,y:rect.midY-7,width:14,height:14)
                if checked {
                    CanvasTheme.fill(box,option.enabled ? CanvasTheme.accentFill : CanvasTheme.hairline,radius:3,in:context)
                    context.setStrokeColor(CanvasTheme.onAccent.cgColor);context.setLineWidth(1.6);context.setLineCap(.round)
                    context.move(to:CGPoint(x:box.minX+3.5,y:box.midY));context.addLine(to:CGPoint(x:box.midX-1,y:box.maxY-4))
                    context.addLine(to:CGPoint(x:box.maxX-3.5,y:box.minY+4));context.strokePath()
                } else { CanvasTheme.stroke(box,radius:3,in:context) }
                inset = inset.offsetBy(dx:22,dy:0);inset.size.width -= 22
            }
            (option.label as NSString).draw(in:inset,withAttributes:attributes(color))
            if !option.value.isEmpty {
                (option.value as NSString).draw(in:inset,withAttributes:CanvasTheme.attributes(CanvasTheme.number(13),option.enabled ? CanvasTheme.muted : CanvasTheme.disabled,alignment:.right))
            }
        }
        if !value.footer.isEmpty {
            (value.footer as NSString).draw(with:shape.footer,options:[.usesLineFragmentOrigin],attributes:attributes(CanvasTheme.accent,size:12))
        }
        if !value.horizontal,let first = shape.options.first,let last = shape.options.last {
            drawMore((shape.moreAbove,shape.moreBelow),x:shape.panel.maxX-16,top:first.rect.minY,bottom:last.rect.maxY,in:context)
        }
    }
    private struct SheetLayout {
        var panel:CGRect; var header:CGFloat; var list:CGRect; var detail:CGRect; var footer:CGFloat
        var rows:[(index:Int,rect:CGRect)]; var buttons:[(index:Int,rect:CGRect)]
    }
    private static let sheetRows = 8,sheetRow:CGFloat = 24
    private func sheetLayout(_ value:CanvasSheet) -> SheetLayout {
        let panel = viewport.insetBy(dx:8,dy:8),header = panel.minY+78,footer = panel.maxY-40
        let list = CGRect(x:panel.minX+8,y:header+6,width:210,height:Self.sheetRow*CGFloat(Self.sheetRows))
        let detail = CGRect(x:list.maxX+14,y:header+10,width:panel.maxX-list.maxX-30,height:footer-header-18)
        let shown = min(value.rows.count,Self.sheetRows),first = min(firstVisible,max(0,value.rows.count-shown))
        let rows = (0..<shown).map { (index:first+$0,rect:CGRect(x:list.minX,y:list.minY+CGFloat($0)*Self.sheetRow,width:list.width,height:Self.sheetRow-2)) }
        let width:CGFloat = 76,gap:CGFloat = 8,total = CGFloat(value.buttons.count)*(width+gap)-gap
        let buttons = value.buttons.indices.map { (index:$0,rect:CGRect(x:panel.maxX-12-total+CGFloat($0)*(width+gap),y:footer+6,width:width,height:28)) }
        return SheetLayout(panel:panel,header:header,list:list,detail:detail,footer:footer,rows:rows,buttons:buttons)
    }
    /// Screen position of one button, for callers that test the window.
    func sheetButtonRect(_ index:Int) -> CGRect? { sheet.flatMap { sheetLayout($0).buttons.first{$0.index == index}?.rect } }
    func sheetRowRect(_ index:Int) -> CGRect? { sheet.flatMap { sheetLayout($0).rows.first{$0.index == index}?.rect } }
    private func revealSheetRow() {
        guard let value = sheet else { firstVisible = 0;return }
        let limit = max(0,value.rows.count-Self.sheetRows)
        if value.selected < firstVisible { firstVisible = value.selected }
        if value.selected >= firstVisible+Self.sheetRows { firstVisible = value.selected-Self.sheetRows+1 }
        firstVisible = min(max(0,firstVisible),limit)
    }
    private func drawDetail(_ detail:CanvasSheet.Detail,in rect:CGRect,context:CGContext) {
        var y = rect.minY
        if !detail.heading.isEmpty {
            (detail.heading as NSString).draw(in:CGRect(x:rect.minX,y:y,width:rect.width,height:22),withAttributes:CanvasTheme.attributes(CanvasTheme.font(15,.semibold),CanvasTheme.text))
            y += 26
        }
        if !detail.body.isEmpty {
            let height = ceil((detail.body as NSString).boundingRect(with:CGSize(width:rect.width,height:200),options:[.usesLineFragmentOrigin],attributes:attributes(CanvasTheme.muted,size:13)).height)
            (detail.body as NSString).draw(with:CGRect(x:rect.minX,y:y,width:rect.width,height:height+2),options:[.usesLineFragmentOrigin],attributes:attributes(CanvasTheme.muted,size:13))
            y += height+8
        }
        for item in detail.list {
            (item as NSString).draw(in:CGRect(x:rect.minX,y:y,width:rect.width,height:18),withAttributes:attributes(CanvasTheme.text,size:13))
            y += 19
        }
        // Facts close an item's text from below; alone they follow the heading.
        let closing = !detail.body.isEmpty
        var row = closing ? rect.maxY-CGFloat(detail.facts.count)*20 : y
        if closing,!detail.facts.isEmpty { CanvasTheme.divider(from:CGPoint(x:rect.minX,y:row-5.5),to:CGPoint(x:rect.maxX,y:row-5.5),in:context) }
        for fact in detail.facts {
            let line = CGRect(x:rect.minX,y:row,width:rect.width,height:18)
            (fact.label as NSString).draw(in:line,withAttributes:attributes(closing ? CanvasTheme.muted : CanvasTheme.text,size:closing ? 12 : 13))
            (fact.value as NSString).draw(in:line,withAttributes:CanvasTheme.attributes(CanvasTheme.number(13,.medium),CanvasTheme.text,alignment:.right))
            row += 20
        }
    }
    private func drawSheet(_ value:CanvasSheet,in context:CGContext) {
        let shape = sheetLayout(value),panel = shape.panel
        CanvasTheme.panel(panel,in:context)
        var textX = panel.minX+16
        if let portrait = value.portrait {
            let picture = CGRect(x:panel.minX+12,y:panel.minY+10,width:47,height:58)
            context.saveGState();CanvasTheme.rounded(picture,5,in:context);context.clip()
            Renderer.image(portrait,in:picture,context:context);context.restoreGState()
            textX = picture.maxX+12
        }
        let badgeWidth:CGFloat = 96,textWidth = panel.maxX-textX-badgeWidth-20
        (value.speaker as NSString).draw(in:CGRect(x:textX,y:panel.minY+10,width:textWidth,height:18),withAttributes:CanvasTheme.attributes(CanvasTheme.font(12,.semibold),CanvasTheme.accent))
        (value.line as NSString).draw(with:CGRect(x:textX,y:panel.minY+29,width:textWidth,height:44),options:[.usesLineFragmentOrigin],attributes:attributes())
        let badge = CGRect(x:panel.maxX-16-badgeWidth,y:panel.minY+10,width:badgeWidth,height:16)
        (value.badge.label as NSString).draw(in:badge,withAttributes:CanvasTheme.attributes(CanvasTheme.font(11),CanvasTheme.muted,alignment:.right))
        (value.badge.value as NSString).draw(in:badge.offsetBy(dx:0,dy:15).insetBy(dx:0,dy:-2),withAttributes:CanvasTheme.attributes(CanvasTheme.number(16,.semibold),CanvasTheme.text,alignment:.right))
        CanvasTheme.divider(from:CGPoint(x:panel.minX,y:shape.header+0.5),to:CGPoint(x:panel.maxX,y:shape.header+0.5),in:context)
        CanvasTheme.divider(from:CGPoint(x:panel.minX,y:shape.footer+0.5),to:CGPoint(x:panel.maxX,y:shape.footer+0.5),in:context)
        CanvasTheme.divider(from:CGPoint(x:shape.list.maxX+6.5,y:shape.header),to:CGPoint(x:shape.list.maxX+6.5,y:shape.footer),in:context)
        let frozen = value.mode != .list
        for (index,rect) in shape.rows {
            let row = value.rows[index]
            if index == value.selected { CanvasTheme.fill(rect,frozen ? CanvasTheme.inset : CanvasTheme.selection,in:context) }
            let inset = rect.insetBy(dx:10,dy:3)
            (row.label as NSString).draw(in:inset,withAttributes:attributes(frozen && index != value.selected ? CanvasTheme.muted : CanvasTheme.text))
            if !row.value.isEmpty {
                let color = row.warns ? CanvasTheme.danger : frozen ? CanvasTheme.disabled : CanvasTheme.muted
                (row.value as NSString).draw(in:inset,withAttributes:CanvasTheme.attributes(CanvasTheme.number(13),color,alignment:.right))
            }
        }
        if let first = shape.rows.first,let last = shape.rows.last {
            drawMore((first.index > 0,last.index+1 < value.rows.count),x:shape.list.maxX-10,top:first.rect.minY,bottom:last.rect.maxY,in:context)
        }
        if let detail = value.detail ?? (value.rows.indices.contains(value.selected) ? value.rows[value.selected].detail : nil) {
            drawDetail(detail,in:shape.detail,context:context)
        }
        (value.hint as NSString).draw(in:CGRect(x:panel.minX+18,y:shape.footer+12,width:panel.width-200,height:16),withAttributes:attributes(CanvasTheme.muted,size:11))
        for (index,rect) in shape.buttons { drawButton(value.buttons[index],in:rect,focused:index == sheetButton,context:context) }
    }
    private func drawNotice(_ value:CanvasNotice,in context:CGContext) {
        let rect = noticeRect(value)
        CanvasTheme.panel(rect,in:context)
        var textX = rect.minX+20
        if let portrait = value.portrait {
            let picture = CGRect(x:rect.minX+10,y:rect.minY+10,width:67,height:84)
            context.saveGState();CanvasTheme.rounded(picture,5,in:context);context.clip()
            Renderer.image(portrait,in:picture,context:context);context.restoreGState()
            textX = picture.maxX+14
        } else if !value.speaker.isEmpty { textX = rect.minX+18 }
        if !value.speaker.isEmpty {
            (value.speaker as NSString).draw(in:CGRect(x:textX,y:rect.minY+10,width:rect.maxX-textX-12,height:18),
                withAttributes:CanvasTheme.attributes(CanvasTheme.font(12,.semibold),CanvasTheme.accent))
        }
        let top = value.speaker.isEmpty ? (value.portrait == nil ? rect.minY+14 : rect.minY+18) : rect.minY+30
        (value.text as NSString).draw(with:CGRect(x:textX,y:top,width:rect.maxX-textX-18,height:rect.maxY-top-6),
                                      options:[.usesLineFragmentOrigin],attributes:attributes())
        if value.timeout == nil,value.portrait != nil || !value.speaker.isEmpty {
            CanvasTheme.continueMark(at:CGPoint(x:rect.maxX-16,y:rect.maxY-13),in:context)
        }
    }
    private func drawTerrain(_ value:CanvasTerrain,in context:CGContext) {
        let facts = value.layout,x = Int(value.origin.x),y = Int(value.origin.y)
        CanvasTheme.panel(CGRect(x:x,y:y,width:facts.size[0],height:facts.size[1]),in:context)
        if let tile = value.tile {
            Renderer.image(tile,in:CGRect(x:x+facts.tile[0],y:y+facts.tile[1],width:facts.tile[2],height:facts.tile[3]),context:context)
        }
        func line(_ text:String,_ px:Int,_ py:Int) { (text as NSString).draw(at:CGPoint(x:px,y:py-1),withAttributes:attributes()) }
        line(value.heading,x+facts.textX,y+facts.headingY)
        let paragraph = NSMutableParagraphStyle();paragraph.alignment = .center
        var centered = attributes();centered[.paragraphStyle] = paragraph
        (value.percent as NSString).draw(in:CGRect(x:x+facts.textX,y:y+facts.percentY-1,width:facts.percentWidth,height:18),withAttributes:centered)
        line(value.name,x+facts.tile[0],y+facts.nameY)
        if let recovery = value.recovery { line(recovery,x+facts.textX,y+facts.nameY) }
    }
    private func drawBrief(_ value:CanvasBrief,in context:CGContext) {
        let facts = value.layout
        CanvasTheme.panel(OriginalBattleLayout.rect(facts.window),in:context)
        for box in [facts.textBox,facts.turnBox] {
            CanvasTheme.fill(OriginalBattleLayout.rect(box),CanvasTheme.inset,in:context)
        }
        func line(_ text:String,_ column:Int,_ y:Int,_ color:NSColor = CanvasTheme.text) {
            (text as NSString).draw(at:CGPoint(x:column*8,y:y-1),withAttributes:attributes(color))
        }
        line(value.title,facts.titleColumn,facts.headerY)
        line(value.heading,facts.headingColumn,facts.headerY,CanvasTheme.accent)
        for (index,text) in value.lines.enumerated() { line(text,facts.textColumn,facts.textY+index*facts.lineStep) }
        line(value.turns,facts.turnColumn,facts.turnY)
        if let picture = value.button { Renderer.image(picture,in:OriginalBattleLayout.rect(facts.button),context:context) }
    }
    override func draw(_ dirtyRect:NSRect) {
        guard active,let context = NSGraphicsContext.current?.cgContext else { return }
        let shape = geometry
        context.saveGState()
        context.translateBy(x:shape.origin.x,y:shape.origin.y);context.scaleBy(x:shape.scale,y:shape.scale)
        context.interpolationQuality = .none
        if let value = selector {
            for parent in parents { drawMenu(parent,in:context) }
            drawMenu(value,in:context)
        } else if let value = sheet { drawSheet(value,in:context) }
        else if let value = brief { drawBrief(value,in:context) }
        else if let value = terrain { drawTerrain(value,in:context) }
        else if let value = notice { drawNotice(value,in:context) }
        context.restoreGState()
    }
    override func keyDown(with event:NSEvent) {
        if notice != nil {
            if [36,49,76,53].contains(event.keyCode),!event.isARepeat { dismissNotice() }
            return
        }
        if brief != nil {
            if [36,49,76,53].contains(event.keyCode),!event.isARepeat { dismissBrief() }
            return
        }
        if terrain != nil {
            if !event.isARepeat { dismissTerrain() }
            return
        }
        if sheet != nil { sheetKey(event);return }
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
    private func sheetKey(_ event:NSEvent) {
        guard var value = sheet,!event.isARepeat || [125,126].contains(event.keyCode) else { return }
        switch value.mode {
        case .timed:if [36,49,76,53].contains(event.keyCode) { finishSheet(0) }
        case .list:
            switch event.keyCode {
            case 125,126:
                guard !value.rows.isEmpty else { return }
                value.selected = (value.selected+(event.keyCode == 125 ? 1 : value.rows.count-1))%value.rows.count
                sheet = value;revealSheetRow();needsDisplay = true
            case 36,49,76:if value.rows.indices.contains(value.selected) { finishSheet(value.selected) }
            case 53:finishSheet(nil)
            default:break
            }
        case .buttons:
            switch event.keyCode {
            case 123,124,125,126,48:sheetButton = (sheetButton+1)%max(1,value.buttons.count);needsDisplay = true
            case 36,49,76:finishSheet(sheetButton)
            case 53:finishSheet(value.buttons.count-1)      // the last button declines
            default:break
            }
        }
    }
    override func mouseMoved(with event:NSEvent) {
        let point = canvasPoint(event)
        if var value = sheet {
            if value.mode == .list,let hit = sheetLayout(value).rows.first(where:{ $0.rect.contains(point) }),hit.index != value.selected {
                value.selected = hit.index;sheet = value;needsDisplay = true
            }
            if value.mode == .buttons,let hit = sheetLayout(value).buttons.first(where:{ $0.rect.contains(point) }),hit.index != sheetButton {
                sheetButton = hit.index;needsDisplay = true
            }
        } else if var value = selector,let hit = layout(value).options.first(where:{ $0.rect.contains(point) }),
                  value.options[hit.index].enabled,hit.index != value.selected {
            value.selected = hit.index;selector = value;needsDisplay = true
        }
    }
    override func mouseDown(with event:NSEvent) {
        if let value = sheet {
            let point = canvasPoint(event),shape = sheetLayout(value)
            switch value.mode {
            case .timed:finishSheet(0)
            case .list:if let hit = shape.rows.first(where:{ $0.rect.contains(point) }) { finishSheet(hit.index) }
            case .buttons:if let hit = shape.buttons.first(where:{ $0.rect.contains(point) }) { finishSheet(hit.index) }
            }
            return
        }
        if notice != nil { dismissNotice();return }
        if brief != nil { dismissBrief();return }
        if terrain != nil { dismissTerrain();return }
        guard let value = selector else { return }
        let point = canvasPoint(event),shape = layout(value)
        if let hit = shape.options.first(where:{ $0.rect.insetBy(dx:-3,dy:-2).contains(point) }) { choose(hit.index) }
        else if value.cancellable,!shape.panel.contains(point) { choose(nil) }
    }
    override func scrollWheel(with event:NSEvent) {
        if var value = sheet,value.mode == .list,event.scrollingDeltaY != 0,!value.rows.isEmpty {
            value.selected = min(max(0,value.selected+(event.scrollingDeltaY < 0 ? 1 : -1)),value.rows.count-1)
            sheet = value;revealSheetRow();needsDisplay = true
            return
        }
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
        if let value = sheet { finishSheet(value.mode == .list ? nil : value.mode == .timed ? 0 : value.buttons.count-1) }
        else if let value = selector,value.cancellable { choose(nil) } else if notice != nil { dismissNotice() } else if brief != nil { dismissBrief() } else if terrain != nil { dismissTerrain() }
    }
}
