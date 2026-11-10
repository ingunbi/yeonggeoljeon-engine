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
        /// An SF Symbol drawn before the label (engine presentation).
        var icon:String? = nil
        /// Ends or abandons something (quit, retreat): drawn in the danger colour.
        var destructive = false
        /// A hairline above the row starts a new group.
        var separatorBefore = false
        /// Plain-language help for the highlighted option, in the panel footer.
        var help = ""
    }
    var title:String
    var options:[Option]
    var selected = 0
    var horizontal = false
    /// Escape or a secondary click chooses nil when cancellation is allowed.
    var cancellable = false
    /// A status line under the options (remaining capacity, a refusal).
    var footer = ""
    var displayedFooter:String {
        guard options.indices.contains(selected),!options[selected].help.isEmpty else { return footer }
        return options[selected].help
    }
    /// Top-left corner for a window that opens beside a map cell. The panel
    /// keeps a compact width and stays inside the viewport. A title menu
    /// hangs from this point by its top centre instead.
    var anchor:CGPoint? = nil
    /// MAIN's own window picture and its button rectangles, in canvas pixels.
    struct Art {
        var image:CGImage; var frame:CGRect; var buttons:[CGRect]; var text:NSColor; var disabled:NSColor
        /// MAIN's glyphs for a label (enabled or not), 16 pixels high.
        var label:((String,Bool) -> CGImage?)? = nil
    }
    enum Style { case panel,title,window(Art) }
    /// `.title` sets larger rows straight over a picture, on a soft band;
    /// `.window` labels the buttons of an original window picture.
    var style = Style.panel
    var onChoose:(Int?) -> Void
    /// A click outside the window cancels it. The title menu turns this off:
    /// its cancel ends the game, which needs Esc or a right click.
    var cancelsOnOutsideClick = true
    /// Left and right change a row that shows a value in place (index, step);
    /// the owner stores it and shows the menu again.
    var onAdjust:((Int,Int) -> Void)? = nil
}

/// A black sheet for MAIN's palette fades over the stage and the battle; it takes no input.
final class CanvasCurtain:NSView {
    override init(frame:NSRect) { super.init(frame:frame);wantsLayer = true;layer?.backgroundColor = CGColor(gray:0,alpha:1);isHidden = true }
    convenience init() { self.init(frame:.zero) }
    required init?(coder:NSCoder) { nil }
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
}

/// A line of text that waits for one input (battle dialogue, retirement).
struct CanvasNotice {
    var speaker:String
    var text:String
    var portrait:CGImage?
    /// Seconds before a source timed message closes by itself; input closes
    /// it sooner. Nil waits for input.
    var timeout:TimeInterval? = nil
    /// A script line that waits for input sits low, where dialogue does,
    /// even without a speaker, so a picture above it stays visible.
    var narration = false
    /// MAIN337FE: a battle line whose speaker is in the lower half of the map
    /// sits near the top of the viewport so it does not cover the unit.
    var placeAtTop = false
    var onDismiss:() -> Void
    /// A spoken or narrated line that waits for input (it shows the continue mark).
    var waitsAsLine:Bool { timeout == nil && (portrait != nil || !speaker.isEmpty || narration) }
}

