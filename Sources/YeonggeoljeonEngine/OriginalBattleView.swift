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
    private var waitingForItem = false
    /// Battle system menu texts exported from the caller's MAIN. Without a
    /// campaign host the retreat/quit results have no outer dispatcher.
    var menuTexts:OriginalBattleMenuTexts? { didSet { needsDisplay = true } }
    var suspended:Bool { flow.suspended }
    /// The campaign window plays actions; verification and `--battle` do not.
    var animatesActions = false { didSet { flow.presentsNativeActions = animatesActions } }
    /// A battle effect starts. The id is the source sound number.
    var onSound:((Int)->Void)? { didSet { overlay.onSound = onSound } }
    private var animator = OriginalBattleAnimator()
    var isAnimating:Bool { !animator.isIdle }
    private var afterCues:(()->Void)?
    /// Cues that wait for a scene or a notice before them to end.
    private var heldAfter:[OriginalBattleCue] = []
    var settingsTexts:OriginalSettingsTexts?
    /// The enlarged view, when its local art exists.
    var combatArt:OriginalCombatArt?
    var portraitImage:((Int)->CGImage?)?
    /// Whether a sound effect is still playing, and a way to stop it.
    var soundBusy:(()->Bool)?
    var stopSound:(()->Void)?
    private var combatPlayer:OriginalCombatPlayer?
    private var combatPicture:(index:Int,image:CGImage)?
    var isInCombatView:Bool { combatPlayer != nil }
    var inputReady:(()->Bool)?
    /// Replaces the status line while the owner has something to report.
    var externalStatus:String? { didSet { if externalStatus != oldValue { needsDisplay = true } } }
    /// Replay captures label slots, because input files address units by slot.
    var showsSlotNumbers = false
    /// Chapter and scenario objective text, when a campaign owns this battle.
    var objective:(() -> (chapter:Int,text:String?))?
    /// Live play shows the phase opening; replays drive the flow directly.
    var announcesPhases = false
    private var announcedRound:Int?
    /// A hint or result. It fades after a few seconds unless a step waits on it.
    private var message = "" { didSet { messageTime = Date() } }
    private var messageTime = Date()
    /// Steps of MAIN's unit command routine (2D9D4), one at a time.
    private enum Phase:Equatable { case idle,moving(Int),command(Int),attackTarget(Int),giveTarget(Int,item:Int),itemTarget(Int,item:Int) }
    private var phase = Phase.idle
    /// A unit whose move range stays shown behind its refusal (MAIN30F5A).
    private var previewSlot:Int?
    private(set) var layoutFacts:OriginalBattleLayout
    var presentation = CanvasPresentation.original {
        didSet {
            guard presentation != oldValue else { return }
            layoutFacts = presentation == .modern ? style.layout.modern() : style.layout
            let focus = (selected ?? inspected).flatMap { session.units[$0]?.position }
            camera = OriginalBattleCamera(width:session.width,height:session.height,layout:layoutFacts)
            if let focus = focus { camera.center(on:focus) }
            overlay.viewport = layoutFacts.viewportRect;listTop = 0;needsDisplay = true
        }
    }
    private(set) var camera:OriginalBattleCamera
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
        layoutFacts = style.layout
        camera = OriginalBattleCamera(width:session.width,height:session.height,layout:style.layout)
        super.init(frame:CGRect(x:0,y:0,width:960,height:600))
        autoresizingMask = [.width,.height]
        overlay.frame = bounds;overlay.autoresizingMask = [.width,.height];overlay.viewport = style.layout.viewportRect
        overlay.restoreFocus = { [weak self] in
            guard let self = self else { return }
            self.window?.makeFirstResponder(self);self.needsDisplay = true
        }
        addSubview(overlay)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func start() throws { try flow.start();announcePhase();needsDisplay = true }
    private func play(_ cues:[OriginalBattleCue],then done:@escaping ()->Void) {
        guard animatesActions,!cues.isEmpty else { done();return }
        afterCues = done;perform(cues)
    }
    private func perform(_ cues:[OriginalBattleCue]) {
        animator.effectSounds = sprites?.catalog.effects?.sounds ?? []
        animator.play(cues,options:session.sourceOptionsWord)
        followCue();needsDisplay = true
    }
    private var followsEnemies:Bool { session.sourceOptionsWord&0x1000 != 0 }
    /// With the setting off the camera stays put (MAIN2C4D6). The source still
    /// walks an unseen unit; here a walk with no visible cell is skipped.
    private func visible(_ cue:OriginalBattleCue) -> Bool {
        guard case .walk(let slot,let path,_) = cue,slot >= 15,!followsEnemies else { return true }
        return path.contains { layoutFacts.viewportRect.intersects(camera.rect(of:$0,in:layoutFacts.viewportRect,size:layoutFacts.cell)) }
    }
    /// MAIN2997E keeps the action in view; the source calls it before each one.
    private func followCue() {
        switch animator.cues.first {
        case .walk(let slot,let path,_)?:
            if slot >= 15,!followsEnemies { return }
            if let walker = animator.walker {
                camera.follow(GridPoint(x:Int(walker.x.rounded()),y:Int(walker.y.rounded())),margin:layoutFacts.followMargin)
            } else if let first = path.first { camera.follow(first,margin:layoutFacts.followMargin) }
        case .shot(_,let to,_)?:camera.follow(to,margin:layoutFacts.followMargin)
        case .effect(_,let x,let y)?:camera.follow(GridPoint(x:x/2,y:y/2),margin:layoutFacts.followMargin)
        case .combat?,.notice?,nil:break
        }
    }
    /// The campaign's duel window, and the steps of one opcode as they play.
    var duelStage:OriginalDuelStage? { didSet { if duelStage != oldValue { needsDisplay = true } } }
    private var duelPlayer:OriginalDuelPlayer?
    private var afterDuel:(()->Void)?
    var isPlayingDuel:Bool { duelPlayer != nil }
    func playDuel(_ steps:[OriginalDuelStep],then done:@escaping ()->Void) {
        duelPlayer = OriginalDuelPlayer(steps:steps);afterDuel = done;needsDisplay = true
    }
    func advanceAnimation(_ seconds:Double) {
        if var player = duelPlayer {
            for action in player.advance(seconds,soundBusy:soundBusy?() ?? false) {
                switch action {
                case .sound(let id):onSound?(id)
                case .stopSound:stopSound?()
                }
            }
            duelPlayer = player.finished ? nil : player
            if duelPlayer == nil,let done = afterDuel { afterDuel = nil;done() }
            needsDisplay = true
            return
        }
        if var player = combatPlayer {
            for action in player.advance(seconds,soundBusy:soundBusy?() ?? false) {
                switch action {
                case .sound(let id):onSound?(id)
                case .stopSound:stopSound?()
                }
            }
            combatPlayer = player.finished ? nil : player
            if combatPlayer == nil { stopSound?();combatPicture = nil;updateRosterAfterCombat() }
            needsDisplay = true
            return
        }
        guard !animator.isIdle else { return }
        for id in animator.advance(seconds) { onSound?(id) }
        followCue();needsDisplay = true
        if animator.isIdle,let done = afterCues { afterCues = nil;done() }
    }
    private func updateRosterAfterCombat() { inspected = nil }
    /// True when a scene opened; a terrain outside the source tables has none.
    private func startCombat(_ cues:[OriginalBattleCue]) -> Bool {
        guard case .combat(let snapshot)? = cues.first,let art = combatArt,
              var scene = try? OriginalCombatScene(catalog:art.catalog,snapshot:snapshot),
              let attacker = try? session.people.person(snapshot.attackerPerson).name,
              let target = try? session.people.person(snapshot.targetPerson).name else { return false }
        scene.addResults(attackerName:attacker,targetName:target)
        combatPlayer = OriginalCombatPlayer(scene:scene);combatPicture = nil;needsDisplay = true
        return true
    }
    /// True while the cues own the screen. A scene takes the whole view, so
    /// notices play up to it and whatever follows waits for it to close.
    private func presentHeld(_ cues:[OriginalBattleCue]) -> Bool {
        if case .combat? = cues.first {
            let rest = Array(cues.dropFirst())
            if startCombat(cues) { heldAfter = rest;return true }
            return presentHeld(rest)
        }
        let scene = cues.firstIndex { if case .combat = $0 { return true };return false } ?? cues.count
        heldAfter = Array(cues[scene...])
        guard scene > 0 else { return false }
        perform(Array(cues[..<scene]));return true
    }
    func resumeSourceFlow() throws {
        guard animator.isIdle,combatPlayer == nil else { return }
        let held = heldAfter+flow.takeCues().filter(visible)
        heldAfter = []
        if presentHeld(held) { return }
        try flow.resumeSourceFlow()
        // A counter follows at once, so the map never shows between its scenes.
        if flow.peekCues.first?.isPresentation == true,presentHeld(flow.takeCues()) { return }
        if waitingForStrategy,let result = flow.lastStrategy {showStrategyResult(result);waitingForStrategy = false}
        if waitingForAttack,let result = flow.lastAttack {showAttackResult(result);waitingForAttack = false}
        if waitingForItem,let result = flow.lastItem {waitingForItem = false;finishItem(result)}
        announcePhase();needsDisplay = true
    }
    private var canInput:Bool {animator.isIdle && combatPlayer == nil && flow.acceptsManualInput && (inputReady?() ?? true)}
    private var scale:CGFloat { CanvasGeometry(bounds:bounds).scale }
    private var canvasOrigin:CGPoint { CanvasGeometry(bounds:bounds).origin }
    private func canvasPoint(_ event:NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow,from:nil)
        return CGPoint(x:(p.x-canvasOrigin.x)/scale,y:(p.y-canvasOrigin.y)/scale)
    }
    private func yesNo(_ text:String,_ answer:@escaping (Bool) -> Void) {
        overlay.show(CanvasMenu(title:text,options:[.init(label:"예"),.init(label:"아니요")],horizontal:true) { index in answer(index == 0) })
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
    /// Engine addition: the campaign asks before it ends a phase in which a
    /// unit could still act. The source ends it at once (MAIN27D12).
    var confirmsTurnEnd = false
    private func requestEndTurn() {
        let left = session.turns.stage == .manualFriendly ? readyUnits().count : 0
        guard confirmsTurnEnd,left > 0,canInput else {
            do { try endTurn() } catch { message = "\(error)" }
            return
        }
        yesNo("아직 행동하지 않은 부대가 \(left)개 있습니다. 턴을 끝낼까요?") { [weak self] yes in
            guard let self = self,yes else { return }
            do { try self.endTurn() } catch { self.message = "\(error)" }
            self.needsDisplay = true
        }
    }
    /// Friendly units the player may still command this phase, in slot order.
    private func readyUnits() -> [Int] {
        session.units.values.filter { unit in
            unit.status == 2 && OriginalBattleCommand.denial(unit) == nil && (try? session.requireManualUnit(unit.slot)) != nil
        }.map(\.slot).sorted()
    }
    /// Engine addition: Tab picks the next unit that can still act, as a
    /// click on it would, and brings it into view. Shift goes back.
    private func selectNextUnit(_ step:Int) {
        guard canInput,strategySelection == nil,session.turns.stage == .manualFriendly else { return }
        let current:Int?
        switch phase {
        case .idle:current = selected
        case .moving(let slot):current = slot
        default:return
        }
        let ready = readyUnits()
        guard !ready.isEmpty else { message = "행동할 수 있는 부대가 없습니다.";return }
        let index = current.flatMap { ready.firstIndex(of:$0) }.map { ($0+step+ready.count)%ready.count } ?? (step > 0 ? 0 : ready.count-1)
        guard let unit = session.units[ready[index]] else { return }
        resetCommand();inspected = nil
        camera.center(on:unit.position)
        selected = unit.slot
        if unit.scriptFlags&0x20 == 0 { openCommand(unit.slot) } else { phase = .moving(unit.slot) }
    }
    /// Engine addition: the cells visible enemies could strike this turn.
    var showsThreat = false { didSet { if showsThreat != oldValue { needsDisplay = true } } }
    private var threatCache:(key:[Int],cells:Set<GridPoint>)?
    @objc func toggleThreat(_ sender:Any?) { showsThreat.toggle() }
    private func threatCells() -> Set<GridPoint> {
        let key = session.units.values.filter { $0.status == 2 }.sorted { $0.slot < $1.slot }.flatMap { unit in
            [unit.slot,unit.position.x,unit.position.y,Int(unit.scriptFlags),(try? session.people.person(unit.person).classID) ?? -1]
        }
        if let cache = threatCache,cache.key == key { return cache.cells }
        let cells = (try? session.threatCells()) ?? []
        threatCache = (key,cells)
        return cells
    }
    /// A tinted cell and an edge where the region ends.
    private func drawThreat(_ context:CGContext,rect:(GridPoint) -> CGRect) {
        let cells = threatCells()
        context.setFillColor(CGColor(red:1,green:0.42,blue:0.12,alpha:0.2))
        for point in cells { context.fill(rect(point)) }
        context.setStrokeColor(CGColor(red:1,green:0.55,blue:0.2,alpha:0.85));context.setLineWidth(1.5)
        for point in cells {
            let box = rect(point)
            if !cells.contains(GridPoint(x:point.x,y:point.y-1)) { context.strokeLineSegments(between:[CGPoint(x:box.minX,y:box.minY),CGPoint(x:box.maxX,y:box.minY)]) }
            if !cells.contains(GridPoint(x:point.x,y:point.y+1)) { context.strokeLineSegments(between:[CGPoint(x:box.minX,y:box.maxY),CGPoint(x:box.maxX,y:box.maxY)]) }
            if !cells.contains(GridPoint(x:point.x-1,y:point.y)) { context.strokeLineSegments(between:[CGPoint(x:box.minX,y:box.minY),CGPoint(x:box.minX,y:box.maxY)]) }
            if !cells.contains(GridPoint(x:point.x+1,y:point.y)) { context.strokeLineSegments(between:[CGPoint(x:box.maxX,y:box.minY),CGPoint(x:box.maxX,y:box.maxY)]) }
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
        message = ""
        announcePhase()
    }
    /// MAIN27876..27A3A. The opening view states the turn limit; the menu
    /// view states the current turn too.
    private func showConditions(opening:Bool,then done:@escaping () -> Void = { }) {
        guard let texts = style.commands?.conditions,let state = objective?() else { done();return }
        let facts = layoutFacts.conditions
        let chapter = texts.chapterLabels.indices.contains(state.chapter) ? texts.chapterLabels[state.chapter] : ""
        let turns = opening ? OriginalBattleConditions.numbered(texts.turnLimit,[session.header.turnLimit]) :
            OriginalBattleConditions.numbered(texts.currentTurn,[session.turns.roundIndex+1,session.header.turnLimit])
        overlay.show(CanvasBrief(layout:facts,title:OriginalBattleConditions.title(texts.titleFormat,chapter:chapter,name:session.definition.name ?? session.definition.id),
            heading:texts.heading,lines:OriginalBattleConditions.lines(state.text ?? "",width:facts.lineWidth,count:(facts.lineEnd-facts.textY)/facts.lineStep),
            turns:turns,button:style.ok,onDismiss:done))
    }
    /// MAIN27AC6..27AE8: the first friendly phase opens with the conditions,
    /// and every friendly phase with the side notice.
    func announcePhase() {
        guard announcesPhases,session.turns.stage == .manualFriendly,canInput,!overlay.active,
              announcedRound != session.turns.roundIndex else { return }
        announcedRound = session.turns.roundIndex
        let notice:() -> Void = { [weak self] in
            guard let self = self else { return }
            // MAIN28139 names the turn and its weather before the side's line.
            let round = self.session.turns.roundIndex+1,weather = self.session.turns.weatherIndex
            self.play([.notice(.turn(round:round,weather:Int(weather)))]) { [weak self] in
                guard let text = self?.style.commands?.conditions.playerPhase else { return }
                self?.say(text)
            }
        }
        if session.turns.roundIndex == 0 { showConditions(opening:true,then:notice) } else { notice() }
    }
    /// The 기능 button opens MAIN27D12's list. Items without a restored
    /// handler stay visible and disabled.
    private func openFunctionMenu() {
        guard canInput,phase == .idle,strategySelection == nil else { return }
        var restored:Set<String> = menuTexts == nil ? ["end-turn"] : ["end-turn","retreat","quit"]
        if settingsTexts != nil { restored.formUnion(["unit-combat","move-speed","enemy-move","bgm","sound"]) }
        if objective != nil,style.commands != nil { restored.insert("conditions") }
        let items = menuTexts?.items ?? [OriginalTitleMenuItem(index:0,action:"end-turn",text:"End turn")]
        functionOpen = true;needsDisplay = true
        overlay.show(CanvasMenu(title:"",options:items.map { .init(label:$0.text,enabled:restored.contains($0.action)) },cancellable:true) { [weak self] index in
            guard let self = self else { return }
            self.functionOpen = false;self.needsDisplay = true
            guard let index = index else { return }
            switch items[index].action {
            case "end-turn": self.requestEndTurn()
            case "unit-combat","move-speed","enemy-move","bgm","sound": self.openSetting(items[index].action)
            case "retreat": self.requestRetreat()
            case "conditions": self.showConditions(opening:false)
            case "quit": self.requestQuit()
            default: break
            }
        })
    }
    /// MAIN27DC4..27E7B and 27774. A pick takes effect at once.
    private func openSetting(_ action:String) {
        guard let texts = settingsTexts else { return }
        var settings = OriginalSettings.current
        let labels:[String],current:Int,apply:(Int) -> Void
        switch action {
        case "unit-combat":labels = texts.show;current = settings.unitCombat;apply = { settings.unitCombat = $0 }
        case "move-speed":labels = texts.moveSpeed;current = settings.moveSpeed;apply = { settings.moveSpeed = $0 }
        case "enemy-move":labels = texts.show;current = settings.enemyMove ? 0 : 1;apply = { settings.enemyMove = $0 == 0 }
        case "bgm":labels = texts.onOff;current = OriginalAudio.musicEnabled ? 0 : 1;apply = { OriginalAudio.musicEnabled = $0 == 0 }
        default:labels = texts.onOff;current = OriginalAudio.effectsEnabled ? 0 : 1;apply = { OriginalAudio.effectsEnabled = $0 == 0 }
        }
        overlay.show(CanvasMenu(title:"",options:labels.enumerated().map { .init(label:$0.element,checked:$0.offset == current) },selected:current,cancellable:true) { [weak self] index in
            guard let self = self,let index = index else { return }
            apply(index);OriginalSettings.current = settings
            self.session.sourceOptionsWord = settings.battleWord;self.needsDisplay = true
        })
    }
    private func refusal(_ key:String) -> String { style.commands?.messages[key] ?? key }
    private func filled(_ key:String,_ value:String) -> String { refusal(key).replacingOccurrences(of:"%s",with:value) }
    private func resetCommand() { phase = .idle;selected = nil;strategySelection = nil;previewSlot = nil }
    /// A nested window sits one step on from its parent (MAIN2AACA..2AB3C).
    private func windowOrigin(_ slot:Int,depth:Int) -> CGPoint? {
        guard let unit = session.units[slot] else { return nil }
        if presentation == .modern {
            let origin = besideCell(unit.position,width:112)
            return CGPoint(x:origin.x+CGFloat(depth)*12,y:origin.y+CGFloat(depth)*12)
        }
        let window = OriginalBattleCommand.window(cell:unit.position,camera:camera,layout:layoutFacts)
        return CGPoint(x:window.origin.x+window.step.x*CGFloat(depth),y:window.origin.y+window.step.y*CGFloat(depth))
    }
    /// The modern layout opens a window right next to its cell, on the side with room.
    private func besideCell(_ cell:GridPoint,width:CGFloat) -> CGPoint {
        let box = camera.rect(of:cell,in:layoutFacts.viewportRect,size:layoutFacts.cell)
        return CGPoint(x:box.maxX+6+width <= layoutFacts.viewportRect.maxX ? box.maxX+6 : box.minX-6-width,y:box.minY)
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
            say(refusal("noEnemyInRange")) { [weak self] in self?.openCommand(slot) }
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
            say(refusal("noStrategy")) { [weak self] in self?.openCommand(slot) }
            return
        }
        let options = rows.map { CanvasMenu.Option(label:strategyTitle($0.ability),enabled:$0.enabled,value:"\($0.cost)") }
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
            say(refusal("noItems")) { [weak self] in self?.openCommand(slot) }
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
    private func itemText(_ key:String) -> String { style.commands?.itemMessages[key] ?? key }
    /// The source format strings take their %s arguments in order.
    private func filled(item key:String,_ values:String...) -> String {
        values.reduce(itemText(key)) { text,value in
            guard let range = text.range(of:"%s") else { return text }
            return text.replacingCharacters(in:range,with:value)
        }
    }
    /// MAIN3C5E mode0 waits a fixed time unless input arrives.
    private func say(_ text:String,then done:@escaping () -> Void = { }) {
        overlay.show(CanvasNotice(speaker:"",text:text,portrait:nil,timeout:OriginalBattleAnimator.noticeSeconds,onDismiss:done))
    }
    private func kindLabel(_ kind:Int) -> String { style.commands?.kindLabels[kind] ?? String(kind) }
    private func className(_ id:Int) -> String { style.commands?.classNames[id] ?? String(id) }
    /// MAIN2E0E6: each group asks or announces before its picker or effect.
    private func beginItemUse(_ slot:Int,item:Int) throws {
        let again:() -> Void = { [weak self] in self?.openItemList(slot,action:0) }
        let pick:() -> Void = { [weak self] in self?.beginItemTarget(slot,item:item) }
        let use = OriginalItemUse.of(item)
        switch use {
        case .unusable: say(itemText("unusable"),then:again)
        case .classChange(let target):
            try confirmClassChange(slot,item:item,use:use,prompt:"classPrompt",target:target)
        case .promotion(let required,_):
            try confirmClassChange(slot,item:item,use:use,prompt:"promotePrompt",target:required+1)
        case .attack(let family,_):
            if family == 0 && session.combat.strategyEnvironmentLookup[Int(session.turns.weatherIndex)] == 2 { say(itemText("rainFire"),then:again);return }
            say(filled(item:"attackWith",style.commands?.familyLabels[family] ?? String(family)),then:pick)
        case .confuse: say(itemText("confuseEnemy"),then:pick)
        case .recovery(let kind,_): say(filled(item:"recoverKind",kindLabel(kind)),then:pick)
        case .areaRecovery(let kind,_):
            yesNo(filled(item:"areaPrompt",kindLabel(kind))) { [weak self] yes in
                guard let self = self else { return }
                if yes { self.performItem(slot,item:item,target:nil) } else { again() }
            }
        case .bomb: say(itemText("bombAttack"),then:pick)
        }
    }
    private func confirmClassChange(_ slot:Int,item:Int,use:OriginalItemUse,prompt:String,target:Int) throws {
        if let refusal = try OriginalItemOperation.classRefusal(in:session,userSlot:slot,use:use) {
            say(itemText(refusal)) { [weak self] in self?.openItemList(slot,action:0) };return
        }
        yesNo(filled(item:prompt,className(target))) { [weak self] yes in
            guard let self = self else { return }
            if yes { self.performItem(slot,item:item,target:nil) } else { self.openItemList(slot,action:0) }
        }
    }
    private func itemCells(_ slot:Int,_ use:OriginalItemUse) throws -> Set<GridPoint> {
        guard let raw = use.rangeCode else { return [] }
        let value = try actor(slot)
        var cells = Set(try OriginalAI.rangeCells(profile:session.movement,board:value.board,point:value.actor.position,raw:raw))
        if use.targetsFriends { cells.insert(value.actor.position) }
        return cells
    }
    /// MAIN29B68: with no enemy in range the picker refuses and returns.
    private func beginItemTarget(_ slot:Int,item:Int) {
        do {
            let use = OriginalItemUse.of(item)
            guard try !OriginalItemOperation.targetSlots(in:session,userSlot:slot,use:use).isEmpty else {
                say(refusal(use.targetsFriends ? "noAllyInRange" : "noEnemyInRange")) { [weak self] in self?.openItemList(slot,action:0) }
                return
            }
            phase = .itemTarget(slot,item:item)
            message = "\(itemName(item))의 대상을 클릭하세요. 오른쪽 클릭·Esc: 취소";needsDisplay = true
        } catch { message = "\(error)";openItemList(slot,action:0) }
    }
    private func pickItemTarget(_ slot:Int,item:Int,point:GridPoint,target:OriginalLiveUnit?) throws {
        let use = OriginalItemUse.of(item)
        guard try itemCells(slot,use).contains(point) else { say(refusal(use.targetsFriends ? "outOfItemRange" : "outOfAttackRange"));return }
        guard let target = target else { return }
        if use.targetsFriends,target.enemy { say(refusal("enemyUnit"));return }
        if !use.targetsFriends,!target.enemy { say(refusal("cannotAttackAlly"));return }
        // The source refuses after the pick and before any consumption.
        if let rejection = try OriginalItemOperation.begin(in:session,userSlot:slot,item:item,target:target.slot).execution?.rejection {
            say(rejectionText(rejection,use)) { [weak self] in self?.openItemList(slot,action:0) };return
        }
        let name = try session.people.person(target.person).name
        let proceed:() -> Void = { [weak self] in self?.performItem(slot,item:item,target:target.slot) }
        switch use {
        case .attack: say(filled(item:"usedItem",itemName(item)),then:proceed)
        case .recovery(let kind,_): say(filled(item:"recoveryLine",name,kindLabel(kind),itemText("raised")),then:proceed)
        case .bomb: say(itemText("bombThrow"),then:proceed)
        default: proceed()
        }
    }
    private func rejectionText(_ key:String,_ use:OriginalItemUse) -> String {
        if key == "terrain",case .attack(let family,_) = use { return style.commands?.terrainRefusals[family] ?? key }
        return itemText(key)
    }
    /// MAIN2E3B1, 2E436 and 2E68D: effect nine for a thrown item, four otherwise.
    private func itemCues(item:Int,target:Int?) -> [OriginalBattleCue] {
        guard let target = target,let cell = session.units[target]?.position else { return [] }
        switch OriginalItemUse.of(item) {
        case .attack,.bomb:return [.effect(9,halfX:cell.x*2,halfY:cell.y*2)]
        case .recovery,.areaRecovery:return [.effect(4,halfX:cell.x*2,halfY:cell.y*2)]
        default:return []
        }
    }
    private func performItem(_ slot:Int,item:Int,target:Int?) {
        play(itemCues(item:item,target:target)) { [weak self] in self?.commitItem(slot,item:item,target:target) }
    }
    private func commitItem(_ slot:Int,item:Int,target:Int?) {
        do {
            if let result = try flow.manualItem(slot,item:item,target:target) { finishItem(result) }
            else { waitingForItem = true;resetCommand();message = "도구의 퇴장 대사·이벤트가 끝나기를 기다립니다." }
        } catch { message = "\(error)";openItemList(slot,action:0) }
        needsDisplay = true
    }
    /// MAIN2E807: a completed use ends the action; a refusal returns to the list.
    private func finishItem(_ result:OriginalItemExecution) {
        guard result.completed else {
            let use = OriginalItemUse.of(result.item)
            say(rejectionText(result.rejection ?? "unusable",use)) { [weak self] in self?.openItemList(result.userSlot,action:0) }
            return
        }
        if case .classChange = OriginalItemUse.of(result.item) { onSound?(8) }  // MAIN2E7B5
        resetCommand()
        let user = session.units[result.userSlot].flatMap { try? session.people.person($0.person).name } ?? ""
        let name:(OriginalStrategyTargetEffect) -> String = { [session] in (try? session.people.person($0.person).name) ?? "" }
        var lines:[String] = []
        let use = OriginalItemUse.of(result.item)
        switch use {
        case .classChange(let target): lines.append(filled(item:"classDone",user,className(target)))
        case .promotion(let required,_): lines.append(filled(item:"promoteDone",user,className(required+1)))
        case .confuse: lines = result.targets.map { filled(item:"becameConfused",name($0)) }
        case .areaRecovery(let kind,_): lines.append(filled(item:"areaDone",itemText("friendlySide"),kindLabel(kind)))
        default: break
        }
        let troops = result.targets.compactMap { $0.damage?.damage ?? $0.quantity }.reduce(0,+)
        message = troops > 0 ? "\(itemName(result.item)): 피해 \(troops)" : "\(itemName(result.item))을(를) 사용했습니다."
        if !lines.isEmpty { say(lines.joined(separator:"\n")) }
    }
    private func runItemAction(_ action:Int,item:Int,_ slot:Int) throws {
        let again:() -> Void = { [weak self] in self?.openItemList(slot,action:action) }
        switch action {
        case 0: try beginItemUse(slot,item:item)
        case 1:
            phase = .giveTarget(slot,item:item);message = "\(itemName(item))을(를) 건넬 아군을 클릭하세요. 오른쪽 클릭·Esc: 취소"
        case 2:
            guard let unit = session.units[slot] else { return }
            try session.people.discardItem(person:unit.person,item:item)
            say(filled("discarded",itemName(item)),then:again)
        default:
            overlay.show(CanvasNotice(speaker:itemName(item),text:itemRecord(item)?.description ?? "",portrait:nil,onDismiss:again))
        }
    }
    /// MAIN2E911..2ED02: the line a player's caster reads before choosing.
    private func strategyIntent(_ ability:Int) -> String? {
        guard let texts = combatArt?.catalog.texts,let labels = style.commands else { return nil }
        switch ability {
        case 0...14:return originalFormat(texts.attackIntent,[labels.familyLabels[ability/5]])
        case 15...17:return texts.confuseIntent
        case 18...20:return texts.moraleIntent
        case 21...29:return originalFormat(texts.healIntent,[kindLabel(ability >= 0x1B ? 3 : ability >= 0x18 ? 1 : 2)])
        default:return nil
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
            if let line = strategyIntent(ability) { message = line } else { message = ability < 30 ? "\(strategyTitle(ability)): 표시된 대상을 클릭하거나 화살표·Tab으로 선택한 뒤 Enter를 누르세요." : "\(strategyTitle(ability)): 표시된 \(targets.count)개 부대에 적용합니다. Enter로 확인하세요." }
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
        let cues = try flow.beginManualStrategy(slot,abilityID:selection.abilityID,target:selection.targetSlot)
        strategySelection = nil
        play(cues) { [weak self] in
            guard let self = self else { return }
            do {
                if let result = try self.flow.finishManualOperation().strategy {
                    self.showStrategyResult(result)
                    // MAIN2DDCD returns to the command window unless the unit acted.
                    if result.completed {self.resetCommand()} else {self.openCommand(slot)}
                }
                else {self.waitingForStrategy = true;self.resetCommand();self.message = "책략의 퇴장 대사·이벤트가 끝나기를 기다립니다."}
            } catch { self.message = "\(error)";self.resetCommand() }
            self.needsDisplay = true
        }
    }
    private func showStrategyResult(_ result:OriginalStrategyExecution) {
        if let experience = result.completionExperience,let person = session.units[result.casterSlot]?.person,
           let notices = try? session.levelNotices(person:person,experience:experience),!notices.isEmpty {
            perform(notices.map { .notice($0) })
        }
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
    private func label(_ value:String,in rect:CGRect,font:NSFont,color:NSColor = CanvasTheme.text,alignment:NSTextAlignment = .left) {
        (value as NSString).draw(in:rect,withAttributes:CanvasTheme.attributes(font,color,alignment:alignment))
    }
    /// The modern screen: a slim bar above the map and a plain sidebar.
    private func drawModernFrame(_ context:CGContext) {
        let facts = layoutFacts,map = facts.viewportRect,button = OriginalBattleLayout.rect(facts.functionButton)
        context.setFillColor(CanvasTheme.background);context.fill(CGRect(x:0,y:0,width:640,height:400))
        context.setFillColor(CGColor(gray:0,alpha:1));context.fill(map)
        if functionOpen { context.setFillColor(CanvasTheme.selection);context.fill(button) }
        label("기능",in:CGRect(x:button.minX,y:button.minY+1.5,width:button.width,height:14),font:CanvasTheme.font(10,.semibold),color:CanvasTheme.accent,alignment:.center)
        label(session.definition.name ?? session.definition.id,in:CGRect(x:button.maxX,y:1.5,width:map.width-button.width*2,height:14),font:CanvasTheme.font(10,.medium),alignment:.center)
        label("\(session.turns.roundIndex+1)/\(session.header.turnLimit) 턴 · 날씨 \(weatherName)",
              in:CGRect(x:map.maxX-120,y:1.5,width:114,height:14),font:CanvasTheme.font(10),color:CanvasTheme.muted,alignment:.right)
        CanvasTheme.divider(from:CGPoint(x:map.maxX+0.5,y:0),to:CGPoint(x:map.maxX+0.5,y:400),in:context)
    }
    /// The force, the two list tabs, the units and the small map, top to bottom.
    private func drawSidebar(_ context:CGContext) {
        let facts = layoutFacts.list,rows = listRows,map = layoutFacts.viewportRect
        listTop = min(listTop,listTopLimit)
        let column = CGRect(x:map.maxX+8,y:0,width:640-map.maxX-16,height:400)
        if let unit = session.units[listSide == 0 ? 0 : 15],let texts = style.texts,texts.forces.indices.contains(force(of:unit)) {
            label(texts.forces[force(of:unit)]+texts.forceSuffix,in:CGRect(x:column.minX,y:9,width:column.width,height:18),font:CanvasTheme.font(13,.semibold),color:CanvasTheme.accent,alignment:.center)
        }
        for (side,value) in layoutFacts.sideButtons.enumerated() {
            let rect = OriginalBattleLayout.rect(value).insetBy(dx:1,dy:0)
            CanvasTheme.fill(rect,side == listSide ? CanvasTheme.selection : CanvasTheme.inset,in:context)
            label(side == 0 ? "아군" : "적군",in:CGRect(x:rect.minX,y:rect.minY+3,width:rect.width,height:15),font:CanvasTheme.font(11,.medium),
                  color:side == listSide ? CanvasTheme.text : CanvasTheme.muted,alignment:.center)
        }
        for row in 0..<facts.rows where listTop+row < rows.count {
            guard let unit = session.units[rows[listTop+row]],let person = try? session.people.person(unit.person) else { continue }
            let box = CGRect(x:facts.rect[0],y:facts.rect[1]+row*facts.rowHeight,width:facts.hover[1],height:facts.rowHeight-1)
            if unit.slot == (inspected ?? selected) { CanvasTheme.fill(box,CanvasTheme.selection,in:context) }
            let name = color(OriginalBattleRoster.nameColor(unit))
            label(person.name,in:CGRect(x:box.minX+6,y:box.minY+0.5,width:78,height:15),font:CanvasTheme.font(11,.medium),color:unit.status == 2 ? name : CanvasTheme.disabled)
            if unit.status != 2 {
                label(style.texts?.retired ?? "",in:CGRect(x:box.minX+60,y:box.minY+1,width:box.width-66,height:14),font:CanvasTheme.font(9.5),color:CanvasTheme.disabled,alignment:.right)
                continue
            }
            let maximum = (try? OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:session.combat)) ?? 0
            label("\(person.rawTroops)/\(maximum)",in:CGRect(x:box.minX+60,y:box.minY+1.5,width:box.width-66,height:13),font:CanvasTheme.number(9.5),color:CanvasTheme.muted,alignment:.right)
            let bar = CGRect(x:box.minX+6,y:box.minY+15,width:box.width-12,height:2.5)
            CanvasTheme.fill(bar,CanvasTheme.hairline,radius:1.25,in:context)
            let gauge = OriginalBattleGauge(current:person.rawTroops,maximum:maximum,width:Int(bar.width))
            let tint = gauge.tile == "high" ? CGColor(red:0.40,green:0.80,blue:0.55,alpha:1) : gauge.tile == "middle" ? CanvasTheme.accentFill : CanvasTheme.danger.cgColor
            CanvasTheme.fill(CGRect(x:bar.minX,y:bar.minY,width:CGFloat(gauge.fill),height:bar.height),tint,radius:1.25,in:context)
        }
        if listTopLimit > 0 {
            let track = OriginalBattleLayout.rect(facts.track),height = track.height*CGFloat(facts.rows)/CGFloat(rows.count)
            CanvasTheme.fill(CGRect(x:track.minX,y:track.minY+(track.height-height)*CGFloat(listTop)/CGFloat(listTopLimit),width:track.width,height:height),CanvasTheme.hairline,radius:1.5,in:context)
        }
    }
    private func drawFrame(_ context:CGContext) {
        if presentation == .modern { drawModernFrame(context);return }
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
        if showsThreat { drawThreat(context,rect:rect) }
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
        if case .itemTarget(let slot,let item) = phase {
            let use = OriginalItemUse.of(item)
            if let cells = try? itemCells(slot,use) {
                for point in cells {
                    (use.targetsFriends ? NSColor(calibratedRed:0.1,green:1,blue:0.7,alpha:0.3) : NSColor(calibratedRed:1,green:0.25,blue:0.2,alpha:0.3)).setFill()
                    rect(point).fill()
                }
            }
        }
        let strategyTargets = strategySelection.flatMap { choice in selected.flatMap {try? legalStrategyTargets(choice.abilityID,casterSlot:$0)} } ?? []
        for slot in strategyTargets {
            guard let unit = session.units[slot] else {continue}
            NSColor(calibratedRed:0.1,green:1,blue:0.7,alpha:0.3).setFill();rect(unit.position).fill()
        }
        // MAIN2A143..2A15B: an enemy with mask 0x20 clear is hidden from the map.
        for unit in session.units.values.sorted(by:{$0.slot < $1.slot}) where unit.status == 2 && !(unit.enemy && unit.scriptFlags&0x20 == 0) {
            guard let person = try? session.people.person(unit.person) else { continue }
            var box = rect(unit.position)
            let walker = animator.walker.flatMap { $0.slot == unit.slot ? $0 : nil }
            if let walker = walker { box = rect(GridPoint(x:0,y:0)).offsetBy(dx:CGFloat(walker.x)*CGFloat(cell),dy:CGFloat(walker.y)*CGFloat(cell)) }
            if let sprites = sprites {
                do {
                    let image = try walker.map { try sprites.image(unit:unit,classID:person.classID,direction:$0.direction,stepPixels:$0.stepPixels) }
                        ?? sprites.image(unit:unit,classID:person.classID)
                    Renderer.image(image,in:box,context:context)
                }
                catch { message = "원작 그림 경계: \(error)";text("?",in:box,color:.systemYellow) }
            } else {
                (unit.enemy ? NSColor.systemRed : NSColor.systemBlue).setFill();NSBezierPath(ovalIn:box.insetBy(dx:3,dy:3)).fill()
            }
            if selected == unit.slot { NSColor.systemYellow.setStroke();let p = NSBezierPath(rect:box.insetBy(dx:1,dy:1));p.lineWidth = 2;p.stroke() }
            if strategySelection?.targetSlot == unit.slot {NSColor.systemGreen.setStroke();let p = NSBezierPath(rect:box);p.lineWidth = 3;p.stroke()}
            if showsSlotNumbers { text(String(unit.slot),in:CGRect(x:box.minX+1,y:box.maxY-11,width:24,height:11),color:.systemYellow,size:9) }
        }
        if let sprites = sprites {
            let origin = rect(GridPoint(x:0,y:0))
            if let effect = animator.effect,let image = try? sprites.effectImage(effect.frame) {
                Renderer.image(image,in:origin.offsetBy(dx:CGFloat(effect.halfX*cell)/2,dy:CGFloat(effect.halfY*cell)/2),context:context)
            }
            if let shot = animator.shot,let image = try? sprites.shotImage(shot.frame) {
                let quarter = CGFloat(cell)/4
                let box = CGRect(x:origin.minX+CGFloat(shot.x)*CGFloat(cell)+quarter,y:origin.minY+CGFloat(shot.y)*CGFloat(cell)+quarter,width:quarter*2,height:quarter*2)
                Renderer.image(image,in:box,context:context)
            }
        }
        if let duel = session.scriptActions.duel,duel.active,let stage = duelStage,let picture = duelPlayer?.picture ?? Optional(stage.shown) {
            drawDuel(context,stage:stage,picture:picture)
        } else if let duel = session.scriptActions.duel,duel.active,let sprites = sprites {
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
        if presentation == .modern { drawSidebar(context);return }
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
        // MAIN2BA39: only units with mask 0x20 mark the minimap.
        for unit in session.units.values where unit.status == 2 && unit.scriptFlags&0x20 != 0 {
            context.setFillColor(color(OriginalBattleRoster.markColor(unit)).cgColor)
            context.fill(CGRect(x:map.minX+CGFloat(unit.position.x*scale),y:map.minY+CGFloat(unit.position.y*scale),width:CGFloat(scale),height:CGFloat(scale)))
        }
        // MAIN291CC..29278: a two-pixel colour6 box around the visible cells.
        let box = CGRect(x:map.minX+CGFloat(camera.x*scale/2),y:map.minY+CGFloat(camera.y*scale/2),width:CGFloat(facts.columns*scale),height:CGFloat(facts.rows*scale))
        context.setStrokeColor(presentation == .modern ? CanvasTheme.accentFill : color(6).cgColor);context.setLineWidth(2);context.stroke(box.insetBy(dx:1,dy:1))
    }
    private func unitDetails(_ slot:Int) -> String? {
        guard let unit = session.units[slot],let person = try? session.people.person(unit.person) else { return nil }
        let maximum = (try? OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:session.combat)) ?? 0
        return "\(person.name) · 병력 \(person.rawTroops)/\(maximum) · Lv \(person.level) EXP \(person.experience) · 사기 \(unit.morale) · MP \(unit.mp)"
    }
    /// Turn, the selected unit and any hint float over the map window.
    private func drawStatus(_ context:CGContext) {
        // The duel window covers the whole map view and has its own panels.
        if duelStage != nil,session.scriptActions.duel?.active == true { return }
        let map = layoutFacts.viewportRect,width = map.width-32
        if presentation == .original {
            CanvasTheme.chip("\(session.turns.roundIndex+1)/\(session.header.turnLimit) 턴 · 날씨 \(weatherName)",
                             at:CGPoint(x:map.minX+8,y:map.minY+18),centered:false,maximumWidth:width,in:context)
        }
        var detail = (inspected ?? selected ?? hovered).flatMap(unitDetails) ?? ""
        if let choice = strategySelection {
            if choice.abilityID >= 30 {detail = "범위 대상 · Enter: 확인 · Esc: 취소"}
            else if let slot = choice.targetSlot,let unit = session.units[slot],let person = try? session.people.person(unit.person) {
                detail = "대상: \(person.name) · 병력 \(person.rawTroops) · 사기 \(unit.morale) · 화살표/Tab: 변경 · Enter: 실행 · Esc: 취소"
            }
        }
        if !session.objectiveEvents.isEmpty && onRetirement == nil { detail = "원작 목표 이벤트 \(session.objectiveEvents.map(\.kind)) 발생 · 캠페인에 적용하지 않음" }
        var y = map.maxY-18
        if !detail.isEmpty,!overlay.active {
            CanvasTheme.chip(detail,at:CGPoint(x:map.midX,y:y),maximumWidth:width,in:context);y -= 30
        }
        let waits = phase != .idle || strategySelection != nil
        let note = externalStatus ?? (waits || Date().timeIntervalSince(messageTime) < 4 ? message : "")
        if !note.isEmpty { CanvasTheme.chip(note,at:CGPoint(x:map.midX,y:y),maximumWidth:width,in:context) }
    }
    override func draw(_ dirtyRect:NSRect) {
        updateCamera()
        NSColor.black.setFill();bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x:canvasOrigin.x,y:canvasOrigin.y);context.scaleBy(x:scale,y:scale)
        context.interpolationQuality = .none
        drawFrame(context);drawField(context);drawList(context);drawMinimap(context);drawStatus(context)
        if combatPlayer == nil { drawForecasts(context) }
        if combatPlayer != nil { drawCombat(context) }
        let area = layoutFacts.viewportRect
        var corner = area.minY+16
        if fastForward {
            CanvasTheme.chip("빨리 감기 ×\(OriginalBattleView.fastRate)",at:CGPoint(x:area.maxX-56,y:corner),maximumWidth:120,in:context);corner += 24
        }
        if showsThreat,combatPlayer == nil {
            CanvasTheme.chip("적 공격 범위",at:CGPoint(x:area.maxX-50,y:corner),maximumWidth:120,color:NSColor(red:1,green:0.62,blue:0.3,alpha:1),in:context)
        }
        if let notice = animator.notice,let catalog = combatArt?.catalog {
            let area = layoutFacts.viewportRect,text = catalog.text(notice,person:personName,strategy:strategyTitle,kind:kindLabel)
            CanvasTheme.chip(text,at:CGPoint(x:area.midX,y:area.midY),maximumWidth:area.width-32,in:context)
        }
        context.restoreGState()
    }
    private var weatherName:String {
        let names = combatArt?.catalog.weathers ?? [],index = Int(session.turns.weatherIndex)
        return names.indices.contains(index) ? names[index] : String(index)
    }
    /// Held Control runs the campaign this many times as fast.
    static let fastRate = 4
    var fastForward = false { didSet { if fastForward != oldValue { needsDisplay = true } } }
    /// Fast-forward closes lines and timed notices as a click would.
    func skipLines() {
        if overlay.notice != nil { overlay.skipNotice() }
        if animator.notice != nil { animator.dismissNotice() }
    }
    /// Each enemy in reach shows the damage it would take and its counter
    /// chance. An engine addition over the source's red cells.
    private func drawForecasts(_ context:CGContext) {
        guard case .attackTarget(let slot) = phase,let cells = try? attackCells(slot) else { return }
        let facts = layoutFacts,viewport = facts.viewportRect
        context.saveGState();context.clip(to:viewport)
        for unit in session.units.values where unit.status == 2 && unit.enemy && cells.contains(unit.position) && unit.scriptFlags&0x20 != 0 {
            guard let value = try? session.attackForecast(slot,target:unit.slot) else { continue }
            let cell = camera.rect(of:unit.position,in:viewport,size:facts.cell)
            var text = value.defeats ? "-\(value.damage) 격파" : "-\(value.damage)"
            if value.counterPercent > 0 { text += " · 반격 \(value.counterPercent)%" }
            CanvasTheme.chip(text,at:CGPoint(x:cell.midX,y:cell.minY-6),maximumWidth:180,
                             color:value.defeats ? CanvasTheme.accent : CanvasTheme.text,in:context)
        }
        context.restoreGState()
    }
    private func personName(_ id:Int) -> String { (try? session.people.person(id).name) ?? "" }
    /// 2CB4:125E's window: the scene at (16,32,416,208) over the combat view's
    /// background, participant 1 drawn first, and two panels set at setup.
    private func drawDuel(_ context:CGContext,stage:OriginalDuelStage,picture:OriginalDuelPicture) {
        let scene = OriginalDuelSprites.sourceViewport
        context.setFillColor(presentation == .modern ? CanvasTheme.background : CGColor(gray:0,alpha:1));context.fill(layoutFacts.viewportRect)
        context.saveGState();context.clip(to:scene)
        if let image = combatArt?.backdrop(terrain:stage.terrain,scroll:picture.camera) { Renderer.image(image,in:scene,context:context) }
        else { context.setFillColor(CGColor(gray:0,alpha:1));context.fill(scene) }
        if let sprites = sprites {
            for side in OriginalDuelSprites.sourceDrawOrder {
                guard let pose = picture.poses[side] else { continue }
                do {
                    let image = try sprites.duelImage(person:stage.people[side],loadMode:pose.mode,frame:pose.frame)
                    Renderer.image(image,in:CGRect(x:16+pose.x*16,y:32+3*16,width:96,height:96),context:context)
                } catch { message = "원작 일기토 그림 경계: \(error)" }
            }
        }
        context.restoreGState()
        if let art = combatArt { for (side,panel) in stage.panels.enumerated() { drawDuelPanel(context,side:side,panel:panel,art:art) } }
    }
    /// 1CB6:F752 with sides 2 and 3: level and class, strength, troops and experience.
    private func drawDuelPanel(_ context:CGContext,side:Int,panel:OriginalDuelPanel,art:OriginalCombatArt) {
        CanvasTheme.panel(CGRect(x:side == 0 ? 16 : 224,y:240,width:208,height:144),in:context)
        let portraitX = side == 0 ? 24 : 360
        if let image = portraitImage?(panel.person) { Renderer.image(image,in:CGRect(x:portraitX,y:248,width:64,height:80),context:context) }
        let plain = CanvasTheme.attributes(CanvasTheme.font(12),CanvasTheme.text),faint = CanvasTheme.attributes(CanvasTheme.font(12),CanvasTheme.muted)
        let name = personName(panel.person),width = (name as NSString).size(withAttributes:plain).width
        (name as NSString).draw(at:CGPoint(x:CGFloat(portraitX)+32-width/2,y:346),withAttributes:plain)
        let textX = side == 0 ? 104 : 240,gaugeX = textX+40,texts = art.catalog.texts
        let className = art.catalog.classNames.indices.contains(panel.classID) ? art.catalog.classNames[panel.classID] : ""
        (originalFormat(texts.level,[String(panel.level),className]) as NSString).draw(at:CGPoint(x:CGFloat(textX),y:254),withAttributes:plain)
        for (row,value) in [(texts.strength,panel.strength,100),(texts.troops,panel.troops,panel.maxTroops),(texts.duelExperience,panel.experience,100)].enumerated() {
            let y = 278+row*24
            (value.0 as NSString).draw(at:CGPoint(x:CGFloat(textX),y:CGFloat(y)),withAttributes:faint)
            drawCombatGauge(context,x:gaugeX,y:y+6,width:64,value:value.1,maximum:value.2,text:"\(value.1)")
        }
    }
    /// MAIN2A556 and F752: the scene at (16,32,416,208) and two stat windows.
    private func drawCombat(_ context:CGContext) {
        guard let player = combatPlayer,let art = combatArt else { return }
        context.setFillColor(CanvasTheme.background);context.fill(layoutFacts.viewportRect)
        if let shown = player.picture {
            if combatPicture?.index != shownIndex(player),let image = art.picture(shown,scene:player.scene) {
                combatPicture = (shownIndex(player),image)
            }
            if let image = combatPicture?.image { Renderer.image(image,in:CGRect(x:16,y:32,width:416,height:208),context:context) }
        }
        let s = player.scene.snapshot,texts = art.catalog.texts,friendly = s.attackerSlot < 15
        drawCombatPanel(context,side:0,art:art,person:friendly ? s.attackerPerson : s.targetPerson,classID:friendly ? s.attackerClass : s.targetClass,
            level:friendly ? s.attackerLevel : s.targetLevel,value:friendly ? s.attackValue : s.defenseValue,valueLabel:friendly ? texts.attack : texts.defense,
            troops:friendly ? s.attackerTroops : s.targetTroops,maximum:friendly ? s.attackerMaxTroops : s.targetMaxTroops,
            morale:friendly ? s.attackerMorale : s.targetMorale,last:friendly ? (texts.exp,s.experience,100) : (texts.terrain,nil,s.terrainPercent))
        drawCombatPanel(context,side:1,art:art,person:friendly ? s.targetPerson : s.attackerPerson,classID:friendly ? s.targetClass : s.attackerClass,
            level:friendly ? s.targetLevel : s.attackerLevel,value:friendly ? s.defenseValue : s.attackValue,valueLabel:friendly ? texts.defense : texts.attack,
            troops:friendly ? s.targetTroops : s.attackerTroops,maximum:friendly ? s.targetMaxTroops : s.attackerMaxTroops,
            morale:friendly ? s.targetMorale : s.attackerMorale,last:friendly ? (texts.terrain,nil,s.terrainPercent) : nil)
        guard let frame = player.frame else { return }
        if let notice = frame.notice {
            CanvasTheme.chip(notice,at:CGPoint(x:224,y:152),maximumWidth:320,in:context)
        }
        guard let page = frame.page else { return }
        let window = CGRect(x:48,y:112,width:352,height:96)
        CanvasTheme.panel(window,in:context)
        let style = CanvasTheme.attributes(CanvasTheme.font(14,.medium),CanvasTheme.text)
        for line in page.lines { (line.text as NSString).draw(at:CGPoint(x:104,y:CGFloat(line.y)-2),withAttributes:style) }
        for gauge in page.gauges { drawCombatGauge(context,x:144,y:gauge.y,width:160,value:gauge.value,maximum:gauge.maximum,text:"\(gauge.value)") }
    }
    private func shownIndex(_ player:OriginalCombatPlayer) -> Int {
        guard let shown = player.picture else { return -1 }
        return shown.layers.hashValue^shown.scroll
    }
    /// MAIN28806: the bar turns at seven and three tenths of the maximum.
    private func drawCombatGauge(_ context:CGContext,x:Int,y:Int,width:Int,value:Int,maximum:Int,text:String) {
        let box = CGRect(x:x,y:y-1,width:width,height:10)
        context.setFillColor(CGColor(gray:0,alpha:0.85));context.fill(box)
        if maximum > 0 {
            let share = value*10/maximum
            context.setFillColor(share >= 7 ? CGColor(red:0.46,green:0.76,blue:0.54,alpha:1) : share >= 3 ? CanvasTheme.accentFill : CGColor(red:0.9,green:0.42,blue:0.36,alpha:1))
            context.fill(CGRect(x:x,y:y-1,width:min(value*width/maximum,width),height:10))
        }
        (text as NSString).draw(at:CGPoint(x:CGFloat(x)+CGFloat(width)/2-12,y:CGFloat(y)-4),
            withAttributes:CanvasTheme.attributes(CanvasTheme.number(11,.semibold),CanvasTheme.text))
    }
    private func drawCombatPanel(_ context:CGContext,side:Int,art:OriginalCombatArt,person:Int,classID:Int,level:Int,value:Int,valueLabel:String,
                                 troops:Int,maximum:Int,morale:Int,last:(label:String,value:Int?,maximum:Int)?) {
        let window = CGRect(x:side == 0 ? 16 : 224,y:240,width:208,height:144)
        CanvasTheme.panel(window,in:context)
        let portraitX = side == 0 ? 24 : 360
        if let image = portraitImage?(person) { Renderer.image(image,in:CGRect(x:portraitX,y:248,width:64,height:80),context:context) }
        let name = (try? session.people.person(person).name) ?? ""
        let plain = CanvasTheme.attributes(CanvasTheme.font(12),CanvasTheme.text),faint = CanvasTheme.attributes(CanvasTheme.font(12),CanvasTheme.muted)
        let width = (name as NSString).size(withAttributes:plain).width
        (name as NSString).draw(at:CGPoint(x:CGFloat(portraitX)+32-width/2,y:346),withAttributes:plain)
        let textX = side == 0 ? 104 : 240,gaugeX = textX+40,texts = art.catalog.texts
        let className = art.catalog.classNames.indices.contains(classID) ? art.catalog.classNames[classID] : ""
        (originalFormat(texts.level,[String(level),className]) as NSString).draw(at:CGPoint(x:CGFloat(textX),y:254),withAttributes:plain)
        (valueLabel as NSString).draw(at:CGPoint(x:CGFloat(textX),y:278),withAttributes:faint)
        drawCombatGauge(context,x:gaugeX,y:284,width:64,value:value,maximum:2000,text:"\(value)")
        (texts.troops as NSString).draw(at:CGPoint(x:CGFloat(textX),y:302),withAttributes:faint)
        drawCombatGauge(context,x:gaugeX,y:308,width:64,value:troops,maximum:maximum,text:"\(troops)")
        (texts.morale as NSString).draw(at:CGPoint(x:CGFloat(textX),y:326),withAttributes:faint)
        drawCombatGauge(context,x:gaugeX,y:332,width:64,value:morale,maximum:100,text:"\(morale)")
        guard let last = last else { return }
        (last.label as NSString).draw(at:CGPoint(x:CGFloat(textX),y:350),withAttributes:faint)
        if let shown = last.value { drawCombatGauge(context,x:gaugeX,y:356,width:64,value:shown,maximum:last.maximum,text:"\(shown)") }
        else { (originalFormat(texts.percent,[String(last.maximum)]) as NSString).draw(at:CGPoint(x:CGFloat(gaugeX),y:350),withAttributes:plain) }
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
        if combatPlayer != nil { combatPlayer?.skip();return }
        if animator.notice != nil { animator.dismissNotice();return }
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
    /// MAIN27C7A: a click with no unit under it shows that cell's terrain.
    private func showTerrain(_ point:GridPoint) {
        guard let texts = style.commands?.terrain else { return }
        let id = Int(session.terrain[point.y*session.width+point.x]),facts = layoutFacts.terrain,cell = layoutFacts.cell
        let tile = background?.cropping(to:CGRect(x:point.x*cell,y:point.y*cell,width:cell,height:cell))
        let map = layoutFacts.viewportRect
        var origin = OriginalBattleTerrain.windowOrigin(cell:point,camera:camera)
        if presentation == .modern {
            origin = besideCell(point,width:CGFloat(facts.size[0]))
            origin.y = min(origin.y,map.maxY-CGFloat(facts.size[1])-6)
        }
        overlay.show(CanvasTerrain(layout:facts,origin:origin,tile:tile,
            name:texts.names.indices.contains(id) ? texts.names[id] : String(id),heading:texts.defense,
            percent:OriginalBattleTerrain.defenseText(session.combat.terrainDefensePercent[id],none:texts.none,percent:texts.percent),
            recovery:OriginalBattleTerrain.recovers(terrain:id) ? texts.recovery : nil) { })
    }
    /// One map click in the current step of the unit command routine.
    private func clickField(_ point:GridPoint,_ target:OriginalLiveUnit?) throws {
        switch phase {
        case .idle:
            // MAIN27BB2..27BC7: a hidden enemy counts as an empty cell.
            guard let unit = target,!(unit.enemy && unit.scriptFlags&0x20 == 0) else { showTerrain(point);return }
            if let denial = OriginalBattleCommand.denial(unit) {
                previewSlot = unit.slot;inspected = unit.slot
                say(refusal(denial)) { [weak self] in self?.previewSlot = nil;self?.needsDisplay = true }
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
                say(refusal("outOfMoveRange"))
                return
            }
            let path = try session.move(slot,to:point)
            play([.walk(slot:slot,path:path,sound:try session.walkSound(slot))]) { [weak self] in
                self?.onSound?(42);self?.openCommand(slot)       // MAIN2D565
            }
        case .attackTarget(let slot):
            guard try attackCells(slot).contains(point) else {
                say(refusal("outOfAttackRange"));return
            }
            guard let target = target else { return }
            guard target.enemy else {
                say(refusal("cannotAttackAlly"));return
            }
            let cues = try flow.beginManualAttack(slot,target:target.slot)
            resetCommand()
            play(cues) { [weak self] in
                guard let self = self else { return }
                do {
                    if let result = try self.flow.finishManualOperation().attack { self.showAttackResult(result) }
                    else {self.waitingForAttack = true;self.message = "공격의 퇴장 대사·이벤트가 끝나기를 기다립니다."}
                } catch { self.message = "\(error)" }
                self.needsDisplay = true
            }
        case .giveTarget(let slot,let item):
            guard let unit = session.units[slot] else { return }
            guard try giveCells(slot).contains(point) || point == unit.position else {
                say(refusal("outOfItemRange"));return
            }
            guard let target = target else { return }
            if target.enemy { say(refusal("enemyUnit"));return }
            if target.slot == slot { openItemList(slot,action:1);return }
            if try flow.manualGive(slot,to:target.slot,item:item) {
                resetCommand()
                say(filled("gave",itemName(item)))
            } else {
                say(refusal("inventoryFull")) { [weak self] in self?.openItemList(slot,action:1) }
            }
        case .itemTarget(let slot,let item): try pickItemTarget(slot,item:item,point:point,target:target)
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
        case .itemTarget(let slot,_): openItemList(slot,action:0)
        case .idle: openFunctionMenu()
        case .command: break
        }
        needsDisplay = true
    }
    /// Engine addition: the unit under the pointer fills the status line.
    private var hovered:Int?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow],owner:self))
    }
    override func mouseMoved(with event:NSEvent) {
        let cell = camera.cell(at:canvasPoint(event),in:layoutFacts.viewportRect,size:layoutFacts.cell)
        // A hidden enemy stays hidden here too (MAIN2A143).
        let unit = cell.flatMap { point in
            session.units.values.first { $0.status == 2 && $0.position == point && !($0.enemy && $0.scriptFlags&0x20 == 0) }
        }
        if unit?.slot != hovered { hovered = unit?.slot;needsDisplay = true }
    }
    override func mouseExited(with event:NSEvent) { if hovered != nil { hovered = nil;needsDisplay = true } }
    /// The source has no such shortcut; a scene has no effect on results.
    override func rightMouseDown(with event:NSEvent) {
        if combatPlayer != nil { combatPlayer?.finish();return }
        stepBack()
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
        if combatPlayer != nil {
            if event.keyCode == 53 { combatPlayer?.finish() } else { combatPlayer?.skip() }
            return
        }
        if animator.notice != nil { animator.dismissNotice();return }
        if strategySelection == nil,let step = [123:(-1,0),124:(1,0),125:(0,1),126:(0,-1)][Int(event.keyCode)] {
            camera.move(columns:step.0,rows:step.1);needsDisplay = true;return
        }
        guard !event.isARepeat else { return }
        if event.keyCode == 2,event.modifierFlags.intersection([.command,.control,.option]).isEmpty { showsThreat.toggle();return }
        do {
            guard !suspended,inputReady?() ?? true else { return }
            if strategySelection == nil,event.keyCode == 48 {
                selectNextUnit(event.modifierFlags.contains(.shift) ? -1 : 1)
            } else if strategySelection != nil {
                guard canInput else {return}
                if event.keyCode == 53 {cancelStrategy()}
                else if [36,76].contains(event.keyCode) {try executeSelectedStrategy()}
                else if [48,49,124,125].contains(event.keyCode) {try cycleStrategyTarget(event.modifierFlags.contains(.shift) ? -1 : 1)}
                else if [123,126].contains(event.keyCode) {try cycleStrategyTarget(-1)}
            } else if event.keyCode == 53 || event.keyCode == 51 {
                if phase != .idle || event.keyCode == 53 { stepBack() }
            } else if [36,76].contains(event.keyCode) {
                if phase == .idle { requestEndTurn() }
            } else { super.keyDown(with:event) }
        } catch { message = "\(error)" }
        needsDisplay = true
    }
    /// The menu shows whether the threat view is on, however it was turned on.
    @objc func validateMenuItem(_ item:NSMenuItem) -> Bool {
        if item.action == #selector(toggleThreat(_:)) { item.state = showsThreat ? .on : .off }
        return true
    }
    func capture(to url:URL) throws {
        guard let rep = bitmapImageRepForCachingDisplay(in:bounds) else { throw EngineError.invalid("Cannot allocate original battle capture") }
        cacheDisplay(in:bounds,to:rep)
        guard let png = rep.representation(using:.png,properties:[:]) else { throw EngineError.invalid("Cannot encode original battle capture") }
        try png.write(to:url,options:.atomic)
    }
}
