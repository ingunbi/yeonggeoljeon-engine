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
    var animatesActions = false { didSet { flow.presentsNativeActions = animatesActions;flow.emitsCombatPresentationCues = animatesActions } }
    var foregroundFavorites:(()->Set<Int>)?
    private var hasPresentedCombat = false
    private var enemyTurnBefore:EnemyTurnSnapshot?
    private var lastEnemyTurnChanges:[EnemyTurnSnapshot.Change] = []
    private var hasEnemyTurnSummary = false
    /// A battle effect starts. The id is the source sound number.
    var onSound:((Int)->Void)? { didSet { overlay.onSound = onSound } }
    /// Auto, skip and log controls on battle lines; the campaign owns them.
    var onLineControl:((CanvasOverlayView.LineControl)->Void)? { didSet { overlay.onLineControl = onLineControl } }
    var onSuspend:(()->Void)?
    /// Opens the campaign's shared native/original save selector.
    var onLoad:(()->Void)?
    /// Engine-only inventory protection. Scripted source consumption bypasses this UI hook.
    var onItemUseRefusal:((Int,Int)->String?)?
    var onItemDiscardRefusal:((Int,Int)->String?)?
    var onItemTransfer:((Int,Int,Int)->Void)?
    var favoriteCommands:((Int)->[BattleFavoriteAction])?
    var favoriteCommandsSourceIssue:(()->String?)?
    var onResetFavoriteSource:(()->Void)?
    var onFavoriteCommandsChanged:((Int,[BattleFavoriteAction])throws->Void)?
    var onManageInventory:(()->Void)?
    var onEventHints:(()->Void)?
    var onMapViewPreferenceChanged:((BattleMapViewMode)->Void)?
    var onControlSettings:(()->Void)?
    var allowsAutomaticGuidance:(()->Bool)?
    private var lastRefusal:String?
    var onAcceptedInput:((OriginalPlayInput)->Void)?
    var onRecordingBoundary:(()->Void)?
    private var acceptedInputRevision = 0
    private var boundaryRevision:Int?
    var annotations:(()->BattleAnnotations?)?
    var onAnnotationsChanged:((BattleAnnotations)throws->Void)?
    private var showsAnnotations = true
    private var annotationDraft:(kind:BattleAnnotations.Kind,start:GridPoint?)?
    private var annotationCursor:GridPoint?
    private var annotationEditing:BattleAnnotations.Entry?
    private var assistedArea:(key:BattleProjection.Key,slot:Int,point:GridPoint,targets:[Int])?
    /// A campaign save prompt temporarily owns input without replacing a battle line.
    func setOverlaySuspended(_ value:Bool) { overlay.setSuspended(value) }
    /// The player's turn waits for a command, with no line or menu open.
    var awaitsCommand:Bool { canInput && !overlay.active && animator.notice == nil && duelPlayer == nil }
    /// A battle window waits for an answer or a look (menus, the conditions).
    var asksPlayer:Bool { overlay.active && overlay.notice == nil }
    var controlContext:AppControlPreferences.Context {
        if overlay.notice != nil || overlay.brief != nil {return .dialogue}
        return overlay.active ? .list : .battle
    }
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
    var objectiveProgress:(()->[BattleObjectiveTracker.Condition])?
    private var showsObjectiveTracker = true
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
    private var mapViewMode = AppControlRuntime.current.battleMapMode
    private var previousTacticalMode = AppControlRuntime.current.battleMapMode
    private var renderedTextScale = CanvasTheme.textScale
    var presentation = CanvasPresentation.original {
        didSet {
            guard presentation != oldValue else { return }
            layoutFacts = presentation == .modern ? BattleMapViewport.layout(source:style.layout,width:session.width,height:session.height,mode:mapViewMode,textScale:CanvasTheme.textScale) : style.layout
            let chosen:GridPoint? = (selected ?? inspected ?? speakingSlot).flatMap { session.units[$0]?.position }
            let leader:GridPoint? = session.units[0]?.status == 2 ? session.units[0]?.position : nil
            let first:GridPoint? = session.units.values.filter({ !$0.enemy && $0.status == 2 }).min(by:{ $0.slot < $1.slot })?.position
            let focus = chosen ?? leader ?? first
            camera = OriginalBattleCamera(width:session.width,height:session.height,layout:layoutFacts)
            if let focus = focus { camera.center(on:focus) }
            overlay.viewport = layoutFacts.viewportRect;listTop = 0;needsDisplay = true
        }
    }
    private(set) var camera:OriginalBattleCamera
    private var listSide = 0
    private var listTop = 0
    private var rosterOptions = BattleRosterOptions.current
    /// The unit whose details the status line shows.
    private var inspected:Int?
    private var functionOpen = false
    private var learningGuideOpen = false
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
        // MAIN2726E..27296 centres the initial camera on slot 0 before drawing.
        if let leader = (session.units[0]?.status == 2 ? session.units[0] : nil) ?? session.units.values.filter({ !$0.enemy && $0.status == 2 }).min(by:{ $0.slot < $1.slot }) {
            camera.center(on:leader.position)
        }
        super.init(frame:CGRect(x:0,y:0,width:960,height:600))
        flow.onAcceptedInput = { [weak self] input in self?.acceptedInput(input) }
        flow.onEnemyTurnStart = { [weak self] in guard let self else {return};self.enemyTurnBefore = EnemyTurnSnapshot(self.session) }
        autoresizingMask = [.width,.height]
        overlay.frame = bounds;overlay.autoresizingMask = [.width,.height];overlay.viewport = style.layout.viewportRect
        overlay.restoreFocus = { [weak self] in
            guard let self = self else { return }
            self.window?.makeFirstResponder(self);self.needsDisplay = true
            self.checkAutoTurnEndPrompt()
        }
        addSubview(overlay)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func start() throws { try flow.start();_ = drainHeldCues();recordingBoundaryIfReady();announcePhase();needsDisplay = true }
    private func acceptedInput(_ input:OriginalPlayInput) {
        acceptedInputRevision += 1;lastRefusal = nil;onAcceptedInput?(input)
    }
    private func recordingBoundaryIfReady() {
        if canInput,!overlay.active,boundaryRevision != acceptedInputRevision {
            boundaryRevision = acceptedInputRevision;onRecordingBoundary?();queueTutorial()
        }
    }
    func focusAssistancePoint(_ point:GridPoint) {
        guard canInput,(0..<session.width).contains(point.x),(0..<session.height).contains(point.y) else {return}
        camera.center(on:point);hoveredCell = point;needsDisplay = true
    }
    func showTutorialLibrary() {
        guard canInput else {return}
        TutorialGuidanceUI.library(overlay:overlay,onDetails:{ [weak self] in self?.openTutorialDestination($0) },onClose:{})
    }
    private func openTutorialDestination(_ destination:TutorialGuidance.Destination) {
        guard canInput else {return}
        let slot = selected ?? inspected ?? hovered
        switch destination {
        case .strategies:if let slot {openStrategyGuide(slot) {}} else {openStrategyGuidePeople(returnMenuIndex:0)}
        case .conditions:if let slot {openConditionDetails(slot)} else {notice("부대를 먼저 선택한 뒤 상태 안내를 열어 주세요.")}
        case .controls:onControlSettings?()
        case .refusal:notice(lastRefusal ?? "책략 목록의 회색 행 또는 현재 사용 조건 자세히에서 제한을 확인하세요.")
        case .recovery:if let slot {openRecoveryFinder(slot)} else {notice("회복할 아군을 먼저 선택해 주세요.")}
        }
    }
    private func queueTutorial() {
        DispatchQueue.main.async { [weak self] in
            guard let self,self.animatesActions,self.allowsAutomaticGuidance?() ?? true,
                  self.canInput,!self.overlay.active,self.animator.notice == nil,self.duelPlayer == nil,
                  self.annotationDraft == nil,self.window?.attachedSheet == nil,NSApp.modalWindow == nil else {return}
            let unit = (self.selected ?? self.inspected ?? self.hovered).flatMap {self.session.units[$0]}
            let visible = unit.map {!$0.enemy || $0.scriptFlags&0x20 != 0} ?? false
            let stats = unit.flatMap {try? self.session.people.stats($0.person,morale:$0.morale)}
            let maxTroops = stats.flatMap {try? OriginalCombat.maxTroops(classID:$0.classID,level:$0.level,tables:self.session.combat)}
            let context = TutorialGuidance.Context(safeToPresent:true,
                selectingAreaStrategy:self.strategySelection.map {BattleProjection.isAreaStrategy($0.abilityID)} ?? false,
                confusedPublicUnit:visible && unit.map {$0.scriptFlags&2 != 0} == true,
                mayCancelMove:!self.session.pendingMovementSlots.isEmpty,unavailableReason:self.lastRefusal,
                recoveryUseful:unit?.enemy == false && stats.map {$0.troops < (maxTroops ?? $0.troops) || $0.morale < 100} == true)
            guard let topic = TutorialGuidance.next(context:context,preferences:OriginalSettings.current.tutorials) else {return}
            TutorialGuidanceUI.present(topic,overlay:self.overlay,reason:self.lastRefusal,
                onDetails:{ [weak self] in self?.openTutorialDestination($0) },onClose:{})
        }
    }
    /// MAIN33747..33827 (2CB4:0207): during battle dialogue outside a duel,
    /// the camera scrolls to the speaking unit's cell and marks it on the map.
    private(set) var speakingSlot:Int?
    var speakerInLowerHalf:Bool {
        guard let slot = speakingSlot,let unit = session.units[slot],unit.status == 2 else { return false }
        return unit.position.y-camera.y/2 >= (presentation == .modern ? layoutFacts.rows/2 : 6)
    }
    @discardableResult
    func focusSpeaker(_ person:Int?) -> Bool {
        guard let person = person,session.scriptActions.duel?.active != true else {
            speakingSlot = nil;needsDisplay = true;return false
        }
        var found:OriginalLiveUnit?
        for slot in 0..<45 {
            guard let unit = session.units[slot],unit.status == 2,unit.person == person else { continue }
            if unit.enemy && unit.scriptFlags&0x20 == 0 { continue }
            found = unit;break
        }
        guard let unit = found else {
            speakingSlot = nil;needsDisplay = true;return false
        }
        speakingSlot = unit.slot
        listSide = unit.enemy ? 1 : 0
        let rows = listRows
        if let idx = rows.firstIndex(of:unit.slot) {
            listTop = min(listTopLimit,max(0,idx-layoutFacts.list.rows/2))
        }
        camera.center(on:unit.position)
        needsDisplay = true
        return true
    }
    func clearSpeakerFocus() {
        guard speakingSlot != nil else { return }
        speakingSlot = nil;needsDisplay = true
    }
    private func play(_ cues:[OriginalBattleCue],then done:@escaping ()->Void) {
        guard animatesActions,!cues.isEmpty else { done();return }
        afterCues = done;perform(cues)
    }
    func playScriptCues(_ cues:[OriginalBattleCue],then done:@escaping ()->Void) {
        play(cues,then:done)
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
            if slot >= 15,!followsEnemies,afterCues == nil { return }
            if let walker = animator.walker {
                camera.follow(GridPoint(x:Int(walker.x.rounded()),y:Int(walker.y.rounded())),margin:layoutFacts.followMargin)
            } else if let first = path.first { camera.follow(first,margin:layoutFacts.followMargin) }
        case .shot(_,let to,_)?:camera.follow(to,margin:layoutFacts.followMargin)
        case .effect(_,let x,let y)?:camera.follow(GridPoint(x:x/2,y:y/2),margin:layoutFacts.followMargin)
        case .number(let slot,_,_,_)?:
            if let cell = session.units[slot]?.position { camera.follow(cell,margin:layoutFacts.followMargin) }
        case .combat?,.notice?,nil:break
        }
    }
    /// The campaign's duel window, and the steps of one opcode as they play.
    var duelStage:OriginalDuelStage? { didSet { if duelStage != oldValue { needsDisplay = true } } }
    private var duelPlayer:OriginalDuelPlayer?
    private var afterDuel:(()->Void)?
    var isPlayingDuel:Bool { duelPlayer != nil }
    func playDuel(_ steps:[OriginalDuelStep],then done:@escaping ()->Void) {
        guard OriginalSettings.current.showDuelPresentation else {done();needsDisplay = true;return}
        duelPlayer = OriginalDuelPlayer(steps:steps);afterDuel = done;needsDisplay = true
    }
    /// MAIN0x28D57..0x28D74: while it waits for input the battle re-arms
    /// CF5:2502(4), four units of six ticks, and flips byte5 of DS:E196
    /// (1CB6:7904); 2A0E0 draws a unit that has not acted with frame 0 or 1
    /// by that byte. The engine keeps the flip running in every phase.
    static let idleSeconds = 24*OriginalBattleAnimator.tick
    private var idlePhase:UInt8 = 0
    private var idleClock = 0.0
    func advanceAnimation(_ seconds:Double) {
        guard !overlay.isSuspended else {return}
        idleClock += seconds
        if idleClock >= Self.idleSeconds { idleClock = idleClock.truncatingRemainder(dividingBy:Self.idleSeconds);idlePhase ^= 1;needsDisplay = true }
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
            if combatPlayer == nil { stopSound?();combatPicture = nil;updateRosterAfterCombat();checkAutoTurnEndPrompt() }
            needsDisplay = true
            return
        }
        guard !animator.isIdle else { checkAutoTurnEndPrompt();return }
        for id in animator.advance(seconds) { onSound?(id) }
        followCue();needsDisplay = true
        if animator.isIdle {
            if let done = afterCues { afterCues = nil;done() }
            checkAutoTurnEndPrompt()
        }
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
        hasPresentedCombat = true
        return true
    }
    /// True while the cues own the screen. A scene takes the whole view, so
    /// notices play up to it and whatever follows waits for it to close.
    private func presentHeld(_ cues:[OriginalBattleCue]) -> Bool {
        if case .combat(let snapshot)? = cues.first {
            let rest = Array(cues.dropFirst())
            let settings = OriginalSettings.current
            let policy = CombatPresentationPolicy(mode:settings.combatPresentationMode,importantPersonIDs:foregroundFavorites?() ?? [],showsDuels:settings.showDuelPresentation)
            if !policy.showsCombat(snapshot,hasPresentedCombat:hasPresentedCombat) {
                return presentHeld(policy.abbreviatedCues(for:snapshot)+rest)
            }
            if startCombat(cues) { heldAfter = rest;return true }
            return presentHeld(policy.abbreviatedCues(for:snapshot)+rest)
        }
        let scene = cues.firstIndex { if case .combat = $0 { return true };return false } ?? cues.count
        heldAfter = Array(cues[scene...])
        guard scene > 0 else { return false }
        perform(Array(cues[..<scene]));return true
    }
    @discardableResult
    private func drainHeldCues() -> Bool {
        let held = heldAfter+flow.takeCues().filter(visible)
        heldAfter = []
        return presentHeld(held)
    }
    func resumeSourceFlow() throws {
        guard !overlay.isSuspended,animator.isIdle,combatPlayer == nil else { return }
        if drainHeldCues() { return }
        try flow.resumeSourceFlow()
        // Pull held walk, shot, effect, notice or counter scenes immediately so
        // the map never renders an AI unit at its destination before its walk.
        if drainHeldCues() { return }
        if waitingForStrategy,let result = flow.lastStrategy {showStrategyResult(result);waitingForStrategy = false}
        if waitingForAttack,let result = flow.lastAttack {showAttackResult(result);waitingForAttack = false}
        if waitingForItem,let result = flow.lastItem {waitingForItem = false;finishItem(result)}
        if canInput,let before = enemyTurnBefore {
            lastEnemyTurnChanges = before.changes(to:EnemyTurnSnapshot(session));enemyTurnBefore = nil;hasEnemyTurnSummary = true
        }
        recordingBoundaryIfReady()
        announcePhase()
        checkAutoTurnEndPrompt()
        needsDisplay = true
    }
    private var canInput:Bool {!overlay.isSuspended && animator.isIdle && combatPlayer == nil && flow.acceptsManualInput && (inputReady?() ?? true)}
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
            catch { self.report(error) }
            self.needsDisplay = true
        }
    }
    /// MAIN27E87..27EA3. The framework then shows MAIN's retry selector.
    private func requestQuit() {
        guard canInput,let texts = menuTexts else { return }
        yesNo(texts.quit.confirm.text) { [weak self] yes in
            guard let self = self,yes else { return }
            do { try self.flow.requestQuit();self.selected = nil } catch { self.report(error) }
            self.needsDisplay = true
        }
    }
    /// MAIN27D65..27D76 and 27EEF..27F8C: the battle system menu's item 0 and
    /// the post-action loop when no controllable friendly unit remains both
    /// ask DS:[3D1C] ("전부대의 명령을 종료하겠습니까?"). When units can still act,
    /// the engine names how many remain.
    var confirmsTurnEnd = false
    private var autoTurnEndPromptedRound:Int?
    private var turnEndConfirmText:String {
        menuTexts?.endTurnConfirm?.text ?? "전부대의 명령을 종료하겠습니까?"
    }
    private func checkAutoTurnEndPrompt() {
        if phase == .idle,strategySelection == nil {recordingBoundaryIfReady()}
        guard session.turns.stage == .manualFriendly else { autoTurnEndPromptedRound = nil;return }
        guard confirmsTurnEnd,canInput,phase == .idle,strategySelection == nil,!overlay.active,!functionOpen,!learningGuideOpen,
              animator.isIdle,combatPlayer == nil,duelPlayer == nil,
              readyUnits().isEmpty,autoTurnEndPromptedRound != session.turns.roundIndex else { return }
        autoTurnEndPromptedRound = session.turns.roundIndex
        yesNo(turnEndConfirmText) { [weak self] yes in
            guard let self = self,yes else { return }
            do { try self.endTurn() } catch { self.report(error) }
            self.needsDisplay = true
        }
    }
    private func requestEndTurn() {
        let left = session.turns.stage == .manualFriendly ? readyUnits().count : 0
        guard confirmsTurnEnd,session.turns.stage == .manualFriendly,canInput else {
            do { try endTurn() } catch { report(error) }
            return
        }
        let prompt = left > 0 ? "아직 행동하지 않은 부대가 \(left)개 있습니다. 턴을 끝낼까요?" : turnEndConfirmText
        yesNo(prompt) { [weak self] yes in
            guard let self = self,yes else { return }
            do { try self.endTurn() } catch { self.report(error) }
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
        selectReadyUnit(ready[index])
    }
    private var isChoosingMove:Bool { if case .moving = phase { return true };return false }
    private func selectReadyUnit(_ slot:Int,center:Bool = true) {
        guard canInput,let unit = session.units[slot],OriginalBattleCommand.denial(unit) == nil,
              (try? session.requireManualUnit(slot)) != nil else { return }
        resetCommand();inspected = nil
        if center { camera.center(on:unit.position) }
        selected = unit.slot
        if unit.scriptFlags&0x20 == 0 || unit.scriptFlags&0x40 != 0 { openCommand(unit.slot) } else { phase = .moving(unit.slot) }
        needsDisplay = true;queueTutorial()
    }
    /// A resumed move is still provisional. Reopen its command menu so Esc
    /// returns to the saved origin instead of permitting another move.
    func restorePendingMovementCommand() {
        guard canInput,let slot = session.pendingMovementSlots.first,let unit = session.units[slot] else { return }
        selected = slot;previewSlot = nil;camera.center(on:unit.position)
        openCommand(slot);needsDisplay = true
    }
    func prepareSuspendedPresentation() {
        if session.turns.stage == .manualFriendly { announcedRound = session.turns.roundIndex }
        restorePendingMovementCommand()
    }
    func restoreKeyboardFocus() { window?.makeFirstResponder(overlay.active ? overlay : self) }
    /// Engine addition: the cells visible enemies could strike this turn.
    var showsThreat = false { didSet { if showsThreat != oldValue { needsDisplay = true } } }
    private var threatCache:(key:BattleProjection.Key,pin:Int?,map:BattleProjection.ThreatMap)?
    private var pinnedThreat:(slot:Int,person:Int)?
    private var threatMode = 2 // 0 physical, 1 strategy, 2 both
    private var previewAbility:Int?
    private var movePreviewCache:(key:BattleProjection.Key,slot:Int,point:GridPoint,value:BattleProjection.MovePreview)?
    private var effectCache:(key:BattleProjection.Key,values:[Int:BattleProjection.Effect])?
    @objc func toggleThreat(_ sender:Any?) { showsThreat.toggle() }
    private func threatMap() -> BattleProjection.ThreatMap {
        guard let snapshot = try? BattleProjection(session) else {return .init()}
        if let pin = pinnedThreat,!(snapshot.key.units.contains {$0.live.slot == pin.slot && $0.live.person == pin.person}) {pinnedThreat = nil}
        if let cache = threatCache,cache.key == snapshot.key,cache.pin == pinnedThreat?.slot {return cache.map}
        let map = (try? snapshot.threats(only:pinnedThreat?.slot)) ?? .init()
        threatCache = (snapshot.key,pinnedThreat?.slot,map)
        return map
    }
    private func threatSources(_ point:GridPoint,_ map:BattleProjection.ThreatMap)->Set<Int> {
        threatMode == 0 ? map.physical[point] ?? [] : threatMode == 1 ? map.strategies[point] ?? [] : map.sources(point)
    }
    private func movePreview(_ slot:Int,at point:GridPoint)->BattleProjection.MovePreview? {
        guard let movement = try? BattleAssistance.movement(in:session,slot:slot,to:point),movement.reason == nil,
              let snapshot = try? BattleProjection(session) else {movePreviewCache = nil;return nil}
        if let cache = movePreviewCache,cache.key == snapshot.key,cache.slot == slot,cache.point == point {return cache.value}
        guard let value = try? snapshot.preview(slot,at:point) else {movePreviewCache = nil;return nil}
        movePreviewCache = (snapshot.key,slot,point,value);return value
    }
    /// A tinted cell and an edge where the region ends.
    private func drawThreat(_ context:CGContext,rect:(GridPoint) -> CGRect) {
        let map = threatMap(),cells = Set(map.cells.filter {!threatSources($0,map).isEmpty})
        for point in cells {
            let count = threatSources(point,map).count,box = rect(point)
            context.setFillColor(CGColor(red:1,green:0.42,blue:0.12,alpha:min(0.48,0.12+CGFloat(count)*0.08)));context.fill(box)
            CanvasRangePattern.draw(kind:.threat,in:box,context:context)
            if presentation == .modern {
                let strategy = threatMode != 0 && !(map.strategies[point] ?? []).isEmpty
                label("\(count)"+(strategy ? "✦" : ""),in:CGRect(x:box.minX+1,y:box.minY+1,width:box.width-2,height:11),font:CanvasTheme.font(8,.bold),alignment:.right)
            }
        }
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
            if let slot = selected { try cancelRecordedMove(slot) }
            resetCommand()
            try flow.finishManual()
            _ = drainHeldCues()
        }
        else if !suspended { try flow.start();_ = drainHeldCues() }
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
            turns:turns,button:presentation == .original ? style.ok : nil,onDismiss:done))
    }
    /// MAIN27AA7..27AE8: the camera follows slot 0, the first friendly phase
    /// opens with the conditions, and every friendly phase with the side notice.
    func announcePhase() {
        guard announcesPhases,session.turns.stage == .manualFriendly,canInput,!overlay.active,
              announcedRound != session.turns.roundIndex else { return }
        announcedRound = session.turns.roundIndex
        autoTurnEndPromptedRound = nil
        listSide = 0
        if let leader = (session.units[0]?.status == 2 ? session.units[0] : nil) ?? session.units.values.filter({ !$0.enemy && $0.status == 2 }).min(by:{ $0.slot < $1.slot }) {
            camera.follow(leader.position,margin:layoutFacts.followMargin)
        }
        let notice:() -> Void = { [weak self] in
            guard let self = self else { return }
            // MAIN28139 names the turn and its weather before the side's line.
            let round = self.session.turns.roundIndex+1
            self.play([.notice(.turn(round:round,weather:self.weatherClass))]) { [weak self] in
                guard let self = self,self.style.commands?.conditions.playerPhase != nil else { return }
                self.say(self.playerPhaseText)
            }
        }
        if session.turns.roundIndex == 0 { showConditions(opening:true,then:notice) } else { notice() }
    }
    /// MAIN0x27ADD hands DS:3D20 to CF5:3C5E unchanged, and the Korean MAIN
    /// keeps it as "Player군 순서". Original frames show it as is; the engine
    /// layout says 아군 순서.
    private var playerPhaseText:String {
        let source = style.commands?.conditions.playerPhase ?? "아군 순서"
        return presentation == .modern ? source.replacingOccurrences(of:"Player",with:"아") : source
    }
    /// The 기능 button opens MAIN27D12's list. Items without a restored
    /// handler stay visible and disabled.
    /// Engine menus carry a symbol per action; original frames stay plain.
    private func icon(_ action:String) -> String? {
        guard presentation == .modern else { return nil }
        return ["roster":"line.3.horizontal.decrease.circle","unit-status":"info.circle","result-log":"list.bullet.rectangle","learning-guide":"book.closed.fill","suspend":"pause.circle.fill","load":"folder","end-turn":"flag.checkered","retreat":"arrow.uturn.backward","conditions":"target","unit-combat":"rectangle.on.rectangle",
                "move-speed":"hare.fill","enemy-move":"eye.fill","bgm":"music.note","sound":"speaker.wave.2.fill",
                "battle-pace":"gauge.with.dots.needle.67percent","auto":"text.bubble.fill","quit":"power","attack":"figure.fencing","strategy":"sparkles",
                "item":"bag.fill","wait":"hourglass","strike":"bolt.fill","release":"eye","use":"hand.tap.fill",
                "give":"arrow.left.arrow.right","drop":"trash","inspect":"magnifyingglass"][action]
    }
    private static var paceLabels:[String] {
        OriginalSettings.battlePaceRates.map { $0 == 1 ? "보통" : String(format:$0 == $0.rounded() ? "%.0f배" : "%.1f배",$0) }
    }
    /// One setting row: its choices, the current one and how a choice is stored.
    private func settingChoices(_ action:String) -> (labels:[String],current:Int,apply:(inout OriginalSettings,Int) -> Void)? {
        guard let texts = settingsTexts else { return nil }
        let settings = OriginalSettings.current
        switch action {
        case "unit-combat":
            let modes = CombatPresentationPolicy.Mode.allCases
            return (modes.map(\.label),modes.firstIndex(of:settings.combatPresentationMode) ?? 0,{ $0.combatPresentationMode = modes[$1] })
        case "duel-presentation":return (["본다","생략"],settings.showDuelPresentation ? 0 : 1,{$0.showDuelPresentation = $1 == 0})
        case "move-speed":return (texts.moveSpeed,settings.moveSpeed,{ $0.moveSpeed = $1 })
        case "enemy-move":return (texts.show,settings.enemyMove ? 0 : 1,{ $0.enemyMove = $1 == 0 })
        case "battle-pace":return (Self.paceLabels,settings.battlePace,{ $0.battlePace = $1 })
        case "auto":return OriginalCampaignView.autoChoices(settings)
        case "bgm":return (texts.onOff,OriginalAudio.musicEnabled ? 0 : 1,{ _,index in OriginalAudio.musicEnabled = index == 0 })
        case "sound":return (texts.onOff,OriginalAudio.effectsEnabled ? 0 : 1,{ _,index in OriginalAudio.effectsEnabled = index == 0 })
        default:return nil
        }
    }
    /// Steps a setting row to its next or previous choice, as MAIN27DC4's
    /// selector would store it.
    private func changeSetting(_ action:String,by delta:Int) {
        guard let choice = settingChoices(action),!choice.labels.isEmpty else { return }
        var settings = OriginalSettings.current
        choice.apply(&settings,(choice.current+delta+choice.labels.count)%choice.labels.count)
        OriginalSettings.current = settings
        applySourcePresentationSetting(action,settings:settings);needsDisplay = true
    }
    private func applySourcePresentationSetting(_ action:String,settings:OriginalSettings) {
        // Restore owns the complete source word. Presentation controls update
        // only their own harmless bits; the source RNG's combat nibble survives.
        let before = session.sourceOptionsWord
        switch action {
        case "move-speed":session.sourceOptionsWord = (session.sourceOptionsWord & ~0xF)|(settings.moveSpeed&0xF)
        case "enemy-move":session.sourceOptionsWord = (session.sourceOptionsWord & ~0x1000)|(settings.enemyMove ? 0x1000 : 0)
        default:break
        }
        if before != session.sourceOptionsWord {acceptedInput(.init(kind:.battleOptions,index:session.sourceOptionsWord));recordingBoundaryIfReady()}
    }
    private func openFunctionMenu(selected:Int = 0) {
        guard canInput,phase == .idle,strategySelection == nil else { return }
        if presentation == .modern,mapViewMode == .overview {applyMapView(previousTacticalMode)}
        var restored:Set<String> = menuTexts == nil ? ["end-turn"] : ["end-turn","retreat","quit"]
        if settingsTexts != nil { restored.formUnion(["unit-combat","move-speed","enemy-move","bgm","sound","battle-pace","auto"]) }
        if objective != nil,style.commands != nil { restored.insert("conditions") }
        var items = menuTexts?.items ?? [OriginalTitleMenuItem(index:0,action:"end-turn",text:"End turn")]
        if onManageInventory != nil {restored.insert("inventory-tools");items.append(.init(index:-10,action:"inventory-tools",text:"소지품 관리 · 보호 해제"))}
        if presentation == .modern {restored.insert("map-view");items.append(.init(index:-11,action:"map-view",text:"지도 보기 · 확대 / 전체"))}
        if onAnnotationsChanged != nil {restored.insert("annotations");items.append(.init(index:-12,action:"annotations",text:"작전 메모"))}
        if objective != nil {restored.insert("objective-progress");items.append(.init(index:-15,action:"objective-progress",text:"현재 목표 진행"))}
        if onEventHints != nil {restored.insert("event-hints");items.append(.init(index:-14,action:"event-hints",text:"이벤트 힌트"))}
        restored.insert("tutorials");items.append(.init(index:-13,action:"tutorials",text:"상황별 도움말"))
        restored.insert("learning-guide")
        restored.insert("result-log")
        restored.insert("roster")
        restored.insert("enemy-summary")
        items.append(OriginalTitleMenuItem(index:-8,action:"enemy-summary",text:"적 턴 변화"))
        if settingsTexts != nil {
            restored.insert("duel-presentation")
            items.insert(OriginalTitleMenuItem(index:-9,action:"duel-presentation",text:"일기토 연출"),at:items.firstIndex(where:{$0.action == "unit-combat"}).map {$0+1} ?? items.endIndex)
        }
        items.insert(OriginalTitleMenuItem(index:-7,action:"roster",text:"부대 목록 · 정렬과 필터"),at:items.firstIndex(where:{ $0.action == "unit-combat" }) ?? items.endIndex)
        items.insert(OriginalTitleMenuItem(index:-4,action:"learning-guide",text:"책략 습득표"),at:items.firstIndex(where:{ $0.action == "quit" }) ?? items.endIndex)
        items.insert(OriginalTitleMenuItem(index:-5,action:"result-log",text:"전투 결과 기록"),at:items.firstIndex(where:{ $0.action == "unit-combat" }) ?? items.endIndex)
        if onSuspend != nil {
            restored.insert("suspend")
            items.insert(OriginalTitleMenuItem(index:-3,action:"suspend",text:"중단 저장 후 타이틀로"),at:0)
        }
        if onLoad != nil {
            restored.insert("load")
            items.insert(OriginalTitleMenuItem(index:-6,action:"load",text:"불러오기"),at:onSuspend == nil ? 0 : 1)
        }
        // Engine addition after the source rows: how fast the battle plays.
        if settingsTexts != nil,let quit = items.firstIndex(where:{ $0.action == "quit" }) {
            items.insert(contentsOf:[OriginalTitleMenuItem(index:-1,action:"battle-pace",text:"전투 속도"),
                                     OriginalTitleMenuItem(index:-2,action:"auto",text:"대사 자동 넘기기")],at:quit)
        }
        functionOpen = true;needsDisplay = true
        // Settings show their current choice and change in place (click or left/right).
        let options = items.map { item -> CanvasMenu.Option in
            var option = CanvasMenu.Option(label:presentation == .modern ? BattleSettingPresentation.label(item.action,original:item.text) : item.text,
                                           enabled:restored.contains(item.action))
            if let choice = settingChoices(item.action),choice.labels.indices.contains(choice.current) { option.value = choice.labels[choice.current] }
            if presentation == .modern { option.help = BattleSettingPresentation.help(item.action) }
            if item.action == "load" { option.help = "일반 저장·중단 저장·원작 슬롯을 불러옵니다." }
            option.icon = icon(item.action)
            option.destructive = ["retreat","quit"].contains(item.action)
            option.separatorBefore = ["unit-combat","quit"].contains(item.action)
            return option
        }
        var menu = CanvasMenu(title:"",options:options,selected:selected,cancellable:true) { [weak self] index in
            guard let self = self else { return }
            self.functionOpen = false;self.needsDisplay = true
            guard let index = index else { return }
            switch items[index].action {
            case "inventory-tools":self.onManageInventory?()
            case "map-view":self.openMapViewMenu()
            case "annotations":self.openAnnotations()
            case "event-hints":self.onEventHints?()
            case "objective-progress":self.openObjectiveProgress()
            case "tutorials":self.showTutorialLibrary()
            case "enemy-summary":self.openEnemyTurnSummary()
            case "roster": self.openRosterTools { [weak self] in self?.openFunctionMenu(selected:index) }
            case "result-log": self.openBattleResultLog(returnMenuIndex:index)
            case "learning-guide": self.openStrategyGuidePeople(returnMenuIndex:index)
            case "suspend": self.onSuspend?()
            case "load": self.onLoad?()
            case "end-turn": self.requestEndTurn()
            case "unit-combat","duel-presentation","move-speed","enemy-move","bgm","sound","battle-pace","auto":
                self.changeSetting(items[index].action,by:1);self.openFunctionMenu(selected:index)
            case "retreat": self.requestRetreat()
            case "conditions": self.showConditions(opening:false)
            case "quit": self.requestQuit()
            default: break
            }
        }
        menu.onAdjust = { [weak self] index,delta in
            guard let self = self,self.settingChoices(items[index].action) != nil else { return }
            self.changeSetting(items[index].action,by:delta);self.openFunctionMenu(selected:index)
        }
        if presentation == .modern { menu.footer = "↑↓ 선택 · ←→ 설정 변경 · Esc 닫기" }
        overlay.show(menu,keepScroll:true)
    }
    /// Engine reference view of committed results; reading issues no command.
    private func openBattleResultLog(selected:Int = 0,returnMenuIndex:Int) {
        guard canInput,duelPlayer == nil else { return }
        overlay.show(BattleResultLogSheet.sheet(session.resultLog,selected:selected,
            personName:{ [session] in (try? session.people.person($0).name) ?? "알 수 없는 장수" },
            strategyName:strategyTitle,itemName:itemName,className:className) { [weak self] row in
                guard let self = self else { return }
                if let row { self.openBattleResultLog(selected:row,returnMenuIndex:returnMenuIndex) }
                else { self.openFunctionMenu(selected:returnMenuIndex) }
            })
    }
    /// UI-only projection: no actual slots, AI order or Tab order are changed.
    private func openRosterTools(selected row:Int = 0,onClose:@escaping ()->Void = {}) {
        guard canInput,duelPlayer == nil else {return}
        let filters = BattleRosterOptions.Filter.allCases,sorts = BattleRosterOptions.Sort.allCases
        var options = filters.map { CanvasMenu.Option(label:$0.title,checked:rosterOptions.filters.contains($0)) }
        options.append(.init(label:"정렬",value:rosterOptions.sort.title,separatorBefore:true))
        options.append(.init(label:"정렬 방향",value:rosterOptions.descending ? "내림차순" : "오름차순"))
        options.append(.init(label:"조건 초기화"))
        options.append(.init(label:"부대 찾아보기",value:"\(listRows.count)명",separatorBefore:true))
        let apply:(Int,Int)->Void = { [weak self] index,delta in
            guard let self else {return}
            if index < filters.count {
                let filter = filters[index]
                if self.rosterOptions.filters.contains(filter) {self.rosterOptions.filters.remove(filter)} else {self.rosterOptions.filters.insert(filter)}
            } else if index == filters.count {
                let current = sorts.firstIndex(of:self.rosterOptions.sort) ?? 0
                self.rosterOptions.sort = sorts[(current+delta+sorts.count)%sorts.count]
            } else if index == filters.count+1 {self.rosterOptions.descending.toggle()}
            else if index == filters.count+2 {self.rosterOptions = BattleRosterOptions()}
            self.listTop = 0;self.inspected = nil;BattleRosterOptions.current = self.rosterOptions;self.needsDisplay = true
        }
        var menu = CanvasMenu(title:"부대 목록 · \(listSide == 0 ? "아군" : "적군")",options:options,selected:row,cancellable:true,
            footer:"필터는 동시에 적용 · 회복 자격은 대상 존재와 별개\nR: 목록 · I: 선택 부대 상태 · Tab 순서는 유지") { [weak self] index in
                guard let self else {return}
                guard let index else {onClose();return}
                if index == filters.count+3 {
                    self.openRosterBrowser { [weak self] in self?.openRosterTools(selected:index,onClose:onClose) };return
                }
                apply(index,1);self.openRosterTools(selected:index,onClose:onClose)
            }
        menu.onAdjust = { [weak self] index,delta in
            guard index == filters.count || index == filters.count+1 else {return}
            apply(index,delta);self?.openRosterTools(selected:index,onClose:onClose)
        }
        overlay.show(menu)
    }
    private func openRosterBrowser(selected index:Int = 0,onClose:@escaping ()->Void) {
        guard canInput else {onClose();return}
        let slots = listRows
        var rows = slots.compactMap { slot -> CanvasSheet.Row? in
            guard let unit = session.units[slot],let person = try? session.people.person(unit.person) else {return nil}
            return .init(label:person.name,value:"Lv.\(person.level) · 병력 \(person.rawTroops)",
                detail:.init(heading:person.name,body:"\(className(person.classID))\n선택하면 해당 부대의 위치를 보여줍니다.\n지도에서 I 또는 부대 정보 카드를 눌러 상태를 확인하세요.",portrait:portraitImage?(person.id)))
        }
        if rows.isEmpty {rows = [.init(label:"조건에 맞는 부대 없음",detail:.init(heading:"목록 필터",body:"Esc로 돌아가 필터를 해제하세요.\n"+rosterOptions.summary))]}
        overlay.show(CanvasSheet(portrait:nil,speaker:"부대 찾아보기",line:rosterOptions.summary,badge:("표시","\(slots.count)명"),rows:rows,
            selected:min(max(0,index),rows.count-1),mode:.list,hint:"↑↓ 선택 · Enter 위치 보기 · Esc 돌아가기",fullCanvas:true) { [weak self] chosen in
                guard let self else {return}
                guard let chosen else {onClose();return}
                guard slots.indices.contains(chosen),let unit = self.session.units[slots[chosen]] else {self.openRosterBrowser(onClose:onClose);return}
                self.inspected = unit.slot
                if unit.status == 2 {self.camera.center(on:unit.position)}
                self.needsDisplay = true
            })
    }
    private func openConditionDetails(_ slot:Int,selected row:Int = 0,onClose:@escaping ()->Void = {}) {
        guard canInput,duelPlayer == nil else {return}
        do {
            let entries = try BattleAssistance.conditions(in:session,slot:slot)
            guard let unit = session.units[slot] else {return}
            let person = try session.people.person(unit.person)
            let rows = entries.map { item in CanvasSheet.Row(label:item.title,
                detail:.init(heading:item.title,body:item.body,facts:item.facts.map {($0.label,$0.value)},portrait:portraitImage?(person.id))) }
            overlay.show(CanvasSheet(portrait:nil,speaker:person.name+" · 상태 안내",line:"현재 상태의 제한과 회복 방법",badge:("현재 사기","\(unit.morale)"),rows:rows,
                selected:min(max(0,row),rows.count-1),mode:.list,buttons:unit.enemy ? [] : ["회복할 방법 찾기"],hint:"↑↓ 읽기 · Tab 회복 찾기 · Esc 돌아가기",fullCanvas:true,onButton:{ [weak self] _ in self?.openRecoveryFinder(slot) }) { [weak self] chosen in
                    if let chosen {self?.openConditionDetails(slot,selected:chosen,onClose:onClose)} else {onClose()}
                })
        } catch {report(error);onClose()}
    }
    private func openMovePreviewActions(_ slot:Int) {
        guard let snapshot = try? BattleProjection(session),let ids = try? snapshot.availableStrategies(slot) else {return}
        let options:[CanvasMenu.Option] = [.init(label:"일반 공격",checked:previewAbility == nil)]+ids.map {
            .init(label:strategyTitle($0),value:"MP \(session.movement.strategyMPCosts?[$0] ?? 0)",checked:previewAbility == $0)
        }
        overlay.show(CanvasMenu(title:"이동 전 미리보기 · 행동은 실행하지 않습니다",options:options,cancellable:true) { [weak self] index in
            if let index {self?.previewAbility = index == 0 ? nil : ids[index-1]}
            self?.needsDisplay = true
        })
    }
    private func applyMapView(_ mode:BattleMapViewMode,focus:GridPoint? = nil) {
        guard presentation == .modern,canInput,duelPlayer == nil else {return}
        let center = focus ?? hoveredCell ?? (selected ?? inspected).flatMap {session.units[$0]?.position}
            ?? GridPoint(x:camera.x/2+camera.columns/2,y:camera.y/2+camera.rows/2)
        if mode == .overview,mapViewMode != .overview {previousTacticalMode = mapViewMode}
        mapViewMode = mode
        if mode != .overview {onMapViewPreferenceChanged?(mode)}
        layoutFacts = BattleMapViewport.layout(source:style.layout,width:session.width,height:session.height,mode:mode,textScale:CanvasTheme.textScale)
        camera = OriginalBattleCamera(width:session.width,height:session.height,layout:layoutFacts);camera.center(on:center)
        overlay.viewport = layoutFacts.viewportRect;hoveredCell = nil
        message = mode == .overview ? "전체 전장 · 칸을 선택하면 해당 위치를 확대합니다. 이동·공격은 실행하지 않습니다." : mode.label
        needsDisplay = true
    }
    private func openMapViewMenu() {
        let modes = BattleMapViewMode.allCases
        overlay.show(CanvasMenu(title:"지도 보기",options:modes.map {.init(label:$0.label,checked:$0 == mapViewMode)},cancellable:true,
            footer:"지도만 확대합니다. 전체 전장의 칸 선택은 위치 보기이며 이동·공격을 실행하지 않습니다.") { [weak self] index in
                if let index {self?.applyMapView(modes[index])}
            })
    }
    private func currentAnnotations() throws -> BattleAnnotations {
        if let stored = annotations?(),stored.matches(session) {try stored.validate();return stored}
        return BattleAnnotations(battleID:session.definition.id,attemptID:session.resultLog.attemptID,width:session.width,height:session.height)
    }
    private func openAnnotations(selected row:Int = 0) {
        guard canInput,onAnnotationsChanged != nil else {return}
        do {
            let saved = try currentAnnotations(),kinds = BattleAnnotations.Kind.allCases
            var options = kinds.map {CanvasMenu.Option(label:"새 "+$0.label)}
            options += [.init(label:"메모 목록 · \(saved.entries.count)개",separatorBefore:true),.init(label:showsAnnotations ? "메모 표시 끄기" : "메모 표시 켜기"),.init(label:"현재 전투 메모 모두 지우기",enabled:!saved.entries.isEmpty,destructive:true)]
            overlay.show(CanvasMenu(title:"작전 메모",options:options,selected:min(row,options.count-1),cancellable:true,
                footer:"사용자 메모만 저장합니다. 원작 지도·부대·행동에는 영향이 없습니다.") { [weak self] choice in
                    guard let self,let choice else {return}
                    if choice < kinds.count {
                        self.beginAnnotation(kinds[choice])
                    } else if choice == kinds.count {self.openAnnotationList()}
                    else if choice == kinds.count+1 {self.showsAnnotations.toggle();self.openAnnotations(selected:choice);self.needsDisplay = true}
                    else {
                        self.yesNo("현재 전투의 사용자 메모 \(saved.entries.count)개를 모두 지울까요?") { [weak self] yes in
                            guard let self else {return}
                            if yes {do {var current = try self.currentAnnotations();current.clear();try self.onAnnotationsChanged?(current)} catch {self.report(error)}}
                            self.openAnnotations(selected:choice)
                        }
                    }
                })
        } catch {report(error)}
    }
    private func openAnnotationList(selected row:Int = 0) {
        do {
            let saved = try currentAnnotations()
            var rows = saved.entries.map { entry in CanvasSheet.Row(label:entry.kind.label+" · "+(entry.text.isEmpty ? "(\(entry.start.x+1), \(entry.start.y+1))" : entry.text),
                detail:.init(heading:entry.kind.label,body:entry.text,facts:[("시작","(\(entry.start.x+1), \(entry.start.y+1))"),("끝",entry.end.map {"(\($0.x+1), \($0.y+1))"} ?? "없음"),("표시",entry.style.label)])) }
            if rows.isEmpty {rows = [.init(label:"현재 전투의 작전 메모 없음")]}
            overlay.show(CanvasSheet(portrait:nil,speaker:"작전 메모 목록",line:"전투 재시작은 새 시도이므로 이전 메모를 표시하지 않습니다.",badge:("메모","\(saved.entries.count)/100"),rows:rows,
                selected:min(max(0,row),rows.count-1),mode:.list,buttons:saved.entries.isEmpty ? [] : ["위치 보기","내용·색 편집","위치 수정","삭제"],hint:"↑↓ 읽기 · Tab 작업 · Esc 메모 메뉴",fullCanvas:true,onRowButton:{ [weak self] button,row in
                    guard let self,saved.entries.indices.contains(row) else {return}
                    let entry = saved.entries[row]
                    if button == 0 {self.camera.center(on:entry.start);self.needsDisplay = true}
                    else if button == 1 {self.editAnnotation(entry,returnRow:row)}
                    else if button == 2 {self.beginAnnotation(entry.kind,editing:entry)}
                    else {do {var current = try self.currentAnnotations();current.remove(entry.id);try self.onAnnotationsChanged?(current);self.openAnnotationList(selected:row)} catch {self.report(error)}}
                }) { [weak self] chosen in if let chosen {self?.openAnnotationList(selected:chosen)} else {self?.openAnnotations()} })
        } catch {report(error)}
    }
    private func beginAnnotation(_ kind:BattleAnnotations.Kind,editing:BattleAnnotations.Entry? = nil) {
        annotationDraft = (kind,nil);annotationEditing = editing;showsAnnotations = true
        annotationCursor = editing?.start ?? hoveredCell ?? (selected ?? inspected).flatMap {session.units[$0]?.position}
            ?? GridPoint(x:min(session.width-1,camera.x/2+camera.columns/2),y:min(session.height-1,camera.y/2+camera.rows/2))
        message = "\(kind.label) 시작 칸 · 클릭 또는 방향키·Enter · Esc: 작성 취소";needsDisplay = true
    }
    private func cancelAnnotationDraft() {
        annotationDraft = nil;annotationEditing = nil;annotationCursor = nil;message = "메모 작성을 취소했습니다.";needsDisplay = true
    }
    private func pickAnnotation(_ point:GridPoint) {
        guard let draft = annotationDraft else {return}
        if draft.start == nil,(draft.kind == .line || draft.kind == .arrow) {
            annotationDraft = (draft.kind,point);annotationCursor = point;message = "끝 칸 · 클릭 또는 방향키·Enter · Esc: 작성 취소";needsDisplay = true;return
        }
        annotationDraft = nil
        let entry = BattleAnnotations.Entry(id:annotationEditing?.id ?? UUID(),kind:draft.kind,start:draft.start ?? point,
            end:draft.start == nil ? nil : point,text:annotationEditing?.text ?? "",style:annotationEditing?.style ?? .gold)
        annotationEditing = nil;annotationCursor = nil
        editAnnotation(entry)
    }
    private func editAnnotation(_ entry:BattleAnnotations.Entry,returnRow:Int = 0) {
        guard canInput else {return}
        let alert = NSAlert();alert.messageText = entry.kind.label+" 내용과 표시";alert.informativeText = "짧은 메모는 80자까지 입력할 수 있습니다. 취소하면 기존 메모가 유지됩니다."
        let field = NSTextField(string:entry.text);field.frame = CGRect(x:0,y:34,width:340,height:26)
        let styles = NSPopUpButton(frame:CGRect(x:0,y:0,width:340,height:26));styles.addItems(withTitles:BattleAnnotations.Style.allCases.map(\.label))
        styles.selectItem(at:BattleAnnotations.Style.allCases.firstIndex(of:entry.style) ?? 0)
        let box = NSView(frame:CGRect(x:0,y:0,width:340,height:60));box.addSubview(field);box.addSubview(styles);alert.accessoryView = box
        alert.addButton(withTitle:"저장");alert.addButton(withTitle:"취소")
        guard alert.runModal() == .alertFirstButtonReturn else {needsDisplay = true;return}
        do {
            var changed = entry;changed.text = field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines);changed.style = BattleAnnotations.Style.allCases[styles.indexOfSelectedItem]
            var saved = try currentAnnotations();try saved.upsert(changed);try onAnnotationsChanged?(saved)
            showsAnnotations = true;needsDisplay = true;openAnnotationList(selected:returnRow)
        } catch {report(error);notice("메모를 저장하지 못했습니다. 80자·100개·지도 좌표 제한을 확인하세요.")}
    }
    private func openEnemyTurnSummary() {
        guard hasEnemyTurnSummary else {notice("아직 비교할 적 턴 시작·종료 기록이 없습니다. 중간 재개한 턴은 다음 적 턴부터 비교합니다.");return}
        let changes = lastEnemyTurnChanges
        overlay.show(EnemyTurnSnapshot.sheet(changes) { [weak self] selected in
            guard let self,let selected,changes.indices.contains(selected),changes[selected].point != nil,
                  let unit = self.session.units.values.first(where:{$0.person == changes[selected].person && $0.status == 2 && (!$0.enemy || $0.scriptFlags&0x20 != 0)}) else {return}
            self.inspected = unit.slot;self.camera.center(on:unit.position);self.needsDisplay = true
        })
    }
    private func openRecoveryFinder(_ target:Int,selected row:Int = 0) {
        guard canInput,let recipient = session.units[target],!recipient.enemy,recipient.status == 2 else {return}
        do {
            let snapshot = try BattleProjection(session)
            let options = try snapshot.recoveries(target:target).filter { option in
                guard case .item(let item) = option.action,let caster = session.units[option.caster] else {return true}
                return onItemUseRefusal?(caster.person,item) == nil
            }
            func quantity(_ range:ClosedRange<Int>)->String {range.lowerBound == range.upperBound ? "\(range.lowerBound)" : "\(range.lowerBound)~\(range.upperBound)"}
            var rows = options.map { option -> CanvasSheet.Row in
                let name:String,cost:String
                switch option.action {
                case .strategy(let id):name = strategyTitle(id);cost = "MP \(option.cost)"
                case .item(let id):name = itemName(id);cost = "도구 1개 소모"
                }
                let point = option.origins[0]
                var facts:[(String,String)] = [("시전자",(try? snapshot.unit(option.caster).name) ?? ""),("비용",cost),
                    ("병력 변화",quantity(option.troops)),("사기 변화",quantity(option.morale)),
                    ("도착점","(\(point.x+1), \(point.y+1)) · 가능한 위치 \(option.origins.count)곳")]
                if let chance = option.conditionChance {facts.append(("혼란 해제","약 \(quantity(chance))% · 사기 회복 시 판정"))}
                return .init(label:((try? snapshot.unit(option.caster).name) ?? "")+" · "+name,value:cost,
                    detail:.init(heading:name,body:"현재 공개 배치에서 이번 턴 사용할 수 있는 수단입니다. 최소 이동 비용 위치를 먼저 안내합니다.\n위치 안내를 누른 뒤 이동과 명령을 직접 확인하세요. 병력의 음수 변화는 원본 상한 조정입니다.",facts:facts))
            }
            if rows.isEmpty {rows = [.init(label:"지금 사용할 수 있는 회복 수단 없음",detail:.init(heading:"현재 조건",body:"대상이 회복되어 있거나, 이번 턴 행동 가능한 장수의 MP·소지품·사거리가 부족할 수 있습니다. 보호한 도구는 제외합니다. 장수별 사용 조건과 상태 안내에서 확인할 수 있습니다."))]}
            let index = min(max(0,row),rows.count-1)
            overlay.show(CanvasSheet(portrait:nil,speaker:personName(recipient.person)+" · 회복 방법",line:"병력·사기·혼란 회복 수단 · 현재 상태 기준",badge:("후보","\(options.count)개"),rows:rows,
                selected:index,mode:.list,buttons:options.isEmpty ? [] : ["최소 이동 위치 안내","가능한 위치 모두 보기"],hint:"↑↓ 비교 · Enter 상세 · Tab 위치 안내 · Esc 닫기",fullCanvas:true,onRowButton:{ [weak self] button,index in
                    guard let self,options.indices.contains(index) else {return}
                    let option = options[index]
                    guard (try? BattleProjection(self.session).key) == snapshot.key else {self.openRecoveryFinder(target);return}
                    if button == 1 {self.openRecoveryOrigins(option,key:snapshot.key,returnRow:index)}
                    else {self.guideRecovery(option,at:option.origins[0],key:snapshot.key,returnRow:index)}
                }) { [weak self] chosen in if let chosen {self?.openRecoveryFinder(target,selected:chosen)} })
        } catch {report(error)}
    }
    private func objectiveEntries() -> [BattleObjectiveTracker.Entry] {
        guard let text = objective?().text,!text.isEmpty else {return []}
        return BattleObjectiveTracker.entries(session:session,publicText:text,conditions:objectiveProgress?() ?? [])
    }
    private func openObjectiveProgress() {
        let entries = objectiveEntries(),remaining = max(0,session.header.turnLimit-session.turns.roundIndex)
        let rows = entries.map {entry in CanvasSheet.Row(label:entry.state.rawValue,detail:.init(heading:"현재 공개 목표",body:entry.text,
            facts:[("근거",entry.sourceReference),("판정 범위","검토된 완료 사건이 실제 반환된 기록만 확인합니다. 단순 조건 일치나 적 부대의 부재로 승리를 추정하지 않습니다.")]))}
        overlay.show(CanvasSheet(portrait:nil,speaker:"현재 목표 진행",line:"현재 턴 포함 \(remaining)턴 남음",badge:("턴","\(session.turns.roundIndex+1)/\(session.header.turnLimit)"),rows:rows,
            mode:.list,buttons:["공개 목표 위치","승리조건 원문"],hint:"목표 위치는 현재 공개되어 있는 대상만 안내합니다",fullCanvas:true,onRowButton:{ [weak self] button,row in
                guard let self else {return}
                if button == 1 {self.showConditions(opening:false);return}
                guard entries.indices.contains(row),let point = entries[row].target else {self.notice("현재 공개된 목표 위치를 확인할 수 없습니다.");return}
                self.camera.center(on:point);self.needsDisplay = true
            }) {_ in })
    }
    private func openAreaAdvice(_ slot:Int,ability:Int? = nil,selected row:Int = 0) {
        guard canInput,let caster = session.units[slot],!caster.enemy else {return}
        guard caster.scriptFlags&0x20 != 0,OriginalBattleCommand.denial(caster) == nil else {notice("현재 명령 가능한 공개 아군을 선택해 주세요. 매복·혼란·행동 완료 상태에서는 범위 책략 위치를 안내하지 않습니다.");return}
        do {
            let snapshot = try BattleProjection(session)
            guard let ability else {
                let choices = try snapshot.availableStrategies(slot).filter(BattleProjection.isAreaStrategy)
                guard !choices.isEmpty else {notice("현재 배운 범위 책략 중 사용 가능한 것이 없습니다. 책략 습득표와 현재 사용 조건에서 레벨·MP·날씨를 확인하세요.");return}
                overlay.show(CanvasMenu(title:"범위 책략 위치 추천",options:choices.map {.init(label:strategyTitle($0),value:"MP \(session.movement.strategyMPCosts?[$0] ?? 0)")},cancellable:true) { [weak self] index in
                    if let index {self?.openAreaAdvice(slot,ability:choices[index])}
                });return
            }
            let search = try snapshot.areaAdvice(slot,ability:ability),candidates = Array(search.candidates.prefix(40))
            var rows = try candidates.map { candidate -> CanvasSheet.Row in
                var facts:[(String,String)] = [("시전자 위치","(\(candidate.origin.x+1), \(candidate.origin.y+1)) · 이동 비용 \(candidate.movementCost)"),
                    ("중심 대상",try candidate.center.map {try snapshot.unit($0).name} ?? "시전자 중심"),("MP 비용","\(snapshot.movement.strategyMPCosts?[ability] ?? 0)"),
                    ("유효 대상","\(candidate.usefulTargets)개 · 표시된 부대만")]
                for (index,target) in candidate.targets.enumerated() {
                    let detail = effectText(candidate.effects[index])+(candidate.effects[index].facts.last(where:{$0.label == "순차 시전자 레벨"}).map {" · 시전자 Lv"+$0.value} ?? "")
                    facts.append((try snapshot.unit(target).name,detail))
                }
                if candidate.limitation == nil {facts.append(("실패 포함 전체 병력 효과","\(candidate.troops.lowerBound)~\(candidate.troops.upperBound)"))}
                facts.append(("계산 분기","\(candidate.assessment.branches)개 · 순차 레벨·병력·사기 반영"))
                let boundary = candidate.limitation ?? "대상별 성공 시 효과와 단일 판정 확률을 표시합니다. 연속 난수의 조합 확률은 추정하지 않습니다. 전체 범위는 실패를 포함한 보수적 결과입니다."
                return .init(label:"(\(candidate.origin.x+1), \(candidate.origin.y+1)) · \(candidate.usefulTargets)개 대상",value:"이동 \(candidate.movementCost)",
                    detail:.init(heading:strategyTitle(ability),body:boundary,facts:facts))
            }
            if rows.isEmpty {rows = [.init(label:"현재 공개된 배치에서 유효한 후보 없음",detail:.init(heading:"현재 조건",body:"현재 이동·점유·지형·날씨·회복 상한으로 찾은 결과입니다. 숨겨진 부대는 계산하지 않으며 실제 이동 시 조건을 다시 확인합니다."))]}
            overlay.show(CanvasSheet(portrait:nil,speaker:"범위 책략 위치 추천",line:"\(search.examined)개 조합 확인 · 상위 \(candidates.count)개 표시"+(search.limited ? " · 탐색 한도 도달" : ""),badge:("책략",strategyTitle(ability)),rows:rows,
                selected:min(max(0,row),rows.count-1),mode:.list,buttons:candidates.isEmpty ? [] : ["이 위치 안내"],hint:"추천 선택은 이동·책략을 실행하지 않습니다 · Esc 닫기",fullCanvas:true,
                onRowButton:{ [weak self] _,index in
                    guard let self,candidates.indices.contains(index) else {return}
                    guard (try? BattleProjection(self.session).key) == snapshot.key else {self.openAreaAdvice(slot,ability:ability);return}
                    let candidate = candidates[index]
                    self.guidePlannedOrigin(slot,point:candidate.origin,ability:ability,label:"범위 책략 추천")
                    self.assistedArea = (snapshot.key,slot,candidate.origin,candidate.targets)
                }) { [weak self] chosen in if let chosen {self?.openAreaAdvice(slot,ability:ability,selected:chosen)} })
        } catch {report(error)}
    }
    private func cooperationActionName(_ action:BattleProjection.PlannedAction)->String {
        switch action {case .attack:return "일반 공격";case .strategy(let ability):return strategyTitle(ability)}
    }
    private func cooperationFacts(_ candidate:BattleProjection.CooperativeCandidate,_ snapshot:BattleProjection) throws -> [(String,String)] {
        var facts = try candidate.steps.enumerated().map {index,step -> (String,String) in
            ("\(index+1). "+(try snapshot.unit(step.actor).name),cooperationActionName(step.action)+" · (\(step.origin.x+1), \(step.origin.y+1)) · 이동 \(step.movementCost) · 피해 \(step.damageRange.lowerBound)~\(step.damageRange.upperBound)")
        }
        facts.append(("대상 잔여 병력","\(candidate.remaining.lowerBound)~\(candidate.remaining.upperBound)"))
        facts.append(("아군 반격 피해 합계","\(candidate.counterLoss.lowerBound)~\(candidate.counterLoss.upperBound)"))
        facts.append(("분기","\(candidate.branches)개"+(candidate.exhaustive ? "" : " · 한도 도달, 결과 미확정")))
        for boundary in candidate.boundaries {facts.append(("계산 경계",boundary))};return facts
    }
    private func openCooperation(_ target:Int,selected row:Int = 0) {
        guard canInput,let unit = session.units[target],unit.enemy,unit.status == 2,unit.scriptFlags&0x20 != 0 else {return}
        do {
            let snapshot = try BattleProjection(session),search = try snapshot.cooperation(target:target)
            let candidates = Array(search.candidates.prefix(40))
            var rows = try candidates.map {candidate -> CanvasSheet.Row in
                let names = try candidate.steps.map {try snapshot.unit($0.actor).name}.joined(separator:" → ")
                return .init(label:names,value:candidate.guaranteed ? "전 분기 병력 0" : "잔여 \(candidate.remaining.lowerBound)~\(candidate.remaining.upperBound)",
                    detail:.init(heading:candidate.condition,body:search.limitation,facts:try cooperationFacts(candidate,snapshot)))
            }
            if rows.isEmpty {rows = [.init(label:"확인한 범위에서 행동 후보 없음",detail:.init(heading:"계산 범위",body:search.limitation))]}
            overlay.show(CanvasSheet(portrait:nil,speaker:"제한된 협공 계산",line:"공격·책략 최대 두 행동 · \(search.examined)개 조합"+(search.limited ? " · 탐색 한도 도달" : ""),badge:("대상",try snapshot.unit(target).name),rows:rows,
                selected:min(max(0,row),rows.count-1),mode:.list,buttons:candidates.isEmpty ? [] : ["첫 부대 위치 안내","순서 뒤집어 비교"],hint:"안내만 하며 이동·공격을 실행하지 않습니다 · Esc 닫기",fullCanvas:true,
                onRowButton:{ [weak self] button,index in
                    guard let self,candidates.indices.contains(index),let first = candidates[index].steps.first else {return}
                    guard (try? BattleProjection(self.session).key) == snapshot.key else {self.openCooperation(target);return}
                    if button == 1 {
                        do {
                            let plan = candidates[index].steps.reversed().map {BattleProjection.PlannedStep(actor:$0.actor,origin:$0.origin,action:$0.action,target:target)}
                            let reversed = try snapshot.evaluateCooperation(plan,target:target)
                            self.overlay.show(CanvasSheet(portrait:nil,speaker:"협공 순서 비교",line:reversed.condition,badge:("순서","역순"),rows:[.init(label:"역순 계산 결과",detail:.init(heading:reversed.condition,body:search.limitation,facts:try self.cooperationFacts(reversed,snapshot)))],mode:.list,fullCanvas:true) { [weak self] _ in self?.openCooperation(target,selected:index) })
                        } catch {self.report(error)}
                    } else {
                        let ability:Int?;if case .strategy(let value) = first.action {ability = value} else {ability = nil}
                        self.guidePlannedOrigin(first.actor,point:first.origin,ability:ability,label:"협공 첫 부대")
                    }
                }) { [weak self] chosen in if let chosen {self?.openCooperation(target,selected:chosen)} })
        } catch {report(error)}
    }
    private func guidePlannedOrigin(_ slot:Int,point:GridPoint,ability:Int?,label:String) {
        guard !session.pendingMovementSlots.contains(where:{$0 != slot}) else {notice("다른 부대의 이동을 먼저 취소하거나 명령을 완료해 주세요.");return}
        guard let unit = session.units[slot],point == unit.position || ((try? BattleAssistance.movement(in:session,slot:slot,to:point)).map {$0.reason == nil} == true) else {
            notice("현재 조건에서는 이 위치를 안내할 수 없습니다. 전장 상태를 다시 확인해 주세요.");return
        }
        selectReadyUnit(slot);hoveredCell = point;previewAbility = ability;camera.center(on:point)
        message = "\(label) (\(point.x+1), \(point.y+1)) · 이동과 대상을 직접 확인해 주세요.";needsDisplay = true
    }
    private func openRecoveryOrigins(_ option:BattleProjection.RecoveryOption,key:BattleProjection.Key,returnRow:Int) {
        let rows = option.origins.enumerated().map { index,point in
            CanvasSheet.Row(label:"(\(point.x+1), \(point.y+1))"+(index == 0 ? " · 최소 이동 비용" : ""),
                detail:.init(heading:"회복 가능한 도착 위치",body:"현재 공개 배치에서 계산한 위치입니다. 선택은 위치를 안내하며 실제 이동이나 회복을 실행하지 않습니다. 실제 이동 전에 현재 점유와 행동 조건을 다시 검사합니다."))
        }
        overlay.show(CanvasSheet(portrait:nil,speaker:"회복 도착 위치",line:"이동 비용이 적은 위치부터 · 같은 비용은 지도 좌표 순서",badge:("가능 위치","\(rows.count)곳"),rows:rows,
            mode:.list,hint:"↑↓ 위치 읽기 · Enter 지도 안내 · Esc 후보 비교",fullCanvas:true) { [weak self] chosen in
                guard let self else {return}
                guard let chosen,option.origins.indices.contains(chosen) else {self.openRecoveryFinder(option.target,selected:returnRow);return}
                self.guideRecovery(option,at:option.origins[chosen],key:key,returnRow:returnRow)
            })
    }
    private func guideRecovery(_ option:BattleProjection.RecoveryOption,at point:GridPoint,key:BattleProjection.Key,returnRow:Int) {
        guard (try? BattleProjection(session).key) == key else {openRecoveryFinder(option.target);return}
        if session.pendingMovementSlots.contains(where:{$0 != option.caster}) {
            say("다른 부대의 이동을 먼저 취소하거나 명령을 완료한 뒤 위치를 안내할 수 있습니다.") { [weak self] in self?.openRecoveryFinder(option.target,selected:returnRow) };return
        }
        selectReadyUnit(option.caster);hoveredCell = point
        if case .strategy(let ability) = option.action {previewAbility = ability}
        message = "회복 위치 (\(point.x+1), \(point.y+1)) 안내 · 이동과 회복 대상을 직접 확인하세요."
        needsDisplay = true
    }
    private func openDamageDetails(_ slot:Int,target:Int) {
        do {
            let snapshot = try BattleProjection(session),impact = try snapshot.physical(slot,target:target)
            let defender = try snapshot.unit(target),terrain = Int(snapshot.key.terrain[defender.live.position.y*snapshot.key.width+defender.live.position.x])
            let facts:[(String,String)] = [("공격력","\(impact.attack)"),("기본 방어력","\(impact.defense)"),
                ("병과 상성 적용 방어력","\(impact.adjustedDefense)"),("지형 방어","\(session.combat.terrainDefensePercent[terrain])%"),
                ("최종 병력 피해","\(impact.damage)"),("대상 잔여 병력","\(impact.remainingTroops)"),("사기 손실","\(impact.moraleLoss)")]
            overlay.show(CanvasSheet(portrait:nil,speaker:"일반 공격 피해 근거",line:personName(session.units[slot]?.person ?? -1)+" → "+defender.name,
                badge:("공격 피해","\(impact.damage)"),rows:[.init(label:"현재 수치와 적용 순서",detail:.init(heading:"일반 공격",body:"장비 최대 보너스가 적용된 공격·방어력 → 병과 상성 → 지형 방어 → 공격 유형 → 대상 병력 상한 순서입니다.\n반격과 퇴각 후 이벤트는 별도이며 이 수치에 합산하지 않습니다. 다음 RNG 결과는 조회하지 않습니다.",facts:facts))],
                mode:.list,hint:"Esc 닫기 · 피해 근거 조회는 행동을 소모하지 않습니다",fullCanvas:true) {_ in })
        } catch {report(error)}
    }
    private func projectedEffect(_ slot:Int,ability:Int,target:Int)->BattleProjection.Effect? {
        guard let snapshot = try? BattleProjection(session) else {return nil}
        if effectCache?.key != snapshot.key {effectCache = (snapshot.key,[:])}
        let id = (slot*36+ability)*45+target
        if let cached = effectCache?.values[id] {return cached}
        guard let effect = try? snapshot.strategyEffect(slot,ability:ability,target:target) else {return nil}
        effectCache?.values[id] = effect;return effect
    }
    private func effectText(_ effect:BattleProjection.Effect)->String {
        func range(_ value:ClosedRange<Int>)->String {value.lowerBound == value.upperBound ? "\(value.lowerBound)" : "\(value.lowerBound)~\(value.upperBound)"}
        let chance = effect.successPercentRange.map {String(format:" · 성공 %.1f~%.1f%%",$0.lowerBound,$0.upperBound)} ?? effect.successPercent.map {String(format:" · 성공 %.1f%%",$0)} ?? ""
        switch effect.kind {
        case .damage:return "성공 시 -"+range(effect.troops)+chance
        case .confusion:return "혼란"+chance
        case .morale:return "성공 시 사기 -"+range(effect.morale)+chance
        case .healing:
            var parts:[String] = []
            if effect.troops != 0...0 {parts.append((effect.troops.lowerBound < 0 ? "병력 조정 " : "병력 +")+range(effect.troops))}
            if effect.morale != 0...0 {parts.append("사기 +"+range(effect.morale))}
            if let chance = effect.conditionPercent {
                parts.append(chance.lowerBound == chance.upperBound ? String(format:"혼란 해제 %.1f%%",chance.lowerBound) : String(format:"혼란 해제 %.1f~%.1f%%",chance.lowerBound,chance.upperBound))
            }
            return parts.isEmpty ? "회복량 0" : parts.joined(separator:" · ")
        }
    }
    private func openStrategyEffectDetails(_ slot:Int,ability:Int,target:Int) {
        guard let effect = projectedEffect(slot,ability:ability,target:target) else {return}
        overlay.show(CanvasSheet(portrait:nil,speaker:strategyTitle(ability)+" · 효과 근거",line:effectText(effect),badge:("MP","\(session.movement.strategyMPCosts?[ability] ?? 0)"),
            rows:[.init(label:"대상별 수치와 판정",detail:.init(heading:strategyTitle(ability),body:"성공 시 효과와 성공 확률을 구분합니다. 확률은 원본 난수 분포 기준이며 현재 다음 난수 결과를 읽지 않습니다.\n현재 한 대상 기준입니다. 퇴각 후 이벤트가 주변 배치를 바꾸는 후속 효과는 확정하지 않습니다.",facts:effect.facts.map {($0.label,$0.value)}))],
            mode:.list,hint:"Esc 닫기 · 원래 대상 선택을 유지합니다",fullCanvas:true) {_ in })
    }
    private func openGrowthForecast(_ slot:Int,target:Int?,ability:Int?,selected row:Int = 0) {
        do {
            let snapshot = try BattleProjection(session),attacker = try snapshot.unit(slot)
            let forecast = try snapshot.growth(slot,target:target,ability:ability,names:(0..<36).map(strategyTitle))
            var rows = forecast.branches.map { branch -> CanvasSheet.Row in
                let next = branch.nextStrategies.isEmpty ? "현재 병과의 추가 습득 없음" : branch.nextStrategies.map {"\($0.name) Lv.\($0.requiredLevel) (\($0.remainingLevels)레벨 남음)"}.joined(separator:" · ")
                let ignored = branch.ignoredReason == nil ? "" : "\n원본 NPC/레벨 상한 규칙에 따라 경험치가 적용되지 않습니다."
                return .init(label:branch.condition,value:branch.ignoredReason == nil ? "EXP +\(branch.total)" : "EXP 적용 없음",
                    detail:.init(heading:branch.condition,body:(forecast.limitation ?? "")+ignored,
                        facts:[("기본 효과 보상","\(branch.hit)"),("격파 보상","\(branch.defeated)"),("책략 완료 보상","\(branch.completion)"),
                            ("레벨","\(attacker.stats.level) → \(branch.level)"),("경험치","\(attacker.experience) → \(branch.experience)"),("다음 책략",next)]))
            }
            if rows.isEmpty {rows = [.init(label:"현재 행동 보상 계산 불가",detail:.init(heading:"조건 확인",body:forecast.limitation ?? "대상과 행동을 먼저 선택하세요."))]}
            overlay.show(CanvasSheet(portrait:nil,speaker:attacker.name+" · 성장 예측",line:"실행 전 조건별 경험치와 다음 습득 · 실제 상태는 그대로 유지",badge:("현재","Lv.\(attacker.stats.level) EXP \(attacker.experience)"),rows:rows,
                selected:min(max(0,row),rows.count-1),mode:.list,buttons:["책략 습득표"],hint:"↑↓ 조건 읽기 · Tab 습득표 · Esc 대상 선택으로",fullCanvas:true,onRowButton:{ [weak self] _,row in
                    self?.openStrategyGuide(slot) { [weak self] in self?.openGrowthForecast(slot,target:target,ability:ability,selected:row) }
                }) { [weak self] chosen in if let chosen {self?.openGrowthForecast(slot,target:target,ability:ability,selected:chosen)} })
        } catch {report(error)}
    }
    /// MAIN27DC4..27E7B and 27774. A pick takes effect at once.
    private func openSetting(_ action:String) {
        guard let texts = settingsTexts else { return }
        var settings = OriginalSettings.current
        let labels:[String],current:Int,apply:(Int) -> Void
        switch action {
        case "unit-combat":
            let modes = CombatPresentationPolicy.Mode.allCases
            labels = modes.map(\.label);current = modes.firstIndex(of:settings.combatPresentationMode) ?? 0;apply = {settings.combatPresentationMode = modes[$0]}
        case "move-speed":labels = texts.moveSpeed;current = settings.moveSpeed;apply = { settings.moveSpeed = $0 }
        case "enemy-move":labels = texts.show;current = settings.enemyMove ? 0 : 1;apply = { settings.enemyMove = $0 == 0 }
        case "battle-pace":
            labels = OriginalSettings.battlePaceRates.map { $0 == 1 ? "보통" : String(format:$0 == $0.rounded() ? "%.0f배" : "%.1f배",$0) }
            current = settings.battlePace;apply = { settings.battlePace = $0 }
        case "bgm":labels = texts.onOff;current = OriginalAudio.musicEnabled ? 0 : 1;apply = { OriginalAudio.musicEnabled = $0 == 0 }
        default:labels = texts.onOff;current = OriginalAudio.effectsEnabled ? 0 : 1;apply = { OriginalAudio.effectsEnabled = $0 == 0 }
        }
        overlay.show(CanvasMenu(title:"",options:labels.enumerated().map { .init(label:$0.element,checked:$0.offset == current) },selected:current,cancellable:true) { [weak self] index in
            guard let self = self,let index = index else { return }
            apply(index);OriginalSettings.current = settings
            self.applySourcePresentationSetting(action,settings:settings);self.needsDisplay = true
        })
    }
    private func refusal(_ key:String) -> String { style.commands?.messages[key] ?? key }
    private func filled(_ key:String,_ value:String) -> String { refusal(key).replacingOccurrences(of:"%s",with:value) }
    private func resetCommand() { phase = .idle;selected = nil;strategySelection = nil;previewSlot = nil;previewAbility = nil;movePreviewCache = nil }
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
        let shown = unit.scriptFlags&0x20 != 0
        let labels = shown ? (style.commands?.labels ?? ["Attack","Strategy","Item","Wait"]) : (style.commands?.ambush ?? ["Strike","Release"])
        let actions = shown ? ["attack","strategy","item","wait"] : ["strike","release"]
        var options = labels.enumerated().map { CanvasMenu.Option(label:$0.element,icon:actions.indices.contains($0.offset) ? icon(actions[$0.offset]) : nil) }
        options.append(CanvasMenu.Option(label:"책략 습득표",icon:icon("learning-guide"),separatorBefore:true))
        options.append(CanvasMenu.Option(label:"상태 안내",icon:icon("unit-status")))
        guard let favoriteCommands,onFavoriteCommandsChanged != nil else {
            return CanvasMenu(title:"",options:options,cancellable:true,anchor:windowOrigin(slot,depth:0),onChoose:choose)
        }
        let favorites = shown ? favoriteCommands(unit.person) : []
        let quick = favorites.map { action -> CanvasMenu.Option in
            let reasons = favoriteReasons(action,slot:slot)
            return .init(label:"★ "+favoriteName(action),enabled:reasons.isEmpty,help:reasons.isEmpty ? "기존 대상 선택·확인 화면으로 이동합니다." : reasons.joined(separator:" · "))
        }
        let originalCount = options.count
        options = quick+options+[.init(label:"즐겨찾기 관리",separatorBefore:true)]
        return CanvasMenu(title:"",options:options,cancellable:true,anchor:windowOrigin(slot,depth:0)) { [weak self] row in
            guard let self else {return}
            guard let row else {choose(nil);return}
            if row < favorites.count {self.runFavorite(favorites[row],slot:slot)}
            else if row == favorites.count+originalCount {self.openFavoriteManagement(slot)}
            else {choose(row-favorites.count)}
        }
    }
    private func favoriteName(_ action:BattleFavoriteAction)->String {
        if favoriteCommandsSourceIssue?() != nil {
            switch action {case .strategy(let id):return "이전 자료 책략 #\(id)";case .item(let id):return "이전 자료 도구 #\(id)"}
        }
        switch action {case .strategy(let id):return strategyTitle(id);case .item(let id):return itemName(id)}
    }
    private func favoriteReasons(_ action:BattleFavoriteAction,slot:Int)->[String] {
        if let issue = favoriteCommandsSourceIssue?() {return [issue]}
        var reasons = (try? OfficerCommandFavorites.reasons(action,in:session,slot:slot)) ?? ["현재 부대 상태 확인 불가"]
        if case .item(let id) = action,let person = session.units[slot]?.person,let refusal = onItemUseRefusal?(person,id) {reasons.append(refusal)}
        return reasons
    }
    private func runFavorite(_ action:BattleFavoriteAction,slot:Int) {
        let reasons = favoriteReasons(action,slot:slot)
        guard canInput,reasons.isEmpty else {say(reasons.joined(separator:" · ")) { [weak self] in self?.openCommand(slot) };return}
        do {
            switch action {
            case .strategy(let ability):selectStrategy(ability,slot)
            case .item(let id):try beginItemUse(slot,item:id)
            }
        } catch {report(error);openCommand(slot)}
    }
    private func openFavoriteManagement(_ slot:Int,selected row:Int = 0) {
        guard canInput,let unit = session.units[slot],!unit.enemy,let getter = favoriteCommands,let setter = onFavoriteCommandsChanged,
              let person = try? session.people.person(unit.person) else {return}
        let favorites = getter(unit.person)
        if let issue = favoriteCommandsSourceIssue?() {
            var rows = favorites.enumerated().map {index,action in CanvasSheet.Row(label:favoriteName(action),value:"\(index+1)번",detail:.init(heading:"다른 자료의 즐겨찾기",body:issue+"\n기존 항목을 보존했습니다. 실행·추가·정렬은 잠겼습니다."))}
            if rows.isEmpty {rows = [.init(label:"현재 장수의 기존 항목 없음",detail:.init(heading:"자료 확인 필요",body:issue))]}
            overlay.show(CanvasSheet(portrait:nil,speaker:"즐겨찾기 자료 확인",line:issue,badge:("사용","잠김"),rows:rows,
                selected:min(max(0,row),rows.count-1),mode:.list,buttons:onResetFavoriteSource == nil ? [] : ["현재 자료로 초기화"],fullCanvas:true,onRowButton:{ [weak self] _,_ in
                    guard let self else {return}
                    self.yesNo("모든 장수의 기존 즐겨찾기를 비우고 현재 자료로 새로 시작할까요?") { [weak self] yes in
                        guard let self else {return};if yes {self.onResetFavoriteSource?()};self.openFavoriteManagement(slot)
                    }
                }) { [weak self] index in if let index {self?.openFavoriteManagement(slot,selected:index)} else {self?.openCommand(slot)} })
            return
        }
        var choices = favorites
        if let levels = session.movement.strategyLevelRequirements,levels.count == 36 {
            for id in 0..<36 where levels[id].indices.contains(person.classID) && levels[id][person.classID] <= 99 {
                let action = BattleFavoriteAction.strategy(id)
                if !choices.contains(action) {choices.append(action)}
            }
        }
        for item in Set(person.itemIDs).sorted() where item != 255 {
            let action = BattleFavoriteAction.item(item)
            if !choices.contains(action) {choices.append(action)}
        }
        var rows = choices.map { action -> CanvasSheet.Row in
            let reasons = favoriteReasons(action,slot:slot),registered = favorites.firstIndex(of:action)
            return .init(label:(registered == nil ? "" : "★ ")+favoriteName(action),value:registered.map {"\($0+1)번"} ?? "미등록",
                detail:.init(heading:favoriteName(action),body:reasons.isEmpty ? "지금 사용할 수 있습니다. 즐겨찾기 실행도 기존 대상 선택·확인을 거칩니다." : reasons.joined(separator:"\n"),
                    facts:[("장수",person.name),("등록 수","\(favorites.count) / 16"),("관리","등록·정렬은 행동·소지품·책략치를 소모하지 않습니다.")]))
        }
        if rows.isEmpty {rows = [.init(label:"등록할 책략이나 소지품 없음")]}
        let index = min(max(0,row),rows.count-1)
        overlay.show(CanvasSheet(portrait:nil,speaker:person.name+" · 즐겨찾기",line:"장수별로 저장 · ★ 순서대로 명령창 상단에 표시",badge:("등록","\(favorites.count)/16"),rows:rows,
            selected:index,mode:.list,buttons:choices.isEmpty ? [] : ["등록 / 해제","위로","아래로"],hint:"↑↓ 이유 읽기 · Tab 관리 버튼 · Esc 명령창",fullCanvas:true,onRowButton:{ [weak self] button,row in
                guard let self,choices.indices.contains(row) else {return}
                guard self.favoriteCommandsSourceIssue?() == nil else {self.openFavoriteManagement(slot,selected:row);return}
                let action = choices[row];var changed = getter(unit.person)
                if button == 0 {
                    if changed.contains(action) {changed.removeAll {$0 == action}}
                    else if changed.count < 16 {changed.append(action)}
                    else {self.say("장수별 즐겨찾기는 16개까지 등록할 수 있습니다.") { [weak self] in self?.openFavoriteManagement(slot,selected:row) };return}
                } else if let index = changed.firstIndex(of:action) {
                    let destination = index+(button == 1 ? -1 : 1)
                    if changed.indices.contains(destination) {changed.swapAt(index,destination)}
                }
                do {try setter(unit.person,changed);self.openFavoriteManagement(slot,selected:changed.firstIndex(of:action) ?? row)}
                catch {self.report(error);self.openFavoriteManagement(slot,selected:row)}
            }) { [weak self] chosen in
                if let chosen {self?.openFavoriteManagement(slot,selected:chosen)} else {self?.openCommand(slot)}
            })
    }
    private func openCommand(_ slot:Int) {
        guard presentation != .modern || mapViewMode != .overview else {return}
        updateCamera()
        guard let unit = session.units[slot],unit.status == 2 else { resetCommand();return }
        selected = slot;phase = .command(slot);inspected = nil;strategySelection = nil
        let hidden = unit.scriptFlags&0x20 == 0
        guard let menu = commandMenu(slot,{ [weak self] index in
            guard let self = self else { return }
            guard let index = index else { self.cancelCommand(slot);return }
            do { if hidden { try self.runAmbushCommand(index,slot) } else { try self.runCommand(index,slot) } }
            catch { self.report(error);self.openCommand(slot) }
            self.needsDisplay = true
        }) else { return }
        overlay.show(menu)
    }
    /// MAIN2DE08..2DE1D clears moved40 and returns the unit to its origin.
    private func cancelCommand(_ slot:Int) {
        do { try cancelRecordedMove(slot) } catch { report(error) }
        resetCommand();needsDisplay = true
    }
    private func cancelRecordedMove(_ slot:Int) throws {
        let pending = session.pendingMovementSlots.contains(slot)
        try session.cancelMove(slot)
        if pending,!session.pendingMovementSlots.contains(slot) {acceptedInput(.init(kind:.battleCancelMove,slot:slot));recordingBoundaryIfReady()}
    }
    private func runCommand(_ index:Int,_ slot:Int) throws {
        switch index {
        case 0: try beginAttack(slot)
        case 1: try openStrategies(slot)
        case 2: openItems(slot)
        case 4: openStrategyGuide(slot) { [weak self] in self?.openCommand(slot) }
        case 5: openConditionDetails(slot) { [weak self] in self?.openCommand(slot) }
        default:
            guard canInput else { return }
            try flow.manualWait(slot);resetCommand();message = "대기했습니다."
            _ = drainHeldCues();checkAutoTurnEndPrompt()
        }
    }
    private func runAmbushCommand(_ index:Int,_ slot:Int) throws {
        if index == 2 { openStrategyGuide(slot) { [weak self] in self?.openCommand(slot) };return }
        if index == 3 { openConditionDetails(slot) { [weak self] in self?.openCommand(slot) };return }
        if index == 0 { try beginAttack(slot);return }
        yesNo(refusal("releaseAmbush")) { [weak self] yes in
            guard let self = self else { return }
            if yes {
                do { try self.flow.manualReleaseAmbush(slot) } catch { self.report(error) }
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
            var text = refusal("noStrategy")
            if presentation == .modern {
                let future = levels.enumerated().compactMap { ability,requirements -> (ability:Int,level:Int)? in
                    guard person.classID != 17,requirements.indices.contains(person.classID) else { return nil }
                    let level = requirements[person.classID]
                    return level > person.level && level <= 99 ? (ability,level) : nil
                }
                text = "\(person.name) · Lv.\(person.level)\n아직 습득한 책략이 없습니다."
                if let nextLevel = future.map(\.level).min() {
                    let names = future.filter { $0.level == nextLevel }.map { strategyTitle($0.ability) }.joined(separator:" · ")
                    text += "\n다음 습득: \(names) · Lv.\(nextLevel)"
                } else {
                    text += "\n현재 병과에서 배울 수 있는 책략이 없습니다."
                }
            }
            say(text) { [weak self] in self?.openCommand(slot) }
            return
        }
        var options = rows.map { row -> CanvasMenu.Option in
            let reasons = BattleAssistance.strategyReasons(ability:row.ability,cost:row.cost,mp:unit.mp,rain:rain).map(\.text)
            return .init(label:strategyTitle(row.ability)+(reasons.isEmpty ? "" : " · "+reasons.joined(separator:" · ")),
                enabled:row.enabled,value:"MP\(row.cost)",help:"현재 MP \(unit.mp) · 필요 MP \(row.cost)")
        }
        options.append(CanvasMenu.Option(label:"현재 사용 조건 자세히",icon:icon("unit-status"),separatorBefore:true))
        options.append(CanvasMenu.Option(label:"전체 책략 습득표",icon:icon("learning-guide")))
        overlay.show(CanvasMenu(title:"",options:options,cancellable:true,anchor:windowOrigin(slot,depth:1)) { [weak self] index in
            guard let self = self else { return }
            guard let index = index else { self.openCommand(slot);return }
            if index == rows.count {
                self.openStrategyAvailability(slot);return
            }
            if index == rows.count+1 {
                self.openStrategyGuide(slot) { [weak self] in
                    guard let self = self else { return }
                    do { try self.openStrategies(slot) } catch { self.report(error);self.openCommand(slot) }
                }
                return
            }
            self.selectStrategy(rows[index].ability,slot);self.needsDisplay = true
        },behind:[commandMenu(slot) { _ in }].compactMap { $0 })
    }
    /// Disabled execution rows remain readable with the keyboard in this
    /// separate sheet. Enter reads a row; it never executes the ability.
    private func openStrategyAvailability(_ slot:Int,selected index:Int = 0) {
        guard canInput,let unit = session.units[slot],let person = try? session.people.person(unit.person),
              let levels = session.movement.strategyLevelRequirements,let costs = session.movement.strategyMPCosts else {return}
        let rain = session.combat.strategyEnvironmentLookup[Int(session.turns.weatherIndex)] == 2
        let abilities = OriginalBattleCommand.strategyRows(classID:person.classID,level:person.level,mp:unit.mp,rain:rain,levels:levels,costs:costs)
        var rows = abilities.map { row -> CanvasSheet.Row in
            let reasons = BattleAssistance.strategyReasons(ability:row.ability,cost:row.cost,mp:unit.mp,rain:rain).map(\.text)
            return .init(label:strategyTitle(row.ability),value:reasons.isEmpty ? "사용 조건 충족" : "사용 불가",warns:!reasons.isEmpty,
                detail:.init(heading:strategyTitle(row.ability),body:reasons.isEmpty ? "현재 MP와 날씨 조건을 충족합니다.\n실제 대상의 사거리·지형·회복 필요 여부는 대상 선택 때 다시 확인합니다." : reasons.joined(separator:"\n"),
                    facts:[("현재 MP","\(unit.mp)"),("필요 MP","\(row.cost)"),("날씨",rain ? "비" : "화계 사용 제한 없음")]))
        }
        if rows.isEmpty {rows = [.init(label:"현재 습득한 책략 없음",detail:.init(heading:"책략 사용 조건",body:"앞으로 배울 책략은 전체 책략 습득표에서 확인하세요."))]}
        overlay.show(CanvasSheet(portrait:nil,speaker:person.name+" · 책략 사용 조건",line:"회색 책략도 여기에서 이유를 읽을 수 있습니다.",badge:("현재 MP","\(unit.mp)"),rows:rows,
            selected:min(max(0,index),rows.count-1),mode:.list,hint:"↑↓ 읽기 · Esc 책략 목록 · 여기에서는 책략을 실행하지 않습니다",fullCanvas:true) { [weak self] chosen in
                guard let self else {return}
                if let chosen {self.openStrategyAvailability(slot,selected:chosen)}
                else {do {try self.openStrategies(slot)} catch {self.report(error);self.openCommand(slot)}}
            })
    }
    /// Read-only engine guide; future rows never enter the strategy executor.
    private func openStrategyGuide(_ slot:Int,selected row:Int = 0,onClose:@escaping () -> Void) {
        guard canInput,duelPlayer == nil,let unit = session.units[slot],
              !(unit.enemy && unit.scriptFlags&0x20 == 0) else { onClose();return }
        do {
            guard let levels = session.movement.strategyLevelRequirements,let costs = session.movement.strategyMPCosts else {
                throw BattleError.unsupported("Original strategy learning tables are unavailable")
            }
            let person = try session.people.person(unit.person)
            let sheet = try StrategyLearningGuide.sheet(person:person,levels:levels,costs:costs,
                names:(0..<36).map(strategyTitle),profile:session.movement,terrainNames:style.commands?.terrain.names,
                className:className(person.classID),
                portrait:portraitImage?(unit.person),selected:row) { [weak self] index in
                    guard let self = self else { return }
                    if let index = index { self.openStrategyGuide(slot,selected:index,onClose:onClose) }
                    else {
                        self.learningGuideOpen = false;self.overlay.viewport = self.layoutFacts.viewportRect
                        onClose()
                    }
                }
            learningGuideOpen = true;overlay.viewport = CGRect(x:8,y:8,width:624,height:384)
            overlay.show(sheet)
        } catch {
            learningGuideOpen = false;overlay.viewport = layoutFacts.viewportRect
            report(error);onClose()
        }
    }
    /// The battle menu also exposes already-acted and retired friendly officers.
    private func openStrategyGuidePeople(selected:Int = 0,returnMenuIndex:Int) {
        guard canInput,duelPlayer == nil else { return }
        let officers = session.units.values.filter { !$0.enemy }.sorted { $0.slot < $1.slot }.compactMap { unit -> (unit:OriginalLiveUnit,person:OriginalPersonDefinition)? in
            guard let person = try? session.people.person(unit.person) else { return nil }
            return (unit,person)
        }
        let rows = officers.map { unit,person -> CanvasSheet.Row in
            return CanvasSheet.Row(label:person.name,value:"Lv.\(person.level)",
                detail:.init(heading:person.name,body:"\(className(person.classID)) · 현재 병과의 책략 습득표를 확인합니다.",portrait:portraitImage?(unit.person)))
        }
        learningGuideOpen = true;overlay.viewport = CGRect(x:8,y:8,width:624,height:384)
        overlay.show(CanvasSheet(portrait:nil,speaker:"장수별 책략 습득표",line:"확인할 장수를 선택하세요.",badge:("아군","\(rows.count)명"),
            rows:rows,selected:selected,mode:.list,hint:"↑↓ 이동 · ↩ 습득표 · esc 뒤로") { [weak self] index in
                guard let self = self else { return }
                if let index = index,officers.indices.contains(index) {
                    self.openStrategyGuide(officers[index].unit.slot) { [weak self] in self?.openStrategyGuidePeople(selected:index,returnMenuIndex:returnMenuIndex) }
                } else {
                    self.learningGuideOpen = false;self.overlay.viewport = self.layoutFacts.viewportRect
                    self.openFunctionMenu(selected:returnMenuIndex)
                }
            })
    }
    private func heldItems(_ slot:Int) -> [Int] {
        guard let unit = session.units[slot],let person = try? session.people.person(unit.person) else { return [] }
        return person.itemIDs.filter { $0 != 255 }
    }
    private func itemRecord(_ id:Int) -> OriginalItemEffect? { session.combat.items.first(where:{ $0.id == id }) }
    private func itemName(_ id:Int) -> String { itemRecord(id)?.name ?? "도구 #\(id)" }
    private var itemActionLabels:[String] { style.commands?.itemActions ?? ["Use","Give","Drop","Inspect"] }
    private func itemActionMenu(_ slot:Int,_ choose:@escaping (Int?) -> Void) -> CanvasMenu {
        let actions = ["use","give","drop","inspect"]
        return CanvasMenu(title:"",options:itemActionLabels.enumerated().map { CanvasMenu.Option(label:$0.element,icon:actions.indices.contains($0.offset) ? icon(actions[$0.offset]) : nil) },
                          cancellable:true,anchor:windowOrigin(slot,depth:1),onChoose:choose)
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
            do { try self.runItemAction(action,item:items[index],slot) } catch { self.report(error);self.openItemList(slot,action:action) }
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
        if let unit = session.units[slot],let refusal = onItemUseRefusal?(unit.person,item) {
            say(refusal) { [weak self] in self?.openItemList(slot,action:0) };return
        }
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
        try showPromotionPreview(slot,item:item)
    }
    /// The source refusal check remains before the engine's comparison sheet.
    /// Browsing changes no person, item, turn, movement origin or RNG state.
    private func showPromotionPreview(_ slot:Int,item:Int,selected:Int = 0) throws {
        guard let commands = style.commands else {throw BattleError.unsupported("Original promotion names are unavailable")}
        let unit = try session.live(slot),person = try session.people.person(unit.person)
        let comparison = try PromotionPreview.build(person:person,morale:unit.morale,item:item,combat:session.combat,
            movement:session.movement,classNames:commands.classNames,strategyNames:commands.strategyNames,terrainNames:commands.terrain.names)
        overlay.show(PromotionPreview.sheet(comparison,selected:selected,onChoose:{ [weak self] row in
            guard let self = self else {return}
            guard let row else {self.openItemList(slot,action:0);return}
            do {try self.showPromotionPreview(slot,item:item,selected:row)}
            catch {self.report(error);self.openItemList(slot,action:0)}
        },onButton:{ [weak self] index in
            guard let self = self else {return}
            guard index == 0 else {self.openItemList(slot,action:0);return}
            do {
                // Recheck the shown forecast before committing an action.
                let current = try self.session.live(slot),now = try self.session.people.person(current.person)
                let latest = try PromotionPreview.build(person:now,morale:current.morale,item:item,combat:self.session.combat,
                    movement:self.session.movement,classNames:commands.classNames,strategyNames:commands.strategyNames,terrainNames:commands.terrain.names)
                guard latest == comparison,current == unit else {try self.showPromotionPreview(slot,item:item,selected:selected);return}
                if let refusal = try OriginalItemOperation.classRefusal(in:self.session,userSlot:slot,use:OriginalItemUse.of(item)) {
                    self.say(self.itemText(refusal)) { [weak self] in self?.openItemList(slot,action:0) };return
                }
                self.performItem(slot,item:item,target:nil)
            } catch {self.report(error);self.openItemList(slot,action:0)}
        }))
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
        } catch { report(error);openItemList(slot,action:0) }
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
        if let unit = session.units[slot],let refusal = onItemUseRefusal?(unit.person,item) {
            say(refusal) { [weak self] in self?.openItemList(slot,action:0) };return
        }
        play(itemCues(item:item,target:target)) { [weak self] in self?.commitItem(slot,item:item,target:target) }
    }
    private func commitItem(_ slot:Int,item:Int,target:Int?) {
        do {
            if let result = try flow.manualItem(slot,item:item,target:target) { _ = drainHeldCues();finishItem(result) }
            else { _ = drainHeldCues();waitingForItem = true;resetCommand();message = "" }
        } catch { report(error);openItemList(slot,action:0) }
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
        if !lines.isEmpty { say(lines.joined(separator:"\n")) { [weak self] in self?.checkAutoTurnEndPrompt() } }
        else { checkAutoTurnEndPrompt() }
    }
    private func runItemAction(_ action:Int,item:Int,_ slot:Int) throws {
        let again:() -> Void = { [weak self] in self?.openItemList(slot,action:action) }
        switch action {
        case 0: try beginItemUse(slot,item:item)
        case 1:
            phase = .giveTarget(slot,item:item);message = "\(itemName(item))을(를) 건넬 아군을 클릭하세요. 오른쪽 클릭·Esc: 취소"
        case 2:
            guard let unit = session.units[slot] else { return }
            if let refusal = onItemDiscardRefusal?(unit.person,item) {say(refusal,then:again);return}
            try session.people.discardItem(person:unit.person,item:item)
            acceptedInput(.init(kind:.battleDiscard,slot:slot,item:item));recordingBoundaryIfReady()
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
            queueTutorial()
        } catch {report(error);openCommand(slot)}
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
                    _ = self.drainHeldCues()
                    self.showStrategyResult(result)
                    // MAIN2DDCD returns to the command window unless the unit acted.
                    if result.completed {self.resetCommand();self.checkAutoTurnEndPrompt()} else {self.openCommand(slot)}
                }
                else {_ = self.drainHeldCues();self.waitingForStrategy = true;self.resetCommand();self.message = ""}
            } catch { self.report(error);self.resetCommand() }
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
    private var listRows:[Int] {
        let slots = OriginalBattleRoster.rows(side:listSide,units:session.units) {self.force(of:$0)}
        return (try? BattleAssistance.rosterRows(in:session,slots:slots,options:rosterOptions)) ?? []
    }
    private var unitCardRect:CGRect {
        let facts = layoutFacts.list
        let y = CGFloat(facts.rect[1]+facts.rect[3])+6
        return CGRect(x:CGFloat(facts.rect[0])-2,y:y,width:CGFloat(facts.rect[2])+4,height:CGFloat(layoutFacts.minimap.panel[1])-y-6)
    }
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
        let tracked = !seenPositions.isEmpty
        for unit in session.units.values.sorted(by:{$0.slot < $1.slot}) where unit.status == 2 {
            if animator.walker?.slot == unit.slot { continue }
            if let old = seenPositions[unit.slot] {
                if old != unit.position { moved = unit.position }
            } else if tracked,!(unit.enemy && unit.scriptFlags&0x20 == 0) {
                moved = unit.position
            }
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
    /// Information and controls occupy separate rows, leaving the map unobscured.
    private func drawModernFrame(_ context:CGContext) {
        let map = layoutFacts.viewportRect
        CanvasTheme.gradient(CGRect(x:0,y:0,width:640,height:400),top:CanvasTheme.surfaceTop,bottom:CanvasTheme.surfaceBottom,radius:0,in:context)
        CanvasTheme.gradient(ModernBattleControls.header,top:CanvasTheme.surfaceTop,bottom:CanvasTheme.surfaceBottom,radius:0,in:context)
        context.setFillColor(CGColor(gray:0,alpha:1));context.fill(map)
        label(session.definition.name ?? session.definition.id,in:ModernBattleControls.title,font:CanvasTheme.font(12,.bold))
        let weatherIcon = weatherClass == 0 ? "☀" : weatherClass == 1 ? "☁" : "☂"
        label("\(session.turns.roundIndex+1) / \(session.header.turnLimit)턴 · \(weatherIcon) \(weatherName)",
              in:ModernBattleControls.turn,font:CanvasTheme.number(11,.semibold),color:CanvasTheme.accent,alignment:.right)
        drawPlayerControls(context)
        CanvasTheme.divider(from:CGPoint(x:0,y:map.minY-0.5),to:CGPoint(x:map.maxX,y:map.minY-0.5),in:context)
        CanvasTheme.divider(from:CGPoint(x:480.5,y:0),to:CGPoint(x:480.5,y:400),in:context)
    }
    private func drawPlayerControls(_ context:CGContext) {
        let footer = ModernBattleControls.footer
        CanvasTheme.gradient(footer,top:CanvasTheme.surfaceTop,bottom:CanvasTheme.surfaceBottom,radius:0,in:context)
        CanvasTheme.divider(from:CGPoint(x:footer.minX,y:footer.minY+0.5),to:CGPoint(x:footer.maxX,y:footer.minY+0.5),in:context)
        let buttons = playerControls
        let first = buttons.filter { $0.rect.minY >= footer.minY }.map { $0.rect.minX }.min() ?? footer.maxX
        let hint:String
        if !canInput { hint = combatPlayer != nil ? "클릭: 다음 장면 · Esc: 전투 연출 마치기" : "부대의 행동을 진행하고 있습니다." }
        else if overlay.active { hint = "명령 선택 · Esc: 뒤로" }
        else if let selection = strategySelection {
            hint = selection.abilityID >= 30 ? "표시된 부대 전체에 책략 적용" : "대상 선택 · ↩ 실행"
        } else {
            switch phase {
            case .idle:hint = "아군 선택 → 이동 → 명령 · Tab: 다음 부대"
            case .moving:hint = "이동할 칸을 선택하세요."
            case .attackTarget:hint = "공격할 적을 선택하세요."
            case .giveTarget:hint = "도구를 건넬 아군을 선택하세요."
            case .itemTarget:hint = "도구를 사용할 대상을 선택하세요."
            case .command:hint = "명령을 선택하세요."
            }
        }
        label(hint,in:CGRect(x:8,y:footer.minY+9,width:first-16,height:17),font:CanvasTheme.font(10.5),color:CanvasTheme.muted)
        for button in buttons {
            let active = button.enabled && button.primary
            CanvasTheme.pill(button.rect,active:active,in:context)
            let color = !button.enabled ? CanvasTheme.disabled : active ? CanvasTheme.onAccent : CanvasTheme.text
            CanvasTheme.drawSingleLine(button.label,in:button.rect.insetBy(dx:6,dy:0),font:CanvasTheme.font(10.5,.semibold),color:color,alignment:.center,context:context)
        }
    }
    /// The force, the two list tabs, the units and the small map, top to bottom.
    private func drawSidebar(_ context:CGContext) {
        let facts = layoutFacts.list,rows = listRows
        listTop = min(listTop,listTopLimit)
        let column = CGRect(x:486,y:0,width:148,height:400)
        if let unit = session.units[listSide == 0 ? 0 : 15],let texts = style.texts,texts.forces.indices.contains(force(of:unit)) {
            let banner = CGRect(x:column.minX+2,y:5,width:column.width-4,height:22)
            CanvasTheme.card(banner,radius:6,in:context)
            CanvasTheme.drawSingleLine("❖ "+texts.forces[force(of:unit)]+texts.forceSuffix,in:banner.insetBy(dx:6,dy:0),
                  font:CanvasTheme.font(12,.bold),color:CanvasTheme.accent,alignment:.center,context:context)
        }
        let allyCount = session.units.values.filter { !$0.enemy && $0.status == 2 }.count
        let enemyCount = session.units.values.filter { $0.enemy && $0.status == 2 && $0.scriptFlags&0x20 != 0 }.count
        for (side,value) in layoutFacts.sideButtons.enumerated() {
            let rect = OriginalBattleLayout.rect(value).insetBy(dx:1.5,dy:0.5)
            let active = side == listSide
            CanvasTheme.pill(rect,active:active,danger:side == 1 && active,in:context)
            let count = side == 0 ? allyCount : enemyCount
            CanvasTheme.drawSingleLine("\(side == 0 ? "아군" : "적군") \(count)",in:rect.insetBy(dx:4,dy:0),font:CanvasTheme.font(10.5,.bold),
                  color:active ? (side == 1 ? CanvasTheme.text : CanvasTheme.onAccent) : CanvasTheme.muted,alignment:.center,context:context)
        }
        let listPanel = CGRect(x:CGFloat(facts.rect[0])-2,y:CGFloat(facts.rect[1])-2,width:CGFloat(facts.rect[2])+4,height:CGFloat(facts.rect[3])+4)
        CanvasTheme.card(listPanel,radius:7,in:context)
        if rows.isEmpty {
            label("조건에 맞는 부대 없음\nR: 목록 필터 변경",in:listPanel.insetBy(dx:8,dy:32),font:CanvasTheme.font(10),color:CanvasTheme.muted,alignment:.center)
        }
        for row in 0..<facts.rows where listTop+row < rows.count {
            guard let unit = session.units[rows[listTop+row]],let person = try? session.people.person(unit.person) else { continue }
            let box = CGRect(x:facts.rect[0],y:facts.rect[1]+row*facts.rowHeight,width:facts.hover[1],height:facts.rowHeight-1)
            let focused = unit.slot == (inspected ?? selected ?? hovered)
            if focused {
                CanvasTheme.gradient(box,top:CGColor(red:0.91,green:0.75,blue:0.40,alpha:0.26),
                                     bottom:CGColor(red:0.91,green:0.75,blue:0.40,alpha:0.08),radius:4,vertical:false,in:context)
                CanvasTheme.fill(CGRect(x:box.minX+1.5,y:box.minY+3,width:2.5,height:box.height-6),CanvasTheme.accentFill,radius:1.25,in:context)
            }
            // A friendly unit that has acted this phase (flag80) reads as done.
            let done = !unit.enemy && unit.scriptFlags&0x80 != 0 && session.turns.stage == .manualFriendly
            let name = done ? CanvasTheme.muted : color(OriginalBattleRoster.nameColor(unit))
            label(person.name,in:CGRect(x:box.minX+6,y:box.minY+0.5,width:CanvasTheme.textScale > 1 ? 56 : 72,height:22),font:CanvasTheme.font(11,.semibold),color:unit.status == 2 ? name : CanvasTheme.disabled)
            let statusX = box.minX+(CanvasTheme.textScale > 1 ? 6 : 44),statusY = box.minY+(CanvasTheme.textScale > 1 ? 20 : 1.5)
            let statusHeight:CGFloat = CanvasTheme.textScale > 1 ? 16 : 11,statusWidth:CGFloat = CanvasTheme.textScale > 1 ? 36 : 24
            if unit.scriptFlags&2 != 0,unit.status == 2 {
                let tag = CGRect(x:statusX,y:statusY,width:statusWidth,height:statusHeight)
                CanvasTheme.fill(tag,CGColor(red:0.52,green:0.18,blue:0.60,alpha:0.85),radius:3,in:context)
                label("혼란",in:tag,font:CanvasTheme.font(8,.bold),color:CanvasTheme.text,alignment:.center)
            } else if unit.scriptFlags&0x20 == 0,unit.status == 2 {
                let tag = CGRect(x:statusX,y:statusY,width:statusWidth,height:statusHeight)
                CanvasTheme.fill(tag,CGColor(red:0.14,green:0.48,blue:0.46,alpha:0.85),radius:3,in:context)
                label("매복",in:tag,font:CanvasTheme.font(8,.bold),color:CanvasTheme.text,alignment:.center)
            } else if done,unit.status == 2 {
                label("완료",in:CGRect(x:statusX,y:statusY,width:statusWidth,height:statusHeight),font:CanvasTheme.font(8.5,.medium),color:CanvasTheme.disabled)
            }
            if unit.status != 2 {
                label(style.texts?.retired ?? "",in:CGRect(x:box.minX+60,y:box.minY+1,width:box.width-66,height:14),font:CanvasTheme.font(9.5),color:CanvasTheme.disabled,alignment:.right)
                continue
            }
            let maximum = (try? OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:session.combat)) ?? 0
            label("\(person.rawTroops)/\(maximum)",in:CGRect(x:box.minX+60,y:box.minY+1.5,width:box.width-66,height:21),font:CanvasTheme.number(9.5,.medium),color:CanvasTheme.muted,alignment:.right)
            let bar = CGRect(x:box.minX+6,y:box.maxY-4,width:box.width-12,height:2.5)
            CanvasTheme.fill(bar,CGColor(gray:1,alpha:0.12),radius:1.25,in:context)
            let gauge = OriginalBattleGauge(current:person.rawTroops,maximum:maximum,width:Int(bar.width))
            let tint = gauge.tile == "high" ? CGColor(red:0.38,green:0.82,blue:0.54,alpha:1) : gauge.tile == "middle" ? CanvasTheme.accentFill : CanvasTheme.danger.cgColor
            CanvasTheme.fill(CGRect(x:bar.minX,y:bar.minY,width:CGFloat(gauge.fill),height:bar.height),tint,radius:1.25,in:context)
        }
        if listTopLimit > 0 {
            let track = OriginalBattleLayout.rect(facts.track),height = track.height*CGFloat(facts.rows)/CGFloat(rows.count)
            CanvasTheme.fill(CGRect(x:track.minX,y:track.minY+(track.height-height)*CGFloat(listTop)/CGFloat(listTopLimit),width:track.width,height:height),CanvasTheme.accentBorder,radius:1.5,in:context)
        }
        drawUnitCard(unitCardRect,context)
    }
    private static let troopTint = CGColor(red:0.38,green:0.82,blue:0.54,alpha:1)
    /// The engine sidebar's card for the inspected, selected or hovered unit:
    /// portrait, name, class and level, then troops, MP, morale and experience.
    private func drawUnitCard(_ card:CGRect,_ context:CGContext) {
        CanvasTheme.card(card,radius:CanvasTheme.radius,in:context)
        guard let slot = inspected ?? selected ?? hovered ?? speakingSlot,let unit = session.units[slot],
              !unit.enemy || unit.scriptFlags&0x20 != 0,let person = try? session.people.person(unit.person) else {
            label("부대를 선택해\n전력을 확인하세요.",in:card.insetBy(dx:10,dy:34),font:CanvasTheme.font(10.5),color:CanvasTheme.muted,alignment:.center)
            return
        }
        let face = CGRect(x:card.minX+7,y:card.minY+7,width:34,height:42)
        if let picture = portraitImage?(unit.person) {
            context.saveGState();CanvasTheme.rounded(face,4,in:context);context.clip()
            Renderer.image(picture,in:face,context:context);context.restoreGState()
            CanvasTheme.stroke(face,CanvasTheme.accentBorder,radius:4,in:context)
        } else { CanvasTheme.fill(face,CanvasTheme.hairline,radius:4,in:context) }
        let textX = face.maxX+8,textWidth = card.maxX-textX-6
        label(person.name,in:CGRect(x:textX,y:card.minY+6,width:textWidth-28,height:24),font:CanvasTheme.font(12.5,.bold),
              color:unit.status == 2 ? color(OriginalBattleRoster.nameColor(unit)) : CanvasTheme.disabled)
        let sideBadge = CGRect(x:card.maxX-34,y:card.minY+7,width:28,height:CanvasTheme.textScale > 1 ? 18 : 13)
        let sideTint = unit.enemy ? CGColor(red:0.78,green:0.24,blue:0.24,alpha:0.85) : unit.orderMode == 7 ? CGColor(red:0.20,green:0.46,blue:0.78,alpha:0.85) : CGColor(red:0.20,green:0.60,blue:0.42,alpha:0.85)
        CanvasTheme.fill(sideBadge,sideTint,radius:4,in:context)
        CanvasTheme.drawSingleLine(unit.enemy ? "적군" : unit.orderMode == 7 ? "아군" : "우군",in:sideBadge,font:CanvasTheme.font(8,.bold),color:CanvasTheme.text,alignment:.center,context:context)
        let statusTag = unit.status != 2 ? (style.texts?.retired ?? "퇴각") : unit.scriptFlags&2 != 0 ? "혼란" : unit.scriptFlags&0x20 == 0 ? "매복" : nil
        // A unit without a condition shows none; I still opens the status sheet.
        label("\(className(person.classID)) · Lv \(person.level)" + (CanvasTheme.textScale > 1 ? "" : statusTag.map { " · \($0)" } ?? ""),
              in:CGRect(x:textX,y:card.minY+30,width:textWidth,height:21),font:CanvasTheme.font(10,.medium),
              color:unit.status == 2 && unit.scriptFlags&2 != 0 ? color(3) : CanvasTheme.muted)
        let troops = (try? OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:session.combat)) ?? 0
        let mp = (try? OriginalCombat.maxMP(stats:session.people.stats(unit.person,morale:100))) ?? 0
        let gauge = OriginalBattleGauge(current:person.rawTroops,maximum:troops,width:100)
        let troopTint = gauge.tile == "high" ? Self.troopTint : gauge.tile == "middle" ? CanvasTheme.accentFill : CanvasTheme.danger.cgColor
        let rows:[(String,Int,Int,CGColor)] = [("병력",person.rawTroops,troops,troopTint),("책략",Int(unit.mp),mp,CGColor(red:0.42,green:0.68,blue:0.98,alpha:1)),
                                              ("사기",Int(unit.morale),100,CanvasTheme.accentFill),("경험",person.experience,100,CGColor(red:0.74,green:0.56,blue:0.98,alpha:1))]
        for (index,row) in rows.enumerated() {
            let y = card.minY+53+CGFloat(index)*(CanvasTheme.textScale > 1 ? 18 : 12.2)
            label(row.0,in:CGRect(x:card.minX+8,y:y,width:30,height:18),font:CanvasTheme.font(9.5,.semibold),color:CanvasTheme.muted)
            let bar = CGRect(x:card.minX+36,y:y+7,width:card.width-(CanvasTheme.textScale > 1 ? 108 : 88),height:4)
            CanvasTheme.fill(bar,CGColor(gray:1,alpha:0.12),radius:2,in:context)
            let part = row.2 > 0 ? min(1,CGFloat(row.1)/CGFloat(row.2)) : 0
            if part > 0 { CanvasTheme.fill(CGRect(x:bar.minX,y:bar.minY,width:max(4,bar.width*part),height:bar.height),row.3,radius:2,in:context) }
            label(row.0 == "사기" || row.0 == "경험" ? "\(row.1)" : "\(row.1)/\(row.2)",in:CGRect(x:bar.maxX+4,y:y,width:card.maxX-bar.maxX-9,height:18),
                  font:CanvasTheme.number(9,.medium),color:CanvasTheme.text,alignment:.right)
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
        let modern = presentation == .modern
        func region(_ cells:Set<GridPoint>,_ tint:Tint) {
            if modern { drawRegion(cells,tint,context,rect:rect);return }
            for point in cells { NSColor(calibratedRed:tint.red,green:tint.green,blue:tint.blue,alpha:tint.alpha).setFill();rect(point).fill() }
        }
        if let slot = rangeSlot,let cells = try? session.reachable(slot) { region(Set(cells),Self.moveTint) }
        if canInput,!overlay.active,case .moving(let slot) = phase,let point = hoveredCell,let preview = movePreview(slot,at:point) {
            if let ability = previewAbility {
                region(Set((preview.strategies[ability] ?? []).compactMap {session.units[$0]?.position}),ability >= 21 ? Self.supportTint : Self.attackTint)
            } else {region(preview.attackCells,Self.attackTint)}
        }
        if case .attackTarget(let slot) = phase,let cells = try? attackCells(slot) { region(Set(cells),Self.attackTint) }
        if case .giveTarget(let slot,_) = phase,let cells = try? giveCells(slot) { region(Set(cells),Self.supportTint) }
        if case .itemTarget(let slot,let item) = phase {
            let use = OriginalItemUse.of(item)
            if let cells = try? itemCells(slot,use) { region(Set(cells),use.targetsFriends ? Self.supportTint : Self.attackTint) }
        }
        let strategyTargets = strategySelection.flatMap { choice in selected.flatMap {try? legalStrategyTargets(choice.abilityID,casterSlot:$0)} } ?? []
        region(Set(strategyTargets.compactMap { session.units[$0]?.position }),Self.supportTint)
        if modern,case .moving(let slot) = phase,let unit = session.units[slot],let target = hoveredCell,target != unit.position,
           (try? session.reachable(slot))?.contains(target) == true,let path = try? session.route(slot,to:target) {
            drawRoute([unit.position]+path.filter { $0 != unit.position },context,rect:rect)
        }
        if modern,canInput,let cell = hoveredCell,combatPlayer == nil {
            CanvasTheme.stroke(rect(cell).insetBy(dx:1,dy:1),CGColor(gray:1,alpha:0.55),radius:3,in:context)
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
                        ?? sprites.image(unit:unit,classID:person.classID,phase:idlePhase)
                    // Modern: a friendly unit that has acted (flag80) is drawn darker.
                    if modern,!unit.enemy,unit.scriptFlags&0x80 != 0,walker == nil {
                        context.beginTransparencyLayer(in:box,auxiliaryInfo:nil)
                        Renderer.image(image,in:box,context:context)
                        context.setBlendMode(.sourceAtop);context.setFillColor(CGColor(gray:0,alpha:0.42));context.fill(box)
                        context.endTransparencyLayer()
                    } else { Renderer.image(image,in:box,context:context) }
                }
                catch { message = "원작 그림 경계: \(error)";text("?",in:box,color:.systemYellow) }
            } else {
                (unit.enemy ? NSColor.systemRed : NSColor.systemBlue).setFill();NSBezierPath(ovalIn:box.insetBy(dx:3,dy:3)).fill()
            }
            if modern {
                drawTroopBar(unit,person,box,context)
                if unit.scriptFlags&2 != 0 {
                    let badge = CGRect(x:box.minX+4,y:box.minY+1,width:box.width-8,height:10)
                    CanvasTheme.fill(badge,CGColor(red:0.48,green:0.18,blue:0.56,alpha:0.88),radius:3,in:context)
                    label("혼란",in:CGRect(x:badge.minX,y:badge.minY-0.5,width:badge.width,height:11),font:CanvasTheme.font(7.5,.bold),alignment:.center)
                }
            }
            if selected == unit.slot {
                if modern { drawCorners(box,CanvasTheme.accentFill,context) }
                else { NSColor.systemYellow.setStroke();let p = NSBezierPath(rect:box.insetBy(dx:1,dy:1));p.lineWidth = 2;p.stroke() }
            }
            if modern,[.friendlyAI,.enemyAI].contains(session.turns.stage),
               (animator.walker?.slot ?? session.turns.pendingAI.first) == unit.slot {
                let ringColor = unit.enemy ? CGColor(red:1,green:0.42,blue:0.38,alpha:0.95) : CanvasTheme.accentFill
                drawCorners(box,ringColor,context)
            }
            if speakingSlot == unit.slot {
                // MAIN337D9 (1CB6:746E): mark the unit that owns the current battle line.
                if modern {
                    CanvasTheme.fill(box.insetBy(dx:1,dy:1),CGColor(red:0.96,green:0.82,blue:0.44,alpha:0.22),radius:4,in:context)
                    drawCorners(box,CGColor(red:1,green:0.88,blue:0.48,alpha:1),context)
                    let tag = CGRect(x:box.midX-18,y:max(viewport.minY+2,box.minY-14),width:36,height:12)
                    CanvasTheme.pill(tag,active:true,in:context)
                    CanvasTheme.drawSingleLine("대화",in:tag,font:CanvasTheme.font(8,.bold),color:CanvasTheme.onAccent,alignment:.center,context:context)
                } else {
                    NSColor.systemYellow.setStroke()
                    let outer = NSBezierPath(rect:box.insetBy(dx:1,dy:1));outer.lineWidth = 2;outer.stroke()
                    NSColor.cyan.setStroke()
                    let inner = NSBezierPath(rect:box.insetBy(dx:3,dy:3));inner.lineWidth = 1;inner.stroke()
                }
            }
            if strategySelection?.targetSlot == unit.slot {NSColor.systemGreen.setStroke();let p = NSBezierPath(rect:box);p.lineWidth = 3;p.stroke()}
            for floater in floaters where floater.slot == unit.slot { drawFloater(floater,over:box) }
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
        // MAIN2858A..2871F (1CB6:502A): flashes damage or recovery over the target cell.
        if let number = animator.number,number.visible,let unit = session.units[number.slot],unit.status == 2 {
            drawMapNumber(number.value,colorIndex:number.color,over:rect(unit.position),modern:modern,context:context)
        }
        if let advice = assistedArea,selected == advice.slot,hoveredCell == advice.point,
           (try? BattleProjection(session).key) == advice.key {
            for slot in advice.targets {
                guard let target = session.units[slot],target.status == 2,(!target.enemy || target.scriptFlags&0x20 != 0) else {continue}
                context.setStrokeColor(CanvasTheme.accentFill);context.setLineWidth(2)
                context.stroke(rect(target.position).insetBy(dx:2,dy:2))
            }
        }
        drawAnnotations(context,rect:rect)
        context.restoreGState()
        // Cinematics retain their 416×352 source layout below the modern header,
        // extending through the unused action bar while manual input is blocked.
        if let duel = session.scriptActions.duel,duel.active,let stage = duelStage,let picture = duelPlayer?.picture ?? Optional(stage.shown) {
            drawDuel(context,stage:stage,picture:picture)
        } else if let duel = session.scriptActions.duel,duel.active,let sprites = sprites {
            let duelViewport = OriginalDuelSprites.sourceViewport
            context.saveGState()
            if presentation == .modern { context.translateBy(x:16,y:16) }
            context.clip(to:duelViewport);context.setFillColor(CGColor(gray:0,alpha:1));context.fill(duelViewport)
            do {
                for side in OriginalDuelSprites.sourceDrawOrder {
                    Renderer.image(try sprites.duelImage(duel,side:side),in:try OriginalDuelSprites.sourceRect(duel:duel,side:side),context:context)
                }
            } catch { message = "원작 일기토 그림 경계: \(error)" }
            context.restoreGState()
        }
    }
    /// Visible enabled states and hit targets share one description. No game
    /// state is changed while drawing or inspecting these controls.
    var playerControls:[BattleControlButton] {
        guard presentation == .modern else { return [] }
        let idle = canInput && !overlay.active && phase == .idle && strategySelection == nil && annotationDraft == nil
        let available = readyUnits().count
        let controls = AppControlRuntime.current,largeText = CanvasTheme.textScale > 1
        func key(_ command:AppControlPreferences.Command)->String {controls.shortcutLabel(command:command,context:.battle)}
        let pace = OriginalSettings.current.battlePace
        let paceText = Self.paceLabels.indices.contains(pace) ? Self.paceLabels[pace] : "보통"
        var buttons = ModernBattleControls.top.map { item -> BattleControlButton in
            let label:String,enabled:Bool,primary:Bool
            switch item.action {
            case .menu:label = "메뉴";enabled = idle;primary = functionOpen
            case .conditions:label = "승리조건";enabled = idle && objective != nil && style.commands != nil;primary = false
            case .threat:label = showsThreat ? "위협 켜짐" : (largeText ? "위협" : "위협 "+key(.threat));enabled = combatPlayer == nil && duelPlayer == nil && !overlay.active;primary = showsThreat
            case .pace:label = "재생 \(paceText)";enabled = settingsTexts != nil && combatPlayer == nil && duelPlayer == nil && !overlay.active;primary = pace > 0
            case .nextUnit:label = largeText ? "다음" : "다음 "+key(.nextUnit);enabled = canInput && !overlay.active && strategySelection == nil && (phase == .idle || isChoosingMove) && available > 0;primary = false
            case .endTurn:label = available > 0 ? (largeText ? "종료 · \(available)남음" : "턴 종료 · \(available)부대 남음") : "턴 종료";enabled = idle;primary = available == 0
            default:label = "";enabled = false;primary = false
            }
            return BattleControlButton(action:item.action,label:label,rect:item.rect,enabled:enabled,primary:primary)
        }
        guard canInput,!overlay.active else { return buttons }
        if annotationDraft != nil {
            return buttons.map {var button = $0;button.enabled = false;return button}+[.init(action:.cancel,label:"메모 취소 Esc",rect:ModernBattleControls.cancel,enabled:true)]
        }
        if mapViewMode == .overview {
            let allowed:[BattlePlayerAction] = [.menu,.conditions,.threat,.pace]
            return buttons.map {var button = $0;button.enabled = button.enabled && allowed.contains(button.action);return button}
                + [.init(action:.cancel,label:"전술 보기",rect:ModernBattleControls.cancel,enabled:true)]
        }
        if strategySelection != nil {
            buttons.append(BattleControlButton(action:.confirmStrategy,label:"책략 실행 ↩",rect:ModernBattleControls.confirm,enabled:true,primary:true))
            buttons.append(BattleControlButton(action:.cancel,label:"취소 Esc",rect:ModernBattleControls.cancel,enabled:true))
        } else if case .moving = phase {
            buttons.append(BattleControlButton(action:.command,label:largeText ? "이 위치에서 행동" : "행동 "+key(.confirm),rect:ModernBattleControls.command,enabled:true,primary:true))
            buttons.append(BattleControlButton(action:.wait,label:largeText ? "대기" : "대기 "+key(.wait),rect:ModernBattleControls.wait,enabled:true))
            buttons.append(BattleControlButton(action:.cancel,label:"취소 Esc",rect:ModernBattleControls.cancel,enabled:true))
        } else if phase != .idle {
            buttons.append(BattleControlButton(action:.cancel,label:"취소 Esc",rect:ModernBattleControls.cancel,enabled:true))
        }
        return buttons
    }
    /// Engine shortcuts dispatch to the same restored command owners as menus.
    /// In particular Return never advances the turn as a side effect of selecting.
    func performPlayerAction(_ action:BattlePlayerAction) throws {
        guard !overlay.active else { return }
        if annotationDraft != nil {if action == .cancel {cancelAnnotationDraft()};return}
        if presentation == .modern,mapViewMode == .overview {
            if action == .cancel {applyMapView(previousTacticalMode);return}
            guard [.menu,.conditions,.threat,.pace].contains(action) else {return}
        }
        switch action {
        case .threat:guard combatPlayer == nil,duelPlayer == nil else { return };showsThreat.toggle()
        case .pace:guard combatPlayer == nil,duelPlayer == nil else { return };changeSetting("battle-pace",by:1)
        default:
            guard canInput else { return }
            switch action {
            case .menu:openFunctionMenu()
            case .conditions:guard phase == .idle,strategySelection == nil else { return };showConditions(opening:false)
            case .nextUnit:selectNextUnit(1)
            case .endTurn:guard phase == .idle,strategySelection == nil else { return };requestEndTurn()
            case .command:if case .moving(let slot) = phase { openCommand(slot) }
            case .wait:if case .moving(let slot) = phase { try runCommand(3,slot) }
            case .confirmStrategy:try executeSelectedStrategy()
            case .cancel:stepBack()
            default:break
            }
        }
        needsDisplay = true
    }
    private func drawMapNumber(_ value:Int,colorIndex:Int,over box:CGRect,modern:Bool,context:CGContext) {
        if modern {
            let badge = CGRect(x:box.midX-22,y:box.midY-9,width:44,height:18)
            CanvasTheme.fill(badge,CGColor(red:0.06,green:0.07,blue:0.11,alpha:0.90),radius:5,in:context)
            let border = colorIndex == 15 ? CanvasTheme.accentFill : CGColor(red:0.96,green:0.42,blue:0.36,alpha:0.9)
            CanvasTheme.stroke(badge,border,radius:5,in:context)
            let textColor = colorIndex == 15 ? CanvasTheme.accent : NSColor(red:1,green:0.86,blue:0.44,alpha:1)
            label("\(value)",in:CGRect(x:badge.minX,y:badge.minY+1,width:badge.width,height:16),
                  font:CanvasTheme.number(12,.heavy),color:textColor,alignment:.center)
            return
        }
        // MAIN28606..286A5: 4-digit right-aligned number at the foot of the cell with 8-way black outline.
        let shown = String(format:"%4d",value)
        let rect = CGRect(x:box.minX,y:box.maxY-15,width:box.width,height:15)
        for (dx,dy) in [(-1,-1),(0,-1),(1,-1),(-1,0),(1,0),(-1,1),(0,1),(1,1)] {
            text(shown,in:rect.offsetBy(dx:CGFloat(dx),dy:CGFloat(dy)),color:.black,size:12,alignment:.right,monospaced:true)
        }
        text(shown,in:rect,color:color(colorIndex),size:12,alignment:.right,monospaced:true)
    }
    private func drawAnnotations(_ context:CGContext,rect:(GridPoint)->CGRect) {
        guard showsAnnotations,let saved = try? currentAnnotations() else {return}
        context.saveGState();context.setLineWidth(2)
        for entry in saved.entries {
            let color:NSColor = entry.style == .gold ? CanvasTheme.accent : entry.style == .blue ? .systemCyan : .systemPink
            context.setStrokeColor(color.cgColor);context.setFillColor(color.cgColor)
            context.setLineDash(phase:0,lengths:entry.style == .gold ? [] : entry.style == .blue ? [2,3] : [7,3])
            let start = CGPoint(x:rect(entry.start).midX,y:rect(entry.start).midY)
            if let end = entry.end {
                let finish = CGPoint(x:rect(end).midX,y:rect(end).midY)
                context.move(to:start);context.addLine(to:finish);context.strokePath()
                if entry.kind == .arrow {
                    let angle = atan2(finish.y-start.y,finish.x-start.x),length:CGFloat = 9
                    context.move(to:CGPoint(x:finish.x-length*cos(angle-0.45),y:finish.y-length*sin(angle-0.45)))
                    context.addLine(to:finish);context.addLine(to:CGPoint(x:finish.x-length*cos(angle+0.45),y:finish.y-length*sin(angle+0.45)));context.strokePath()
                }
            } else {context.strokeEllipse(in:CGRect(x:start.x-5,y:start.y-5,width:10,height:10))}
            if !entry.text.isEmpty {CanvasTheme.chip(entry.text,at:CGPoint(x:start.x,y:start.y+10),maximumWidth:160,color:color,in:context)}
        }
        if let start = annotationDraft?.start {
            context.setStrokeColor(CanvasTheme.accentFill);context.setLineDash(phase:0,lengths:[3,3]);context.stroke(rect(start).insetBy(dx:2,dy:2))
        }
        if annotationDraft != nil,let cursor = annotationCursor {drawCorners(rect(cursor),CanvasTheme.accentFill,context)}
        context.restoreGState()
    }
    /// Engine feedback: a unit's troop change rises from it and fades. Changes
    /// made inside the enlarged combat view show when the map returns.
    private struct Floater { var slot:Int;var amount:Int;var start:Date }
    private var floaters:[Floater] = []
    private var shownTroops:[Int:Int] = [:]
    private static let floaterSeconds = 1.3
    private func trackTroops() {
        floaters.removeAll { Date().timeIntervalSince($0.start) > Self.floaterSeconds }
        guard combatPlayer == nil,duelPlayer == nil else { return }
        for unit in session.units.values {
            guard let person = try? session.people.person(unit.person) else { continue }
            let now = unit.status == 2 ? person.rawTroops : 0
            if let before = shownTroops[unit.slot],before != now,unit.status == 2,presentation == .modern {
                floaters.append(Floater(slot:unit.slot,amount:now-before,start:Date()))
            }
            shownTroops[unit.slot] = now
        }
        if !floaters.isEmpty { DispatchQueue.main.async { [weak self] in self?.needsDisplay = true } }
    }
    private func drawFloater(_ floater:Floater,over box:CGRect) {
        let age = Date().timeIntervalSince(floater.start),t = CGFloat(age/Self.floaterSeconds)
        let alpha = t < 0.55 ? 1 : max(0,1-(t-0.55)/0.45)
        let color = floater.amount > 0 ? NSColor(red:0.55,green:0.95,blue:0.62,alpha:alpha) : NSColor(red:1,green:0.52,blue:0.46,alpha:alpha)
        let text = floater.amount > 0 ? "+\(floater.amount)" : "\(floater.amount)"
        let paragraph = NSMutableParagraphStyle();paragraph.alignment = .center
        let rect = CGRect(x:box.midX-40,y:box.minY-6-16*min(1,t*1.6),width:80,height:16)
        let outline:[NSAttributedString.Key:Any] = [.font:CanvasTheme.number(12,.heavy),.paragraphStyle:paragraph,
            .strokeColor:NSColor(white:0,alpha:alpha*0.85),.strokeWidth:6]
        (text as NSString).draw(in:rect,withAttributes:outline)
        (text as NSString).draw(in:rect,withAttributes:[.font:CanvasTheme.number(12,.heavy),.paragraphStyle:paragraph,.foregroundColor:color])
    }
    /// A refusal the player should read is a Korean reason, shown without the
    /// error's prefix; engine diagnostics go to the console, not the status chip.
    private func report(_ error:Error) {
        if case BattleError.illegalAction(let reason) = error,reason.unicodeScalars.contains(where:{ (0xAC00...0xD7A3).contains($0.value) }) {
            message = reason;lastRefusal = reason;queueTutorial();return
        }
        FileHandle.standardError.write(Data("전투 입력 거부: \(error)\n".utf8))
    }
    struct Tint:Equatable { var red:CGFloat;var green:CGFloat;var blue:CGFloat;var alpha:CGFloat }
    private static let moveTint = Tint(red:0.2,green:0.6,blue:1,alpha:0.25)
    private static let attackTint = Tint(red:1,green:0.25,blue:0.2,alpha:0.3)
    private static let supportTint = Tint(red:0.1,green:1,blue:0.7,alpha:0.3)
    /// Engine cells: a soft tile in each cell and a bright line round the region.
    private func drawRegion(_ cells:Set<GridPoint>,_ tint:Tint,_ context:CGContext,rect:(GridPoint) -> CGRect) {
        guard !cells.isEmpty else { return }
        for point in cells {
            CanvasTheme.fill(rect(point).insetBy(dx:1,dy:1),CGColor(red:tint.red,green:tint.green,blue:tint.blue,alpha:0.24),radius:3,in:context)
            CanvasRangePattern.draw(kind:tint == Self.moveTint ? .movement : tint == Self.attackTint ? .attack : .support,in:rect(point),context:context)
        }
        context.setStrokeColor(CGColor(red:min(1,tint.red+0.25),green:min(1,tint.green+0.25),blue:min(1,tint.blue+0.25),alpha:0.9));context.setLineWidth(1.5)
        for point in cells {
            let box = rect(point).insetBy(dx:0.75,dy:0.75)
            if !cells.contains(GridPoint(x:point.x,y:point.y-1)) { context.move(to:CGPoint(x:box.minX,y:box.minY));context.addLine(to:CGPoint(x:box.maxX,y:box.minY)) }
            if !cells.contains(GridPoint(x:point.x,y:point.y+1)) { context.move(to:CGPoint(x:box.minX,y:box.maxY));context.addLine(to:CGPoint(x:box.maxX,y:box.maxY)) }
            if !cells.contains(GridPoint(x:point.x-1,y:point.y)) { context.move(to:CGPoint(x:box.minX,y:box.minY));context.addLine(to:CGPoint(x:box.minX,y:box.maxY)) }
            if !cells.contains(GridPoint(x:point.x+1,y:point.y)) { context.move(to:CGPoint(x:box.maxX,y:box.minY));context.addLine(to:CGPoint(x:box.maxX,y:box.maxY)) }
        }
        context.strokePath()
    }
    /// The way a chosen unit would walk to the cell under the pointer.
    private func drawRoute(_ path:[GridPoint],_ context:CGContext,rect:(GridPoint) -> CGRect) {
        guard path.count > 1 else { return }
        let points = path.map { CGPoint(x:rect($0).midX,y:rect($0).midY) }
        context.saveGState();context.setLineCap(.round);context.setLineJoin(.round)
        for (width,color) in [(CGFloat(6),CGColor(gray:0,alpha:0.4)),(CGFloat(3),CGColor(gray:1,alpha:0.9))] {
            context.setStrokeColor(color);context.setLineWidth(width);context.addLines(between:points);context.strokePath()
        }
        if let end = points.last {
            context.setFillColor(CanvasTheme.accentFill);context.fillEllipse(in:CGRect(x:end.x-4.5,y:end.y-4.5,width:9,height:9))
        }
        context.restoreGState()
    }
    /// A unit's troops and MP on the map: slim bars along the foot of its cell,
    /// plus a commander crown on slots 0 and 15.
    private func drawTroopBar(_ unit:OriginalLiveUnit,_ person:OriginalPersonDefinition,_ box:CGRect,_ context:CGContext) {
        let maximum = (try? OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:session.combat)) ?? 0
        guard maximum > 0 else { return }
        let maxMP = (try? OriginalCombat.maxMP(stats:session.people.stats(unit.person,morale:100))) ?? 0
        let hasMP = maxMP > 0
        let track = CGRect(x:box.minX+4,y:box.maxY-(hasMP ? 5.5 : 4),width:box.width-8,height:hasMP ? 4.5 : 3)
        CanvasTheme.fill(track.insetBy(dx:-1,dy:-1),CGColor(gray:0,alpha:0.68),radius:2.5,in:context)
        let part = min(1,CGFloat(person.rawTroops)/CGFloat(maximum))
        let tint = unit.enemy ? CGColor(red:0.94,green:0.36,blue:0.32,alpha:1) : Self.troopTint
        if part > 0 {
            CanvasTheme.fill(CGRect(x:track.minX,y:track.minY,width:max(2,track.width*part),height:2.5),tint,radius:1.25,in:context)
        }
        if hasMP {
            let mpPart = min(1,CGFloat(unit.mp)/CGFloat(maxMP))
            if mpPart > 0 {
                CanvasTheme.fill(CGRect(x:track.minX,y:track.minY+3,width:max(2,track.width*mpPart),height:1.5),
                                 CGColor(red:0.42,green:0.72,blue:1,alpha:0.95),radius:0.75,in:context)
            }
        }
        if unit.slot == 0 || unit.slot == 15 {
            let star = CGRect(x:box.maxX-10,y:box.minY+1,width:9,height:9)
            CanvasTheme.fill(star,unit.enemy ? CGColor(red:0.82,green:0.20,blue:0.20,alpha:0.9) : CGColor(red:0.16,green:0.38,blue:0.76,alpha:0.9),radius:4.5,in:context)
            label("★",in:CGRect(x:star.minX,y:star.minY-1,width:star.width,height:10),font:CanvasTheme.font(7,.bold),color:CanvasTheme.accent,alignment:.center)
        }
    }
    private func drawCorners(_ box:CGRect,_ color:CGColor,_ context:CGContext) {
        let r = box.insetBy(dx:1.5,dy:1.5),length:CGFloat = 9
        context.saveGState();context.setStrokeColor(color);context.setLineWidth(2);context.setLineCap(.round)
        for (x,dx) in [(r.minX,CGFloat(1)),(r.maxX,CGFloat(-1))] {
            for (y,dy) in [(r.minY,CGFloat(1)),(r.maxY,CGFloat(-1))] {
                context.move(to:CGPoint(x:x+dx*length,y:y));context.addLine(to:CGPoint(x:x,y:y));context.addLine(to:CGPoint(x:x,y:y+dy*length))
            }
        }
        context.strokePath();context.restoreGState()
    }
    /// The modern turn opening: a band across the map with the turn in large type.
    private func drawBanner(_ text:String,in area:CGRect,_ context:CGContext) {
        let band = CGRect(x:area.minX,y:area.midY-30,width:area.width,height:60)
        let space = CGColorSpaceCreateDeviceRGB()
        func fade(_ alpha:CGFloat,_ red:CGFloat = 0,_ green:CGFloat = 0,_ blue:CGFloat = 0) -> CFArray {
            [CGColor(red:red,green:green,blue:blue,alpha:0),CGColor(red:red,green:green,blue:blue,alpha:alpha),
             CGColor(red:red,green:green,blue:blue,alpha:alpha),CGColor(red:red,green:green,blue:blue,alpha:0)] as CFArray
        }
        context.saveGState()
        if let gradient = CGGradient(colorsSpace:space,colors:fade(0.8),locations:[0,0.22,0.78,1]) {
            context.clip(to:band);context.drawLinearGradient(gradient,start:CGPoint(x:band.minX,y:0),end:CGPoint(x:band.maxX,y:0),options:[])
        }
        context.restoreGState()
        if let line = CGGradient(colorsSpace:space,colors:fade(0.9,0.91,0.75,0.40),locations:[0,0.3,0.7,1]) {
            for y in [band.minY,band.maxY-1.5] {
                context.saveGState();context.clip(to:CGRect(x:band.minX,y:y,width:band.width,height:1.5))
                context.drawLinearGradient(line,start:CGPoint(x:band.minX,y:0),end:CGPoint(x:band.maxX,y:0),options:[])
                context.restoreGState()
            }
        }
        label(text,in:CGRect(x:band.minX,y:band.midY-15,width:band.width,height:30),font:CanvasTheme.font(22,.bold),alignment:.center)
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
        if presentation == .modern {
            let panel = OriginalBattleLayout.rect(facts.minimap.panel).insetBy(dx:-2,dy:-2)
            CanvasTheme.card(panel,radius:7,in:context)
        }
        let origin = facts.minimapOrigin(width:session.width,height:session.height)
        let map = CGRect(x:origin.x,y:origin.y,width:CGFloat(session.width*scale),height:CGFloat(session.height*scale))
        if let picture = style.minimap { Renderer.image(picture,in:map,context:context) }
        else { context.setFillColor(CGColor(gray:0.2,alpha:1));context.fill(map) }
        // MAIN2BA39: only units with mask 0x20 mark the minimap.
        for unit in session.units.values where unit.status == 2 && unit.scriptFlags&0x20 != 0 {
            let dot = CGRect(x:map.minX+CGFloat(unit.position.x*scale),y:map.minY+CGFloat(unit.position.y*scale),width:CGFloat(scale),height:CGFloat(scale))
            if presentation == .modern {
                context.setFillColor(unit.enemy ? CGColor(red:0.98,green:0.38,blue:0.34,alpha:1) : CGColor(red:0.38,green:0.78,blue:1,alpha:1))
                context.fill(dot)
            } else {
                context.setFillColor(color(OriginalBattleRoster.markColor(unit)).cgColor)
                context.fill(dot)
            }
        }
        // MAIN291CC..29278: a two-pixel colour6 box around the visible cells.
        let box = CGRect(x:map.minX+CGFloat(camera.x*scale/2),y:map.minY+CGFloat(camera.y*scale/2),width:CGFloat(facts.columns*scale),height:CGFloat(facts.rows*scale))
        context.setStrokeColor(presentation == .modern ? CanvasTheme.accentFill : color(6).cgColor);context.setLineWidth(presentation == .modern ? 1.5 : 2);context.stroke(box.insetBy(dx:1,dy:1))
    }
    private func unitDetails(_ slot:Int) -> String? {
        guard let unit = session.units[slot],!unit.enemy || unit.scriptFlags&0x20 != 0,let person = try? session.people.person(unit.person) else { return nil }
        let maximum = (try? OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:session.combat)) ?? 0
        let state = unit.scriptFlags&2 != 0 ? " · 혼란" : ""
        return "\(person.name) · 병력 \(person.rawTroops)/\(maximum) · Lv \(person.level) EXP \(person.experience) · 사기 \(unit.morale) · MP \(unit.mp)\(state)"
    }
    private func movementHoverText(_ slot:Int,_ point:GridPoint) -> String? {
        guard let detail = try? BattleAssistance.movement(in:session,slot:slot,to:point),let terrain = detail.terrain else {return nil}
        let names = style.commands?.terrain.names ?? []
        let name = names.indices.contains(terrain) ? names[terrain] : "지형 #\(terrain)"
        let defense = session.combat.terrainDefensePercent.indices.contains(terrain) ? session.combat.terrainDefensePercent[terrain] : 255
        let protection = defense == 255 ? "방어 정보 없음" : "방어 \(defense)%"
        let cost = detail.entryCost.map {$0 == 255 ? "통행 불가" : "칸당 \($0)"} ?? "비용 정보 없음"
        let first = "\(name) · \(protection) · \(cost)"+(OriginalBattleTerrain.recovers(terrain:terrain) ? " · 회복 지형" : "")
        if let reason = detail.reason {return first+"\n"+reason.text}
        if let total = detail.totalCost,let remaining = detail.remaining {
            let action = previewAbility.map(strategyTitle) ?? "일반 공격"
            return first+"\n경로 \(total) / 이동력 \(detail.budget) · 남음 \(remaining) · \(action) · V: 책략 전환"
        }
        return first
    }
    /// Turn, the selected unit and any hint float over the map window.
    private func drawStatus(_ context:CGContext) {
        // The duel window covers the whole map view and has its own panels.
        if duelStage != nil,session.scriptActions.duel?.active == true { return }
        let map = layoutFacts.viewportRect,width = map.width-32
        if presentation == .modern,canInput,!overlay.active,externalStatus == nil,annotationDraft == nil,
           case .moving(let slot) = phase,let cell = hoveredCell,let text = movementHoverText(slot,cell) {
            CanvasTheme.chip(text,at:CGPoint(x:map.midX,y:map.maxY-35),maximumWidth:width,in:context)
            return
        }
        if presentation == .original {
            CanvasTheme.chip("\(session.turns.roundIndex+1)/\(session.header.turnLimit) 턴 · 날씨 \(weatherName)",
                             at:CGPoint(x:map.minX+8,y:map.minY+18),centered:false,maximumWidth:width,in:context)
        }
        // The engine sidebar has a unit card; the original frames keep the chip.
        var detail = presentation == .modern ? "" : (inspected ?? selected ?? hovered).flatMap(unitDetails) ?? ""
        if showsThreat,let point = hoveredCell {
            let map = threatMap(),slots = threatSources(point,map).sorted()
            let names = slots.compactMap {session.units[$0].map {personName($0.person)}}.joined(separator:", ")
            detail = slots.isEmpty ? "공개된 적의 현재 위협 없음 · 숨은 적·증원·상태 회복은 미포함" : "이 칸 위협 \(slots.count)부대: \(names) · AI 행동 확정 아님"
        }
        if let choice = strategySelection {
            if choice.abilityID >= 30 {detail = presentation == .modern ? "" : "범위 대상 · Enter: 확인 · Esc: 취소"}
            else if let slot = choice.targetSlot,let unit = session.units[slot],let person = try? session.people.person(unit.person) {
                detail = "대상: \(person.name) · 병력 \(person.rawTroops) · 사기 \(unit.morale) · 화살표/Tab: 변경 · Enter: 실행 · Esc: 취소"
            }
        }
        if !session.objectiveEvents.isEmpty && onRetirement == nil { detail = "원작 목표 이벤트 \(session.objectiveEvents.map(\.kind)) 발생 · 캠페인에 적용하지 않음" }
        var y = map.maxY-18
        if !detail.isEmpty,!overlay.active {
            CanvasTheme.chip(detail,at:CGPoint(x:map.midX,y:y),maximumWidth:width,in:context);y -= 30
        }
        let waits = phase != .idle || strategySelection != nil || annotationDraft != nil
        let note = externalStatus ?? (waits || Date().timeIntervalSince(messageTime) < 4 ? message : "")
        if !note.isEmpty { CanvasTheme.chip(note,at:CGPoint(x:map.midX,y:y),maximumWidth:width,in:context) }
    }
    override func draw(_ dirtyRect:NSRect) {
        if presentation == .modern,renderedTextScale != CanvasTheme.textScale {
            renderedTextScale = CanvasTheme.textScale
            layoutFacts = BattleMapViewport.layout(source:style.layout,width:session.width,height:session.height,mode:mapViewMode,textScale:renderedTextScale)
            listTop = min(listTop,listTopLimit);overlay.viewport = layoutFacts.viewportRect
        }
        updateCamera()
        NSColor.black.setFill();bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x:canvasOrigin.x,y:canvasOrigin.y);context.scaleBy(x:scale,y:scale)
        context.interpolationQuality = .none
        trackTroops()
        drawFrame(context);drawField(context);drawList(context);drawMinimap(context);drawStatus(context)
        if combatPlayer == nil { drawForecasts(context) }
        if combatPlayer != nil { drawCombat(context) }
        let area = layoutFacts.viewportRect
        var corner = area.minY+16
        if DialoguePace.shared.skipping {
            CanvasTheme.chip("건너뛰는 중",at:CGPoint(x:area.maxX-50,y:corner),maximumWidth:120,color:CanvasTheme.accent,in:context);corner += 24
        } else if fastForward {
            CanvasTheme.chip("빨리 감기 ×\(OriginalBattleView.fastRate)",at:CGPoint(x:area.maxX-56,y:corner),maximumWidth:120,in:context);corner += 24
        }
        if presentation == .modern,combatPlayer == nil,duelPlayer == nil,[.friendlyAI,.enemyAI].contains(session.turns.stage) {
            let enemy = session.turns.stage == .enemyAI
            let actingSlot = animator.walker?.slot ?? session.turns.pendingAI.first
            var text = enemy ? "적군 행동 중" : "우군 행동 중"
            if let slot = actingSlot,let unit = session.units[slot],unit.status == 2,!(unit.enemy && unit.scriptFlags&0x20 == 0),
               let person = try? session.people.person(unit.person) {
                text = "\(enemy ? "적군" : "우군") 행동 · \(person.name) (\(className(person.classID)) Lv\(person.level))"
            }
            CanvasTheme.chip(text,at:CGPoint(x:area.midX,y:area.minY+16),maximumWidth:260,
                             color:enemy ? CanvasTheme.danger : CanvasTheme.accent,in:context)
        }
        if showsThreat,combatPlayer == nil {
            let title = ["일반 공격","책략 ✦","공격 + 책략 ✦"][threatMode]+(pinnedThreat == nil ? "" : " · 1부대 고정")
            CanvasTheme.chip(title+" · Shift D 전환 · P 고정",at:CGPoint(x:area.maxX-125,y:corner),maximumWidth:250,color:NSColor(red:1,green:0.62,blue:0.3,alpha:1),in:context)
        }
        if presentation == .modern,showsObjectiveTracker,canInput,!overlay.active,let text = objective?().text,!text.isEmpty {
            let remaining = max(0,session.header.turnLimit-session.turns.roundIndex)
            // Only a known progress state reaches the player; a battle without
            // tracker facts shows the goal and the turns left.
            let state = objectiveEntries().filter { $0.state != .unavailable }.map { " · "+$0.state.rawValue }.joined()
            let publicText = text.split(whereSeparator:{$0.isNewline}).map(String.init).joined(separator:" · ")
            CanvasTheme.chip("목표: "+publicText+"\n현재 턴 포함 \(remaining)턴 남음\(state) · O 숨기기",
                at:CGPoint(x:area.midX,y:area.minY+45),maximumWidth:area.width-48,color:CanvasTheme.text,in:context)
        }
        if let notice = animator.notice,let catalog = combatArt?.catalog {
            let area = layoutFacts.viewportRect
            let text:String
            if case .phase(let enemy) = notice {
                text = enemy ? (style.commands?.conditions.enemyPhase ?? "적군 순서") : playerPhaseText
            } else {
                text = catalog.text(notice,person:personName,strategy:strategyTitle,kind:kindLabel)
            }
            if presentation == .modern {
                switch notice {
                case .turn,.phase: drawBanner(text,in:area,context)
                default: CanvasTheme.chip(text,at:CGPoint(x:area.midX,y:area.midY),maximumWidth:area.width-32,in:context)
                }
            } else {
                CanvasTheme.chip(text,at:CGPoint(x:area.midX,y:area.midY),maximumWidth:area.width-32,in:context)
            }
        }
        context.restoreGState()
    }
    /// MAIN28122 names the weather through 1CB6:4E08, which reads DS:3B7C at
    /// the weather byte: 0 clear, 1 cloudy, 2 rain.
    private var weatherClass:Int {
        let lookup = session.combat.strategyEnvironmentLookup,index = Int(session.turns.weatherIndex)
        return lookup.indices.contains(index) ? lookup[index] : index
    }
    private var weatherName:String {
        let names = combatArt?.catalog.weathers ?? [],index = weatherClass
        return names.indices.contains(index) ? names[index] : String(index)
    }
    /// Held Control runs the campaign this many times as fast.
    static let fastRate = 4
    var fastForward = false { didSet { if fastForward != oldValue { needsDisplay = true } } }
    /// Fast-forward closes lines and timed notices as a click would.
    func skipLines() {
        guard !overlay.isSuspended else {return}
        if overlay.notice != nil { overlay.skipNotice() }
        if animator.notice != nil { animator.dismissNotice() }
    }
    /// Each target in reach shows the effect or damage it would take.
    /// An engine addition over the source's target cells.
    private func drawForecasts(_ context:CGContext) {
        let facts = layoutFacts,viewport = facts.viewportRect
        context.saveGState();context.clip(to:viewport)
        if canInput,!overlay.active,case .moving(let slot) = phase,let point = hoveredCell,let preview = movePreview(slot,at:point) {
            let targets = previewAbility.flatMap {preview.strategies[$0]} ?? (previewAbility == nil ? preview.attackTargets : [])
            for target in targets {
                guard let unit = session.units[target] else {continue}
                let cell = camera.rect(of:unit.position,in:viewport,size:facts.cell)
                let text:String
                if let ability = previewAbility {text = projectedEffect(slot,ability:ability,target:target).map(effectText) ?? "책략 효과 계산 불가"}
                else if let snapshot = try? BattleProjection(session),let impact = try? snapshot.physical(slot,target:target) {text = "예상 -\(impact.damage)"+(impact.remainingTroops == 0 ? " · 격파" : "")}
                else {text = "공격 대상"}
                CanvasTheme.chip(text,at:CGPoint(x:cell.midX,y:cell.minY-6),maximumWidth:190,color:CanvasTheme.accent,in:context)
            }
        } else if let choice = strategySelection,let slot = selected,let targets = try? legalStrategyTargets(choice.abilityID,casterSlot:slot) {
            for targetSlot in targets {
                guard let unit = session.units[targetSlot],unit.status == 2,!(unit.enemy && unit.scriptFlags&0x20 == 0),
                      let effect = projectedEffect(slot,ability:choice.abilityID,target:targetSlot) else { continue }
                let text = effectText(effect)
                let cell = camera.rect(of:unit.position,in:viewport,size:facts.cell)
                let chosen = choice.targetSlot == targetSlot || choice.abilityID >= 30
                CanvasTheme.chip(text,at:CGPoint(x:cell.midX,y:cell.minY-6),maximumWidth:180,
                                 color:chosen ? CanvasTheme.accent : CanvasTheme.text,in:context)
            }
        } else if case .attackTarget(let slot) = phase,let cells = try? attackCells(slot) {
            for unit in session.units.values where unit.status == 2 && unit.enemy && cells.contains(unit.position) && unit.scriptFlags&0x20 != 0 {
                guard let value = try? session.attackForecast(slot,target:unit.slot) else { continue }
                let cell = camera.rect(of:unit.position,in:viewport,size:facts.cell)
                var text = value.defeats ? "-\(value.damage) 격파" : "-\(value.damage)"
                if value.counterPercent > 0 { text += " · 반격 \(value.counterPercent)%" }
                CanvasTheme.chip(text,at:CGPoint(x:cell.midX,y:cell.minY-6),maximumWidth:180,
                                 color:value.defeats ? CanvasTheme.accent : CanvasTheme.text,in:context)
            }
        } else if case .itemTarget(let slot,let item) = phase {
            let use = OriginalItemUse.of(item)
            let targets = (try? OriginalItemOperation.targetSlots(in:session,userSlot:slot,use:use)) ?? []
            for targetSlot in targets {
                guard let unit = session.units[targetSlot],unit.status == 2,!(unit.enemy && unit.scriptFlags&0x20 == 0),
                      (try? OriginalItemOperation.begin(in:session,userSlot:slot,item:item,target:targetSlot))?.execution == nil,
                      let text = try? session.itemForecast(slot,item:item,target:targetSlot),!text.isEmpty else { continue }
                let cell = camera.rect(of:unit.position,in:viewport,size:facts.cell)
                CanvasTheme.chip(text,at:CGPoint(x:cell.midX,y:cell.minY-6),maximumWidth:180,in:context)
            }
        }
        context.restoreGState()
    }
    private func personName(_ id:Int) -> String { (try? session.people.person(id).name) ?? "" }
    /// 2CB4:125E's window: the scene at (16,32,416,208) over the combat view's
    /// background, participant 1 drawn first, and two panels set at setup.
    private func drawDuel(_ context:CGContext,stage:OriginalDuelStage,picture:OriginalDuelPicture) {
        let scene = OriginalDuelSprites.sourceViewport
        context.setFillColor(presentation == .modern ? CanvasTheme.background : CGColor(gray:0,alpha:1));context.fill(presentation == .modern ? ModernBattleControls.cinematicViewport : layoutFacts.viewportRect)
        context.saveGState()
        if presentation == .modern { context.translateBy(x:16,y:16) }
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
        context.restoreGState()
    }
    /// 1CB6:F752 with sides 2 and 3: level and class, strength, troops and experience.
    private func drawDuelPanel(_ context:CGContext,side:Int,panel:OriginalDuelPanel,art:OriginalCombatArt) {
        let window = CGRect(x:side == 0 ? 16 : 224,y:240,width:208,height:144)
        CanvasTheme.panel(window,in:context)
        let portraitX = side == 0 ? 24 : 360
        if let image = portraitImage?(panel.person) { Renderer.image(image,in:CGRect(x:portraitX,y:248,width:64,height:80),context:context) }
        let plain = CanvasTheme.attributes(CanvasTheme.font(12),CanvasTheme.text),faint = CanvasTheme.attributes(CanvasTheme.font(12),CanvasTheme.muted)
        let name = personName(panel.person),width = (name as NSString).size(withAttributes:plain).width
        (name as NSString).draw(at:CGPoint(x:CGFloat(portraitX)+32-width/2,y:346),withAttributes:plain)
        let textX = side == 0 ? 104 : 240,gaugeX = textX+40,texts = art.catalog.texts
        let className = art.catalog.classNames.indices.contains(panel.classID) ? art.catalog.classNames[panel.classID] : ""
        (originalFormat(texts.level,[String(panel.level),className]) as NSString).draw(at:CGPoint(x:CGFloat(textX),y:254),withAttributes:plain)
        if presentation == .modern {
            let right = CGFloat(side == 0 ? Int(window.maxX)-12 : portraitX-12)
            func row(_ label:String,_ y:CGFloat,_ shown:String,_ share:(value:Int,maximum:Int)) {
                (label as NSString).draw(at:CGPoint(x:CGFloat(textX),y:y),withAttributes:CanvasTheme.attributes(CanvasTheme.font(11),CanvasTheme.muted))
                (shown as NSString).draw(in:CGRect(x:CGFloat(textX),y:y-1,width:right-CGFloat(textX),height:16),
                    withAttributes:CanvasTheme.attributes(CanvasTheme.number(12,.semibold),CanvasTheme.text,alignment:.right))
                drawStatBar(context,CGRect(x:CGFloat(textX),y:y+16,width:right-CGFloat(textX),height:3),value:share.value,maximum:share.maximum)
            }
            row(texts.strength,278,"\(panel.strength)",(panel.strength,100))
            row(texts.troops,304,"\(panel.troops) / \(panel.maxTroops)",(panel.troops,panel.maxTroops))
            row(texts.duelExperience,330,"\(panel.experience)",(panel.experience,100))
            return
        }
        for (row,value) in [(texts.strength,panel.strength,100),(texts.troops,panel.troops,panel.maxTroops),(texts.duelExperience,panel.experience,100)].enumerated() {
            let y = 278+row*24
            (value.0 as NSString).draw(at:CGPoint(x:CGFloat(textX),y:CGFloat(y)),withAttributes:faint)
            drawCombatGauge(context,x:gaugeX,y:y+6,width:64,value:value.1,maximum:value.2,text:"\(value.1)")
        }
    }
    /// MAIN2A556 and F752: the scene at (16,32,416,208) and two stat windows.
    private func drawCombat(_ context:CGContext) {
        guard let player = combatPlayer,let art = combatArt else { return }
        context.setFillColor(CanvasTheme.background);context.fill(presentation == .modern ? ModernBattleControls.cinematicViewport : layoutFacts.viewportRect)
        context.saveGState()
        if presentation == .modern { context.translateBy(x:16,y:16) }
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
        guard let frame = player.frame else { context.restoreGState();return }
        if let notice = frame.notice {
            CanvasTheme.chip(notice,at:CGPoint(x:224,y:152),maximumWidth:320,in:context)
        }
        guard let page = frame.page else { context.restoreGState();return }
        let window = CGRect(x:48,y:112,width:352,height:96)
        CanvasTheme.panel(window,in:context)
        let style = CanvasTheme.attributes(CanvasTheme.font(14,.medium),CanvasTheme.text)
        for line in page.lines { (line.text as NSString).draw(at:CGPoint(x:104,y:CGFloat(line.y)-2),withAttributes:style) }
        for gauge in page.gauges { drawCombatGauge(context,x:144,y:gauge.y,width:160,value:gauge.value,maximum:gauge.maximum,text:"\(gauge.value)") }
        context.restoreGState()
    }
    private func shownIndex(_ player:OriginalCombatPlayer) -> Int {
        guard let shown = player.picture else { return -1 }
        return shown.layers.hashValue^shown.scroll
    }
    /// MAIN28806: the bar turns at seven and three tenths of the maximum.
    private func drawCombatGauge(_ context:CGContext,x:Int,y:Int,width:Int,value:Int,maximum:Int,text:String) {
        if presentation == .modern {
            // A rounded track with the number beside it.
            drawStatBar(context,CGRect(x:CGFloat(x),y:CGFloat(y)+1,width:CGFloat(width)-44,height:6),value:value,maximum:maximum)
            (text as NSString).draw(in:CGRect(x:CGFloat(x+width)-40,y:CGFloat(y)-5,width:40,height:16),
                withAttributes:CanvasTheme.attributes(CanvasTheme.number(12,.semibold),CanvasTheme.text,alignment:.right))
            return
        }
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
        if presentation == .modern {
            // Label and number on a row, a thin bar under them.
            let right = CGFloat(side == 0 ? Int(window.maxX)-12 : portraitX-12)
            func row(_ label:String,_ y:CGFloat,_ shown:String,_ share:(value:Int,maximum:Int)?) {
                (label as NSString).draw(at:CGPoint(x:CGFloat(textX),y:y),withAttributes:CanvasTheme.attributes(CanvasTheme.font(11),CanvasTheme.muted))
                (shown as NSString).draw(in:CGRect(x:CGFloat(textX),y:y-1,width:right-CGFloat(textX),height:16),
                    withAttributes:CanvasTheme.attributes(CanvasTheme.number(12,.semibold),CanvasTheme.text,alignment:.right))
                guard let share = share else { return }
                drawStatBar(context,CGRect(x:CGFloat(textX),y:y+16,width:right-CGFloat(textX),height:3),value:share.value,maximum:share.maximum)
            }
            row(valueLabel,274,"\(value)",(value,2000))
            row(texts.troops,298,"\(troops) / \(maximum)",(troops,maximum))
            row(texts.morale,322,"\(morale)",(morale,100))
            if let last = last {
                if let shown = last.value { row(last.label,346,"\(shown)",(shown,last.maximum)) }
                else { row(last.label,346,originalFormat(texts.percent,[String(last.maximum)]),nil) }
            }
            return
        }
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
    /// The modern combat card's bar, coloured at MAIN28806's seven and three tenths.
    private func drawStatBar(_ context:CGContext,_ track:CGRect,value:Int,maximum:Int) {
        CanvasTheme.fill(track,CGColor(gray:1,alpha:0.10),radius:track.height/2,in:context)
        guard maximum > 0,value > 0 else { return }
        let share = value*10/maximum
        let color = share >= 7 ? CGColor(red:0.46,green:0.76,blue:0.54,alpha:1) : share >= 3 ? CanvasTheme.accentFill : CGColor(red:0.9,green:0.42,blue:0.36,alpha:1)
        CanvasTheme.fill(CGRect(x:track.minX,y:track.minY,width:max(track.height,track.width*CGFloat(min(value,maximum))/CGFloat(maximum)),height:track.height),color,radius:track.height/2,in:context)
    }
    /// Canvas-space panel input, shared with synthetic UI routing checks.
    @discardableResult
    func clickPanel(_ point:CGPoint) -> Bool {
        let facts = layoutFacts
        if presentation == .modern {
            if unitCardRect.contains(point),canInput,!overlay.active,let slot = inspected ?? selected ?? hovered ?? speakingSlot {
                openConditionDetails(slot);return true
            }
            if let button = playerControls.first(where:{ $0.rect.contains(point) }) {
                if button.enabled { do { try performPlayerAction(button.action) } catch { report(error) } }
                return true
            }
            if ModernBattleControls.header.contains(point) || ModernBattleControls.footer.contains(point) { return true }
        } else if OriginalBattleLayout.rect(facts.functionButton).contains(point) { openFunctionMenu();return true }
        if let side = facts.sideButtons.firstIndex(where:{ OriginalBattleLayout.rect($0).contains(point) }) { listSide = side;listTop = 0;inspected = nil;return true }
        if OriginalBattleLayout.rect(facts.list.rect).contains(point) {
            let row = Int(point.y-CGFloat(facts.list.rect[1]))/facts.list.rowHeight+listTop,rows = listRows
            if rows.indices.contains(row),let unit = session.units[rows[row]] {
                inspected = unit.slot
                if unit.status == 2 { camera.center(on:unit.position) }
                if presentation == .modern,mapViewMode != .overview,canInput,!overlay.active,strategySelection == nil,
                   phase == .idle || isChoosingMove,OriginalBattleCommand.denial(unit) == nil,
                   (try? session.requireManualUnit(unit.slot)) != nil {
                    selectReadyUnit(unit.slot)
                }
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
        guard !overlay.isSuspended else {return}
        window?.makeFirstResponder(self)
        if combatPlayer != nil { combatPlayer?.skip();return }
        if animator.notice != nil { animator.dismissNotice();return }
        let p = canvasPoint(event)
        if annotationDraft != nil {
            if canInput,let point = camera.cell(at:p,in:layoutFacts.viewportRect,size:layoutFacts.cell) {pickAnnotation(point)}
            return
        }
        if clickPanel(p) { needsDisplay = true;return }
        guard let point = camera.cell(at:p,in:layoutFacts.viewportRect,size:layoutFacts.cell) else { return }
        if presentation == .modern,mapViewMode == .overview {applyMapView(previousTacticalMode,focus:point);return}
        inspected = nil
        do {
            guard canInput else { throw BattleError.illegalAction("Continue the current source phase first") }
            let target = session.units.values.first(where:{$0.status == 2 && $0.position == point})
            if var choice = strategySelection,let slot = selected {
                let targets = try legalStrategyTargets(choice.abilityID,casterSlot:slot)
                guard let target = target,targets.contains(target.slot) else {throw BattleError.illegalAction("표시된 책략 대상 중에서 선택하세요.")}
                if choice.abilityID < 30 {choice.targetSlot = target.slot;strategySelection = choice;try executeSelectedStrategy()}
                else {message = "아래 책략 실행 버튼 또는 Enter로 전체 대상 적용을 확인하세요."}
            } else { try clickField(point,target) }
        } catch { report(error) }
        needsDisplay = true
    }
    /// MAIN27C7A: a click with no unit under it shows that cell's terrain.
    private func showTerrain(_ point:GridPoint) {
        guard let texts = style.commands?.terrain else { return }
        let id = Int(session.terrain[point.y*session.width+point.x]),facts = layoutFacts.terrain,cell = style.layout.cell
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
            // MAIN2D9F3: a hidden unit keeps its cell and goes straight to commands.
            selectReadyUnit(unit.slot,center:false)
        case .moving(let slot):
            guard let unit = session.units[slot] else { return }
            if point == unit.position { openCommand(slot);return }
            let detail = try BattleAssistance.movement(in:session,slot:slot,to:point)
            guard detail.reason == nil else {
                say(detail.reason?.text ?? refusal("outOfMoveRange"))
                return
            }
            let path = try session.move(slot,to:point)
            acceptedInput(.init(kind:.battleMove,slot:slot,x:point.x,y:point.y))
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
                    if let result = try self.flow.finishManualOperation().attack {
                        _ = self.drainHeldCues()
                        self.showAttackResult(result)
                        self.checkAutoTurnEndPrompt()
                    }
                    else {_ = self.drainHeldCues();self.waitingForAttack = true;self.message = ""}
                } catch { self.report(error) }
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
                onItemTransfer?(unit.person,target.person,item)
                resetCommand()
                _ = drainHeldCues()
                say(filled("gave",itemName(item))) { [weak self] in self?.checkAutoTurnEndPrompt() }
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
        if cell != hoveredCell { hoveredCell = cell;if presentation == .modern { needsDisplay = true } }
        if annotationDraft != nil,let cell {annotationCursor = cell;needsDisplay = true}
    }
    override func mouseExited(with event:NSEvent) {
        if hovered != nil || hoveredCell != nil { hovered = nil;hoveredCell = nil;needsDisplay = true }
    }
    /// The map cell under the pointer, for the modern cursor and route preview.
    private var hoveredCell:GridPoint?
    /// The source has no such shortcut; a scene has no effect on results.
    override func rightMouseDown(with event:NSEvent) {
        guard !overlay.isSuspended else {return}
        if annotationDraft != nil {cancelAnnotationDraft();return}
        if combatPlayer != nil { combatPlayer?.finish();return }
        stepBack()
    }
    override func scrollWheel(with event:NSEvent) {
        guard !overlay.isSuspended else {return}
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
        guard !overlay.isSuspended else {return}
        guard let event = OriginalSettings.current.controls.remappedEvent(event,context:.battle) else {return}
        if combatPlayer != nil {
            if event.keyCode == 53 { combatPlayer?.finish() } else { combatPlayer?.skip() }
            return
        }
        if animator.notice != nil { animator.dismissNotice();return }
        guard !overlay.active else { return }
        if annotationDraft != nil {
            if event.keyCode == 53 {cancelAnnotationDraft()}
            else if [36,76].contains(event.keyCode),let cursor = annotationCursor {pickAnnotation(cursor)}
            else if let step = [123:(-1,0),124:(1,0),125:(0,1),126:(0,-1)][Int(event.keyCode)],let cursor = annotationCursor {
                let point = GridPoint(x:min(session.width-1,max(0,cursor.x+step.0)),y:min(session.height-1,max(0,cursor.y+step.1)))
                annotationCursor = point;camera.follow(point,margin:layoutFacts.followMargin);needsDisplay = true
            }
            return
        }
        if canInput,event.modifierFlags.intersection([.command,.control,.option]).isEmpty {
            if event.keyCode == 45 {openAnnotations();return}
            if event.keyCode == 11,let slot = selected ?? inspected {openFavoriteManagement(slot);return}
            if event.keyCode == 17,let slot = selected ?? inspected {openAreaAdvice(slot);return}
            if event.keyCode == 8,let target = hovered ?? inspected {openCooperation(target);return}
            if event.keyCode == 6,presentation == .modern {
                let next:BattleMapViewMode = mapViewMode == .standard ? .large : mapViewMode == .large ? .overview : previousTacticalMode
                applyMapView(next);return
            }
            if event.keyCode == 31 {showsObjectiveTracker.toggle();needsDisplay = true;return}
            if event.keyCode == 15 {openRosterTools();return}
            if event.keyCode == 34,let slot = inspected ?? selected ?? hovered {openConditionDetails(slot);return}
            if event.keyCode == 4,let slot = inspected ?? selected ?? hovered {openRecoveryFinder(slot);return}
            if event.keyCode == 9,case .moving(let slot) = phase {openMovePreviewActions(slot);return}
            if event.keyCode == 5,let slot = selected {
                let ability = strategySelection?.abilityID ?? previewAbility
                let target = strategySelection?.targetSlot ?? hovered
                if ability != nil || target.flatMap({session.units[$0]?.enemy}) == true {openGrowthForecast(slot,target:target,ability:ability);return}
            }
            if event.keyCode == 35 {
                if let slot = hovered ?? inspected,let unit = session.units[slot],unit.enemy,unit.status == 2,unit.scriptFlags&0x20 != 0 {
                    pinnedThreat = pinnedThreat?.slot == slot ? nil : (slot,unit.person);showsThreat = true
                } else {pinnedThreat = nil}
                needsDisplay = true;return
            }
            if event.keyCode == 3,let slot = selected {
                if let ability = strategySelection?.abilityID ?? previewAbility,let target = strategySelection?.targetSlot ?? hovered {
                    openStrategyEffectDetails(slot,ability:ability,target:target);return
                }
                if let target = hovered,session.units[target]?.enemy == true {openDamageDetails(slot,target:target);return}
            }
        }
        if presentation == .modern,mapViewMode == .overview {
            if event.keyCode == 53 {applyMapView(previousTacticalMode)}
            return
        }
        if strategySelection == nil,let step = [123:(-1,0),124:(1,0),125:(0,1),126:(0,-1)][Int(event.keyCode)] {
            camera.move(columns:step.0,rows:step.1);needsDisplay = true;return
        }
        guard !event.isARepeat else { return }
        if event.keyCode == 2,event.modifierFlags.intersection([.command,.control,.option]).isEmpty {
            if event.modifierFlags.contains(.shift) {threatMode = (threatMode+1)%3;showsThreat = true;needsDisplay = true}
            else {showsThreat.toggle()};return
        }
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
                if phase == .idle { try performPlayerAction(.nextUnit) }
                else { try performPlayerAction(.command) }
            } else if event.keyCode == 49 {
                if phase == .idle { try performPlayerAction(.nextUnit) }
                else { try performPlayerAction(.wait) }
            } else { super.keyDown(with:event) }
        } catch { report(error) }
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
