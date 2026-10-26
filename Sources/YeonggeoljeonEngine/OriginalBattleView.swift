// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Native input surface over restored kernels. The isolated viewer records
/// source script hooks; a campaign host must resolve them before continuing.
final class OriginalBattleView:NSView {
    let session:OriginalBattleSession
    let background:CGImage?
    let sprites:OriginalBattleSpriteRenderer?
    let flow:OriginalBattleFlow
    var onHook:((OriginalTurnHook)throws->Bool)? { get { flow.onHook } set { flow.onHook = newValue } }
    var onRetirement:((OriginalRetirementNotice)throws->Bool)? { get { flow.onRetirement } set { flow.onRetirement = newValue } }
    /// A caller may supply names imported from its own original resources.
    /// The native UI never substitutes a copied table of original names.
    var strategyName:((Int)->String)?
    private var selected:Int?
    private struct StrategySelection {var abilityID:Int;var targetSlot:Int?}
    private var strategySelection:StrategySelection?
    private var waitingForStrategy = false
    private var waitingForAttack = false
    private let strategyButton = NSButton(title:"책략 (S)",target:nil,action:nil)
    private let strategyConfirmButton = NSButton(title:"책략 실행 (Enter)",target:nil,action:nil)
    private let strategyCancelButton = NSButton(title:"취소 (Esc)",target:nil,action:nil)
    private let retreatButton = NSButton(title:"총퇴각",target:nil,action:nil)
    private let quitButton = NSButton(title:"게임종료",target:nil,action:nil)
    /// Battle system menu texts exported from the caller's MAIN. Without a
    /// campaign host the retreat/quit results have no outer dispatcher.
    var menuTexts:OriginalBattleMenuTexts? { didSet { applyMenuTexts() } }
    var suspended:Bool { flow.suspended }
    var inputReady:(()->Bool)?
    private var message = "클릭: 선택·이동·공격 / S: 책략 / Space: 대기 / Return: 턴 종료 / Backspace: 이동 취소"
    private let cell:CGFloat = 32
    private let origin = NSPoint(x:24,y:92)
    var hooks:[OriginalTurnHook] { flow.hooks }
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    init(session:OriginalBattleSession,background:CGImage?,sprites:OriginalBattleSpriteRenderer? = nil) throws {
        self.session = session; self.background = background;self.sprites = sprites;flow = OriginalBattleFlow(session:session)
        super.init(frame:CGRect(x:0,y:0,width:max(920,CGFloat(session.width)*32+48),height:max(680,CGFloat(session.height)*32+260)))
        for button in [strategyButton,strategyConfirmButton,strategyCancelButton,retreatButton,quitButton] {button.target = self;button.bezelStyle = .rounded;addSubview(button)}
        retreatButton.action = #selector(requestRetreat(_:));quitButton.action = #selector(requestQuit(_:))
        retreatButton.isHidden = true;quitButton.isHidden = true
        strategyButton.action = #selector(showStrategyMenu(_:))
        strategyConfirmButton.action = #selector(confirmStrategy(_:))
        strategyCancelButton.action = #selector(cancelStrategy(_:))
        layout()
        refreshControls()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func start() throws { try flow.start();refreshControls();needsDisplay = true }
    func resumeSourceFlow() throws {
        try flow.resumeSourceFlow()
        if waitingForStrategy,let result = flow.lastStrategy {showStrategyResult(result);waitingForStrategy = false}
        if waitingForAttack,let result = flow.lastAttack {showAttackResult(result);waitingForAttack = false}
        refreshControls();needsDisplay = true
    }
    private var canInput:Bool {flow.acceptsManualInput && (inputReady?() ?? true)}
    private var footerY:CGFloat {origin.y+CGFloat(session.height)*cell+12}
    override func layout() {
        super.layout()
        strategyButton.frame = CGRect(x:24,y:footerY+52,width:128,height:28)
        strategyConfirmButton.frame = CGRect(x:164,y:footerY+52,width:170,height:28)
        strategyCancelButton.frame = CGRect(x:346,y:footerY+52,width:128,height:28)
        retreatButton.frame = CGRect(x:486,y:footerY+52,width:110,height:28)
        quitButton.frame = CGRect(x:608,y:footerY+52,width:110,height:28)
    }
    private func applyMenuTexts() {
        retreatButton.title = menuTexts?.retreat.label ?? "총퇴각";quitButton.title = menuTexts?.quit.label ?? "게임종료"
        retreatButton.isHidden = menuTexts == nil;quitButton.isHidden = menuTexts == nil;refreshControls()
    }
    private func confirm(_ text:String) -> Bool {
        let alert = NSAlert();alert.messageText = text
        alert.addButton(withTitle:"예 (Yes)");alert.addButton(withTitle:"아니요 (No)")
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// MAIN27D77..27DA3. The campaign host restarts from source36 afterwards.
    @objc private func requestRetreat(_ sender:Any?) {
        guard canInput,let texts = menuTexts else { return }
        if !flow.retreatAllowed {
            let alert = NSAlert();alert.messageText = texts.retreat.refused?.text ?? texts.retreat.label;alert.runModal();return
        }
        guard confirm(texts.retreat.confirm.text) else { return }
        do { try flow.requestRetreat();selected = nil;message = "총퇴각: 전투 개시 시점의 원작 체크포인트로 돌아갑니다." }
        catch { message = "\(error)" }
        refreshControls();needsDisplay = true
    }
    /// MAIN27E87..27EA3. The framework then shows MAIN's retry selector.
    @objc private func requestQuit(_ sender:Any?) {
        guard canInput,let texts = menuTexts,confirm(texts.quit.confirm.text) else { return }
        do { try flow.requestQuit();selected = nil } catch { message = "\(error)" }
        refreshControls();needsDisplay = true
    }
    private func refreshControls() {
        let unit = selected.flatMap{try? session.requireManualUnit($0)}
        strategyButton.isEnabled = canInput && unit != nil && unit!.scriptFlags&0x82 == 0
        strategyConfirmButton.isHidden = strategySelection == nil
        strategyCancelButton.isHidden = strategySelection == nil
        strategyConfirmButton.isEnabled = canInput && strategySelection != nil
        strategyCancelButton.isEnabled = canInput && strategySelection != nil
        retreatButton.isEnabled = canInput && strategySelection == nil
        quitButton.isEnabled = canInput && strategySelection == nil
    }
    private func strategyTitle(_ id:Int)->String {strategyName?(id) ?? "책략 #\(id)"}
    /// Source range owner followed by the dispatcher's nonmutating preflight:
    /// do not duplicate terrain/weather/full-healing rules in this view.
    private func legalStrategyTargets(_ ability:Int,casterSlot:Int) throws -> [Int] {
        let board = try session.board()
        guard let actor = board.actors.first(where:{$0.runtimeSlot == casterSlot}) else {return []}
        let candidates = try OriginalAI.strategyTargetSlots(profile:session.movement,board:board,actor:actor,abilityID:ability)
        if ability >= 30 {
            let probe = try OriginalStrategyOperation.begin(in:session,casterSlot:casterSlot,abilityID:ability)
            return probe.execution == nil ? candidates : []
        }
        return try candidates.filter { target in
            let probe = try OriginalStrategyOperation.begin(in:session,casterSlot:casterSlot,abilityID:ability,target:target)
            return probe.execution == nil
        }
    }
    @objc private func showStrategyMenu(_ sender:Any?) {
        do {try openStrategyMenu()} catch {message = "\(error)"}
        refreshControls();needsDisplay = true
    }
    private func openStrategyMenu() throws {
        guard canInput,let slot = selected else {throw BattleError.illegalAction("책략을 사용할 부대를 먼저 선택하세요.")}
        let unit = try session.requireManualUnit(slot),person = try session.people.person(unit.person)
        guard unit.scriptFlags&0x82 == 0 else {throw BattleError.illegalAction("이 부대는 현재 책략을 사용할 수 없습니다.")}
        let abilities = try session.movement.availableStrategies(classID:person.classID,level:person.level,mp:unit.mp)
        guard !abilities.isEmpty,let costs = session.movement.strategyMPCosts else {message = "현재 병과·레벨·MP로 사용할 수 있는 책략이 없습니다.";return}
        let menu = NSMenu(title:"책략 선택");menu.autoenablesItems = false
        for ability in abilities {
            let targets = try legalStrategyTargets(ability,casterSlot:slot)
            let item = NSMenuItem(title:"\(strategyTitle(ability)) · MP \(costs[ability])\(targets.isEmpty ? " · 대상 없음" : "")",action:#selector(selectStrategy(_:)),keyEquivalent:"")
            item.target = self;item.tag = ability;item.isEnabled = !targets.isEmpty;menu.addItem(item)
        }
        menu.popUp(positioning:nil,at:NSPoint(x:strategyButton.frame.minX,y:strategyButton.frame.maxY+4),in:self)
        window?.makeFirstResponder(self)
    }
    @objc private func selectStrategy(_ sender:NSMenuItem) {
        do {
            guard canInput,let slot = selected else {return}
            _ = try session.requireManualUnit(slot)
            let targets = try legalStrategyTargets(sender.tag,casterSlot:slot)
            guard !targets.isEmpty else {throw BattleError.illegalAction("현재 선택할 수 있는 대상이 없습니다.")}
            strategySelection = StrategySelection(abilityID:sender.tag,targetSlot:sender.tag < 30 ? targets.first : nil)
            message = sender.tag < 30 ? "\(strategyTitle(sender.tag)): 표시된 대상을 클릭하거나 화살표·Tab으로 선택한 뒤 Enter를 누르세요." : "\(strategyTitle(sender.tag)): 표시된 \(targets.count)개 부대에 적용합니다. 실행 또는 Enter로 확인하세요."
        } catch {message = "\(error)"}
        refreshControls();needsDisplay = true
    }
    @objc private func confirmStrategy(_ sender:Any?) {
        do {try executeSelectedStrategy()} catch {message = "\(error)"}
        refreshControls();needsDisplay = true
    }
    @objc private func cancelStrategy(_ sender:Any?) {
        guard canInput else {return}
        strategySelection = nil;message = "책략 선택을 취소했습니다. 이동 위치는 유지됩니다."
        refreshControls();needsDisplay = true
    }
    private func executeSelectedStrategy() throws {
        guard canInput,let slot = selected,let selection = strategySelection else {return}
        let targets = try legalStrategyTargets(selection.abilityID,casterSlot:slot)
        guard !targets.isEmpty,selection.abilityID >= 30 || selection.targetSlot.map(targets.contains) == true else {
            throw BattleError.illegalAction("책략 대상 상태가 바뀌었습니다. 대상을 다시 선택하세요.")
        }
        let result = try flow.manualStrategy(slot,abilityID:selection.abilityID,target:selection.targetSlot)
        strategySelection = nil
        if let result {showStrategyResult(result);if result.completed {selected = nil}}
        else {waitingForStrategy = true;selected = nil;message = "책략의 퇴장 대사·이벤트가 끝나기를 기다립니다."}
    }
    private func showStrategyResult(_ result:OriginalStrategyExecution) {
        if result.completed {message = "\(strategyTitle(result.abilityID)) 실행 · \(result.targets.count)개 대상 처리"}
        else {message = "책략을 실행하지 않았습니다: \(result.rejectionReason ?? "선택 취소")"}
    }
    private func showAttackResult(_ result:OriginalStrikeExchange) {
        message = "피해 \(result.strike.damage) · 반격 \(result.counter?.damage ?? 0) · EXP \(result.experience.experience)"
    }
    private func cycleStrategyTarget(_ step:Int) throws {
        guard let slot = selected,var selection = strategySelection,selection.abilityID < 30 else {return}
        let targets = try legalStrategyTargets(selection.abilityID,casterSlot:slot)
        guard !targets.isEmpty else {return}
        let index = selection.targetSlot.flatMap{targets.firstIndex(of:$0)} ?? 0
        selection.targetSlot = targets[(index+step+targets.count)%targets.count];strategySelection = selection
    }
    private func text(_ value:String,_ x:CGFloat,_ y:CGFloat,size:CGFloat = 13,color:NSColor = .white) {
        (value as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:size),.foregroundColor:color])
    }
    override func draw(_ dirtyRect:NSRect) {
        refreshControls()
        NSColor(calibratedWhite:0.06,alpha:1).setFill();bounds.fill()
        text("원작 전투 복원 · \(session.definition.id)",24,12,size:19,color:.systemYellow)
        text("\(session.turns.roundIndex+1)/\(session.header.turnLimit) 턴 · \(session.turns.stage.rawValue) · 날씨 코드 \(session.turns.weatherIndex)",24,42)
        text(onHook == nil ? "독립 검증: 원작 수치·이동·복원 AI 사용 / 캠페인 이벤트는 기록 / 원작 화면·전체 난수 일치 미검증" : "원작 캠페인 상태와 연결된 전투",24,66,size:12,color:.lightGray)
        if let background = background,let context = NSGraphicsContext.current?.cgContext {
            Renderer.image(background,in:CGRect(x:origin.x,y:origin.y,width:CGFloat(session.width)*cell,height:CGFloat(session.height)*cell),context:context)
        }
        let reachable = strategySelection == nil ? selected.flatMap { try? session.reachable($0) }.map(Set.init) ?? [] : []
        for point in reachable {
            NSColor(calibratedRed:0.2,green:0.6,blue:1,alpha:0.25).setFill()
            CGRect(x:origin.x+CGFloat(point.x)*cell,y:origin.y+CGFloat(point.y)*cell,width:cell,height:cell).fill()
        }
        let strategyTargets = strategySelection.flatMap { choice in selected.flatMap {try? legalStrategyTargets(choice.abilityID,casterSlot:$0)} } ?? []
        for slot in strategyTargets {
            guard let unit = session.units[slot] else {continue}
            NSColor(calibratedRed:0.1,green:1,blue:0.7,alpha:0.3).setFill()
            CGRect(x:origin.x+CGFloat(unit.position.x)*cell,y:origin.y+CGFloat(unit.position.y)*cell,width:cell,height:cell).fill()
        }
        for unit in session.units.values.sorted(by:{$0.slot < $1.slot}) where unit.status == 2 {
            guard let person = try? session.people.person(unit.person) else { continue }
            let rect = CGRect(x:origin.x+CGFloat(unit.position.x)*cell+3,y:origin.y+CGFloat(unit.position.y)*cell+3,width:cell-6,height:cell-6)
            if let sprites = sprites,let context = NSGraphicsContext.current?.cgContext {
                do { Renderer.image(try sprites.image(unit:unit,classID:person.classID),in:rect.insetBy(dx:-3,dy:-3),context:context) }
                catch { message = "원작 그림 경계: \(error)";text("?",rect.minX,rect.minY,color:.systemYellow) }
            } else {
                (unit.enemy ? NSColor.systemRed : NSColor.systemBlue).setFill();NSBezierPath(ovalIn:rect).fill()
            }
            if selected == unit.slot { NSColor.systemYellow.setStroke();let p = NSBezierPath(rect:rect.insetBy(dx:-2,dy:-2));p.lineWidth = 2;p.stroke() }
            if strategySelection?.targetSlot == unit.slot {NSColor.systemGreen.setStroke();let p = NSBezierPath(rect:rect.insetBy(dx:-3,dy:-3));p.lineWidth = 3;p.stroke()}
            text(String(unit.slot),rect.minX,rect.maxY-8,size:9,color:.systemYellow)
        }
        if let duel = session.scriptActions.duel,duel.active,let sprites = sprites,let context = NSGraphicsContext.current?.cgContext {
            let viewport = OriginalDuelSprites.sourceViewport.offsetBy(dx:origin.x-16,dy:origin.y-32)
            context.saveGState();context.clip(to:viewport);context.setFillColor(CGColor(gray:0,alpha:1));context.fill(viewport)
            do {
                for side in OriginalDuelSprites.sourceDrawOrder {
                    let rect = try OriginalDuelSprites.sourceRect(duel:duel,side:side).offsetBy(dx:origin.x-16,dy:origin.y-32)
                    Renderer.image(try sprites.duelImage(duel,side:side),in:rect,context:context)
                }
            } catch { message = "원작 일기토 그림 경계: \(error)" }
            context.restoreGState()
        }
        let y = footerY
        text(message,24,y,color:.lightGray)
        if let slot = selected,let unit = session.units[slot],let person = try? session.people.person(unit.person) {
            let maximum = (try? OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:session.combat)) ?? 0
            text("\(person.name) · 병력 \(person.rawTroops)/\(maximum) · Lv \(person.level) EXP \(person.experience) · 사기 \(unit.morale) · MP \(unit.mp)",24,y+23)
        }
        if let choice = strategySelection {
            if choice.abilityID >= 30 {text("범위 대상 \(strategyTargets.count)개 · Enter/실행: 확인 · Esc: 취소",24,y+88,color:.systemGreen)}
            else if let slot = choice.targetSlot,let unit = session.units[slot],let person = try? session.people.person(unit.person) {
                text("대상: \(person.name) · 병력 \(person.rawTroops) · 사기 \(unit.morale) · 화살표/Tab: 대상 변경 · Enter: 실행 · Esc: 취소",24,y+88,color:.systemGreen)
            }
        }
        if !session.objectiveEvents.isEmpty && onRetirement == nil { text("원작 목표 이벤트 \(session.objectiveEvents.map(\.kind)) 발생 · 캠페인에 적용하지 않은 독립 검증입니다.",24,y+118,color:.systemYellow) }
    }
    override func mouseDown(with event:NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow,from:nil),point = GridPoint(x:Int(floor((p.x-origin.x)/cell)),y:Int(floor((p.y-origin.y)/cell)))
        guard (0..<session.width).contains(point.x),(0..<session.height).contains(point.y) else { return }
        do {
            guard canInput else { throw BattleError.illegalAction("Continue the current source phase first") }
            let target = session.units.values.first(where:{$0.status == 2 && $0.position == point})
            if var choice = strategySelection,let slot = selected {
                let targets = try legalStrategyTargets(choice.abilityID,casterSlot:slot)
                guard let target = target,targets.contains(target.slot) else {throw BattleError.illegalAction("표시된 책략 대상 중에서 선택하세요.")}
                if choice.abilityID < 30 {choice.targetSlot = target.slot;strategySelection = choice;try executeSelectedStrategy()}
                else {message = "범위 책략은 실행 버튼 또는 Enter로 전체 대상 적용을 확인하세요."}
            } else if let target = target,!target.enemy {
                if let old = selected,old != target.slot { try session.cancelMove(old) }
                _ = try session.requireManualUnit(target.slot);selected = target.slot
            } else if let slot = selected {
                _ = try session.requireManualUnit(slot)
                if let target = target {
                    if let result = try flow.manualAttack(slot,target:target.slot) { showAttackResult(result) }
                    else {waitingForAttack = true;message = "공격의 퇴장 대사·이벤트가 끝나기를 기다립니다."}
                    selected = nil
                } else { _ = try session.move(slot,to:point);message = "이동했습니다. 행동을 선택하거나 Backspace로 취소하세요." }
            }
        } catch { message = "\(error)" }
        refreshControls();needsDisplay = true
    }
    override func keyDown(with event:NSEvent) {
        guard !event.isARepeat else { return }
        do {
            guard !suspended,inputReady?() ?? true else { return }
            if strategySelection != nil {
                guard canInput else {return}
                if event.keyCode == 53 {cancelStrategy(nil)}
                else if [36,76].contains(event.keyCode) {try executeSelectedStrategy()}
                else if [48,49,124,125].contains(event.keyCode) {try cycleStrategyTarget(event.modifierFlags.contains(.shift) ? -1 : 1)}
                else if [123,126].contains(event.keyCode) {try cycleStrategyTarget(-1)}
                else if event.keyCode == 1 || event.charactersIgnoringModifiers?.lowercased() == "s" {try openStrategyMenu()}
            } else if event.keyCode == 1 || event.charactersIgnoringModifiers?.lowercased() == "s" {try openStrategyMenu()}
            else if event.keyCode == 49,let slot = selected {guard canInput else {return};try flow.manualWait(slot);selected = nil;message = "대기했습니다." }
            else if [36,76].contains(event.keyCode) {
                if session.turns.stage == .manualFriendly {
                    guard canInput else {return}
                    if let slot = selected { try session.cancelMove(slot);selected = nil }
                    try flow.finishManual()
                }
                else if !suspended { try flow.start() }
                message = "복원된 원작 순서로 턴을 진행했습니다."
            } else if event.keyCode == 51,let slot = selected {guard canInput else {return};try session.cancelMove(slot);message = "이동을 취소했습니다." }
            else { super.keyDown(with:event) }
        } catch { message = "\(error)" }
        refreshControls();needsDisplay = true
    }
    func capture(to url:URL) throws {
        guard let rep = bitmapImageRepForCachingDisplay(in:bounds) else { throw EngineError.invalid("Cannot allocate original battle capture") }
        cacheDisplay(in:bounds,to:rep)
        guard let png = rep.representation(using:.png,properties:[:]) else { throw EngineError.invalid("Cannot encode original battle capture") }
        try png.write(to:url,options:.atomic)
    }
}
