// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Native input surface over restored kernels. The isolated viewer records
/// source script hooks; a campaign host must resolve them before continuing.
final class OriginalBattleView:NSView {
    let session:OriginalBattleSession
    let background:CGImage?
    var onHook:((OriginalTurnHook)throws->Void)?
    var onObjective:((OriginalCampaignEvent)throws->Void)?
    private var selected:Int?
    private var message = "클릭: 선택·이동·공격 / Space: 대기 / Return: 턴 종료 / Backspace: 이동 취소"
    private let cell:CGFloat = 32
    private let origin = NSPoint(x:24,y:92)
    private(set) var hooks:[OriginalTurnHook] = []
    private var objectivesDelivered = 0
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    init(session:OriginalBattleSession,background:CGImage?) throws {
        self.session = session; self.background = background
        super.init(frame:CGRect(x:0,y:0,width:max(920,CGFloat(session.width)*32+48),height:max(650,CGFloat(session.height)*32+176)))
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func start() throws { try beginRound(); needsDisplay = true }
    private func hook(_ value:OriginalTurnHook) throws { hooks.append(value);try onHook?(value) }
    private func beginRound() throws {
        guard let numbered = try session.beginRound() else { message = "원작 턴 제한 결과: \(session.turns.result)";return }
        try hook(numbered)
        guard session.turns.result == 0 else { return }
        try hook(session.prepareFriendlyRound())
        guard session.turns.result == 0 else { return }
        try session.enterManualFriendly()
    }
    private func objectives() throws {
        for event in session.objectiveEvents.dropFirst(objectivesDelivered) { try onObjective?(event) }
        objectivesDelivered = session.objectiveEvents.count
    }
    private func finishManual() throws {
        try session.finishManualFriendly(); try nativeActions()
        guard session.turns.result == 0 else { return }
        try session.prepareEnemyPhase(); try nativeActions()
        guard session.turns.result == 0 else { return }
        try session.completeRound(); selected = nil;try beginRound()
    }
    private func nativeActions() throws {
        while let slot = session.turns.pendingAI.first,session.turns.result == 0 {
            guard let unit = session.units[slot],unit.status == 2,unit.orderMode != 7,unit.scriptFlags&0x80 == 0 else {
                try session.skipNativeUnit(slot);continue
            }
            let decision = try session.aiDecision(slot)
            try session.applyAIMovement(slot,decision)
            if let strategy = decision.strategyID { _ = try session.executeStrategy(slot,abilityID:strategy,target:decision.targetSlot);try objectives() }
            else if let target = decision.targetSlot { _ = try session.attack(slot,target:target);try objectives() }
            if session.turns.result != 0 { return }
            if let value = try session.completeNativeUnit(slot) { try hook(value) }
        }
    }
    private func text(_ value:String,_ x:CGFloat,_ y:CGFloat,size:CGFloat = 13,color:NSColor = .white) {
        (value as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:size),.foregroundColor:color])
    }
    override func draw(_ dirtyRect:NSRect) {
        NSColor(calibratedWhite:0.06,alpha:1).setFill();bounds.fill()
        text("원작 전투 복원 · \(session.definition.id)",24,12,size:19,color:.systemYellow)
        text("\(session.turns.roundIndex+1)/\(session.header.turnLimit) 턴 · \(session.turns.stage.rawValue) · 날씨 코드 \(session.turns.weatherIndex)",24,42)
        text(onHook == nil ? "독립 검증: 원작 수치·이동·복원 AI 사용 / 캠페인 이벤트는 기록 / 원작 화면·전체 난수 일치 미검증" : "원작 캠페인 상태와 연결된 전투",24,66,size:12,color:.lightGray)
        if let background = background,let context = NSGraphicsContext.current?.cgContext {
            Renderer.image(background,in:CGRect(x:origin.x,y:origin.y,width:CGFloat(session.width)*cell,height:CGFloat(session.height)*cell),context:context)
        }
        let reachable = selected.flatMap { try? session.reachable($0) }.map(Set.init) ?? []
        for point in reachable {
            NSColor(calibratedRed:0.2,green:0.6,blue:1,alpha:0.25).setFill()
            CGRect(x:origin.x+CGFloat(point.x)*cell,y:origin.y+CGFloat(point.y)*cell,width:cell,height:cell).fill()
        }
        for unit in session.units.values.sorted(by:{$0.slot < $1.slot}) where unit.status == 2 {
            guard (try? session.people.person(unit.person)) != nil else { continue }
            let rect = CGRect(x:origin.x+CGFloat(unit.position.x)*cell+3,y:origin.y+CGFloat(unit.position.y)*cell+3,width:cell-6,height:cell-6)
            (unit.enemy ? NSColor.systemRed : NSColor.systemBlue).setFill();NSBezierPath(ovalIn:rect).fill()
            if selected == unit.slot { NSColor.systemYellow.setStroke();let p = NSBezierPath(rect:rect.insetBy(dx:-2,dy:-2));p.lineWidth = 2;p.stroke() }
            text(String(unit.slot),rect.minX+4,rect.minY+4,size:11)
        }
        let y = origin.y+CGFloat(session.height)*cell+12
        text(message,24,y,color:.lightGray)
        if let slot = selected,let unit = session.units[slot],let person = try? session.people.person(unit.person) {
            let maximum = (try? OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:session.combat)) ?? 0
            text("\(person.name) · 병력 \(person.rawTroops)/\(maximum) · Lv \(person.level) EXP \(person.experience) · 사기 \(unit.morale) · MP \(unit.mp)",24,y+23)
        }
        if !session.objectiveEvents.isEmpty && onObjective == nil { text("원작 목표 이벤트 \(session.objectiveEvents.map(\.kind)) 발생 · 캠페인에 적용하지 않은 독립 검증입니다.",24,y+47,color:.systemYellow) }
    }
    override func mouseDown(with event:NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow,from:nil),point = GridPoint(x:Int(floor((p.x-origin.x)/cell)),y:Int(floor((p.y-origin.y)/cell)))
        guard (0..<session.width).contains(point.x),(0..<session.height).contains(point.y) else { return }
        do {
            guard session.turns.stage == .manualFriendly else { throw BattleError.illegalAction("Continue the current source phase first") }
            let target = session.units.values.first(where:{$0.status == 2 && $0.position == point})
            if let target = target,!target.enemy {
                if let old = selected,old != target.slot { try session.cancelMove(old) }
                _ = try session.requireManualUnit(target.slot);selected = target.slot
            } else if let slot = selected {
                _ = try session.requireManualUnit(slot)
                if let target = target {
                    let result = try session.attack(slot,target:target.slot);message = "피해 \(result.strike.damage) · 반격 \(result.counter?.damage ?? 0) · EXP \(result.experience.experience)"
                    try objectives();try hook(session.sourceUnitHook(slot));selected = nil
                } else { _ = try session.move(slot,to:point);message = "이동했습니다. 행동을 선택하거나 Backspace로 취소하세요." }
            }
        } catch { message = "\(error)" }
        needsDisplay = true
    }
    override func keyDown(with event:NSEvent) {
        guard !event.isARepeat else { return }
        do {
            if event.keyCode == 49,let slot = selected { try hook(session.waitManually(slot));selected = nil;message = "대기했습니다." }
            else if [36,76].contains(event.keyCode) {
                if session.turns.stage == .manualFriendly {
                    if let slot = selected { try session.cancelMove(slot);selected = nil }
                    try finishManual()
                }
                else if [.friendlyAI,.enemyAI].contains(session.turns.stage) { try nativeActions() }
                message = "복원된 원작 순서로 턴을 진행했습니다."
            } else if event.keyCode == 51,let slot = selected { try session.cancelMove(slot);message = "이동을 취소했습니다." }
            else { super.keyDown(with:event) }
        } catch { message = "\(error)" }
        needsDisplay = true
    }
    func capture(to url:URL) throws {
        guard let rep = bitmapImageRepForCachingDisplay(in:bounds) else { throw EngineError.invalid("Cannot allocate original battle capture") }
        cacheDisplay(in:bounds,to:rep)
        guard let png = rep.representation(using:.png,properties:[:]) else { throw EngineError.invalid("Cannot encode original battle capture") }
        try png.write(to:url,options:.atomic)
    }
}