/// One window that holds a whole counter visit: who speaks, a list, a detail
/// pane for the highlighted row, and the answers along the bottom.
struct CanvasSheet {
    struct Detail {
        var heading = ""
        var body = ""
        var list:[String] = []
        var facts:[(label:String,value:String)] = []
        /// Lays the list and facts out in two columns.
        var wide = false
        var portrait:CGImage? = nil
        /// A map under the text, with dots placed in unit square coordinates.
        var picture:CGImage? = nil
        var marks:[(point:CGPoint,strong:Bool)] = []
        /// Read-only strategy facts and source-derived grid shapes.
        var strategy:StrategyGuideDetails.Description? = nil
        var rangeComparison:CanvasRangeComparison.Model? = nil
        var rangePatternPreview = false
    }
    struct Row {
        var label:String
        var value = ""
        /// Draws the value as a warning; the row can still be chosen.
        var warns = false
        var detail:Detail? = nil
        var enabled = true
        /// Non-nil draws a check box.
        var checked:Bool? = nil
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
    /// Reference sheets can use the full canvas instead of the map viewport.
    var fullCanvas = false
    /// Optional fixed actions below a browsable list. Row selection only reads;
    /// a button click or explicit keyboard focus is needed to invoke an action.
    var onButton:((Int) -> Void)? = nil
    var onRowButton:((Int,Int) -> Void)? = nil
    var hasRowActions:Bool { onButton != nil || onRowButton != nil }
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
    /// MAIN's MARK button in original frames; nil draws the engine's button.
    var button:CGImage?
    var onDismiss:() -> Void
}

final class CanvasOverlayView:NSView {
    /// Reading controls along a waiting line (engine additions).
    enum LineControl:CaseIterable { case log,auto,skip }
    /// The owner that handles the controls; nil hides them.
    var onLineControl:((LineControl) -> Void)?
    var showsLog = true
    private var hoveredControl:LineControl?
    /// Auto mode counts its reading pause from when the whole line shows.
    private var autoStart:Date?
    private var autoTimer:Timer?
    private var paceObserver:NSObjectProtocol?
    override init(frame:NSRect) {
        super.init(frame:frame)
        paceObserver = NotificationCenter.default.addObserver(forName:DialoguePace.changed,object:nil,queue:.main) { [weak self] _ in
            // Turning skip on also completes a line that was already typing.
            // Keep it revealed if skip stops again at the next boundary.
            if DialoguePace.shared.skipping { self?.stopReveal() }
            self?.updateAuto();self?.needsDisplay = true
        }
    }
    convenience init() { self.init(frame:.zero) }
    required init?(coder:NSCoder) { nil }
    deinit {
        noticeTimer?.invalidate();revealTimer?.invalidate();autoTimer?.invalidate()
        if let observer = paceObserver { NotificationCenter.default.removeObserver(observer) }
    }
    private(set) var selector:CanvasMenu?
    private(set) var notice:CanvasNotice?
    private(set) var brief:CanvasBrief?
    private(set) var terrain:CanvasTerrain?
    private(set) var sheet:CanvasSheet?
    private var noticeTimer:Timer?
    private var noticeDeadline:Date?
    private var timedDismiss:(() -> Void)?
    private var suspendedAt:Date?
    var isSuspended:Bool { suspendedAt != nil }
    /// Cover an existing line or selector without acknowledging it or letting
    /// its reading/timed countdown expire beneath an engine dialog.
    func setSuspended(_ value:Bool,now:Date = Date()) {
        if value {
            if suspendedAt == nil { suspendedAt = now }
        } else if let start = suspendedAt {
            let elapsed = max(0,now.timeIntervalSince(start))
            revealStart = revealStart?.addingTimeInterval(elapsed)
            autoStart = autoStart?.addingTimeInterval(elapsed)
            noticeDeadline = noticeDeadline?.addingTimeInterval(elapsed)
            suspendedAt = nil;updateAuto()
        }
        needsDisplay = true
    }
    /// Parent windows still on screen behind the active selector.
    private var parents:[CanvasMenu] = []
    private var sheetButton = 0
    private var sheetActionFocused = false
    /// First vertical row shown when a list is taller than the viewport.
    private var firstVisible = 0
    private(set) var detailScroll:CGFloat = 0
    private var noticeScroll:CGFloat = 0
    /// The canvas area panels stay inside: the field map window by default,
    /// the battle map window while a battle screen is up.
    static let fieldViewport = CGRect(x:16,y:16,width:512,height:320)
    var viewport = fieldViewport
    private static let portraitSize = CGSize(width:64,height:80)
    private func lineAttributes(_ color:NSColor = CanvasTheme.text) -> [NSAttributedString.Key:Any] {
        var style = CanvasTheme.attributes(CanvasTheme.font(15),color)
        if let paragraph = (style[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            paragraph.lineSpacing = 4;style[.paragraphStyle] = paragraph
        }
        return style
    }
    /// Where a line's text starts and how wide it may run inside its box.
    private func lineText(_ value:CanvasNotice,width:CGFloat) -> (left:CGFloat,width:CGFloat) {
        let left:CGFloat = value.portrait == nil ? 20 : 12+Self.portraitSize.width+16
        return (left,width-left-20)
    }
    private func noticeRect(_ value:CanvasNotice) -> CGRect {
        guard value.portrait == nil,value.speaker.isEmpty,!value.narration else {
            let width = min(viewport.width-16,560),text = lineText(value,width:width)
            let body = value.text.isEmpty ? 0 : ceil((value.text as NSString).boundingRect(with:CGSize(width:text.width,height:600),
                options:[.usesLineFragmentOrigin],attributes:lineAttributes()).height)
            // Text from the top inset down, then the control row.
            let height = min(viewport.height-32,max(value.portrait == nil ? 64 : Self.portraitSize.height+24,18+body+34*CanvasTheme.textScale))
            let y = value.placeAtTop ? viewport.minY+18 : max(viewport.minY+14,viewport.maxY-8-height)
            return CGRect(x:viewport.midX-width/2,y:y,width:width,height:height).integral
        }
        // A plain refusal is a small card in the middle of the map window.
        let style = CanvasTheme.attributes(font,CanvasTheme.text)
        let limit = viewport.width-48
        let width = min(limit,ceil((value.text as NSString).size(withAttributes:style).width))+40
        let height = min(viewport.height-32,textHeight(value.text,width:width-40)+28)
        return CGRect(x:viewport.midX-width/2,y:viewport.midY-height/2,width:width,height:height).integral
    }
    /// Called after the overlay closes so the owner can restore focus.
    var restoreFocus:(() -> Void)?
    var active:Bool { selector != nil || notice != nil || brief != nil || terrain != nil || sheet != nil }
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { active && !isSuspended }
    override func hitTest(_ point:NSPoint) -> NSView? { active && !isSuspended ? super.hitTest(point) : nil }
    private var font:NSFont { CanvasTheme.font(14) }
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
    /// Engine addition: a waiting line's text appears over a moment. The first
    /// input shows the rest at once; the next one closes the line.
    static let revealRate = 60.0
    private var revealStart:Date?
    private var revealTimer:Timer?
    private func revealed(_ text:String) -> Int {
        if DialoguePace.shared.skipping { return text.count }
        guard let start = revealStart else { return text.count }
        return max(0,min(text.count,Int((suspendedAt ?? Date()).timeIntervalSince(start)*Self.revealRate)))
    }
    /// The same count used by drawing; a skipped line never has a blank body.
    var visibleNoticeCharacterCount:Int? { notice.map { revealed($0.text) } }
    private var revealing:Bool { notice.map { revealed($0.text) < $0.text.count } ?? false }
    private func stopReveal() { revealTimer?.invalidate();revealTimer = nil;revealStart = nil;needsDisplay = true }
    func show(_ value:CanvasNotice) {
        clear();notice = value;present()
        if value.waitsAsLine,value.text.count > 1,!DialoguePace.shared.skipping {
            revealStart = Date()
            revealTimer = Timer.scheduledTimer(withTimeInterval:1.0/60,repeats:true) { [weak self] _ in
                guard let self = self,!self.isSuspended else { return }
                self.needsDisplay = true
                if !self.revealing { self.stopReveal();self.updateAuto() }
            }
        }
        updateAuto()
        guard let timeout = value.timeout else { return }
        startTimedNotice(seconds:timeout) { [weak self] in self?.dismissNotice() }
    }
    func show(_ value:CanvasBrief) { clear();brief = value;present() }
    func show(_ value:CanvasTerrain) { clear();terrain = value;present() }
    /// The next step of a visit keeps the list position of the last one.
    func show(_ value:CanvasSheet) {
        clear();sheet = value;sheetButton = 0;sheetActionFocused = false;revealSheetRow();present()
        guard value.mode == .timed else { return }
        startTimedNotice(seconds:2) { [weak self] in self?.finishSheet(0) }
    }
    private func startTimedNotice(seconds:TimeInterval,_ dismiss:@escaping () -> Void) {
        noticeDeadline = Date().addingTimeInterval(seconds);timedDismiss = dismiss
        noticeTimer = Timer.scheduledTimer(withTimeInterval:1.0/30,repeats:true) { [weak self] _ in self?.advanceTimedNotice() }
    }
    /// The explicit clock also permits deterministic presentation tests.
    func advanceTimedNotice(now:Date = Date()) {
        guard !isSuspended,let deadline = noticeDeadline,now >= deadline else { return }
        let dismiss = timedDismiss
        noticeTimer?.invalidate();noticeTimer = nil;noticeDeadline = nil;timedDismiss = nil
        dismiss?()
    }
    private func clear() { detailScroll = 0;noticeScroll = 0;selector = nil;notice = nil;brief = nil;terrain = nil;sheet = nil;parents = [] }
    private func present() {
        noticeTimer?.invalidate();noticeTimer = nil;revealTimer?.invalidate();revealTimer = nil;revealStart = nil
        noticeDeadline = nil;timedDismiss = nil
        isHidden = false;needsDisplay = true
        window?.makeFirstResponder(self)
    }
    /// Auto mode closes a waiting line after DialoguePace.readingSeconds once
    /// all of it shows.
    private func updateAuto() {
        guard !isSuspended else { return }
        guard let value = notice,value.waitsAsLine,onLineControl != nil,DialoguePace.shared.auto,!revealing else {
            autoTimer?.invalidate();autoTimer = nil;autoStart = nil;return
        }
        if autoStart == nil { autoStart = Date() }
        guard autoTimer == nil else { return }
        autoTimer = Timer.scheduledTimer(withTimeInterval:1.0/30,repeats:true) { [weak self] _ in
            guard let self = self,!self.isSuspended,let start = self.autoStart,let value = self.notice else { return }
            self.needsDisplay = true
            if Date().timeIntervalSince(start) >= DialoguePace.readingSeconds(value.text,speed:DialoguePace.shared.speed) { self.dismissNotice() }
        }
    }
    private func close() {
        noticeTimer?.invalidate();noticeTimer = nil;stopReveal()
        noticeDeadline = nil;timedDismiss = nil
        autoTimer?.invalidate();autoTimer = nil;autoStart = nil;hoveredControl = nil
        clear();needsDisplay = true
        restoreFocus?()
    }
    /// Source sound numbers: 0 left click, 1 right click, 10 not selectable.
    var onSound:((Int)->Void)?
    private func refuse() { if let play = onSound { play(10) } else { NSSound.beep() } }
    private func choose(_ index:Int?) {
        guard let value = selector else { return }
        if let index = index,!(value.options.indices.contains(index) && value.options[index].enabled) { refuse();return }
        onSound?(index == nil ? 1 : 0)
        close();value.onChoose(index)
    }
    private func dismissNotice() {
        guard let value = notice else { return }
        if revealing { stopReveal();updateAuto();return }
        close();value.onDismiss()
    }
    /// Fast-forward closes a plain line as a key press would, revealed or not.
    /// Questions and lists still wait for an answer.
    func skipNotice() { guard !isSuspended else { return };stopReveal();dismissNotice() }
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
        if case .timed = value.mode {} else { onSound?(answer == nil ? 1 : 0) }
        close();value.onChoose(answer)
    }
    private func finishSheetAction(_ index:Int) {
        guard let value = sheet,value.mode == .list,value.buttons.indices.contains(index),value.hasRowActions else { return }
        onSound?(0);close()
        if let action = value.onRowButton { action(index,value.selected) } else { value.onButton?(index) }
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
    private struct RowTextLayout {
        var label:CGRect;var value:CGRect;var stacked:Bool
    }
    private func rowStacks(label:String,value:String,width:CGFloat,labelFont:NSFont,valueFont:NSFont) -> Bool {
        !value.isEmpty && CanvasTheme.textWidth(label,font:labelFont)+CanvasTheme.textWidth(value,font:valueFont)+12 > width
    }
    private func rowHeight(label:String,value:String,width:CGFloat,labelFont:NSFont,valueFont:NSFont) -> CGFloat {
        let labelHeight = CanvasTheme.lineHeight(labelFont),valueHeight = CanvasTheme.lineHeight(valueFont)
        return rowStacks(label:label,value:value,width:width,labelFont:labelFont,valueFont:valueFont) ? labelHeight+valueHeight+11 : max(labelHeight,valueHeight)+8
    }
    private func rowTextLayout(label:String,value:String,in rect:CGRect,labelFont:NSFont,valueFont:NSFont) -> RowTextLayout {
        let stacked = rowStacks(label:label,value:value,width:rect.width,labelFont:labelFont,valueFont:valueFont)
        guard !value.isEmpty else {return .init(label:rect,value:.zero,stacked:false)}
        if stacked {
            let labelHeight = CanvasTheme.lineHeight(labelFont),valueHeight = CanvasTheme.lineHeight(valueFont),top = rect.midY-(labelHeight+valueHeight+3)/2
            return .init(label:CGRect(x:rect.minX,y:top,width:rect.width,height:labelHeight),value:CGRect(x:rect.minX,y:top+labelHeight+3,width:rect.width,height:valueHeight),stacked:true)
        }
        let valueWidth = min(rect.width,CanvasTheme.textWidth(value,font:valueFont))
        return .init(label:CGRect(x:rect.minX,y:rect.minY,width:max(0,rect.width-valueWidth-12),height:rect.height),value:CGRect(x:rect.maxX-valueWidth,y:rect.minY,width:valueWidth,height:rect.height),stacked:false)
    }
    private struct ButtonFlow {var buttons:[(index:Int,rect:CGRect)];var height:CGFloat}
    private func buttonFlow(_ labels:[String],width:CGFloat) -> ButtonFlow {
        guard !labels.isEmpty,width > 0 else {return .init(buttons:[],height:0)}
        let font = CanvasTheme.font(13,.bold),gap:CGFloat = 8,pad:CGFloat = 16
        var lines:[[(Int,CGSize)]] = [],current:[(Int,CGSize)] = [],used:CGFloat = 0
        for (index,label) in labels.enumerated() {
            let buttonWidth = min(width,max(76,CanvasTheme.textWidth(label,font:font)+pad*2))
            let textHeight = ceil((label as NSString).boundingRect(with:CGSize(width:max(1,buttonWidth-pad*2),height:100_000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:CanvasTheme.attributes(font,CanvasTheme.text)).height)+2
            let size = CGSize(width:buttonWidth,height:max(30*CanvasTheme.textScale,textHeight+14))
            if !current.isEmpty && used+gap+buttonWidth > width {lines.append(current);current = [];used = 0}
            current.append((index,size));used += (current.count > 1 ? gap : 0)+buttonWidth
        }
        if !current.isEmpty {lines.append(current)}
        var result:[(index:Int,rect:CGRect)] = [],y:CGFloat = 0
        for line in lines {
            let height = line.map {$0.1.height}.max() ?? 0,total = line.reduce(0) {$0+$1.1.width}+CGFloat(max(0,line.count-1))*gap
            var x = max(0,width-total)
            for (index,size) in line {result.append((index,CGRect(x:x,y:y,width:size.width,height:height)));x += size.width+gap}
            y += height+gap
        }
        return .init(buttons:result,height:max(0,y-gap))
    }
    private func menuRowHeight(_ value:CanvasMenu,width:CGFloat) -> CGFloat {
        let prefix:CGFloat = (value.options.contains {$0.checked != nil} ? 22 : 0)+(value.options.contains {$0.icon != nil} ? 22 : 0)
        return max(26*CanvasTheme.textScale,value.options.map {rowHeight(label:$0.label,value:$0.value,width:max(1,width-48-prefix),labelFont:CanvasTheme.font(14),valueFont:CanvasTheme.font(12,.medium))}.max() ?? 0)
    }
    private static var row:CGFloat {26*CanvasTheme.textScale}
    /// Panel width, text heights and how many vertical rows fit in the
    /// viewport (the panel stays eight pixels shorter than it).
    private func metrics(_ value:CanvasMenu) -> (width:CGFloat,title:CGFloat,footer:CGFloat,shown:Int) {
        let check:CGFloat = (value.options.contains(where:{ $0.checked != nil }) ? 22 : 0)+(value.options.contains(where:{ $0.icon != nil }) ? 22 : 0)
        let labelWidth = value.options.map { ceil(($0.label as NSString).size(withAttributes:attributes()).width) }.max() ?? 0
        let valueWidth = value.options.map { ceil(($0.value as NSString).size(withAttributes:attributes()).width) }.max() ?? 0
        let column = valueWidth > 0 ? valueWidth+(value.onAdjust != nil ? 52 : 28) : 0
        let width:CGFloat = value.horizontal ? 300 : value.anchor != nil ? min(viewport.width-16,max(96,labelWidth+column+44+check)) :
            min(viewport.width-16,max(240,labelWidth+column+64+check))
        let title = textHeight(value.title,width:width-40)
        let hasHelp = value.options.contains { !$0.help.isEmpty }
        // Reserve the longest explanation so selecting a different setting
        // never moves the menu or changes its visible row count.
        let footer = hasHelp ? ([value.footer]+value.options.map(\.help)).map { text -> CGFloat in
            text.isEmpty ? 0 : ceil((text as NSString).boundingRect(with:CGSize(width:width-40,height:400),
                options:[.usesLineFragmentOrigin],attributes:attributes(CanvasTheme.muted,size:12)).height)
        }.max() ?? 0 : textHeight(value.footer,width:width-40)
        let chrome = 24+(title > 0 ? title+12 : 0)+(footer > 0 ? footer+10 : 0)
        let shown = value.horizontal ? value.options.count : min(value.options.count,max(1,Int((viewport.height-8-chrome)/menuRowHeight(value,width:width))))
        return (width,title,footer,shown)
    }
    private func revealSelection() {
        guard let value = selector,!value.horizontal else { firstVisible = 0;return }
        let shown:Int
        if case .title = value.style {shown = max(1,min(value.options.count,Int((viewport.height-8)/(Self.titleButton.height+Self.titleGap))))} else {shown = metrics(value).shown}
        if value.selected < firstVisible { firstVisible = value.selected }
        if value.selected >= firstVisible+shown { firstVisible = value.selected-shown+1 }
        firstVisible = min(max(0,firstVisible),max(0,value.options.count-shown))
    }
    /// The engine title screen: wide buttons in a column hanging from the
    /// anchor, each with its symbol, a value chip for a setting and a chevron.
    private static var titleButton:CGSize {CGSize(width:268*CanvasTheme.textScale,height:25*CanvasTheme.textScale)}
    private static let titleGap:CGFloat = 6
    private func titleLayout(_ value:CanvasMenu) -> Layout {
        let size = CGSize(width:min(viewport.width-16,Self.titleButton.width),height:Self.titleButton.height),step = size.height+Self.titleGap
        let shown = max(1,min(value.options.count,Int((viewport.height-8)/step)))
        let first = min(firstVisible,max(0,value.options.count-shown))
        let height = CGFloat(shown)*step-Self.titleGap
        let top = value.anchor ?? CGPoint(x:viewport.midX,y:viewport.midY-height/2)
        let panel = CGRect(x:top.x-size.width/2,y:max(viewport.minY+4,min(top.y,viewport.maxY-height-4)),width:size.width,height:height).integral
        let options = (first..<first+shown).map { (index:$0,rect:CGRect(x:panel.minX,y:panel.minY+CGFloat($0-first)*step,width:size.width,height:size.height)) }
        return Layout(panel:panel,title:.zero,options:options,footer:.zero,moreAbove:first > 0,moreBelow:first+shown < value.options.count)
    }
    private func drawTitleMenu(_ value:CanvasMenu,in context:CGContext) {
        let shape = titleLayout(value)
        for (index,rect) in shape.options {
            let option = value.options[index],selected = index == value.selected
            context.saveGState()
            context.setShadow(offset:CGSize(width:0,height:2),blur:8,color:CGColor(gray:0,alpha:0.5))
            CanvasTheme.fill(rect,selected ? CGColor(red:0.20,green:0.16,blue:0.09,alpha:0.92) : CGColor(red:0.05,green:0.06,blue:0.09,alpha:0.80),radius:7,in:context)
            context.restoreGState()
            CanvasTheme.stroke(rect,selected ? CanvasTheme.accentFill : CGColor(gray:1,alpha:0.10),radius:7,in:context)
            if selected {
                CanvasTheme.stroke(rect.insetBy(dx:0.5,dy:0.5),CanvasTheme.accentFill,radius:7,in:context)
                CanvasTheme.fill(CGRect(x:rect.minX+6,y:rect.minY+6,width:3,height:rect.height-12),CanvasTheme.accentFill,radius:1.5,in:context)
            }
            let color = !option.enabled ? CanvasTheme.disabled : option.destructive && selected ? CanvasTheme.danger : CanvasTheme.text
            var x = rect.minX+18
            if let name = option.icon {
                drawSymbol(name,in:CGRect(x:x,y:rect.midY-8,width:16,height:16),color:selected ? CanvasTheme.accent : CanvasTheme.muted)
                x += 26
            } else if option.checked == true {
                // The current setting carries a dot at the row's left.
                context.setFillColor(CanvasTheme.accentFill)
                context.fillEllipse(in:CGRect(x:x+4,y:rect.midY-3.5,width:7,height:7));x += 22
            } else if option.checked == false { x += 22 }
            (option.label as NSString).draw(in:CGRect(x:x,y:rect.midY-10*CanvasTheme.textScale,width:rect.maxX-x-30,height:20*CanvasTheme.textScale),
                                            withAttributes:CanvasTheme.attributes(CanvasTheme.font(14,selected ? .bold : .semibold),color))
            if !option.value.isEmpty {
                let style = CanvasTheme.attributes(CanvasTheme.font(11.5,.medium),selected ? CanvasTheme.text : CanvasTheme.muted,alignment:.center)
                let width = ceil((option.value as NSString).size(withAttributes:style).width)+18
                let chip = CGRect(x:rect.maxX-34-width,y:rect.midY-8.5*CanvasTheme.textScale,width:width,height:17*CanvasTheme.textScale)
                CanvasTheme.fill(chip,CGColor(gray:1,alpha:selected ? 0.14 : 0.07),radius:8.5,in:context)
                (option.value as NSString).draw(in:chip.offsetBy(dx:0,dy:1.5),withAttributes:style)
            }
            if selected {
                ((value.onAdjust != nil && !option.value.isEmpty ? "‹ ›" : "›") as NSString).draw(in:CGRect(x:rect.maxX-30,y:rect.midY-10,width:22,height:20),
                    withAttributes:CanvasTheme.attributes(CanvasTheme.font(14,.bold),CanvasTheme.accent,alignment:.center))
            }
        }
    }
    private func layout(_ value:CanvasMenu) -> Layout {
        switch value.style {
        case .title:return titleLayout(value)
        case .window(let art):
            let options = art.buttons.prefix(value.options.count).enumerated().map { (index:$0.offset,rect:$0.element) }
            return Layout(panel:art.frame,title:.zero,options:options,footer:.zero,moreAbove:false,moreBelow:false)
        case .panel:break
        }
        if value.horizontal {return confirmationLayout(value)}
        let m = metrics(value),width = m.width
        let step = menuRowHeight(value,width:width)
        let rows = CGFloat(m.shown)*step
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
                options.append((index,CGRect(x:panel.minX+8,y:top+CGFloat(index-first)*step,width:width-16,height:step-2)))
            }
        }
        let footer = CGRect(x:panel.minX+20,y:top+rows+8,width:width-40,height:m.footer)
        return Layout(panel:panel,title:title,options:options,footer:footer,
                      moreAbove:first > 0,moreBelow:first+m.shown < value.options.count)
    }
    private func confirmationLayout(_ value:CanvasMenu) -> Layout {
        let font = CanvasTheme.font(13,.bold)
        let actionsWidth = value.options.reduce(CGFloat(0)) {$0+max(76,CanvasTheme.textWidth($1.label,font:font)+32)}+CGFloat(max(0,value.options.count-1))*8
        let width = min(viewport.width-24,max(420,min(560,actionsWidth+40)))
        let inner = max(1,width-40),titleHeight = measured(value.title,width:inner,size:14)
        let bodyHeight = measured(value.displayedFooter,width:inner,size:13)
        let flow = buttonFlow(value.options.map(\.label),width:inner)
        let height = min(viewport.height-16,20+titleHeight+(bodyHeight > 0 ? 14+bodyHeight : 0)+20+flow.height+16)
        let panel = CGRect(x:viewport.midX-width/2,y:viewport.midY-height/2,width:width,height:height).integral
        let title = CGRect(x:panel.minX+20,y:panel.minY+18,width:inner,height:titleHeight)
        let buttonsTop = panel.maxY-16-flow.height
        let footer = CGRect(x:panel.minX+20,y:title.maxY+14,width:inner,height:max(0,buttonsTop-title.maxY-28))
        let buttons = flow.buttons.map {(index:$0.index,rect:$0.rect.offsetBy(dx:panel.minX+20,dy:buttonsTop))}
        return Layout(panel:panel,title:title,options:buttons,footer:footer,moreAbove:false,moreBelow:false)
    }
    var menuPanelRect:CGRect? {selector.map {layout($0).panel}}
    func menuOptionRect(_ index:Int) -> CGRect? {selector.flatMap {layout($0).options.first {$0.index == index}?.rect}}
    var menuDescriptionRect:CGRect? {selector.map {layout($0).footer}}
    /// An SF Symbol tinted to one colour, drawn into the flipped canvas.
    private func drawSymbol(_ name:String,in rect:CGRect,color:NSColor) {
        guard let base = NSImage(systemSymbolName:name,accessibilityDescription:nil) else { return }
        let config = NSImage.SymbolConfiguration(pointSize:12,weight:.semibold).applying(NSImage.SymbolConfiguration(paletteColors:[color]))
        guard let image = base.withSymbolConfiguration(config) else { return }
        let size = image.size,scale = min(rect.width/size.width,rect.height/size.height,1)
        let box = CGRect(x:rect.midX-size.width*scale/2,y:rect.midY-size.height*scale/2,width:size.width*scale,height:size.height*scale)
        image.draw(in:box,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
    }
    private func drawButton(_ label:String,in rect:CGRect,focused:Bool,context:CGContext) {
        CanvasTheme.pill(rect,active:focused,in:context)
        let style = CanvasTheme.attributes(CanvasTheme.font(13,.bold),focused ? CanvasTheme.onAccent : CanvasTheme.text,alignment:.center)
        let width = max(1,rect.width-32),height = ceil((label as NSString).boundingRect(with:CGSize(width:width,height:100_000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:style).height)+2
        let box = CGRect(x:rect.minX+16,y:rect.midY-height/2,width:width,height:height)
        context.saveGState();context.clip(to:rect.insetBy(dx:8,dy:4))
        (label as NSString).draw(with:box,options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:style)
        context.restoreGState()
    }
    private func drawMore(_ more:(above:Bool,below:Bool),x:CGFloat,top:CGFloat,bottom:CGFloat,in context:CGContext) {
        context.setFillColor(CanvasTheme.muted.cgColor)
        for (shown,y,dy) in [(more.above,top+5,CGFloat(-4)),(more.below,bottom-5,CGFloat(4))] where shown {
            context.move(to:CGPoint(x:x-4,y:y));context.addLine(to:CGPoint(x:x+4,y:y))
            context.addLine(to:CGPoint(x:x,y:y+dy));context.closePath();context.fillPath()
        }
    }
    private func drawCheck(_ box:CGRect,checked:Bool,enabled:Bool,context:CGContext) {
        guard checked else { CanvasTheme.stroke(box,radius:3,in:context);return }
        CanvasTheme.fill(box,enabled ? CanvasTheme.accentFill : CanvasTheme.hairline,radius:3,in:context)
        context.setStrokeColor(CanvasTheme.onAccent.cgColor);context.setLineWidth(1.6);context.setLineCap(.round)
        context.move(to:CGPoint(x:box.minX+3.5,y:box.midY));context.addLine(to:CGPoint(x:box.midX-1,y:box.maxY-4))
        context.addLine(to:CGPoint(x:box.maxX-3.5,y:box.minY+4));context.strokePath()
    }
    /// Each label starts at column x/8 + (w/8 − bytes)/2 of its button (CF5:1AC8),
    /// in MAIN's glyphs when the data has them; the outline marking the
    /// keyboard row is an engine addition.
    private func drawWindowMenu(_ value:CanvasMenu,art:CanvasMenu.Art,in context:CGContext) {
        Renderer.image(art.image,in:art.frame,context:context)
        for (index,rect) in layout(value).options {
            let option = value.options[index]
            if let picture = art.label?(option.label,option.enabled) {
                let column = max(0,(Int(rect.width)/8-OriginalFont.bytes(option.label).count)/2)
                Renderer.image(picture,in:CGRect(x:rect.minX+CGFloat(8*column),y:rect.minY,width:CGFloat(picture.width),height:CGFloat(picture.height)),context:context)
            } else {
                let style = CanvasTheme.attributes(CanvasTheme.font(13,.bold),option.enabled ? art.text : art.disabled,alignment:.center)
                (option.label as NSString).draw(in:CGRect(x:rect.minX,y:rect.midY-9,width:rect.width,height:18),withAttributes:style)
            }
            if index == value.selected {
                context.setStrokeColor(CanvasTheme.accentFill);context.setLineWidth(1.5)
                context.stroke(rect.insetBy(dx:-3.5,dy:-3.5))
            }
        }
    }
    private func drawMenu(_ value:CanvasMenu,in context:CGContext) {
        switch value.style {
        case .title:drawTitleMenu(value,in:context);return
        case .window(let art):drawWindowMenu(value,art:art,in:context);return
        case .panel:break
        }
        let shape = layout(value)
        CanvasTheme.panel(shape.panel,in:context)
        (value.title as NSString).draw(with:shape.title,options:[.usesLineFragmentOrigin],attributes:attributes())
        for (index,rect) in shape.options {
            let option = value.options[index]
            if value.horizontal { drawButton(option.label,in:rect,focused:index == value.selected,context:context);continue }
            let selected = index == value.selected
            if option.separatorBefore,index != shape.options.first?.index {
                CanvasTheme.divider(from:CGPoint(x:rect.minX+8,y:rect.minY-1.5),to:CGPoint(x:rect.maxX-8,y:rect.minY-1.5),in:context)
            }
            if selected {
                CanvasTheme.gradient(rect,top:CGColor(red:0.91,green:0.75,blue:0.40,alpha:0.28),
                                     bottom:CGColor(red:0.91,green:0.75,blue:0.40,alpha:0.10),radius:CanvasTheme.rowRadius,vertical:false,in:context)
                CanvasTheme.stroke(rect,CanvasTheme.accentBorder,radius:CanvasTheme.rowRadius,in:context)
                CanvasTheme.fill(CGRect(x:rect.minX+2.5,y:rect.minY+5,width:3,height:rect.height-10),CanvasTheme.accentFill,radius:1.5,in:context)
            }
            let color = !option.enabled ? CanvasTheme.disabled : option.destructive ? CanvasTheme.danger : CanvasTheme.text
            var inset = rect.insetBy(dx:12,dy:3)
            if let checked = option.checked {
                drawCheck(CGRect(x:inset.minX,y:rect.midY-7,width:14,height:14),checked:checked,enabled:option.enabled,context:context)
                inset = inset.offsetBy(dx:22,dy:0);inset.size.width -= 22
            }
            if let name = option.icon {
                drawSymbol(name,in:CGRect(x:inset.minX,y:rect.midY-8,width:16,height:16),
                           color:!option.enabled ? CanvasTheme.disabled : option.destructive ? CanvasTheme.danger : selected ? CanvasTheme.accent : CanvasTheme.muted)
                inset = inset.offsetBy(dx:22,dy:0);inset.size.width -= 22
            }
            let text = rowTextLayout(label:option.label,value:option.value,in:inset,labelFont:CanvasTheme.font(14),valueFont:CanvasTheme.font(12,.medium))
            CanvasTheme.drawSingleLine(option.label,in:text.label,font:CanvasTheme.font(14),color:color,context:context)
            if !option.value.isEmpty {
                CanvasTheme.drawSingleLine(option.value,in:text.value,font:CanvasTheme.font(12,.medium),color:option.enabled ? CanvasTheme.muted : CanvasTheme.disabled,alignment:text.stacked ? .left : .right,context:context)
            }
        }
        if !value.displayedFooter.isEmpty {
            let hasHelp = value.options.contains { !$0.help.isEmpty }
            if hasHelp {
                CanvasTheme.divider(from:CGPoint(x:shape.footer.minX,y:shape.footer.minY-5),
                                    to:CGPoint(x:shape.footer.maxX,y:shape.footer.minY-5),in:context)
            }
            context.saveGState();context.clip(to:shape.footer)
            let bodyHeight = measured(value.displayedFooter,width:shape.footer.width,size:value.horizontal ? 13 : 12)
            if value.horizontal {noticeScroll = min(noticeScroll,max(0,bodyHeight-shape.footer.height))}
            (value.displayedFooter as NSString).draw(with:CGRect(x:shape.footer.minX,y:shape.footer.minY-(value.horizontal ? noticeScroll : 0),width:shape.footer.width,height:bodyHeight),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:attributes(CanvasTheme.muted,size:value.horizontal ? 13 : 12))
            context.restoreGState()
        }
        if !value.horizontal,let first = shape.options.first,let last = shape.options.last {
            drawMore((shape.moreAbove,shape.moreBelow),x:shape.panel.maxX-16,top:first.rect.minY,bottom:last.rect.maxY,in:context)
        }
    }
    private struct SheetLayout {
        var panel:CGRect; var header:CGFloat; var list:CGRect; var detail:CGRect; var footer:CGFloat
        var rows:[(index:Int,rect:CGRect)]; var buttons:[(index:Int,rect:CGRect)]
    }
    private static let sheetRows = 8
    private func sheetRowHeight(_ value:CanvasSheet,width:CGFloat) -> CGFloat {
        max(24,value.rows.map {rowHeight(label:$0.label,value:$0.value,width:max(1,width-20-($0.checked == nil ? 0 : 22)),labelFont:CanvasTheme.font(14),valueFont:CanvasTheme.number(13))}.max() ?? 24)
    }
    private func measured(_ text:String,width:CGFloat,size:CGFloat) -> CGFloat {
        guard !text.isEmpty else {return 0}
        return ceil((text as NSString).boundingRect(with:CGSize(width:max(1,width),height:100_000),options:[.usesLineFragmentOrigin],attributes:attributes(size:size)).height)+2
    }
    private func sheetLayout(_ value:CanvasSheet) -> SheetLayout {
        let vp = value.fullCanvas ? CGRect(x:8,y:8,width:624,height:384) : self.viewport
        let size = CGSize(width:min(vp.width-16,value.fullCanvas ? 608 : 540),height:min(vp.height-16,value.fullCanvas ? 368 : 340))
        let panel = CGRect(x:vp.midX-size.width/2,y:vp.midY-size.height/2,width:size.width,height:size.height)
        let flow = buttonFlow(value.buttons,width:panel.width-24)
        let hint = AppControlRuntime.current.displayHint(value.hint,context:.list)
        let hintHeight = measured(hint,width:panel.width-28,size:10)
        let footerHeight = flow.height+(flow.height > 0 ? 8 : 0)+hintHeight+12
        let footer = panel.maxY-footerHeight
        let hasBadge = !value.badge.label.isEmpty || !value.badge.value.isEmpty
        let textWidth = panel.width-32-(value.portrait == nil ? 0 : 59)-(hasBadge ? 112 : 0)
        let speakerHeight = measured(value.speaker,width:textWidth,size:12)
        let headerHeight = max(value.portrait == nil ? 0 : 74,14+speakerHeight+measured(value.line,width:textWidth,size:14)+6)
        let listWidth:CGFloat = value.rows.isEmpty ? 0 : min(250,panel.width*0.47)
        let step = sheetRowHeight(value,width:listWidth)
        let header = min(panel.minY+headerHeight,footer-step-20)
        let list = CGRect(x:panel.minX+8,y:header+6,width:listWidth,height:max(step,footer-header-12))
        let detail = CGRect(x:list.maxX+14,y:header+8,width:panel.maxX-list.maxX-28,height:max(1,footer-header-16))
        let capacity = max(1,min(Self.sheetRows,Int(list.height/step)))
        let shown = min(value.rows.count,capacity),first = min(firstVisible,max(0,value.rows.count-shown))
        let rows = (0..<shown).map {(index:first+$0,rect:CGRect(x:list.minX,y:list.minY+CGFloat($0)*step,width:list.width,height:step-2))}
        let buttons = flow.buttons.map {(index:$0.index,rect:$0.rect.offsetBy(dx:panel.minX+12,dy:footer+6))}
        return SheetLayout(panel:panel,header:header,list:list,detail:detail,footer:footer,rows:rows,buttons:buttons)
    }
    private func measuredWidth(_ text:String,size:CGFloat) -> CGFloat {ceil((text as NSString).size(withAttributes:attributes(size:size)).width)}
    /// Screen position of one button, for callers that test the window.
    func sheetButtonRect(_ index:Int) -> CGRect? { sheet.flatMap { sheetLayout($0).buttons.first{$0.index == index}?.rect } }
    func sheetRowRect(_ index:Int) -> CGRect? { sheet.flatMap { sheetLayout($0).rows.first{$0.index == index}?.rect } }
    func sheetRowTextRects(_ index:Int) -> (label:CGRect,value:CGRect)? {
        guard let value = sheet,value.rows.indices.contains(index),let rect = sheetRowRect(index) else {return nil}
        let row = value.rows[index],prefix:CGFloat = row.checked == nil ? 0 : 22
        var content = rect.insetBy(dx:10,dy:3);content.origin.x += prefix;content.size.width -= prefix
        let result = rowTextLayout(label:row.label,value:row.value,in:content,labelFont:CanvasTheme.font(14),valueFont:CanvasTheme.number(13))
        return (result.label,result.value)
    }
    private func revealSheetRow() {
        guard let value = sheet else { firstVisible = 0;return }
        let visible = max(1,sheetLayout(value).rows.count)
        let limit = max(0,value.rows.count-visible)
        if value.selected < firstVisible { firstVisible = value.selected }
        if value.selected >= firstVisible+visible { firstVisible = value.selected-visible+1 }
        firstVisible = min(max(0,firstVisible),limit)
    }
    private func detailHeight(_ detail:CanvasSheet.Detail,width:CGFloat) -> CGFloat {
        if detail.rangeComparison != nil {return 290*CanvasTheme.textScale}
        if let strategy = detail.strategy {return CanvasStrategyDetail.requiredHeight(detail,strategy:strategy,width:width)}
        let textWidth = width-(detail.portrait == nil ? 0 : 57)
        var total = measured(detail.heading,width:textWidth,size:15)+measured(detail.body,width:textWidth,size:13)+16
        if detail.portrait != nil {total = max(total,66)}
        total += detail.list.reduce(0) {$0+measured($1,width:width,size:13)+5}
        total += detail.facts.reduce(0) {$0+measured($1.label+"  "+$1.value,width:width,size:13)+6}
        if detail.picture != nil {total += 160}
        if detail.rangePatternPreview {total += 160*CanvasTheme.textScale}
        return total
    }
    private func selectedDetail(_ value:CanvasSheet) -> CanvasSheet.Detail? {value.detail ?? (value.rows.indices.contains(value.selected) ? value.rows[value.selected].detail : nil)}
    var sheetDetailViewport:CGRect? {sheet.map {sheetLayout($0).detail}}
    var sheetPanelRect:CGRect? {sheet.map {sheetLayout($0).panel}}
    private func scrollDetail(by delta:CGFloat,edge:Bool = false) {
        guard let value = sheet,let detail = selectedDetail(value) else {return}
        let rect = sheetLayout(value).detail,limit = max(0,detailHeight(detail,width:rect.width)-rect.height)
        detailScroll = edge ? (delta < 0 ? 0 : limit) : min(limit,max(0,detailScroll+delta));needsDisplay = true
    }
    private func drawDetail(_ detail:CanvasSheet.Detail,in viewport:CGRect,context:CGContext) {
        let height = max(viewport.height,detailHeight(detail,width:viewport.width))
        detailScroll = min(detailScroll,max(0,height-viewport.height))
        context.saveGState();context.clip(to:viewport);context.translateBy(x:0,y:-detailScroll)
        defer {context.restoreGState()}
        let rect = CGRect(x:viewport.minX,y:viewport.minY,width:viewport.width,height:height)
        if let ranges = detail.rangeComparison {CanvasRangeComparison.draw(detail,model:ranges,in:rect,context:context);return}
        if let strategy = detail.strategy {CanvasStrategyDetail.draw(detail,strategy:strategy,in:rect,context:context);return}
        var y = rect.minY,textWidth = rect.width
        if let portrait = detail.portrait {
            let box = CGRect(x:rect.maxX-47,y:rect.minY,width:47,height:58)
            context.saveGState();CanvasTheme.rounded(box,5,in:context);context.clip();Renderer.image(portrait,in:box,context:context);context.restoreGState();textWidth -= 57
        }
        func text(_ value:String,size:CGFloat,color:NSColor,width:CGFloat) {
            guard !value.isEmpty else {return}
            let h = measured(value,width:width,size:size)
            (value as NSString).draw(with:CGRect(x:rect.minX,y:y,width:width,height:h),options:[.usesLineFragmentOrigin],attributes:attributes(color,size:size));y += h+5
        }
        text(detail.heading,size:15,color:CanvasTheme.text,width:textWidth)
        text(detail.body,size:13,color:CanvasTheme.muted,width:textWidth)
        if detail.portrait != nil {y = max(y,rect.minY+66)}
        for item in detail.list {text(item,size:13,color:CanvasTheme.text,width:rect.width)}
        for fact in detail.facts {text(fact.label+"  "+fact.value,size:13,color:CanvasTheme.text,width:rect.width)}
        if detail.rangePatternPreview {
            let step = 80*CanvasTheme.textScale,width = (rect.width-10)/2
            for (index,kind) in CanvasRangePattern.Kind.allCases.enumerated() {
                let x = rect.minX+CGFloat(index%2)*(width+10),top = y+CGFloat(index/2)*step
                let sample = CGRect(x:x,y:top,width:32,height:32)
                CanvasTheme.fill(sample,CGColor(gray:0.3,alpha:1),radius:2,in:context)
                CanvasRangePattern.draw(kind:kind,in:sample,context:context)
                (kind.label as NSString).draw(with:CGRect(x:x,y:top+37,width:width,height:step-37),options:[.usesLineFragmentOrigin],attributes:attributes(size:10))
            }
            y += 160*CanvasTheme.textScale
        }
        if let picture = detail.picture {
            let area = CGRect(x:rect.minX,y:y+6,width:rect.width,height:150)
            let scale = min(area.width/CGFloat(picture.width),area.height/CGFloat(picture.height))
            let box = CGRect(x:area.midX-CGFloat(picture.width)*scale/2,y:area.minY,width:CGFloat(picture.width)*scale,height:CGFloat(picture.height)*scale)
            Renderer.image(picture,in:box,context:context)
            for mark in detail.marks {
                let center = CGPoint(x:box.minX+mark.point.x*box.width,y:box.minY+mark.point.y*box.height),radius:CGFloat = mark.strong ? 4 : 2
                context.setFillColor(mark.strong ? CanvasTheme.accentFill : CGColor(gray:1,alpha:0.85));context.fillEllipse(in:CGRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2))
            }
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
        let badgeWidth:CGFloat = 96,hasBadge = !value.badge.label.isEmpty || !value.badge.value.isEmpty
        let textWidth = panel.maxX-textX-16-(hasBadge ? 112 : 0)
        let speakerHeight = measured(value.speaker,width:textWidth,size:12)
        CanvasTheme.drawSingleLine(value.speaker,in:CGRect(x:textX,y:panel.minY+10,width:textWidth,height:speakerHeight),font:CanvasTheme.font(12,.semibold),color:CanvasTheme.accent,context:context)
        (value.line as NSString).draw(with:CGRect(x:textX,y:panel.minY+12+speakerHeight,width:textWidth,height:max(0,shape.header-panel.minY-16-speakerHeight)),options:[.usesLineFragmentOrigin],attributes:attributes())
        let badge = CGRect(x:panel.maxX-16-badgeWidth,y:panel.minY+10,width:badgeWidth,height:16*CanvasTheme.textScale)
        (value.badge.label as NSString).draw(in:badge,withAttributes:CanvasTheme.attributes(CanvasTheme.font(11),CanvasTheme.muted,alignment:.right))
        (value.badge.value as NSString).draw(in:badge.offsetBy(dx:0,dy:15*CanvasTheme.textScale).insetBy(dx:0,dy:-2),withAttributes:CanvasTheme.attributes(CanvasTheme.number(16,.semibold),CanvasTheme.text,alignment:.right))
        CanvasTheme.divider(from:CGPoint(x:panel.minX,y:shape.header+0.5),to:CGPoint(x:panel.maxX,y:shape.header+0.5),in:context)
        CanvasTheme.divider(from:CGPoint(x:panel.minX,y:shape.footer+0.5),to:CGPoint(x:panel.maxX,y:shape.footer+0.5),in:context)
        if !value.rows.isEmpty {CanvasTheme.divider(from:CGPoint(x:shape.list.maxX+6.5,y:shape.header),to:CGPoint(x:shape.list.maxX+6.5,y:shape.footer),in:context)}
        let frozen = value.mode != .list || sheetActionFocused
        for (index,rect) in shape.rows {
            let row = value.rows[index]
            if index == value.selected {
                if frozen { CanvasTheme.fill(rect,CanvasTheme.inset,in:context) }
                else {
                    CanvasTheme.gradient(rect,top:CGColor(red:0.91,green:0.75,blue:0.40,alpha:0.28),
                                         bottom:CGColor(red:0.91,green:0.75,blue:0.40,alpha:0.10),radius:CanvasTheme.rowRadius,vertical:false,in:context)
                    CanvasTheme.stroke(rect,CanvasTheme.accentBorder,radius:CanvasTheme.rowRadius,in:context)
                    CanvasTheme.fill(CGRect(x:rect.minX+2.5,y:rect.minY+4,width:3,height:rect.height-8),CanvasTheme.accentFill,radius:1.5,in:context)
                }
            }
            var inset = rect.insetBy(dx:10,dy:3)
            if let checked = row.checked {
                drawCheck(CGRect(x:inset.minX,y:rect.midY-7,width:14,height:14),checked:checked,enabled:row.enabled,context:context)
                inset = inset.offsetBy(dx:22,dy:0);inset.size.width -= 22
            }
            let text = rowTextLayout(label:row.label,value:row.value,in:inset,labelFont:CanvasTheme.font(14),valueFont:CanvasTheme.number(13))
            CanvasTheme.drawSingleLine(row.label,in:text.label,font:CanvasTheme.font(14),color:!row.enabled ? CanvasTheme.disabled : frozen && index != value.selected ? CanvasTheme.muted : CanvasTheme.text,context:context)
            if !row.value.isEmpty {
                CanvasTheme.drawSingleLine(row.value,in:text.value,font:CanvasTheme.number(13),color:row.warns ? CanvasTheme.danger : frozen ? CanvasTheme.disabled : CanvasTheme.muted,alignment:text.stacked ? .left : .right,context:context)
            }
        }
        if let first = shape.rows.first,let last = shape.rows.last {
            drawMore((first.index > 0,last.index+1 < value.rows.count),x:shape.list.maxX-10,top:first.rect.minY,bottom:last.rect.maxY,in:context)
        }
        if let detail = value.detail ?? (value.rows.indices.contains(value.selected) ? value.rows[value.selected].detail : nil) {
            drawDetail(detail,in:shape.detail,context:context)
        }
        let hintTop = (shape.buttons.map { $0.rect.maxY }.max() ?? shape.footer)+3
        (AppControlRuntime.current.displayHint(value.hint,context:.list) as NSString).draw(with:CGRect(x:panel.minX+14,y:hintTop,width:panel.width-28,height:max(0,panel.maxY-hintTop-4)),options:[.usesLineFragmentOrigin],attributes:attributes(CanvasTheme.muted,size:10))
        for (index,rect) in shape.buttons {
            drawButton(value.buttons[index],in:rect,focused:index == sheetButton && (value.mode == .buttons || sheetActionFocused),context:context)
        }
    }
    /// Controls along the bottom of a waiting line, right to left before the continue mark.
    private func lineControls(_ rect:CGRect) -> [(control:LineControl,label:String,rect:CGRect)] {
        guard onLineControl != nil,notice?.waitsAsLine == true else { return [] }
        let style = CanvasTheme.attributes(CanvasTheme.font(11,.medium),CanvasTheme.muted)
        var right = rect.maxX-30,result:[(control:LineControl,label:String,rect:CGRect)] = []
        let pace = DialoguePace.shared,autoLabel = pace.auto ? "자동 · "+DialoguePace.speedLabels[min(max(0,pace.speed),DialoguePace.speedLabels.count-1)] : "자동 "+AppControlRuntime.current.shortcutLabel(command:.auto,context:.dialogue)
        for (control,label) in [(LineControl.skip,"건너뛰기 "+AppControlRuntime.current.shortcutLabel(command:.skip,context:.dialogue)),(.auto,autoLabel),(.log,"기록 "+AppControlRuntime.current.shortcutLabel(command:.log,context:.dialogue))] where control != .log || showsLog {
            let width = ceil((label as NSString).size(withAttributes:style).width)+16
            result.append((control,label,CGRect(x:right-width,y:rect.maxY-25*CanvasTheme.textScale,width:width,height:19*CanvasTheme.textScale)))
            right -= width+4
        }
        return result
    }
    private func drawLineControls(_ rect:CGRect,in context:CGContext) {
        let pace = DialoguePace.shared
        for item in lineControls(rect) {
            let on = item.control == .auto ? pace.auto : item.control == .skip ? pace.skipping : false
            if on { CanvasTheme.pill(item.rect,active:true,in:context) }
            else if item.control == hoveredControl {
                CanvasTheme.fill(item.rect,CanvasTheme.selection,radius:item.rect.height/2,in:context)
                CanvasTheme.stroke(item.rect,CanvasTheme.accentBorder,radius:item.rect.height/2,in:context)
            } else {
                CanvasTheme.fill(item.rect,CGColor(red:0.04,green:0.05,blue:0.08,alpha:0.55),radius:item.rect.height/2,in:context)
                CanvasTheme.stroke(item.rect,CGColor(gray:1,alpha:0.12),radius:item.rect.height/2,in:context)
            }
            let color = on ? CanvasTheme.onAccent : item.control == hoveredControl ? CanvasTheme.accent : CanvasTheme.muted
            CanvasTheme.drawSingleLine(item.label,in:item.rect.insetBy(dx:4,dy:0),font:CanvasTheme.font(10.5,.semibold),color:color,alignment:.center,context:context)
        }
    }
    private func drawNotice(_ value:CanvasNotice,in context:CGContext) {
        let rect = noticeRect(value)
        let line = value.portrait != nil || !value.speaker.isEmpty || value.narration
        CanvasTheme.panel(rect,in:context)
        var textX = rect.minX+20
        if line {
            textX = rect.minX+lineText(value,width:rect.width).left
            if let portrait = value.portrait {
                let picture = CGRect(origin:CGPoint(x:rect.minX+12,y:rect.minY+12),size:Self.portraitSize)
                CanvasTheme.card(picture.insetBy(dx:-2,dy:-2),radius:6,in:context)
                context.saveGState();CanvasTheme.rounded(picture,4,in:context);context.clip()
                Renderer.image(portrait,in:picture,context:context);context.restoreGState()
                CanvasTheme.stroke(picture,CanvasTheme.accentBorder,radius:4,in:context)
            }
            // The speaker's name sits on a tag over the box's top edge.
            if !value.speaker.isEmpty {
                let style = CanvasTheme.attributes(CanvasTheme.font(12,.bold),CanvasTheme.onAccent,alignment:.center)
                let width = ceil((value.speaker as NSString).size(withAttributes:style).width)+26
                let tag = CGRect(x:textX-4,y:rect.minY-11,width:width,height:22)
                CanvasTheme.pill(tag,active:true,in:context)
                CanvasTheme.drawSingleLine(value.speaker,in:tag.insetBy(dx:8,dy:0),font:CanvasTheme.font(12,.bold),color:CanvasTheme.onAccent,alignment:.center,context:context)
            }
        }
        let top = line ? rect.minY+18 : rect.minY+14
        // Unrevealed characters are laid out but clear, so lines never re-wrap.
        let text = NSMutableAttributedString(string:value.text,attributes:line ? lineAttributes() : attributes())
        let shown = visibleNoticeCharacterCount ?? value.text.count
        if shown < value.text.count {
            let start = value.text.index(value.text.startIndex,offsetBy:shown)
            text.addAttribute(.foregroundColor,value:NSColor.clear,range:NSRange(start...,in:value.text))
        }
        let body = CGRect(x:textX,y:top,width:rect.maxX-textX-18,height:max(1,rect.maxY-top-(value.waitsAsLine ? 30*CanvasTheme.textScale : 8)))
        let height = ceil(text.boundingRect(with:CGSize(width:body.width,height:100_000),options:[.usesLineFragmentOrigin]).height)+2
        noticeScroll = min(noticeScroll,max(0,height-body.height))
        context.saveGState();context.clip(to:body)
        text.draw(with:CGRect(x:body.minX,y:body.minY-noticeScroll,width:body.width,height:height),options:[.usesLineFragmentOrigin]);context.restoreGState()
        if value.waitsAsLine,shown >= value.text.count {
            CanvasTheme.continueMark(at:CGPoint(x:rect.maxX-16,y:rect.maxY-15),in:context)
        }
        if value.waitsAsLine { drawLineControls(rect,in:context) }
    }
    private func drawTerrain(_ value:CanvasTerrain,in context:CGContext) {
        let facts = value.layout,x = Int(value.origin.x),y = Int(value.origin.y)
        let card = CGRect(x:x,y:y,width:facts.size[0],height:facts.size[1])
        CanvasTheme.panel(card,in:context)
        if CanvasPresentation.current == .modern {
            let tileBox = CGRect(x:card.minX+10,y:card.minY+12,width:36,height:36)
            CanvasTheme.card(tileBox.insetBy(dx:-1,dy:-1),radius:6,in:context)
            if let tile = value.tile {
                context.saveGState();CanvasTheme.rounded(tileBox,5,in:context);context.clip()
                Renderer.image(tile,in:tileBox,context:context);context.restoreGState()
            }
            CanvasTheme.stroke(tileBox,CanvasTheme.accentBorder,radius:5,in:context)
            let rightX = tileBox.maxX+10,rightWidth = card.maxX-rightX-8
            (value.name as NSString).draw(in:CGRect(x:rightX,y:card.minY+11,width:rightWidth,height:18),
                withAttributes:CanvasTheme.attributes(CanvasTheme.font(13.5,.bold),CanvasTheme.accent))
            (value.heading as NSString).draw(in:CGRect(x:rightX,y:card.minY+31,width:rightWidth,height:14),
                withAttributes:CanvasTheme.attributes(CanvasTheme.font(10,.medium),CanvasTheme.muted))
            (value.percent as NSString).draw(in:CGRect(x:rightX,y:card.minY+30,width:rightWidth,height:16),
                withAttributes:CanvasTheme.attributes(CanvasTheme.number(12,.bold),CanvasTheme.text,alignment:.right))
            if let recovery = value.recovery {
                let badge = CGRect(x:card.minX+10,y:card.maxY-23,width:card.width-20,height:16)
                CanvasTheme.fill(badge,CGColor(red:0.20,green:0.62,blue:0.42,alpha:0.28),radius:8,in:context)
                CanvasTheme.stroke(badge,CGColor(red:0.40,green:0.84,blue:0.58,alpha:0.55),radius:8,in:context)
                ("✦ "+recovery as NSString).draw(in:badge.insetBy(dx:0,dy:1.5),
                    withAttributes:CanvasTheme.attributes(CanvasTheme.font(10.5,.semibold),NSColor(red:0.58,green:0.95,blue:0.72,alpha:1),alignment:.center))
            } else {
                let foot = CGRect(x:card.minX+10,y:card.maxY-21,width:card.width-20,height:14)
                ("지형 정보" as NSString).draw(in:foot,withAttributes:CanvasTheme.attributes(CanvasTheme.font(10),CanvasTheme.muted,alignment:.center))
            }
            return
        }
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
        let window = OriginalBattleLayout.rect(facts.window)
        CanvasTheme.panel(window,in:context)
        if value.button == nil {
            let scale = CanvasTheme.textScale
            let panel = CGRect(x:viewport.minX+18,y:viewport.minY+24,width:viewport.width-36,height:viewport.height-48)
            CanvasTheme.panel(panel,in:context)
            let heading = value.title+"  ·  "+value.heading
            let headingHeight = measured(heading,width:panel.width-32,size:14)
            (heading as NSString).draw(with:CGRect(x:panel.minX+16,y:panel.minY+12,width:panel.width-32,height:headingHeight),options:[.usesLineFragmentOrigin],attributes:attributes(CanvasTheme.accent,size:14))
            let body = CGRect(x:panel.minX+16,y:panel.minY+headingHeight+22,width:panel.width-32,height:max(1,panel.height-headingHeight-78*scale))
            let text = value.lines.map {"• "+$0}.joined(separator:"\n\n"),height = measured(text,width:body.width,size:14)
            noticeScroll = min(noticeScroll,max(0,height-body.height))
            context.saveGState();context.clip(to:body)
            (text as NSString).draw(with:CGRect(x:body.minX,y:body.minY-noticeScroll,width:body.width,height:height),options:[.usesLineFragmentOrigin],attributes:attributes());context.restoreGState()
            let bottom = panel.maxY-40*scale
            (value.turns.trimmingCharacters(in:.whitespaces) as NSString).draw(in:CGRect(x:panel.minX+16,y:bottom+8,width:panel.width-130,height:22*scale),withAttributes:attributes(CanvasTheme.accent,size:13))
            drawButton("확인",in:CGRect(x:panel.maxX-100,y:bottom,width:84,height:30*scale),focused:true,context:context)
            return
        }
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
        else { drawButton("확인",in:OriginalBattleLayout.rect(facts.button).insetBy(dx:-6,dy:-2),focused:true,context:context) }
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
        guard !isSuspended else { return }
        guard let event = AppControlRuntime.current.remappedEvent(event,context:notice != nil || brief != nil ? .dialogue : .list) else {return}
        if [116,121,115,119].contains(event.keyCode) {
            let delta:CGFloat = [116,115].contains(event.keyCode) ? -100 : 100
            if notice != nil || brief != nil || selector?.horizontal == true {noticeScroll = [115,119].contains(event.keyCode) ? (delta < 0 ? 0 : 100_000) : max(0,noticeScroll+delta);needsDisplay = true}
            else {scrollDetail(by:delta,edge:[115,119].contains(event.keyCode))}
            return
        }
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
        if [123,124].contains(event.keyCode),let adjust = value.onAdjust,!value.horizontal,
           value.options.indices.contains(value.selected),!value.options[value.selected].value.isEmpty,value.options[value.selected].enabled {
            adjust(value.selected,event.keyCode == 124 ? 1 : -1);return
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
            case 48 where value.hasRowActions && !value.buttons.isEmpty:
                let direction = event.modifierFlags.contains(.shift) ? -1 : 1
                let next = (sheetActionFocused ? sheetButton : -1)+direction
                if direction < 0 && !sheetActionFocused { sheetActionFocused = true;sheetButton = value.buttons.count-1 }
                else if value.buttons.indices.contains(next) { sheetActionFocused = true;sheetButton = next }
                else { sheetActionFocused = false }
                needsDisplay = true
            case 123,124:
                guard sheetActionFocused else { return }
                sheetButton = (sheetButton+(event.keyCode == 124 ? 1 : value.buttons.count-1))%max(1,value.buttons.count)
                needsDisplay = true
            case 125,126:
                sheetActionFocused = false
                guard !value.rows.isEmpty else { return }
                value.selected = (value.selected+(event.keyCode == 125 ? 1 : value.rows.count-1))%value.rows.count
                sheet = value;detailScroll = 0;revealSheetRow();needsDisplay = true
            case 36,49,76:
                if sheetActionFocused { finishSheetAction(sheetButton) }
                else { chooseSheetRow(value.selected) }
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
    private func chooseSheetRow(_ index:Int) {
        guard let value = sheet,value.rows.indices.contains(index) else { return }
        if value.rows[index].enabled { finishSheet(index) } else { refuse() }
    }
    override func mouseMoved(with event:NSEvent) {
        guard !isSuspended else { return }
        let point = canvasPoint(event)
        if var value = sheet {
            if value.mode == .list,let hit = sheetLayout(value).rows.first(where:{ $0.rect.contains(point) }),hit.index != value.selected || sheetActionFocused {
                sheetActionFocused = false;value.selected = hit.index;sheet = value;detailScroll = 0;needsDisplay = true
            }
            if value.mode == .buttons || (value.mode == .list && value.hasRowActions),
               let hit = sheetLayout(value).buttons.first(where:{ $0.rect.contains(point) }) {
                sheetActionFocused = value.mode == .list;sheetButton = hit.index;needsDisplay = true
            }
        } else if var value = selector,let hit = layout(value).options.first(where:{ $0.rect.contains(point) }),
                  value.options[hit.index].enabled,hit.index != value.selected {
            value.selected = hit.index;selector = value;needsDisplay = true
        } else if let value = notice {
            let hit = lineControls(noticeRect(value)).first(where:{ $0.rect.contains(point) })?.control
            if hit != hoveredControl { hoveredControl = hit;needsDisplay = true }
        }
    }
    override func mouseDown(with event:NSEvent) {
        guard !isSuspended else { return }
        if let value = sheet {
            let point = canvasPoint(event),shape = sheetLayout(value)
            switch value.mode {
            case .timed:finishSheet(0)
            case .list:
                if let hit = shape.buttons.first(where:{ $0.rect.contains(point) }),value.hasRowActions { finishSheetAction(hit.index) }
                else if let hit = shape.rows.first(where:{ $0.rect.contains(point) }) { chooseSheetRow(hit.index) }
            case .buttons:if let hit = shape.buttons.first(where:{ $0.rect.contains(point) }) { finishSheet(hit.index) }
            }
            return
        }
        if let value = notice {
            if let hit = lineControls(noticeRect(value)).first(where:{ $0.rect.contains(canvasPoint(event)) }) {
                onLineControl?(hit.control);needsDisplay = true;return
            }
            dismissNotice();return
        }
        if brief != nil { dismissBrief();return }
        if terrain != nil { dismissTerrain();return }
        guard let value = selector else { return }
        let point = canvasPoint(event),shape = layout(value)
        if let hit = shape.options.first(where:{ $0.rect.insetBy(dx:-3,dy:-2).contains(point) }) { choose(hit.index) }
        else if value.cancellable,value.cancelsOnOutsideClick,!shape.panel.contains(point) { choose(nil) }
    }
    override func scrollWheel(with event:NSEvent) {
        guard !isSuspended else { return }
        if notice != nil || brief != nil || selector?.horizontal == true,event.scrollingDeltaY != 0 {noticeScroll = max(0,noticeScroll-event.scrollingDeltaY*3);needsDisplay = true;return}
        if let value = sheet,sheetLayout(value).detail.contains(canvasPoint(event)),event.scrollingDeltaY != 0 {scrollDetail(by:-event.scrollingDeltaY*3);return}
        if var value = sheet,value.mode == .list,event.scrollingDeltaY != 0,!value.rows.isEmpty {
            sheetActionFocused = false
            value.selected = min(max(0,value.selected+(event.scrollingDeltaY < 0 ? 1 : -1)),value.rows.count-1)
            sheet = value;detailScroll = 0;revealSheetRow();needsDisplay = true
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
        guard !isSuspended else { return }
        if let value = sheet { finishSheet(value.mode == .list ? nil : value.mode == .timed ? 0 : value.buttons.count-1) }
        else if let value = selector,value.cancellable { choose(nil) } else if notice != nil { dismissNotice() } else if brief != nil { dismissBrief() } else if terrain != nil { dismissTerrain() }
    }
}
