// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Native input surface over restored kernels, drawn on MAIN's 640×400 battle
/// screen. The isolated viewer records source script hooks; a campaign host
/// must resolve them before continuing.
final class OriginalBattleView:NSView {
    let session:OriginalBattleSession
    let background:CGImage?
    let sprites:OriginalBattleSpriteRenderer?
    let style:OriginalBattleStyle
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
    /// Battle system menu texts exported from the caller's MAIN. Without a
    /// campaign host the retreat/quit results have no outer dispatcher.
    var menuTexts:OriginalBattleMenuTexts? { didSet { needsDisplay = true } }
    var suspended:Bool { flow.suspended }
    var inputReady:(()->Bool)?
    /// Replaces the status line while the owner has something to report.
    var externalStatus:String? { didSet { if externalStatus != oldValue { needsDisplay = true } } }
    /// Replay captures label slots, because input files address units by slot.
    var showsSlotNumbers = false
    private var message = "클릭: 선택·이동·공격 / S: 책략 / Space: 대기 / Return: 턴 종료 / Backspace: 이동 취소 / 방향키·휠: 지도 이동"
    private var layoutFacts:OriginalBattleLayout { style.layout }
    private var camera:OriginalBattleCamera
    private var listSide = 0
    private var listTop = 0
    /// The unit whose details the status line shows.
    private var inspected:Int?
    private var functionOpen = false
    private var seenPositions:[Int:GridPoint] = [:]
    private var seenStage:OriginalTurnStage?
    private var wheelRemainder = CGPoint.zero
    private let overlay = CanvasOverlayView()
    var hooks:[OriginalTurnHook] { flow.hooks }
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    init(session:OriginalBattleSession,background:CGImage?,sprites:OriginalBattleSpriteRenderer? = nil,style:OriginalBattleStyle = .plain) throws {
        self.session = session;self.background = background;self.sprites = sprites;self.style = style
        flow = OriginalBattleFlow(session:session)
        camera = OriginalBattleCamera(width:session.width,height:session.height,layout:style.layout)
        super.init(frame:CGRect(x:0,y:0,width:960,height:640))
        autoresizingMask = [.width,.height]
        overlay.frame = bounds;overlay.autoresizingMask = [.width,.height];overlay.viewport = style.layout.viewportRect
        overlay.restoreFocus = { [weak self] in
            guard let self = self else { return }
            self.window?.makeFirstResponder(self);self.needsDisplay = true
        }
        addSubview(overlay)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func start() throws { try flow.start();needsDisplay = true }
    func resumeSourceFlow() throws {
        try flow.resumeSourceFlow()
        if waitingForStrategy,let result = flow.lastStrategy {showStrategyResult(result);waitingForStrategy = false}
        if waitingForAttack,let result = flow.lastAttack {showAttackResult(result);waitingForAttack = false}
        needsDisplay = true
    }
    private var canInput:Bool {flow.acceptsManualInput && (inputReady?() ?? true)}
    // Canvas mapping matches the campaign view: fit 640×400 above a 40pt status bar.
    private var scale:CGFloat { max(0.1,min(bounds.width/640,(bounds.height-40)/400)) }
    private var canvasOrigin:CGPoint { CGPoint(x:(bounds.width-640*scale)/2,y:0) }
    private func canvasPoint(_ event:NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow,from:nil)
        return CGPoint(x:(p.x-canvasOrigin.x)/scale,y:(p.y-canvasOrigin.y)/scale)
    }
    private func yesNo(_ text:String,_ answer:@escaping (Bool) -> Void) {
        overlay.show(CanvasMenu(title:text,options:[.init(label:"예",image:style.yes),.init(label:"아니요",image:style.no)],
                                horizontal:true) { index in answer(index == 0) })
    }
    private func notice(_ text:String) {
        overlay.show(CanvasNotice(speaker:"",text:text,portrait:nil) { })
    }
    /// MAIN27D77..27DA3. The campaign host restarts from source36 afterwards.
    private func requestRetreat() {
        guard canInput,let texts = menuTexts else { return }
        if !flow.retreatAllowed { notice(texts.retreat.refused?.text ?? texts.retreat.label);return }
        yesNo(texts.retreat.confirm.text) { [weak self] yes in
            guard let self = self,yes else { return }
            do { try self.flow.requestRetreat();self.selected = nil;self.message = "총퇴각: 전투 개시 시점의 원작 체크포인트로 돌아갑니다." }
            catch { self.message = "\(error)" }
            self.needsDisplay = true
        }
    }
    /// MAIN27E87..27EA3. The framework then shows MAIN's retry selector.
    private func requestQuit() {
        guard canInput,let texts = menuTexts else { return }
        yesNo(texts.quit.confirm.text) { [weak self] yes in
            guard let self = self,yes else { return }
            do { try self.flow.requestQuit();self.selected = nil } catch { self.message = "\(error)" }
            self.needsDisplay = true
        }
    }
    private func endTurn() throws {
        if session.turns.stage == .manualFriendly {
            guard canInput else {return}
            if let slot = selected { try session.cancelMove(slot);selected = nil }
            try flow.finishManual()
        }
        else if !suspended { try flow.start() }
        message = "복원된 원작 순서로 턴을 진행했습니다."
    }
    /// The 기능 button opens MAIN27D12's list. Items without a restored
    /// handler stay visible and disabled.
    private func openFunctionMenu() {
        guard canInput else { return }
        let restored:Set<String> = menuTexts == nil ? ["end-turn"] : ["end-turn","retreat","quit"]
        let items = menuTexts?.items ?? [OriginalTitleMenuItem(index:0,action:"end-turn",text:"턴 종료")]
        functionOpen = true;needsDisplay = true
        overlay.show(CanvasMenu(title:"",options:items.map { .init(label:$0.text,enabled:restored.contains($0.action)) },cancellable:true) { [weak self] index in
            guard let self = self else { return }
            self.functionOpen = false;self.needsDisplay = true
            guard let index = index else { return }
            switch items[index].action {
            case "end-turn": do { try self.endTurn() } catch { self.message = "\(error)" }
            case "retreat": self.requestRetreat()
            case "quit": self.requestQuit()
            default: break
            }
        })
    }
    /// Native command list for the selected unit; original unit commands are
    /// reached by key or click in this view.
    private func openUnitMenu(_ slot:Int) {
        overlay.show(CanvasMenu(title:"",options:[.init(label:"책략 (S)"),.init(label:"대기 (Space)"),.init(label:"이동 취소 (Backspace)")],cancellable:true) { [weak self] index in
            guard let self = self,let index = index else { return }
            do {
                switch index {
                case 0: try self.openStrategyMenu()
                case 1: guard self.canInput else { return };try self.flow.manualWait(slot);self.selected = nil;self.message = "대기했습니다."
                default: guard self.canInput else { return };try self.session.cancelMove(slot);self.message = "이동을 취소했습니다."
                }
            } catch { self.message = "\(error)" }
            self.needsDisplay = true
        })
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
    private func openStrategyMenu() throws {
        guard canInput,let slot = selected else {throw BattleError.illegalAction("책략을 사용할 부대를 먼저 선택하세요.")}
        let unit = try session.requireManualUnit(slot),person = try session.people.person(unit.person)
        guard unit.scriptFlags&0x82 == 0 else {throw BattleError.illegalAction("이 부대는 현재 책략을 사용할 수 없습니다.")}
        let abilities = try session.movement.availableStrategies(classID:person.classID,level:person.level,mp:unit.mp)
        guard !abilities.isEmpty,let costs = session.movement.strategyMPCosts else {message = "현재 병과·레벨·MP로 사용할 수 있는 책략이 없습니다.";return}
        var options:[CanvasMenu.Option] = []
        for ability in abilities {
            let targets = try legalStrategyTargets(ability,casterSlot:slot)
            options.append(.init(label:"\(strategyTitle(ability)) · MP \(costs[ability])\(targets.isEmpty ? " · 대상 없음" : "")",enabled:!targets.isEmpty))
        }
        overlay.show(CanvasMenu(title:"책략 선택",options:options,cancellable:true) { [weak self] index in
            guard let self = self,let index = index else { return }
            self.selectStrategy(abilities[index]);self.needsDisplay = true
        })
    }
    private func selectStrategy(_ ability:Int) {
        do {
            guard canInput,let slot = selected else {return}
            _ = try session.requireManualUnit(slot)
            let targets = try legalStrategyTargets(ability,casterSlot:slot)
            guard !targets.isEmpty else {throw BattleError.illegalAction("현재 선택할 수 있는 대상이 없습니다.")}
            strategySelection = StrategySelection(abilityID:ability,targetSlot:ability < 30 ? targets.first : nil)
            message = ability < 30 ? "\(strategyTitle(ability)): 표시된 대상을 클릭하거나 화살표·Tab으로 선택한 뒤 Enter를 누르세요." : "\(strategyTitle(ability)): 표시된 \(targets.count)개 부대에 적용합니다. Enter로 확인하세요."
        } catch {message = "\(error)"}
    }
    private func cancelStrategy() {
        guard canInput else {return}
        strategySelection = nil;message = "책략 선택을 취소했습니다. 이동 위치는 유지됩니다."
        needsDisplay = true
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
    /// MAIN's force label of a unit (MAIN2C51C..2C584). Force 14 borrows the
    /// side leader's force.
    private func force(of unit:OriginalLiveUnit) -> Int {
        guard let person = try? session.people.person(unit.person) else { return 0 }
        let id = person.sourceFlags&31
        guard id == 14,let lead = session.units[unit.enemy ? 15 : 0],let leader = try? session.people.person(lead.person) else { return id }
        return leader.sourceFlags&31
    }
    private var listRows:[Int] { OriginalBattleRoster.rows(side:listSide,units:session.units) { self.force(of:$0) } }
    private var listTopLimit:Int { max(0,listRows.count-layoutFacts.list.rows) }
    private func color(_ index:Int) -> NSColor { style.colors[index&15] }
    private func text(_ value:String,in rect:CGRect,color:NSColor = .white,size:CGFloat = 13,alignment:NSTextAlignment = .left,monospaced:Bool = false) {
        let paragraph = NSMutableParagraphStyle();paragraph.alignment = alignment;paragraph.lineBreakMode = .byClipping
        let font = monospaced ? NSFont.monospacedDigitSystemFont(ofSize:size,weight:.regular) : (NSFont(name:"Apple SD Gothic Neo",size:size) ?? .systemFont(ofSize:size))
        (value as NSString).draw(in:rect,withAttributes:[.font:font,.foregroundColor:color,.paragraphStyle:paragraph])
    }
    /// Keeps moved units in view as MAIN2997E does for each source move.
    private func updateCamera() {
        var moved:GridPoint?
        for unit in session.units.values.sorted(by:{$0.slot < $1.slot}) where unit.status == 2 {
            if let old = seenPositions[unit.slot],old != unit.position { moved = unit.position }
            seenPositions[unit.slot] = unit.position
        }
        let stage = session.turns.stage
        if stage == .manualFriendly,seenStage != stage,moved == nil {
            moved = session.units.values.filter({ !$0.enemy && $0.status == 2 }).min(by:{$0.slot < $1.slot})?.position
        }
        seenStage = stage
        if let cell = moved { camera.follow(cell,margin:layoutFacts.followMargin) }
    }
    private func drawFrame(_ context:CGContext) {
        let facts = layoutFacts
        if let frame = style.frame { Renderer.image(frame,in:CGRect(x:0,y:0,width:640,height:400),context:context) }
        else {
            context.setFillColor(CGColor(gray:0.14,alpha:1));context.fill(CGRect(x:0,y:0,width:640,height:400))
            context.setFillColor(CGColor(red:0.1,green:0.14,blue:0.4,alpha:1));context.fill(OriginalBattleLayout.rect(facts.list.rect))
            context.setStrokeColor(CGColor(gray:0.6,alpha:1));context.stroke(OriginalBattleLayout.rect(facts.functionButton))
            text("기능",in:OriginalBattleLayout.rect(facts.functionButton),alignment:.center)
        }
        context.setFillColor(CGColor(gray:0,alpha:1));context.fill(facts.viewportRect)
        if functionOpen,let picture = style.functionPressed { Renderer.image(picture,in:OriginalBattleLayout.rect(facts.functionButton),context:context) }
        text(session.definition.name ?? session.definition.id,in:CGRect(x:facts.title.column*8,y:facts.title.y-1,width:facts.title.width*8,height:18),color:color(7),alignment:.center)
    }
    private func drawField(_ context:CGContext) {
        let facts = layoutFacts,viewport = facts.viewportRect,cell = facts.cell
        context.saveGState();context.clip(to:viewport)
        func rect(_ point:GridPoint) -> CGRect { camera.rect(of:point,in:viewport,size:cell) }
        if let background = background {
            let map = CGRect(x:Int(viewport.minX)-camera.x*cell/2,y:Int(viewport.minY)-camera.y*cell/2,width:session.width*cell,height:session.height*cell)
            Renderer.image(background,in:map,context:context)
        }
        let reachable = strategySelection == nil ? selected.flatMap { try? session.reachable($0) }.map(Set.init) ?? [] : []
        for point in reachable {
            NSColor(calibratedRed:0.2,green:0.6,blue:1,alpha:0.25).setFill();rect(point).fill()
        }
        let strategyTargets = strategySelection.flatMap { choice in selected.flatMap {try? legalStrategyTargets(choice.abilityID,casterSlot:$0)} } ?? []
        for slot in strategyTargets {
            guard let unit = session.units[slot] else {continue}
            NSColor(calibratedRed:0.1,green:1,blue:0.7,alpha:0.3).setFill();rect(unit.position).fill()
        }
        for unit in session.units.values.sorted(by:{$0.slot < $1.slot}) where unit.status == 2 {
            guard let person = try? session.people.person(unit.person) else { continue }
            let box = rect(unit.position)
            if let sprites = sprites {
                do { Renderer.image(try sprites.image(unit:unit,classID:person.classID),in:box,context:context) }
                catch { message = "원작 그림 경계: \(error)";text("?",in:box,color:.systemYellow) }
            } else {
                (unit.enemy ? NSColor.systemRed : NSColor.systemBlue).setFill();NSBezierPath(ovalIn:box.insetBy(dx:3,dy:3)).fill()
            }
            if selected == unit.slot { NSColor.systemYellow.setStroke();let p = NSBezierPath(rect:box.insetBy(dx:1,dy:1));p.lineWidth = 2;p.stroke() }
            if strategySelection?.targetSlot == unit.slot {NSColor.systemGreen.setStroke();let p = NSBezierPath(rect:box);p.lineWidth = 3;p.stroke()}
            if showsSlotNumbers { text(String(unit.slot),in:CGRect(x:box.minX+1,y:box.maxY-11,width:24,height:11),color:.systemYellow,size:9) }
        }
        if let duel = session.scriptActions.duel,duel.active,let sprites = sprites {
            let duelViewport = OriginalDuelSprites.sourceViewport
            context.saveGState();context.clip(to:duelViewport);context.setFillColor(CGColor(gray:0,alpha:1));context.fill(duelViewport)
            do {
                for side in OriginalDuelSprites.sourceDrawOrder {
                    Renderer.image(try sprites.duelImage(duel,side:side),in:try OriginalDuelSprites.sourceRect(duel:duel,side:side),context:context)
                }
            } catch { message = "원작 일기토 그림 경계: \(error)" }
            context.restoreGState()
        }
        context.restoreGState()
    }
    private func drawList(_ context:CGContext) {
        let facts = layoutFacts.list,rows = listRows
        listTop = min(listTop,listTopLimit)
        let force = rows.first.flatMap { _ in session.units[listSide == 0 ? 0 : 15] }.map { self.force(of:$0) }
        if let force = force,let texts = style.texts,texts.forces.indices.contains(force) {
            let box = layoutFacts.force
            text(texts.forces[force]+texts.forceSuffix,in:CGRect(x:box.column*8,y:box.y-1,width:box.width*8,height:18),color:color(7),alignment:.center)
        }
        for (button,rect) in layoutFacts.sideButtons.enumerated() where style.side.count == 2 {
            Renderer.image(style.side[button][button == listSide ? 1 : 0],in:OriginalBattleLayout.rect(rect),context:context)
        }
        for row in 0..<facts.rows where listTop+row < rows.count {
            guard let unit = session.units[rows[listTop+row]],let person = try? session.people.person(unit.person) else { continue }
            let y = row*facts.rowHeight
            if unit.slot == (inspected ?? selected) {
                context.setStrokeColor(color(7).cgColor);context.setLineWidth(1)
                context.stroke(CGRect(x:facts.hover[0],y:facts.rect[1]+y,width:facts.hover[1],height:facts.rowHeight).insetBy(dx:0.5,dy:0.5))
            }
            let name = color(OriginalBattleRoster.nameColor(unit))
            text(person.name,in:CGRect(x:facts.nameColumn*8,y:facts.textY+y-1,width:(facts.statusColumn-facts.nameColumn)*8,height:18),color:name)
            if unit.status != 2 {
                text(style.texts?.retired ?? "",in:CGRect(x:facts.statusColumn*8,y:facts.textY+y-1,width:88,height:18),color:name)
                continue
            }
            let maximum = (try? OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:session.combat)) ?? 0
            let gauge = OriginalBattleGauge(current:person.rawTroops,maximum:maximum,width:facts.gauge[2])
            let bar = CGRect(x:facts.gauge[0],y:facts.gauge[1]+y,width:facts.gauge[2],height:facts.gauge[3])
            context.setFillColor(CGColor(gray:0,alpha:1));context.fill(bar)
            context.saveGState();context.clip(to:CGRect(x:bar.minX,y:bar.minY,width:CGFloat(gauge.fill),height:bar.height))
            if let tile = style.gauge[gauge.tile] {
                var x = bar.minX
                while x < bar.minX+CGFloat(gauge.fill) { Renderer.image(tile,in:CGRect(x:x,y:bar.minY,width:8,height:10),context:context);x += 8 }
            } else { context.setFillColor(color(gauge.tile == "high" ? 4 : gauge.tile == "middle" ? 14 : 2).cgColor);context.fill(bar) }
            context.restoreGState()
            text(String(format:"%4d/%4d",person.rawTroops,maximum),in:CGRect(x:facts.statusColumn*8,y:facts.textY+y-1,width:80,height:16),color:color(7),size:11,alignment:.right,monospaced:true)
        }
        if listTopLimit > 0 {
            let track = OriginalBattleLayout.rect(facts.track),height = track.height*CGFloat(facts.rows)/CGFloat(rows.count)
            let top = track.minY+(track.height-height)*CGFloat(listTop)/CGFloat(listTopLimit)
            context.setFillColor(color(7).cgColor);context.fill(CGRect(x:track.minX+4,y:top,width:track.width-8,height:height))
        }
    }
    private func drawMinimap(_ context:CGContext) {
        let facts = layoutFacts,scale = facts.minimap.cellPixels
        let origin = facts.minimapOrigin(width:session.width,height:session.height)
        let map = CGRect(x:origin.x,y:origin.y,width:CGFloat(session.width*scale),height:CGFloat(session.height*scale))
        if let picture = style.minimap { Renderer.image(picture,in:map,context:context) }
        else { context.setFillColor(CGColor(gray:0.2,alpha:1));context.fill(map) }
        for unit in session.units.values where unit.status == 2 {
            context.setFillColor(color(OriginalBattleRoster.markColor(unit)).cgColor)
            context.fill(CGRect(x:map.minX+CGFloat(unit.position.x*scale),y:map.minY+CGFloat(unit.position.y*scale),width:CGFloat(scale),height:CGFloat(scale)))
        }
        // MAIN291CC..29278: a two-pixel colour6 box around the visible cells.
        let box = CGRect(x:map.minX+CGFloat(camera.x*scale/2),y:map.minY+CGFloat(camera.y*scale/2),width:CGFloat(facts.columns*scale),height:CGFloat(facts.rows*scale))
        context.setStrokeColor(color(6).cgColor);context.setLineWidth(2);context.stroke(box.insetBy(dx:1,dy:1))
    }
    private func unitDetails(_ slot:Int) -> String? {
        guard let unit = session.units[slot],let person = try? session.people.person(unit.person) else { return nil }
        let maximum = (try? OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:session.combat)) ?? 0
        return "\(person.name) · 병력 \(person.rawTroops)/\(maximum) · Lv \(person.level) EXP \(person.experience) · 사기 \(unit.morale) · MP \(unit.mp)"
    }
    private func drawStatus() {
        let top = 400*scale+2,width = bounds.width-24
        let turn = "\(session.turns.roundIndex+1)/\(session.header.turnLimit) 턴 · 날씨 \(session.turns.weatherIndex)"
        var detail = (inspected ?? selected).flatMap(unitDetails) ?? ""
        if let choice = strategySelection {
            if choice.abilityID >= 30 {detail = "범위 대상 · Enter: 확인 · Esc: 취소"}
            else if let slot = choice.targetSlot,let unit = session.units[slot],let person = try? session.people.person(unit.person) {
                detail = "대상: \(person.name) · 병력 \(person.rawTroops) · 사기 \(unit.morale) · 화살표/Tab: 변경 · Enter: 실행 · Esc: 취소"
            }
        }
        if !session.objectiveEvents.isEmpty && onRetirement == nil { detail = "원작 목표 이벤트 \(session.objectiveEvents.map(\.kind)) 발생 · 캠페인에 적용하지 않은 독립 검증입니다." }
        text(externalStatus ?? message,in:CGRect(x:12,y:top,width:width-150,height:18),color:.lightGray,size:12)
        text(turn,in:CGRect(x:bounds.width-160,y:top,width:148,height:18),color:.white,size:12,alignment:.right)
        text(detail,in:CGRect(x:12,y:top+18,width:width,height:18),color:.white,size:12)
    }
    override func draw(_ dirtyRect:NSRect) {
        updateCamera()
        NSColor.black.setFill();bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x:canvasOrigin.x,y:canvasOrigin.y);context.scaleBy(x:scale,y:scale)
        context.interpolationQuality = .none
        drawFrame(context);drawField(context);drawList(context);drawMinimap(context)
        context.restoreGState()
        drawStatus()
    }
    private func clickPanel(_ point:CGPoint) -> Bool {
        let facts = layoutFacts
        if OriginalBattleLayout.rect(facts.functionButton).contains(point) { openFunctionMenu();return true }
        if let side = facts.sideButtons.firstIndex(where:{ OriginalBattleLayout.rect($0).contains(point) }) { listSide = side;listTop = 0;inspected = nil;return true }
        if OriginalBattleLayout.rect(facts.list.rect).contains(point) {
            let row = Int(point.y-CGFloat(facts.list.rect[1]))/facts.list.rowHeight+listTop,rows = listRows
            if rows.indices.contains(row),let unit = session.units[rows[row]] {
                inspected = unit.slot
                if unit.status == 2 { camera.center(on:unit.position) }
            }
            return true
        }
        let cells = facts.minimap.cellPixels,origin = facts.minimapOrigin(width:session.width,height:session.height)
        let map = CGRect(x:origin.x,y:origin.y,width:CGFloat(session.width*cells),height:CGFloat(session.height*cells))
        if map.contains(point) {
            camera.center(halfX:Int(point.x-map.minX)*2/cells,halfY:Int(point.y-map.minY)*2/cells);return true
        }
        return false
    }
    override func mouseDown(with event:NSEvent) {
        window?.makeFirstResponder(self)
        let p = canvasPoint(event)
        if clickPanel(p) { needsDisplay = true;return }
        guard let point = camera.cell(at:p,in:layoutFacts.viewportRect,size:layoutFacts.cell) else { return }
        inspected = nil
        do {
            guard canInput else { throw BattleError.illegalAction("Continue the current source phase first") }
            let target = session.units.values.first(where:{$0.status == 2 && $0.position == point})
            if var choice = strategySelection,let slot = selected {
                let targets = try legalStrategyTargets(choice.abilityID,casterSlot:slot)
                guard let target = target,targets.contains(target.slot) else {throw BattleError.illegalAction("표시된 책략 대상 중에서 선택하세요.")}
                if choice.abilityID < 30 {choice.targetSlot = target.slot;strategySelection = choice;try executeSelectedStrategy()}
                else {message = "범위 책략은 Enter로 전체 대상 적용을 확인하세요."}
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
            } else if let target = target { inspected = target.slot }
        } catch { message = "\(error)" }
        needsDisplay = true
    }
    override func rightMouseDown(with event:NSEvent) {
        if strategySelection != nil { cancelStrategy();return }
        if let slot = selected,canInput { openUnitMenu(slot);return }
        openFunctionMenu()
    }
    override func scrollWheel(with event:NSEvent) {
        let facts = layoutFacts
        wheelRemainder.x += event.scrollingDeltaX;wheelRemainder.y += event.scrollingDeltaY
        let step:CGFloat = event.hasPreciseScrollingDeltas ? 24 : 1
        let columns = Int(wheelRemainder.x/step),rows = Int(wheelRemainder.y/step)
        guard columns != 0 || rows != 0 else { return }
        wheelRemainder.x -= CGFloat(columns)*step;wheelRemainder.y -= CGFloat(rows)*step
        if OriginalBattleLayout.rect(facts.list.rect).contains(canvasPoint(event)) { listTop = min(listTopLimit,max(0,listTop-rows)) }
        else { camera.move(columns:-columns,rows:-rows) }
        needsDisplay = true
    }
    override func keyDown(with event:NSEvent) {
        if strategySelection == nil,let step = [123:(-1,0),124:(1,0),125:(0,1),126:(0,-1)][Int(event.keyCode)] {
            camera.move(columns:step.0,rows:step.1);needsDisplay = true;return
        }
        guard !event.isARepeat else { return }
        do {
            guard !suspended,inputReady?() ?? true else { return }
            if strategySelection != nil {
                guard canInput else {return}
                if event.keyCode == 53 {cancelStrategy()}
                else if [36,76].contains(event.keyCode) {try executeSelectedStrategy()}
                else if [48,49,124,125].contains(event.keyCode) {try cycleStrategyTarget(event.modifierFlags.contains(.shift) ? -1 : 1)}
                else if [123,126].contains(event.keyCode) {try cycleStrategyTarget(-1)}
                else if event.keyCode == 1 || event.charactersIgnoringModifiers?.lowercased() == "s" {try openStrategyMenu()}
            } else if event.keyCode == 1 || event.charactersIgnoringModifiers?.lowercased() == "s" {try openStrategyMenu()}
            else if event.keyCode == 49,let slot = selected {guard canInput else {return};try flow.manualWait(slot);selected = nil;message = "대기했습니다." }
            else if [36,76].contains(event.keyCode) { try endTurn() }
            else if event.keyCode == 51,let slot = selected {guard canInput else {return};try session.cancelMove(slot);message = "이동을 취소했습니다." }
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
