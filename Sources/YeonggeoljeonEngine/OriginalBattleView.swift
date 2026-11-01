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
    private var message = "클릭: 부대 선택·이동 / 오른쪽 클릭·Esc: 취소, 기능 메뉴 / Return: 턴 종료 / 방향키·휠: 지도 이동"
    /// Steps of MAIN's unit command routine (2D9D4), one at a time.
    private enum Phase:Equatable { case idle,moving(Int),command(Int),attackTarget(Int),giveTarget(Int,item:Int) }
    private var phase = Phase.idle
    /// A unit whose move range stays shown behind its refusal (MAIN30F5A).
    private var previewSlot:Int?
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
            if let slot = selected { try session.cancelMove(slot) }
            resetCommand()
            try flow.finishManual()
        }
        else if !suspended { try flow.start() }
        message = "복원된 원작 순서로 턴을 진행했습니다."
    }
    /// The 기능 button opens MAIN27D12's list. Items without a restored
    /// handler stay visible and disabled.
    private func openFunctionMenu() {
        guard canInput,phase == .idle,strategySelection == nil else { return }
        let restored:Set<String> = menuTexts == nil ? ["end-turn"] : ["end-turn","retreat","quit"]
        let items = menuTexts?.items ?? [OriginalTitleMenuItem(index:0,action:"end-turn",text:"End turn")]
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
    private func refusal(_ key:String) -> String { style.commands?.messages[key] ?? key }
    private func filled(_ key:String,_ value:String) -> String { refusal(key).replacingOccurrences(of:"%s",with:value) }
    private func resetCommand() { phase = .idle;selected = nil;strategySelection = nil;previewSlot = nil }
    /// A nested window sits one step on from its parent (MAIN2AACA..2AB3C).
    private func windowOrigin(_ slot:Int,depth:Int) -> CGPoint? {
        guard let unit = session.units[slot] else { return nil }
        let window = OriginalBattleCommand.window(cell:unit.position,camera:camera,layout:layoutFacts)
        return CGPoint(x:window.origin.x+window.step.x*CGFloat(depth),y:window.origin.y+window.step.y*CGFloat(depth))
    }
    /// MAIN2DAE0: a hidden unit (mask20 clear) gets the two ambush entries.
    private func commandMenu(_ slot:Int,_ choose:@escaping (Int?) -> Void) -> CanvasMenu? {
        guard let unit = session.units[slot] else { return nil }
        let labels = unit.scriptFlags&0x20 != 0 ? (style.commands?.labels ?? ["Attack","Strategy","Item","Wait"]) : (style.commands?.ambush ?? ["Strike","Release"])
        return CanvasMenu(title:"",options:labels.map { .init(label:$0) },cancellable:true,anchor:windowOrigin(slot,depth:0),onChoose:choose)
    }
    private func openCommand(_ slot:Int) {
        updateCamera()
        guard let unit = session.units[slot],unit.status == 2 else { resetCommand();return }
        selected = slot;phase = .command(slot);inspected = nil;strategySelection = nil
        let hidden = unit.scriptFlags&0x20 == 0
        guard let menu = commandMenu(slot,{ [weak self] index in
            guard let self = self else { return }
            guard let index = index else { self.cancelCommand(slot);return }
            do { if hidden { try self.runAmbushCommand(index,slot) } else { try self.runCommand(index,slot) } }
            catch { self.message = "\(error)";self.openCommand(slot) }
            self.needsDisplay = true
        }) else { return }
        overlay.show(menu)
    }
    /// MAIN2DE08..2DE1D clears moved40 and returns the unit to its origin.
    private func cancelCommand(_ slot:Int) {
        do { try session.cancelMove(slot) } catch { message = "\(error)" }
        resetCommand();needsDisplay = true
    }
    private func runCommand(_ index:Int,_ slot:Int) throws {
        switch index {
        case 0: try beginAttack(slot)
        case 1: try openStrategies(slot)
        case 2: openItems(slot)
        default:
            guard canInput else { return }
            try flow.manualWait(slot);resetCommand();message = "대기했습니다."
        }
    }
    private func runAmbushCommand(_ index:Int,_ slot:Int) throws {
        if index == 0 { try beginAttack(slot);return }
        yesNo(refusal("releaseAmbush")) { [weak self] yes in
            guard let self = self else { return }
            if yes {
                do { try self.flow.manualReleaseAmbush(slot) } catch { self.message = "\(error)" }
            }
            self.openCommand(slot)
        }
    }
    private func actor(_ slot:Int) throws -> (board:OriginalMovementBoard,actor:OriginalMovementActor) {
        let board = try session.board()
        guard let actor = board.actors.first(where:{$0.runtimeSlot == slot}) else { throw BattleError.invalid("Original unit is missing from its source board") }
        return (board,actor)
    }
    private func attackCells(_ slot:Int) throws -> Set<GridPoint> {
        let value = try actor(slot)
        return Set(try OriginalAI.attackCells(profile:session.movement,board:value.board,actor:value.actor))
    }
    /// MAIN2DF5E gives within range code one around the unit.
    private func giveCells(_ slot:Int) throws -> Set<GridPoint> {
        let value = try actor(slot)
        return Set(try OriginalAI.rangeCells(profile:session.movement,board:value.board,point:value.actor.position,raw:1))
    }
    /// MAIN29B68: with nobody in range the picker refuses and returns.
    private func beginAttack(_ slot:Int) throws {
        let cells = try attackCells(slot)
        guard session.units.values.contains(where:{ $0.status == 2 && $0.enemy && cells.contains($0.position) }) else {
            overlay.show(CanvasNotice(speaker:"",text:refusal("noEnemyInRange"),portrait:nil) { [weak self] in self?.openCommand(slot) })
            return
        }
        phase = .attackTarget(slot);message = "공격할 적을 클릭하세요. 오른쪽 클릭·Esc: 취소"
    }
    private func openStrategies(_ slot:Int) throws {
        guard let unit = session.units[slot],let levels = session.movement.strategyLevelRequirements,let costs = session.movement.strategyMPCosts else {
            throw BattleError.unsupported("Original strategy tables are unavailable")
        }
        let person = try session.people.person(unit.person)
        let rain = session.combat.strategyEnvironmentLookup[Int(session.turns.weatherIndex)] == 2
        let rows = OriginalBattleCommand.strategyRows(classID:person.classID,level:person.level,mp:unit.mp,rain:rain,levels:levels,costs:costs)
        guard !rows.isEmpty else {
            overlay.show(CanvasNotice(speaker:"",text:refusal("noStrategy"),portrait:nil) { [weak self] in self?.openCommand(slot) })
            return
        }
        let options = rows.map { CanvasMenu.Option(label:"\(strategyTitle($0.ability))  \($0.cost)",enabled:$0.enabled) }
        overlay.show(CanvasMenu(title:"",options:options,cancellable:true,anchor:windowOrigin(slot,depth:1)) { [weak self] index in
            guard let self = self else { return }
            guard let index = index else { self.openCommand(slot);return }
            self.selectStrategy(rows[index].ability,slot);self.needsDisplay = true
        },behind:[commandMenu(slot) { _ in }].compactMap { $0 })
    }
    private func heldItems(_ slot:Int) -> [Int] {
        guard let unit = session.units[slot],let person = try? session.people.person(unit.person) else { return [] }
        return person.itemIDs.filter { $0 != 255 }
    }
    private func itemRecord(_ id:Int) -> OriginalItemEffect? { session.combat.items.first(where:{ $0.id == id }) }
    private func itemName(_ id:Int) -> String { itemRecord(id)?.name ?? "도구 #\(id)" }
    private var itemActionLabels:[String] { style.commands?.itemActions ?? ["Use","Give","Drop","Inspect"] }
    private func itemActionMenu(_ slot:Int,_ choose:@escaping (Int?) -> Void) -> CanvasMenu {
        CanvasMenu(title:"",options:itemActionLabels.map { .init(label:$0) },cancellable:true,anchor:windowOrigin(slot,depth:1),onChoose:choose)
    }
    /// MAIN2DE42..2DEF7: the item command needs at least one held item.
    private func openItems(_ slot:Int) {
        guard !heldItems(slot).isEmpty else {
            overlay.show(CanvasNotice(speaker:"",text:refusal("noItems"),portrait:nil) { [weak self] in self?.openCommand(slot) })
            return
        }
        overlay.show(itemActionMenu(slot) { [weak self] action in
            guard let self = self else { return }
            guard let action = action else { self.openCommand(slot);return }
            self.openItemList(slot,action:action)
        },behind:[commandMenu(slot) { _ in }].compactMap { $0 })
    }
    private func openItemList(_ slot:Int,action:Int) {
        let items = heldItems(slot)
        guard !items.isEmpty else { openItems(slot);return }
        overlay.show(CanvasMenu(title:"",options:items.map { .init(label:itemName($0)) },cancellable:true,anchor:windowOrigin(slot,depth:2)) { [weak self] index in
            guard let self = self else { return }
            guard let index = index else { self.openItems(slot);return }
            do { try self.runItemAction(action,item:items[index],slot) } catch { self.message = "\(error)";self.openItemList(slot,action:action) }
            self.needsDisplay = true
        },behind:[commandMenu(slot) { _ in },itemActionMenu(slot) { _ in }].compactMap { $0 })
    }
    private func runItemAction(_ action:Int,item:Int,_ slot:Int) throws {
        let again:() -> Void = { [weak self] in self?.openItemList(slot,action:action) }
        switch action {
        case 0:
            // MAIN2E0E6..2E833 owns the item effects, which are not restored.
            // The item stays held and the unit keeps its action.
            overlay.show(CanvasNotice(speaker:"",text:"\(itemName(item))의 사용 효과는 아직 복원하지 않았습니다.",portrait:nil,onDismiss:again))
        case 1:
            phase = .giveTarget(slot,item:item);message = "\(itemName(item))을(를) 건넬 아군을 클릭하세요. 오른쪽 클릭·Esc: 취소"
        case 2:
            guard let unit = session.units[slot] else { return }
            try session.people.discardItem(person:unit.person,item:item)
            overlay.show(CanvasNotice(speaker:"",text:filled("discarded",itemName(item)),portrait:nil,onDismiss:again))
        default:
            overlay.show(CanvasNotice(speaker:itemName(item),text:itemRecord(item)?.description ?? "",portrait:nil,onDismiss:again))
        }
    }
    private func strategyTitle(_ id:Int)->String {strategyName?(id) ?? style.commands?.strategyNames[id] ?? "책략 #\(id)"}
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
    private func selectStrategy(_ ability:Int,_ slot:Int) {
        do {
            guard canInput else {return}
            _ = try session.requireManualUnit(slot)
            let targets = try legalStrategyTargets(ability,casterSlot:slot)
            guard !targets.isEmpty else {throw BattleError.illegalAction("현재 선택할 수 있는 대상이 없습니다.")}
            selected = slot
            strategySelection = StrategySelection(abilityID:ability,targetSlot:ability < 30 ? targets.first : nil)
            message = ability < 30 ? "\(strategyTitle(ability)): 표시된 대상을 클릭하거나 화살표·Tab으로 선택한 뒤 Enter를 누르세요." : "\(strategyTitle(ability)): 표시된 \(targets.count)개 부대에 적용합니다. Enter로 확인하세요."
        } catch {message = "\(error)";openCommand(slot)}
    }
    private func cancelStrategy() {
        guard canInput else {return}
        strategySelection = nil;message = "책략 선택을 취소했습니다. 이동 위치는 유지됩니다."
        if case .command(let slot) = phase { openCommand(slot) }
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
        if let result {
            showStrategyResult(result)
            // MAIN2DDCD returns to the command window unless the unit acted.
            if result.completed {resetCommand()} else {openCommand(slot)}
        }
        else {waitingForStrategy = true;resetCommand();message = "책략의 퇴장 대사·이벤트가 끝나기를 기다립니다."}
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
        var rangeSlot = previewSlot
        if case .moving(let slot) = phase { rangeSlot = slot }
        if let slot = rangeSlot,let cells = try? session.reachable(slot) {
            for point in Set(cells) { NSColor(calibratedRed:0.2,green:0.6,blue:1,alpha:0.25).setFill();rect(point).fill() }
        }
        if case .attackTarget(let slot) = phase,let cells = try? attackCells(slot) {
            for point in cells { NSColor(calibratedRed:1,green:0.25,blue:0.2,alpha:0.3).setFill();rect(point).fill() }
        }
        if case .giveTarget(let slot,_) = phase,let cells = try? giveCells(slot) {
            for point in cells { NSColor(calibratedRed:0.1,green:1,blue:0.7,alpha:0.3).setFill();rect(point).fill() }
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
            } else { try clickField(point,target) }
        } catch { message = "\(error)" }
        needsDisplay = true
    }
    /// One map click in the current step of the unit command routine.
    private func clickField(_ point:GridPoint,_ target:OriginalLiveUnit?) throws {
        switch phase {
        case .idle:
            guard let unit = target else { return }
            if let denial = OriginalBattleCommand.denial(unit) {
                previewSlot = unit.slot;inspected = unit.slot
                overlay.show(CanvasNotice(speaker:"",text:refusal(denial),portrait:nil) { [weak self] in self?.previewSlot = nil;self?.needsDisplay = true })
                return
            }
            _ = try session.requireManualUnit(unit.slot)
            selected = unit.slot
            // MAIN2D9F3: a hidden unit keeps its cell and goes straight to commands.
            if unit.scriptFlags&0x20 == 0 { openCommand(unit.slot) } else { phase = .moving(unit.slot) }
        case .moving(let slot):
            guard let unit = session.units[slot] else { return }
            if point == unit.position { openCommand(slot);return }
            guard try session.reachable(slot).contains(point) else {
                overlay.show(CanvasNotice(speaker:"",text:refusal("outOfMoveRange"),portrait:nil) { })
                return
            }
            _ = try session.move(slot,to:point)
            openCommand(slot)
        case .attackTarget(let slot):
            guard try attackCells(slot).contains(point) else {
                overlay.show(CanvasNotice(speaker:"",text:refusal("outOfAttackRange"),portrait:nil) { });return
            }
            guard let target = target else { return }
            guard target.enemy else {
                overlay.show(CanvasNotice(speaker:"",text:refusal("cannotAttackAlly"),portrait:nil) { });return
            }
            if let result = try flow.manualAttack(slot,target:target.slot) { showAttackResult(result) }
            else {waitingForAttack = true;message = "공격의 퇴장 대사·이벤트가 끝나기를 기다립니다."}
            resetCommand()
        case .giveTarget(let slot,let item):
            guard let unit = session.units[slot] else { return }
            guard try giveCells(slot).contains(point) || point == unit.position else {
                overlay.show(CanvasNotice(speaker:"",text:refusal("outOfItemRange"),portrait:nil) { });return
            }
            guard let target = target else { return }
            if target.enemy { overlay.show(CanvasNotice(speaker:"",text:refusal("enemyUnit"),portrait:nil) { });return }
            if target.slot == slot { openItemList(slot,action:1);return }
            if try flow.manualGive(slot,to:target.slot,item:item) {
                resetCommand()
                overlay.show(CanvasNotice(speaker:"",text:filled("gave",itemName(item)),portrait:nil) { })
            } else {
                overlay.show(CanvasNotice(speaker:"",text:refusal("inventoryFull"),portrait:nil) { [weak self] in self?.openItemList(slot,action:1) })
            }
        case .command: break
        }
    }
    /// Right click and Escape step back one level of the routine.
    private func stepBack() {
        if strategySelection != nil { cancelStrategy();return }
        switch phase {
        case .moving: resetCommand()
        case .attackTarget(let slot): openCommand(slot)
        case .giveTarget(let slot,_): openItemList(slot,action:1)
        case .idle: openFunctionMenu()
        case .command: break
        }
        needsDisplay = true
    }
    override func rightMouseDown(with event:NSEvent) { stepBack() }
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
            } else if event.keyCode == 53 || event.keyCode == 51 {
                if phase != .idle || event.keyCode == 53 { stepBack() }
            } else if [36,76].contains(event.keyCode) {
                if phase == .idle { try endTurn() }
            } else { super.keyDown(with:event) }
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
