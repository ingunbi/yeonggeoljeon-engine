// SPDX-License-Identifier: GPL-3.0-only
import AppKit

func battleBackground(_ definition:BattleDefinition,root:URL) throws -> CGImage? {
    guard let path = definition.image else { return nil }
    guard let width = definition.width, let height = definition.height,
          (1...256).contains(width), (1...256).contains(height) else {
        throw EngineError.invalid("Battle background requires established bounded grid dimensions")
    }
    let url = try containedResource(root:root,relative:path)
    guard let image = NSBitmapImageRep(data:try Data(contentsOf:url))?.cgImage,
          image.width == width*32, image.height == height*32 else {
        throw EngineError.invalid("Battle background does not match the source 32px logical-cell geometry")
    }
    return image
}

/// Engine research surfaces. The board deliberately uses generated grid marks,
/// not substitute artwork or a claim to reproduce the original battle screen.
final class BattleBoardView: NSView {
    let session: BattleSession
    let background:CGImage?
    private let cell: CGFloat = 24
    private let origin = NSPoint(x:24,y:90)
    private var message = "클릭: 선택·이동·공격 / Space: 대기 / Return: 턴 종료"
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(session: BattleSession,background:CGImage? = nil) {
        self.session = session; self.background = background
        super.init(frame:CGRect(x:0,y:0,width:max(820,CGFloat(session.width)*24+48),
                               height:max(520,CGFloat(session.height)*24+150)))
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }

    private func text(_ value:String, at point:NSPoint, size:CGFloat=13, color:NSColor = .white) {
        (value as NSString).draw(at:point,withAttributes:[.font:NSFont.systemFont(ofSize:size),.foregroundColor:color])
    }
    override func draw(_ dirtyRect:NSRect) {
        NSColor(calibratedWhite:0.075,alpha:1).setFill(); bounds.fill()
        text("실험 전투 — 원작 전투 수식·AI·승패 조건은 미복원",at:NSPoint(x:24,y:14),size:18,color:.systemYellow)
        text("\(session.definition.name ?? session.definition.id)  |  턴 \(session.round)  |  진영 \(session.activeSide)  |  \(session.outcome.rawValue)",at:NSPoint(x:24,y:44))
        text("무조건 배치 부분집합 · 미해결 조건부 배치 \(session.definition.conditionalUnits?.count ?? 0)개 · 원작 수치와 실험 수치는 별도",at:NSPoint(x:24,y:66),size:12,color:.lightGray)
        if let background = background, let context = NSGraphicsContext.current?.cgContext {
            Renderer.image(background,in:CGRect(x:origin.x,y:origin.y,width:CGFloat(session.width)*cell,height:CGFloat(session.height)*cell),context:context)
        }
        let reachable = (try? session.reachable()).map { Set($0.map(\.position)) } ?? []
        for y in 0..<session.height {
            for x in 0..<session.width {
                let rect = CGRect(x:origin.x+CGFloat(x)*cell,y:origin.y+CGFloat(y)*cell,width:cell,height:cell)
                (reachable.contains(GridPoint(x:x,y:y)) ? NSColor(calibratedRed:0.12,green:0.28,blue:0.35,alpha:0.65) : NSColor(calibratedWhite:0.12,alpha:background == nil ? 1 : 0.16)).setFill()
                rect.fill(); NSColor(calibratedWhite:0.22,alpha:1).setStroke()
                NSBezierPath(rect:rect).stroke()
            }
        }
        for unit in session.units.values.sorted(by:{$0.id < $1.id}) where unit.alive {
            let rect = CGRect(x:origin.x+CGFloat(unit.position.x)*cell+2,y:origin.y+CGFloat(unit.position.y)*cell+2,width:cell-4,height:cell-4)
            (unit.side == 0 ? NSColor.systemBlue : NSColor.systemRed).setFill()
            NSBezierPath(ovalIn:rect).fill()
            if unit.id == session.selectedUnit {
                NSColor.systemYellow.setStroke(); let border = NSBezierPath(rect:rect.insetBy(dx:-1,dy:-1)); border.lineWidth = 2; border.stroke()
            }
            text(String(unit.id),at:NSPoint(x:rect.minX+2,y:rect.minY+2),size:10)
        }
        let bottom = origin.y+CGFloat(session.height)*cell+12
        text(message,at:NSPoint(x:24,y:bottom),color:.lightGray)
        if let selected = session.selectedUnit, let unit = session.units[selected] {
            text("\(unit.name ?? "slot \(unit.id)") · HP \(unit.hp)/\(unit.stats.maxHP) · \(unit.stats.origin)",at:NSPoint(x:24,y:bottom+22),size:12)
        }
    }
    override func mouseDown(with event:NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow,from:nil)
        let x = Int(floor((p.x-origin.x)/cell)), y = Int(floor((p.y-origin.y)/cell))
        guard (0..<session.width).contains(x), (0..<session.height).contains(y) else { return }
        do {
            let target = session.units.values.first { $0.alive && $0.position == GridPoint(x:x,y:y) }
            if let target = target, target.side == session.activeSide { try session.select(unit:target.id) }
            else if let id = session.selectedUnit {
                if let target = target {
                    let result = try session.attack(unit:id,target:target.id)
                    message = "실험 피해 \(result.damage), 상대 HP \(result.remainingHP)"
                } else { _ = try session.move(unit:id,to:GridPoint(x:x,y:y)); message = "이동 완료" }
            }
        } catch { message = "\(error)" }
        needsDisplay = true
    }
    override func keyDown(with event:NSEvent) {
        guard !event.isARepeat else { return }
        do {
            if event.keyCode == 49, let id = session.selectedUnit { try session.wait(unit:id); message = "대기 완료" }
            else if [36,76].contains(event.keyCode) {
                try session.endTurn()
                if session.activeSide == 1 && session.outcome == .ongoing { try session.performEnemyTurn() }
                message = "실험 규칙으로 턴을 진행했습니다."
            } else { super.keyDown(with:event) }
        } catch { message = "\(error)" }
        needsDisplay = true
    }
    func capture(to url:URL) throws {
        guard let representation = bitmapImageRepForCachingDisplay(in:bounds) else { throw EngineError.invalid("Cannot allocate battle view capture") }
        cacheDisplay(in:bounds,to:representation)
        guard let png = representation.representation(using:.png,properties:[:]) else { throw EngineError.invalid("Cannot encode battle view capture") }
        try png.write(to:url,options:.atomic)
    }
}

final class RecordBrowser: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let titles:[String]
    let details:String
    let activate:(Int)->Void
    private let table = NSTableView()
    init(titles:[String],details:String,activate:@escaping(Int)->Void) {
        self.titles = titles; self.details = details; self.activate = activate
        super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() {
        let root = NSView(frame:CGRect(x:0,y:0,width:900,height:600))
        let label = NSTextField(wrappingLabelWithString:details)
        label.frame = CGRect(x:18,y:525,width:864,height:58); label.autoresizingMask = [.width,.minYMargin]
        root.addSubview(label)
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("record")); column.title = "원작에서 읽은 식별자와 지원 범위"; column.width = 850
        table.addTableColumn(column); table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(openSelected); table.rowHeight = 25
        let scroll = NSScrollView(frame:CGRect(x:18,y:65,width:864,height:450)); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.autoresizingMask = [.width,.height]; root.addSubview(scroll)
        let button = NSButton(title:"선택 항목 열기",target:self,action:#selector(openSelected))
        button.frame = CGRect(x:18,y:18,width:170,height:32); root.addSubview(button)
        view = root
    }
    func numberOfRows(in tableView:NSTableView)->Int { titles.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let text = NSTextField(labelWithString:titles[row]); text.lineBreakMode = .byTruncatingTail; return text
    }
    @objc private func openSelected() {
        let row = table.selectedRow
        if titles.indices.contains(row) { activate(row) }
    }
}
