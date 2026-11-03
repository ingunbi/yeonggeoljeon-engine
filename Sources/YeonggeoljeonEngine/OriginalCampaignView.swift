// SPDX-License-Identifier: GPL-3.0-only
import AppKit

final class OriginalCampaignView:NSView,EngineTimedView {
    let host:OriginalCampaignHost
    let renderer:Renderer
    private var timer:Timer?
    private var errorText:String?
    private var inputNotice:String?
    private var battleView:OriginalBattleView?
    /// In-game selectors and waiting lines drawn above the stage and battle.
    private let overlay = CanvasOverlayView()
    private var settings = OriginalSettings.current
    private lazy var combatArt:OriginalCombatArt? = (try? OriginalCombatCatalog.load(from:host.data.root.appendingPathComponent("combat-view.json"))).flatMap { try? OriginalCombatArt(catalog:$0) }
    private var imageCache:[String:CGImage] = [:]
    private var presentationObserver:NSObjectProtocol?
    private lazy var audio:OriginalAudio? = (try? OriginalMusicCatalog.load(from:host.data.root.appendingPathComponent("music.json"))).map { OriginalAudio(catalog:$0) }
    /// Each shop list remembers its row while the visit moves between them.
    private var shopCursor:[OriginalShopList:Int] = [:]
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    convenience init(data:DataSet) throws {
        let c = Calendar.current.dateComponents([.day,.hour,.minute,.second],from:Date())
        func bcd(_ n:Int?) -> UInt8 { let v = n ?? 0;return UInt8(((v/10)<<4)|(v%10)) }
        try self.init(host:OriginalCampaignHost(data:data,rng:OriginalRNG.clockSeed(dayByte:bcd(c.day),hourByte:bcd(c.hour),minuteByte:bcd(c.minute),secondByte:bcd(c.second))))
    }
    init(host:OriginalCampaignHost) throws {
        self.host = host
        host.announcesItems = true
        host.presentsDuels = true
        host.citizensWander = true
        renderer = try Renderer(host.data)
        super.init(frame:CGRect(x:0,y:0,width:1024,height:640))
        curtain.frame = bounds;curtain.autoresizingMask = [.width,.height];addSubview(curtain)
        overlay.frame = bounds;overlay.autoresizingMask = [.width,.height];addSubview(overlay)
        overlay.onSound = { [weak self] id in self?.audio?.playEffect(id) }
        NotificationCenter.default.addObserver(forName:OriginalSettings.changed,object:nil,queue:.main) { [weak self] _ in self?.applySettings() }
        applySettings()
        overlay.restoreFocus = { [weak self] in
            guard let self = self else { return }
            if let board = self.battleView,!board.isHidden { self.window?.makeFirstResponder(board) }
            else { self.window?.makeFirstResponder(self) }
            self.needsDisplay = true
        }
        timer = Timer.scheduledTimer(withTimeInterval:1.0/60,repeats:true) { [weak self] _ in self?.tick() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.flagsChanged]) { [weak self] event in
            guard let self = self,event.window === self.window,self.window?.contentView === self else { return event }
            return self.shortcut(event) ? nil : event
        }
        presentationObserver = NotificationCenter.default.addObserver(forName:CanvasPresentation.changed,object:nil,queue:.main) { [weak self] _ in
            guard let self = self else { return }
            self.battleView?.presentation = CanvasPresentation.current
            if self.battleView?.isHidden != false { self.overlay.viewport = self.fieldOverlay }
            else { self.overlay.viewport = self.battleView?.layoutFacts.viewportRect ?? self.overlay.viewport }
            // The title menu changes between the engine rows and MAIN's window.
            if !self.host.hasStarted,self.screenPlayer == nil,!self.fading,self.overlay.active { self.presentTitleMenu() }
            self.needsDisplay = true
        }
    }
    deinit { presentationObserver.map(NotificationCenter.default.removeObserver) }
    private func image(_ path:String?) -> CGImage? {
        guard let path = path else { return nil }
        if let cached = imageCache[path] { return cached }
        guard let url = try? host.data.containedFile(path),let data = try? Data(contentsOf:url),
              let picture = NSBitmapImageRep(data:data)?.cgImage else { return nil }
        imageCache[path] = picture;return picture
    }
    private func portrait(_ person:Int?,palette:Int) -> CGImage? {
        guard let person = person,let value = host.data.resources.portraits?[String(person)] else { return nil }
        return image(Renderer.portraitPath(value,palette:palette))
    }
    /// The two-button selector shows Yes before No (MAIN164A9..165C4); the
    /// answer is the source value (Yes1, No0).
    private func yesNo(_ text:String,_ answer:@escaping (Bool) -> Void) {
        overlay.show(CanvasMenu(title:text,options:[.init(label:"예"),.init(label:"아니요")],horizontal:true) { index in answer(index == 0) })
    }
    /// Native saves live outside the app bundle and the original GAME folder.
    /// YEONGGEOLJEON_SAVES moves the folder, so a test run never touches the player's saves.
    static func savesDirectory() throws -> URL {
        let folder:URL
        if let path = ProcessInfo.processInfo.environment["YEONGGEOLJEON_SAVES"],!path.isEmpty {
            folder = URL(fileURLWithPath:path,isDirectory:true)
        } else {
            let base = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            folder = base.appendingPathComponent("Yeonggeoljeon Engine",isDirectory:true).appendingPathComponent("Saves",isDirectory:true)
        }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        return folder
    }
    /// Asks for a native resume file and returns a host continuing after its
    /// source3D prompt, or nil when the panel is cancelled.
    static func chooseResume(data:DataSet) throws -> OriginalCampaignHost? {
        let panel = NSOpenPanel();panel.allowedContentTypes = [.json];panel.allowsMultipleSelection = false
        panel.directoryURL = try savesDirectory();panel.message = "자체 엔진 저장 파일을 고르세요."
        guard panel.runModal() == .OK,let url = panel.url else { return nil }
        return try OriginalCampaignHost.resume(data:data,from:OriginalCampaignResume.read(from:url))
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func stop() {
        timer?.invalidate();timer = nil;audio?.shutDown()
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor);keyMonitor = nil }
    }
    /// Engine additions. Held Control runs the game four times as fast, L
    /// opens the dialogue log, and F5 and F9 save and load the quick slot.
    private func shortcut(_ event:NSEvent) -> Bool {
        if event.type == .flagsChanged {
            fastForwardHeld = event.modifierFlags.contains(.control);needsDisplay = true
            return false
        }
        guard !event.isARepeat,event.modifierFlags.intersection([.command,.control,.option]).isEmpty else { return false }
        switch event.keyCode {
        case 37:return presentLog()
        case 96:quickSave(nil);return true
        case 101:quickLoad(nil);return true
        default:return false
        }
    }
    @objc func toggleFastForward(_ sender:Any?) {
        fastForwardLocked.toggle();needsDisplay = true
        (sender as? NSMenuItem)?.state = fastForwardLocked ? .on : .off
    }
    @objc func openDialogueLog(_ sender:Any?) { _ = presentLog() }
    /// Lines the player has read, newest last. The source keeps none.
    private func presentLog() -> Bool {
        guard host.hasStarted,!overlay.active else { return false }
        let rows = dialogueLog.map { entry in
            CanvasSheet.Row(label:entry.speaker.isEmpty ? "—" : entry.speaker,value:String(entry.text.prefix(14)),
                            detail:.init(heading:entry.speaker,body:entry.text))
        }
        guard !rows.isEmpty else { inputNotice = "아직 기록된 대사가 없습니다.";needsDisplay = true;return true }
        overlay.show(fieldSheet(title:"대사 기록",line:"",rows:rows,selected:rows.count-1,hint:"↑↓ 이동 · esc 닫기") { _ in })
        return true
    }
    @objc func quickSave(_ sender:Any?) {
        guard host.hasStarted,!overlay.active else { return }
        do {
            try saveSlots().write(try host.resumeSnapshot(),title:slotTitle,named:.quick)
            overlay.show(CanvasNotice(speaker:"",text:"빠른 저장했습니다.",portrait:nil,timeout:1.2) { })
        } catch { inputNotice = "지금은 저장할 수 없습니다. 마을이나 세계지도에서 다시 시도하세요.";needsDisplay = true }
    }
    @objc func quickLoad(_ sender:Any?) {
        guard !overlay.active else { return }
        guard let slots = try? saveSlots(),slots.entry(.quick) != nil else { inputNotice = "빠른 저장이 없습니다.";needsDisplay = true;return }
        yesNo("빠른 저장을 불러올까요?") { [weak self] yes in
            guard yes,let self = self else { return }
            do { self.replace(with:try OriginalCampaignView(host:try OriginalCampaignHost.resume(data:self.host.data,from:slots.read(.quick)))) }
            catch { self.recordInputError(error) }
        }
    }
    /// An engine addition: an idle field writes the autosave whenever its
    /// scene or map changes since the last one.
    private func autosave() {
        let state = host.vm.state
        let key = "\(state.chapter):\(state.member):\(state.block):\(state.groupBase):\(state.packedMap)"
        guard key != autosaveKey,let slots = try? saveSlots(),let snapshot = try? host.resumeSnapshot() else { return }
        autosaveKey = key
        try? slots.write(snapshot,title:slotTitle,named:.auto)
    }
    /// Word +A bit 8 greys the palette; the filter sits over the whole canvas.
    private func applySettings() {
        settings = OriginalSettings.current
        wantsLayer = true;layerUsesCoreImageFilters = true
        contentFilters = settings.monochrome ? [CIFilter(name:"CIPhotoEffectMono")].compactMap { $0 } : []
        audio?.volume = settings.volume
    }
    /// The opening or ending program in front of everything else.
    private var screenPlayer:OriginalScreenPlayer?
    private var screenIsOpening = false
    private var screenIsQuit = false
    private var keyMonitor:Any?
    private var fastForwardHeld = false
    private var fastForwardLocked = false
    private var fastForward:Bool { fastForwardHeld || fastForwardLocked }
    private var skipTicks = 0
    private var dialogueLog:[(speaker:String,text:String)] = []
    private var lastLogged:CommandSnapshot?
    private var autosaveKey:String?
    private var quitScreenStarted = false
    private var endingMusicStarted = false
    private var endingFade = 0.0
    private static let endingFadeSeconds = 15*OriginalScreenPlayer.tick*4/100
    /// C456 fades to black (4A22) before it draws a new screen and 4A10 fades
    /// back in: GRPDRV function 16h, sixteen steps of two retraces, about
    /// 0.53 s each at 59.94 Hz. The source does nothing else meanwhile.
    static let screenFadeSeconds = 32/59.94
    private var lastPicture:CGImage?
    private lazy var mainFont = OriginalFont.load(host.data)
    private var fadeLevel = 0.0
    private var fadeRising = false
    private var fadeMidpoint:(() -> Void)?
    /// Seconds of black after the midpoint, and of a held fade after the fade in.
    private var fadeHoldBlack = 0.0,fadeHoldAfter = 0.0
    private var fadeReturns = true
    /// The battle entry keeps the last field picture while it fades out.
    private var freezePicture = false
    private var fading:Bool { fadeRising || fadeLevel > 0 || fadeHoldAfter > 0 }
    /// A black sheet above the stage and the battle; the host waits while it moves.
    private let curtain = CanvasCurtain()
    /// Fades to black, runs `action` (which may replace this view), holds black,
    /// then fades in (or lifts at once when the screen below is black already).
    private func fadeThrough(holdBlack:Double = 0,holdAfter:Double = 0,fadeIn:Bool = true,_ action:@escaping () -> Void) {
        fadeRising = true;fadeMidpoint = action;fadeHoldBlack = holdBlack;fadeHoldAfter = holdAfter;fadeReturns = fadeIn
        updateCurtain()
    }
    /// A screen that a load or a new game opens starts black and fades in.
    func fadeIn() { fadeLevel = 1;fadeRising = false;fadeHoldBlack = 0;fadeHoldAfter = 0;fadeReturns = true;updateCurtain() }
    private func advanceFade() {
        let frame = 1.0/60,step = frame/Self.screenFadeSeconds
        if fadeRising {
            fadeLevel = min(1,fadeLevel+step)
            if fadeLevel >= 1 {
                fadeRising = false
                let action = fadeMidpoint;fadeMidpoint = nil;action?()
            }
        } else if fadeHoldBlack > 0 { fadeHoldBlack -= frame }
        else if fadeLevel > 0 { fadeLevel = fadeReturns ? max(0,fadeLevel-step) : 0 }
        else if fadeHoldAfter > 0 { fadeHoldAfter -= frame }
        updateCurtain()
    }
    private func updateCurtain() { curtain.isHidden = fadeLevel <= 0;curtain.alphaValue = CGFloat(fadeLevel);needsDisplay = true }
    private func makeScreen(_ name:String) -> OriginalScreenPlayer? {
        guard let loaded = try? OriginalScreenCatalog.load(from:host.data.root),let ops = loaded.catalog.programs[name] else { return nil }
        let player = OriginalScreenPlayer(ops:ops,assets:loaded.catalog.assets,data:loaded.data)
        player.musicBusy = { [weak self] in self?.audio?.programPlaying ?? false }
        return player
    }
    /// HERO.COM runs OPEN, then MAIN, which opens its menu at once. Without
    /// an intact opening the window starts at that menu.
    func playOpening() {
        screenPlayer = makeScreen("opening");screenIsOpening = screenPlayer != nil
        if screenPlayer == nil { presentTitleMenu() }
    }
    private func advanceScreen(_ player:OriginalScreenPlayer) {
        for action in player.advance(centiseconds:100.0/60) {
            switch action {
            case .music(let bank,let member,let loop):audio?.playProgram(bank:bank,member:member,loop:loop)
            case .stopMusic(let rate):audio?.fadeProgram(rate)
            }
        }
        needsDisplay = true
        if player.finished { leaveScreen() }
    }
    /// HERO.COM runs MAIN after OPEN. END leaves for DOS; here it returns to the title.
    private func leaveScreen() {
        audio?.stopProgram()
        let opening = screenIsOpening,quit = screenIsQuit
        screenPlayer = nil;screenIsOpening = false;screenIsQuit = false;needsDisplay = true
        if quit { window?.performClose(nil) } else if opening { presentTitleMenu() } else { restartMain() }
    }
    /// MAIN1E3A8 runs once before main exits with code 3.
    private func startQuitScreen() {
        guard !quitScreenStarted else { return }
        quitScreenStarted = true
        audio?.select(nil);hideBattle()
        screenPlayer = makeScreen("quit");screenIsQuit = screenPlayer != nil
        window?.makeFirstResponder(self)
    }
    /// END 0x46CA: three runs END2 from its start; the rest continue END1's first scene.
    private func startEndingProgram(_ selection:Int) {
        guard let player = makeScreen(selection == 3 ? "end2" : selection == 0 ? "end1-0" : "end1-1") else { return }
        screenPlayer = player
    }
    private func advanceEnding(_ session:OriginalEndingSession) -> Bool {
        let selection = session.state.selection
        if !endingMusicStarted {
            endingMusicStarted = true
            audio?.select(nil)
            if selection != 3 { audio?.playProgram(bank:2,member:0,loop:false) }
        }
        var frontier = selection == 3
        if case .unsupported = session.output { frontier = true }
        guard frontier else { return false }
        if selection != 3,endingFade < Self.endingFadeSeconds { endingFade += 1.0/60;needsDisplay = true;return true }
        startEndingProgram(selection)
        return screenPlayer != nil
    }
    private func tick() {
        if let player = screenPlayer { advanceScreen(player);return }
        if fading { advanceFade();return }
        if host.frameworkReturn?.outcome == .quit { startQuitScreen() }
        if let session = host.ending,advanceEnding(session) { return }
        // 2CB4:125E plays song 18 for the duel and 1824 restores the one before.
        if host.ending == nil { audio?.select(host.battle?.scriptActions.duel?.active == true ? 18 : host.vm.state.currentMusic) }
        battleView?.externalStatus = errorText ?? inputNotice ?? host.notice ?? host.playerStatus
        battleView?.fastForward = fastForward
        // Fast-forward reads a line for a tenth of a second, then moves on.
        if fastForward,host.hasStarted {
            skipTicks += 1
            if skipTicks >= 6 {
                skipTicks = 0
                if overlay.notice != nil { overlay.skipNotice() }
                battleView?.skipLines()
            }
        }
        guard !overlay.active,errorText == nil else { return }
        do {
            let rate = fastForward ? Double(OriginalBattleView.fastRate) : 1
            battleView?.duelStage = host.duelStage
            if let steps = host.duelSteps,let board = battleView,!board.isPlayingDuel {
                board.playDuel(steps) { [weak self] in self?.host.finishDuelSteps() }
            }
            battleView?.advanceAnimation(rate/60)
            for id in host.takeSounds() { audio?.playEffect(id) }
            try host.advance(microseconds:Int64(16_667*settings.timeScale*rate))
            needsDisplay = true
            // MAIN fades around a battle (research/original-map-transitions.md): from
            // the field out, black, the battle, in and a held fade (0x1E297, 0x272A7);
            // a chained or restarted battle without the black; leaving, out and black
            // until the field's own 05 (C456 at 0x1E36A).
            let closing = host.ending != nil || host.frameworkReturn?.outcome == .quit
            if !closing,host.stage.palette == 3,let session = host.battle,battleView?.session !== session {
                let fromField = battleView?.isHidden != false
                freezePicture = fromField
                fadeThrough(holdBlack:fromField ? Self.screenFadeSeconds : 0,holdAfter:Self.screenFadeSeconds) { [weak self] in
                    self?.freezePicture = false;self?.act { try self?.synchronizeBattle() }
                }
                return
            }
            if !closing,battleView?.isHidden == false,host.stage.palette != 3 || host.battle == nil {
                fadeThrough(holdBlack:Self.screenFadeSeconds,fadeIn:false) { [weak self] in self?.hideBattle() }
                return
            }
            try synchronizeBattle()
            if host.fieldMenuReady { autosave() }
            if let notice = host.takeClosingNotice() { presentClosing(notice);return }
            if host.frameworkReturn?.outcome == .restart { restartMain();return }
            if let value = host.frameworkReturn,value.outcome == .pending,value.asksRetry { presentRetry() }
            else if host.saveRequest != nil { presentSave() }
            else if let choice = host.choice,choice.kind == "choice-skip" || !choice.options.isEmpty { present(choice) }
            else if host.partySelection != nil { presentParty() }
            else if host.shop != nil { presentShop() }
            else if let entry = host.cityEntry { yesNo(entry.question) { [weak self] enter in self?.act { try self?.host.answerCityEntry(enter) } } }
            else if host.retirementPresentation != nil { presentRetirement() }
            else if host.itemOffer != nil { presentItemOffer() }
            else if host.itemMessage != nil { presentItemMessage() }
            else if host.stage.dialogue != nil { presentDialogue() }
        } catch { errorText = "\(error)";needsDisplay = true }
    }
    private func act(_ body:() throws -> Void) {
        do { try body() } catch { errorText = "\(error)" }
        needsDisplay = true
    }
    /// main1E5DD shows the selector over the current screen. The native host
    /// keeps the source result; restart and exit belong to this window owner.
    private func presentRetry() {
        yesNo(host.retryPromptText ?? "원작 재시작 선택") { [weak self] yes in
            guard let self = self else { return }
            self.act { try self.host.answerRetryPrompt(yes ? 1 : 0) }
            if self.host.frameworkReturn?.outcome == .quit { self.hideBattle();self.window?.makeFirstResponder(self) }
        }
    }
    /// Exit code4 makes HERO.COM execute MAIN again. The engine replaces this
    /// campaign host with a new one, which opens on MAIN's title menu.
    private func restartMain() {
        do { replace(with:try OriginalCampaignView(data:host.data)) }
        catch { errorText = "\(error)";needsDisplay = true }
    }
    private func synchronizeBattle() throws {
        guard host.ending == nil,host.frameworkReturn?.outcome != .quit,host.stage.palette == 3,let session = host.battle else {
            hideBattle();return
        }
        if battleView?.session !== session {
            battleView?.removeFromSuperview()
            let board = try OriginalBattleView(session:session,background:battleBackground(session.definition,root:host.data.root),
                sprites:OriginalBattleSpriteRenderer(root:host.data.root),
                style:OriginalBattleStyle.load(definition:session.definition,root:host.data.root,story:host.story))
            board.onHook = { [weak self] value in guard let self = self else { return false };return try self.host.beginTurnHook(value) }
            board.onRetirement = { [weak self] value in
                guard let self = self else { return false }
                return try self.host.beginRetirement(value)
            }
            board.inputReady = { [weak self] in self?.host.battleInputReady == true }
            board.menuTexts = host.framework?.battleMenu
            board.objective = { [weak self] in (self?.host.vm.state.chapter ?? 0,self?.host.vm.state.objectiveText) }
            board.announcesPhases = true
            board.confirmsTurnEnd = true
            board.animatesActions = true
            board.settingsTexts = host.framework?.settings
            board.combatArt = combatArt
            board.portraitImage = { [weak self] person in self?.portrait(person,palette:3) }
            board.soundBusy = { [weak self] in self?.audio?.effectPlaying ?? false }
            board.stopSound = { [weak self] in self?.audio?.stopEffect() }
            session.sourceOptionsWord = settings.battleWord
            board.onSound = { [weak self] id in self?.audio?.playEffect(id) }
            board.presentation = CanvasPresentation.current
            board.frame = bounds
            addSubview(board,positioned:.below,relativeTo:curtain);battleView = board
            window?.makeFirstResponder(board)
        }
        battleView?.isHidden = false;overlay.viewport = battleView?.layoutFacts.viewportRect ?? overlay.viewport
        battleView?.announcePhase()
        if host.battleInputReady,let board = battleView {
            if session.turns.stage == .unstarted { try board.start() }
            else if board.suspended { try board.resumeSourceFlow() }
            if board.flow.canLeaveBattle { try host.finishBattleLoop() }
        }
        battleView?.needsDisplay = true
    }
    private static let pictureViewport = CGRect(x:16,y:16,width:608,height:368)
    private func hideBattle() { battleView?.isHidden = true;overlay.viewport = fieldOverlay }
    /// Modern windows have the whole canvas; original frames keep the map window.
    private var fieldOverlay:CGRect {
        CanvasPresentation.current == .modern ? CGRect(x:8,y:8,width:624,height:384) : CanvasOverlayView.fieldViewport
    }
    private var modernField:Bool { CanvasPresentation.current == .modern && host.fieldScreenState() != nil }
    /// A framed map keeps its window; a full picture gives the line the whole canvas.
    private func presentDialogue() {
        guard let dialogue = host.stage.dialogue else { return }
        if dialogue != lastLogged {
            lastLogged = dialogue;dialogueLog.append((dialogue.speaker,dialogue.text))
            if dialogueLog.count > 300 { dialogueLog.removeFirst() }
        }
        if host.stage.palette != 3 { overlay.viewport = host.fieldScreenState() != nil ? fieldOverlay : Self.pictureViewport }
        // A timed box (source 0B, 0E) closes by itself; narration sits where dialogue does.
        var line = CanvasNotice(speaker:dialogue.speaker,text:dialogue.text,portrait:portrait(dialogue.person,palette:host.stage.palette),timeout:dialogue.closesAfter) { [weak self] in
            guard let self = self else { return }
            self.act { try self.host.acknowledge() }
        }
        line.narration = dialogue.closesAfter == nil
        overlay.show(line)
    }
    /// A visit stays in one window. Each blocking call of the source routine
    /// changes the merchant's line, the list and what answers it.
    private func presentShop() {
        guard let shop = host.shop,let prompt = host.shopPrompt,let money = host.money else { return }
        let catalog = host.shopCatalog,person = catalog.merchant.person,list = shop.list
        let rows = (try? shopRows(shop,money:money)) ?? []
        let mode:CanvasSheet.Mode
        let hint:String
        switch prompt.kind {
        case .say:mode = .timed;hint = ""
        case .ask:mode = .buttons;hint = "←→ 이동 · ↩ 확인 · esc 아니요"
        case .top:mode = .list;hint = "↑↓ 이동 · ↩ 선택 · esc 나가기"
        case .list:mode = .list;hint = "↑↓ 이동 · ↩ 선택 · esc 뒤로"
        }
        // The source breaks lines for its own window width.
        let line = prompt.text.split(separator:"\n").map { $0.trimmingCharacters(in:.whitespaces) }.joined(separator:" ")
        overlay.show(CanvasSheet(portrait:portrait(person,palette:host.stage.palette),speaker:(try? host.people.person(person).name) ?? "",
            line:line,badge:("소지금","\(money)"),rows:rows,selected:min(shopCursor[list] ?? 0,max(0,rows.count-1)),mode:mode,
            buttons:prompt.kind == .ask ? ["예","아니요"] : [],hint:hint) { [weak self] value in
            guard let self = self else { return }
            if prompt.kind == .top || prompt.kind == .list,let value = value { self.shopCursor[list] = value }
            let answer = prompt.kind == .ask ? (value == 0 ? 1 : 0) : value
            self.act { try self.host.answerShop(answer) }
            if self.host.shop == nil { self.shopCursor.removeAll() }
            else if self.errorText == nil { self.presentShop() }
        })
    }
    private func itemName(_ item:Int) -> String { host.source.combat.items.first{$0.id == item}?.name ?? "" }
    private func itemDetail(_ item:Int,facts:[(label:String,value:String)]) -> CanvasSheet.Detail {
        .init(heading:itemName(item),body:host.source.combat.items.first{$0.id == item}?.description ?? "",facts:facts)
    }
    private func shopRows(_ shop:OriginalShopOperation,money:Int) throws -> [CanvasSheet.Row] {
        let catalog = host.shopCatalog
        func held(_ id:Int) throws -> [Int] { try host.people.person(id).itemIDs.filter{$0 != 255} }
        switch shop.list {
        case .top:
            let goods = shop.stock.map { (label:itemName($0),value:"\(catalog.buyingPrice($0))") }
            let owners = try OriginalShopOperation.customers(host.people).prefix(8).map { (label:try host.people.person($0).name,value:"\(try held($0).count) / 8") }
            return [.init(label:catalog.menu[0],detail:.init(heading:catalog.menu[0],facts:goods)),
                    .init(label:catalog.menu[1],detail:.init(heading:catalog.menu[1],facts:owners))]
        case .stock:
            return shop.stock.map { item in
                let price = catalog.buyingPrice(item)
                return .init(label:itemName(item),value:"\(price)",warns:price > money,
                             detail:itemDetail(item,facts:[("구매가","\(price)"),("구매 후",price > money ? "-" : "\(money-price)")]))
            }
        case .customers:
            return try OriginalShopOperation.customers(host.people).map { id in
                let items = try held(id),name = try host.people.person(id).name
                return .init(label:name,value:"\(items.count) / 8",warns:shop.receiving != nil && items.count == 8,
                             detail:.init(heading:name,list:items.isEmpty ? [catalog.texts.noItems] : items.map(itemName)))
            }
        case .held(let person):
            return try held(person).map { item in
                let price = catalog.sellingPrice(item)
                return .init(label:itemName(item),value:"\(price)",
                             detail:itemDetail(item,facts:[("판매가","\(price)"),("판매 후","\(min(10000,money+price))")]))
            }
        }
    }
    private var fieldTexts:OriginalFieldTexts? { host.story.screens?.field.texts }
    private func personPortrait(_ id:Int) -> CGImage? { portrait(id,palette:host.stage.palette) }
    private func heldNames(_ id:Int) -> [String] {
        ((try? host.people.person(id).itemIDs) ?? []).filter{$0 != 255}.map(itemName)
    }
    /// MAIN22DB8: name, class, level, troops, attack, defense and the items.
    private func personDetail(_ id:Int) -> CanvasSheet.Detail {
        guard let person = try? host.people.person(id),let texts = fieldTexts else { return .init() }
        let classes = host.story.screens?.battle.commands.classNames ?? []
        let tables = host.source.combat
        let maximum = (try? OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:tables)) ?? 0
        let stats = try? host.people.stats(id,morale:100)
        let attack = stats.flatMap { try? OriginalCombat.attackStat($0,tables:tables) } ?? 0
        let defense = stats.flatMap { try? OriginalCombat.defenseStat($0,tables:tables) } ?? 0
        let held = heldNames(id)
        var facts:[(label:String,value:String)] = [(texts.stats[0],"\(person.rawTroops)/\(maximum)"),("경험치","\(person.experience)"),
            (texts.stats[1],"\(attack)"),(texts.stats[2],"\(defense)")]
        facts.append(("지력","\(person.intellectScalar)"))
        facts.append(("소지품","\(held.count)/8"))
        return .init(heading:person.name,body:"\(classes.indices.contains(person.classID) ? classes[person.classID] : "") · \(texts.level)\(person.level)",
                     list:held.isEmpty ? [texts.noItems] : held,facts:facts,wide:true,portrait:personPortrait(id))
    }
    private func fieldSheet(title:String,line:String,badge:(label:String,value:String) = ("",""),rows:[CanvasSheet.Row],selected:Int = 0,
                            hint:String = "↑↓ 이동 · ↩ 선택 · esc 뒤로",_ choose:@escaping (Int?) -> Void) -> CanvasSheet {
        CanvasSheet(portrait:nil,speaker:title,line:line,badge:badge,rows:rows,selected:selected,mode:.list,hint:hint,onChoose:choose)
    }
    /// MAIN23230: every companion, with the person screen beside the list.
    private func presentPeople(selected:Int = 0) {
        guard let texts = fieldTexts,let people = try? host.people.companions() else { return }
        let rows = people.map { id in CanvasSheet.Row(label:(try? host.people.person(id).name) ?? "",
            value:"\(texts.level)\((try? host.people.person(id).level) ?? 0)",detail:personDetail(id)) }
        overlay.show(fieldSheet(title:texts.personInfo,line:texts.people,rows:rows,selected:selected,hint:"↑↓ 이동 · esc 닫기") { [weak self] index in
            if let index = index { self?.presentPeople(selected:index) }
        })
    }
    /// MAIN23560 shows two people side by side. The engine takes the same
    /// transfer in three steps: who gives, which item, who receives.
    private func presentExchange(giver:Int? = nil,item:Int? = nil,selected:Int = 0) {
        guard let texts = fieldTexts,let people = try? host.people.companions() else { return }
        func owners(except skip:Int?) -> [CanvasSheet.Row] {
            people.filter{$0 != skip}.map { id in
                let held = heldNames(id)
                return .init(label:(try? host.people.person(id).name) ?? "",value:"\(held.count)/8",warns:skip != nil && held.count == 8,
                             detail:.init(heading:(try? host.people.person(id).name) ?? "",list:held.isEmpty ? [texts.noItems] : held,wide:true,portrait:personPortrait(id)))
            }
        }
        guard let giver = giver else {
            overlay.show(fieldSheet(title:texts.itemExchange,line:texts.exchangePrompt,rows:owners(except:nil),selected:selected) { [weak self] index in
                guard let index = index else { return }
                self?.presentExchange(giver:people[index])
            })
            return
        }
        let name = (try? host.people.person(giver).name) ?? ""
        guard let item = item else {
            let held = ((try? host.people.person(giver).itemIDs) ?? []).filter{$0 != 255}
            guard !held.isEmpty else { presentExchange();return }
            let rows = held.map { CanvasSheet.Row(label:itemName($0),detail:itemDetail($0,facts:[])) }
            overlay.show(fieldSheet(title:texts.itemExchange,line:name,rows:rows,selected:selected) { [weak self] index in
                guard let self = self else { return }
                guard let index = index else { self.presentExchange();return }
                self.presentExchange(giver:giver,item:held[index])
            })
            return
        }
        let others = people.filter{$0 != giver}
        overlay.show(fieldSheet(title:texts.itemExchange,line:"\(name) → \(itemName(item))",rows:owners(except:giver),selected:selected) { [weak self] index in
            guard let self = self else { return }
            guard let index = index else { self.presentExchange(giver:giver);return }
            do {
                if try self.host.exchangeItem(from:giver,to:others[index],item:item) { self.presentExchange(giver:giver) }
                else { NSSound.beep();self.presentExchange(giver:giver,item:item,selected:index) }
            } catch { self.recordInputError(error);self.needsDisplay = true }
        })
    }
    /// MAIN23B60..23D5A: the whole world with its reachable cities. Choosing
    /// one starts the same walk as clicking it. Elsewhere it refuses (MAIN23D7D).
    private func presentWholeMap(selected:Int = 0) {
        guard let texts = fieldTexts else { return }
        let state = host.vm.state
        guard state.packedMap>>12 == 1,let flags = state.cityFlags,let map = try? host.exploration.map(packed:state.packedMap,chapter:state.chapter) else {
            overlay.show(CanvasNotice(speaker:"",text:texts.notHere,portrait:nil,timeout:2) {})
            return
        }
        let cities = host.exploration.destinations(chapter:state.chapter,flags:flags),picture = image(map.image)
        func mark(_ city:OriginalCity) -> CGPoint {
            CGPoint(x:(CGFloat(city.worldX ?? 0)+0.5)/CGFloat(map.walkWidth),y:(CGFloat(city.worldY ?? 0)+0.5)/CGFloat(map.walkHeight))
        }
        let rows = cities.map { city in
            CanvasSheet.Row(label:city.name,value:city.id == state.currentCity ? "현재" : "",
                detail:.init(picture:picture,marks:cities.map{(mark($0),$0.id == city.id)}))
        }
        overlay.show(fieldSheet(title:texts.wholeMap,line:"",rows:rows,selected:selected,hint:"↑↓ 이동 · ↩ 이동 시작 · esc 닫기") { [weak self] index in
            guard let self = self,let index = index else { return }
            do { try self.host.travel(toCity:cities[index].id) } catch { self.recordInputError(error) }
            self.needsDisplay = true
        })
    }
    /// MAIN23A88: the scenario's current objective text.
    private func presentStory() {
        guard let texts = fieldTexts else { return }
        overlay.show(CanvasNotice(speaker:texts.storyInfo,text:host.vm.state.objectiveText ?? "",portrait:nil) {})
    }
    private func presentPeopleMenu(at point:CGPoint) {
        guard let texts = fieldTexts else { return }
        overlay.show(CanvasMenu(title:"",options:[.init(label:texts.personInfo),.init(label:texts.itemExchange)],cancellable:true,anchor:point) { [weak self] index in
            if index == 0 { self?.presentPeople() } else if index == 1 { self?.presentExchange() }
        })
    }
    /// The four handlers of DS:3636, in icon order.
    private func runFieldAction(_ index:Int,at point:CGPoint) {
        switch index {
        case 0:presentStory()
        case 1:presentPeopleMenu(at:point)
        case 2:presentWholeMap()
        default:openFieldMenu(at:point)
        }
    }
    /// MAIN1A726..1A869: a full person chooses what to give up.
    private func presentItemOffer() {
        guard let offer = host.itemOffer else { return }
        let texts = host.shopCatalog.texts
        yesNo(originalFormat(texts.giftFull,[itemName(offer.item)])) { [weak self] yes in
            guard let self = self else { return }
            guard yes else { self.act { try self.host.answerItemOffer(slot:nil,declined:true) };return }
            let items = (try? self.host.people.person(offer.person).itemIDs) ?? []
            let rows = items.map { CanvasSheet.Row(label:self.itemName($0),detail:self.itemDetail($0,facts:[])) }
            self.overlay.show(self.fieldSheet(title:"",line:texts.giftChoose,rows:rows) { [weak self] index in
                self?.act { try self?.host.answerItemOffer(slot:index) }
            })
        }
    }
    private func presentItemMessage() {
        guard let message = host.itemMessage else { return }
        let texts = host.shopCatalog.texts,pattern:String,item:Int
        switch message {
        case .gained(let id):(pattern,item) = (texts.giftGained,id)
        case .declined(let id):(pattern,item) = (texts.giftDeclined,id)
        case .gaveUp(let id):(pattern,item) = (texts.giftGaveUp,id)
        case .discarded(let id):(pattern,item) = (texts.giftDiscarded,id)
        }
        // MAIN1A87C: CF5:3C5E in mode zero.
        overlay.show(CanvasNotice(speaker:"",text:originalFormat(pattern,[itemName(item)]),portrait:nil,timeout:OriginalBattleAnimator.noticeSeconds) { [weak self] in
            self?.act { try self?.host.acknowledgeItemMessage() }
        })
    }
    /// MAIN27F90..28019: the closing bonus levels people up over the field.
    private func presentClosing(_ notice:OriginalBattleNotice) {
        guard let catalog = combatArt?.catalog else { return }
        if let id = notice.sound { audio?.playEffect(id) }
        let host = self.host
        let text = catalog.text(notice,person:{ (try? host.people.person($0).name) ?? "" },
                                strategy:{ host.story.screens?.battle.commands.strategyNames[$0] ?? "" })
        overlay.show(CanvasNotice(speaker:"",text:text,portrait:nil) { })
    }
    private func presentRetirement() {
        guard let text = host.retirementText else { return }
        audio?.playEffect(9)                                // MAIN2BAA7
        overlay.show(CanvasNotice(speaker:"",text:text,portrait:nil) { [weak self] in
            guard let self = self else { return }
            self.act { try self.host.acknowledgeRetirement() }
        })
    }
    /// Native party list over the canvas: rows toggle through the source
    /// selection rules (fixed prefix, capacity), the last row confirms.
    private func presentParty(selected:Int = 0,footer:String? = nil,keepScroll:Bool = false) {
        guard let selection = host.partySelection else { return }
        let chosen = Set(selection.selectedSlots.prefix(selection.capacity)),fixed = Set(selection.selectedSlots.prefix(selection.fixedCount))
        let people = selection.candidates.compactMap { id in (try? host.people.person(id)).map { (id,$0) } }
        var rows = people.map { id,person in
            CanvasSheet.Row(label:person.name,value:"Lv \(person.level)",detail:personDetail(id),enabled:!fixed.contains(id),checked:chosen.contains(id))
        }
        rows.append(.init(label:"출전"))
        overlay.show(fieldSheet(title:"출전 부대 선택",line:footer ?? "함께 나갈 장수를 고르세요.",badge:("남은 선택","\(selection.remaining) / \(selection.capacity)"),
                               rows:rows,selected:selected,hint:"↑↓ 이동 · ↩ 선택") { [weak self] index in
            guard let self = self,let index = index else { self?.presentParty(selected:selected,keepScroll:true);return }
            if index == people.count { self.act { try self.host.confirmParty() };return }
            do { try self.host.toggleParty(person:people[index].0);self.presentParty(selected:index,keepScroll:true) }
            catch {
                NSSound.beep()
                let full = self.host.partySelection.map { $0.remaining == 0 && !chosen.contains(people[index].0) } ?? false
                self.presentParty(selected:index,footer:full ? "남은 선택이 없습니다. 최대 \(selection.capacity)명입니다." : "\(error)",keepScroll:true)
            }
        })
    }
    private func present(_ choice:CampaignVMChoice) {
        if choice.kind == "choice-skip" {
            yesNo(choice.prompt.isEmpty ? "선택" : choice.prompt) { [weak self] yes in
                guard let self = self else { return }
                self.act { try self.host.choose(yes ? 1 : 0) }
            }
            return
        }
        overlay.show(CanvasMenu(title:choice.prompt,options:choice.options.map { .init(label:$0) }) { [weak self] index in
            guard let self = self,let index = index else { return }
            self.act { try self.host.choose(index) }
        })
    }
    /// Writes one native resume file; returns false when cancelled or failed.
    /// Source3D (MAIN22A62..22AA1): Yes opens the save destination; a
    /// cancelled or failed save asks the decline check, whose No retries.
    /// The written file is native engine state, not an original MSAVE slot.
    private func presentSave() {
        let framework = host.framework
        let complete:() -> Void = { [weak self] in
            guard let self = self else { return }
            self.act { try self.host.completeSaveRequest() }
        }
        func attempt() {
            presentSlots(saving:true) { [weak self] written in
                if written { complete();return }
                self?.yesNo(framework?.saveDeclinePrompt?.text ?? "저장하지 않고 진행할까요?") { yes in yes ? complete() : attempt() }
            }
        }
        yesNo(framework?.savePrompt?.text ?? "여기서 저장할까요?") { yes in yes ? attempt() : complete() }
    }
    /// MAIN's own window for a menu at the title, in the original frames.
    private func originalMenu(_ name:String) -> CanvasMenu.Style? {
        guard CanvasPresentation.current == .original,!host.hasStarted,let menus = host.story.screens?.menus,
              let window = menus.windows[name],window.window.count == 4,window.buttons.allSatisfy({ $0.count == 4 }),
              menus.text.count == 3,menus.disabled.count == 3,let picture = image(window.image) else { return nil }
        func color(_ value:[Int]) -> NSColor { NSColor(red:CGFloat(value[0])/255,green:CGFloat(value[1])/255,blue:CGFloat(value[2])/255,alpha:1) }
        let font = mainFont,text = menus.text.map(UInt8.init),disabled = menus.disabled.map(UInt8.init)
        return .window(.init(image:picture,frame:OriginalBattleLayout.rect(window.window),buttons:window.buttons.map(OriginalBattleLayout.rect),
                             text:color(menus.text),disabled:color(menus.disabled),
                             label:font.map { font in { label,enabled in
                                 let rgb = enabled ? text : disabled
                                 return font.picture(label,red:rgb[0],green:rgb[1],blue:rgb[2])
                             } }))
    }
    /// The engine layout sets the rows between the logo and the copyright line
    /// of the opening's title picture; the original frames use MAIN's window.
    private static let titleAnchor = CGPoint(x:320,y:262)
    private func titleMenu(_ choose:@escaping (Int?) -> Void = { _ in }) -> CanvasMenu {
        let items = host.framework?.titleMenu?.map(\.text) ?? ["새로 시작","이어하기","기능설정","오프닝"]
        return CanvasMenu(title:"",options:items.map { .init(label:$0) },cancellable:true,anchor:Self.titleAnchor,
                          style:originalMenu("title") ?? .title,onChoose:choose)
    }
    /// MAIN CF5:C050 menu after the title. Item0 starts, item1 resumes a
    /// native slot, item2 opens the options, and item3
    /// returns to the opening, as exit code0 runs OPEN before MAIN again.
    /// A cancel ends the game through the exit screen (main 0x1E605, 1E3A8).
    private func presentTitleMenu() {
        overlay.viewport = CGRect(x:0,y:0,width:640,height:400)
        overlay.show(titleMenu { [weak self] chosen in
            guard let self = self else { return }
            guard let chosen = chosen else {
                self.startQuitScreen()
                if self.screenPlayer == nil { self.window?.performClose(nil) }
                return
            }
            do {
                switch chosen {
                case 0:self.fadeThrough { [weak self] in self?.act { try self?.host.acknowledge() } }
                case 1:
                    self.presentSlots(saving:false) { [weak self] _ in self?.presentTitleMenu() }
                case 2:self.presentTitleSettings()
                case 3:
                    let next = try OriginalCampaignView(data:self.host.data)
                    self.replace(with:next);next.playOpening()
                default: return
                }
            } catch { self.recordInputError(error) }
            self.needsDisplay = true
        })
    }
    /// MAIN's field menu (input code23, DS:3636/36E2 -> CF5:F382). The
    /// engine opens it with a secondary click or the modern menu button; the
    /// original key binding is not established.
    override func rightMouseDown(with event:NSEvent) {
        guard host.fieldMenuReady,!overlay.active else { super.rightMouseDown(with:event);return }
        openFieldMenu(at:CanvasGeometry(bounds:bounds).canvas(convert(event.locationInWindow,from:nil)))
    }
    private func openFieldMenu(at point:CGPoint) {
        let labels = host.framework?.fieldMenu?.items.map(\.text) ?? OriginalFieldMenuTexts.actions
        // Scroll sets the mouse's edge-scroll step, which the engine's maps do not use.
        let options = labels.enumerated().map { CanvasMenu.Option(label:$0.element,
            enabled:OriginalFieldMenuTexts.actions[$0.offset] != "scroll" && (host.framework?.settings != nil || ["quit","load","save"].contains(OriginalFieldMenuTexts.actions[$0.offset]))) }
        overlay.show(CanvasMenu(title:"",options:options,cancellable:true,anchor:point) { [weak self] index in
            guard let self = self,let index = index else { return }
            self.fieldMenuChosen(OriginalFieldMenuTexts.actions[index])
        })
    }
    private func fieldMenuChosen(_ action:String) {
        guard host.fieldMenuReady else { return }
        switch action {
        case "speed","monitor","bgm","sound","volume","music-time":openSetting(action) { }
        case "quit":
            yesNo(host.framework?.fieldMenu?.quitConfirm.text ?? "게임을 종료할까요?") { [weak self] yes in
                guard yes,let self = self else { return }
                do { try self.host.fieldQuit() } catch { self.recordInputError(error) }
            }
        case "save":presentSlots(saving:true) { _ in }
        case "load":presentSlots(saving:false) { _ in }
        default: return
        }
        needsDisplay = true
    }
    /// MAIN22BFE, 229AE, 228C6 and 22BCE: one selector per option. `done`
    /// continues whatever opened it, such as the title menu.
    private func openSetting(_ action:String,behind parents:[CanvasMenu] = [],_ done:@escaping () -> Void) {
        guard let texts = host.framework?.settings else { done();return }
        var value = OriginalSettings.current
        let labels:[String],current:Int,apply:(Int) -> Void
        switch action {
        case "speed":labels = texts.speed;current = value.speed;apply = { value.speed = $0 }
        case "monitor":labels = texts.monitor;current = value.monochrome ? 1 : 0;apply = { value.monochrome = $0 == 1 }
        case "bgm":labels = texts.onOff;current = OriginalAudio.musicEnabled ? 0 : 1;apply = { OriginalAudio.musicEnabled = $0 == 0 }
        case "sound":labels = texts.onOff;current = OriginalAudio.effectsEnabled ? 0 : 1;apply = { OriginalAudio.effectsEnabled = $0 == 0 }
        case "volume":
            let levels:[Float] = [1,0.75,0.5,0.25]
            labels = levels.map { "\(Int($0*100))%" };current = levels.firstIndex(of:value.volume) ?? 0;apply = { value.volume = levels[$0] }
        default:
            overlay.show(CanvasMenu(title:"",options:texts.listen.map { .init(label:$0) },cancellable:true) { [weak self] index in
                guard let self = self,let index = index else { done();return }
                self.presentListening(songs:index == 0,selected:0,done)
            })
            return
        }
        // MAIN229DA, 22908: the original window shows the current choice disabled.
        if !parents.isEmpty,labels.count == 2,let style = originalMenu(action == "monitor" ? "monitor" : "switch") {
            overlay.show(CanvasMenu(title:"",options:labels.enumerated().map { .init(label:$0.element,enabled:$0.offset != current) },
                                    selected:1-current,cancellable:true,style:style) { index in
                if let index = index { apply(index);OriginalSettings.current = value }
                done()
            },behind:parents)
            return
        }
        // At the title the engine layout keeps its rows under the logo.
        let atTitle = !host.hasStarted
        overlay.show(CanvasMenu(title:"",options:labels.enumerated().map { .init(label:$0.element,checked:$0.offset == current) },selected:current,cancellable:true,
                                anchor:atTitle ? Self.titleAnchor : nil,style:atTitle ? .title : .panel) { index in
            if let index = index { apply(index);OriginalSettings.current = value }
            done()
        })
    }
    /// MAIN22AF6 and 22B7A: each pick plays at once until the list closes.
    private func presentListening(songs:Bool,selected:Int,_ done:@escaping () -> Void) {
        guard let texts = host.framework?.settings else { done();return }
        let rows = (songs ? texts.songs : texts.effects).map { CanvasSheet.Row(label:$0) }
        overlay.show(fieldSheet(title:texts.listen[songs ? 0 : 1],line:"",rows:rows,selected:selected,hint:"↑↓ 이동 · ↩ 재생 · esc 닫기") { [weak self] index in
            guard let self = self else { return }
            guard let index = index else { self.audio?.audition = nil;done();return }
            if songs { self.audio?.audition = index } else { self.audio?.playEffect(index) }
            self.presentListening(songs:songs,selected:index,done)
        })
    }
    /// MAIN CF5:BFDE: monitor, BGM and effects, the field list's items five to
    /// seven (DS:34FC). In the original frames the window opens over the title's.
    private static let titleSettings = ["monitor","bgm","sound"]
    private func titleSettingsMenu(selected:Int,_ choose:@escaping (Int?) -> Void = { _ in }) -> CanvasMenu {
        let labels = Self.titleSettings.map { action in
            host.framework?.fieldMenu?.items.first(where:{ $0.action == action })?.text ?? action
        }
        return CanvasMenu(title:"",options:labels.map { .init(label:$0) },selected:selected,cancellable:true,anchor:Self.titleAnchor,
                          style:originalMenu("settings") ?? .title,onChoose:choose)
    }
    private func presentTitleSettings(selected:Int = 0) {
        let original = originalMenu("settings") != nil
        overlay.show(titleSettingsMenu(selected:selected) { [weak self] index in
            guard let self = self else { return }
            guard let index = index else { self.presentTitleMenu();return }
            self.openSetting(Self.titleSettings[index],behind:original ? [self.titleMenu(),self.titleSettingsMenu(selected:index)] : []) { [weak self] in
                self?.presentTitleSettings(selected:index)
            }
        },behind:original ? [titleMenu()] : [])
    }
    private func saveSlots() throws -> OriginalSaveSlots {
        OriginalSaveSlots(directory:try Self.savesDirectory().appendingPathComponent("slots",isDirectory:true))
    }
    /// MSAVE's slot title is the HUD caption DS:DB4C (0x1E80B); the engine
    /// adds the place when the source has written no caption yet.
    private var slotTitle:String {
        if let caption = host.stage.caption,!caption.isEmpty { return caption }
        let state = host.vm.state
        let place = host.fieldScreenState()?.territory ?? host.battle?.definition.name ?? ""
        return "\(state.chapter)장 \(place)"
    }
    /// The slot dialog CF5:B58C serves saving (0x100) and loading alike. The
    /// callback says whether a slot was written; a load replaces this view.
    private func presentSlots(saving:Bool,_ done:@escaping (Bool) -> Void) {
        guard let slots = try? saveSlots() else { done(false);return }
        let dates = DateFormatter();dates.dateStyle = .short;dates.timeStyle = .short
        let entries = slots.entries()
        enum Target { case slot(Int),named(OriginalSaveSlots.Named),original(OriginalSaveCatalog.Slot),file,none }
        var rows = entries.enumerated().map { index,entry in
            CanvasSheet.Row(label:"슬롯 \(index+1)",value:entry.map { dates.string(from:$0.date) } ?? "비어 있음",
                            detail:entry.map { .init(heading:$0.title) },enabled:saving || entry != nil)
        }
        var targets:[Target] = (0..<rows.count).map { .slot($0) }
        if !saving {
            for name in OriginalSaveSlots.Named.allCases {
                guard let entry = slots.entry(name) else { continue }
                rows.append(.init(label:name == .auto ? "자동 저장" : "빠른 저장",value:dates.string(from:entry.date),detail:.init(heading:entry.title)))
                targets.append(.named(name))
            }
        }
        let originals = saving ? nil : try? OriginalSaveCatalog.load(root:host.data.root)
        for slot in originals?.slots ?? [] {
            let date = slot.date
            rows.append(.init(label:"원작 슬롯 \(slot.slot+1)",value:String(format:"%02d/%02d/%02d %02d:%02d",date.year,date.month,date.day,date.hour,date.minute),
                              detail:.init(heading:slot.title)))
            targets.append(.original(slot))
        }
        for refused in originals?.refused ?? [] {
            rows.append(.init(label:"원작 슬롯 \(refused.slot+1)",value:"읽을 수 없음",enabled:false))
            targets.append(.none)
        }
        if !saving { rows.append(.init(label:"파일에서 불러오기"));targets.append(.file) }
        let items = host.framework?.fieldMenu?.items
        let title = items?.first(where:{ $0.action == (saving ? "save" : "load") })?.text ?? ""
        overlay.show(fieldSheet(title:title,line:"",rows:rows,selected:rows.firstIndex(where:\.enabled) ?? 0) { [weak self] index in
            guard let self = self else { return }
            guard let index = index else { done(false);return }
            do {
                if saving {
                    let write = { [weak self] in
                        guard let self = self else { return }
                        do { try slots.write(try self.host.resumeSnapshot(),title:self.slotTitle,slot:index);done(true) }
                        catch { self.recordInputError(error);done(false) }
                    }
                    if entries[index] == nil { write() } else {
                        self.yesNo("이 슬롯을 덮어쓸까요?") { [weak self] yes in
                            if yes { write() } else { self?.presentSlots(saving:true,done) }
                        }
                    }
                } else {
                    let data = self.host.data,rng = self.host.rng
                    switch targets[index] {
                    case .slot(let slot):
                        self.loadThroughFade(done) { try OriginalCampaignView(host:try OriginalCampaignHost.resume(data:data,from:slots.read(slot:slot))) }
                    case .named(let name):
                        self.loadThroughFade(done) { try OriginalCampaignView(host:try OriginalCampaignHost.resume(data:data,from:slots.read(name))) }
                    case .original(let slot):
                        // MAIN keeps its boot-seeded stream across a load; a slot stores none.
                        self.loadThroughFade(done) { try OriginalCampaignView(host:try OriginalCampaignHost.importOriginal(data:data,slot:slot,rng:rng)) }
                    case .file:
                        if let resumed = try Self.chooseResume(data:self.host.data) { self.replace(with:try OriginalCampaignView(host:resumed)) } else { done(false) }
                    case .none:done(false)
                    }
                }
            } catch { self.recordInputError(error);done(false) }
        })
    }
    /// A load reaches the map through C456 as well: black, then the new screen fades in.
    private func loadThroughFade(_ done:@escaping (Bool) -> Void,_ make:@escaping () throws -> OriginalCampaignView) {
        fadeThrough { [weak self] in
            guard let self = self else { return }
            do { let next = try make();self.replace(with:next);next.fadeIn() }
            catch { self.recordInputError(error);done(false) }
        }
    }
    private func replace(with next:OriginalCampaignView) {
        guard let window = window else { return }
        stop();window.contentView = next;window.makeFirstResponder(next)
    }
    /// Modern field buttons from the right edge, in DS:3636 order.
    var fieldButtons:[(index:Int,label:String,rect:CGRect)] {
        guard let texts = fieldTexts else { return [] }
        var right:CGFloat = 628
        var result:[(index:Int,label:String,rect:CGRect)] = []
        for (index,label) in [(3,"메뉴"),(0,texts.storyInfo),(2,texts.wholeMap),(1,texts.people)] {
            let width = ceil((label as NSString).size(withAttributes:CanvasTheme.attributes(CanvasTheme.font(12,.medium),CanvasTheme.text)).width)+24
            result.append((index,label,CGRect(x:right-width,y:12,width:width,height:28)))
            right -= width+6
        }
        return result
    }
    /// Modern field: who leads, where they are, and what they carry, over the map.
    /// The card carries the source caption (the chapter title, DS:DB4C) above
    /// the territory, so a long title never runs under the field buttons.
    private func drawFieldHUD(_ screen:OriginalFieldScreenState,in context:CGContext) {
        let caption = host.stage.caption ?? "",captionStyle = CanvasTheme.attributes(CanvasTheme.font(11,.medium),CanvasTheme.accent)
        let captionWidth = caption.isEmpty ? 0 : ceil((caption as NSString).size(withAttributes:captionStyle).width)
        let top:CGFloat = caption.isEmpty ? 0 : 16
        let card = CGRect(x:12,y:12,width:min(300,max(178,captionWidth+64)),height:58+top)
        CanvasTheme.panel(card,in:context)
        if let picture = image(screen.portraitImage) {
            let box = CGRect(x:card.minX+7,y:card.midY-23,width:37,height:46)
            context.saveGState();CanvasTheme.rounded(box,4,in:context);context.clip()
            Renderer.image(picture,in:box,context:context);context.restoreGState()
        }
        let textX = card.minX+52
        if !caption.isEmpty {
            let paragraph = NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
            var style = captionStyle;style[.paragraphStyle] = paragraph
            (caption as NSString).draw(in:CGRect(x:textX,y:card.minY+8,width:card.width-58,height:16),withAttributes:style)
        }
        ((screen.territory ?? "") as NSString).draw(in:CGRect(x:textX,y:card.minY+8+top,width:card.width-58,height:20),
            withAttributes:CanvasTheme.attributes(CanvasTheme.font(14,.semibold),CanvasTheme.text))
        ("돈 \(screen.money ?? 0) · 레벨 \(screen.level ?? 0)" as NSString).draw(in:CGRect(x:textX,y:card.minY+31+top,width:card.width-58,height:18),
            withAttributes:CanvasTheme.attributes(CanvasTheme.number(11.5),CanvasTheme.muted))
        if host.fieldMenuReady {
            for button in fieldButtons {
                CanvasTheme.panel(button.rect,in:context)
                (button.label as NSString).draw(in:CGRect(x:button.rect.minX,y:button.rect.minY+6,width:button.rect.width,height:18),
                    withAttributes:CanvasTheme.attributes(CanvasTheme.font(12,.medium),CanvasTheme.text,alignment:.center))
            }
        }
    }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.black.setFill();bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let shape = CanvasGeometry(bounds:bounds)
        if let player = screenPlayer,let image = player.image() { Renderer.image(image,in:shape.rect,context:context);return }
        let screen = host.fieldScreenState(),modern = CanvasPresentation.current == .modern && screen != nil
        // MAIN draws no picture behind its title menu (A7E8 clears to colour 0);
        // the engine layout keeps the opening's title picture there.
        let blankTitle = !host.hasStarted && host.ending == nil && CanvasPresentation.current == .original
        if !blankTitle {
            do {
                // While a map change fades out, the old map stays on screen (MAIN
                // loads the next one offscreen), so the last picture is kept.
                if host.stage.leaving || freezePicture,let picture = lastPicture {
                    Renderer.image(picture,in:shape.rect,context:context)
                    context.setFillColor(CGColor(gray:0,alpha:host.stage.blackAlpha));context.fill(shape.rect)
                } else {
                    let frame = try host.ending.map { try renderer.renderEnding($0) } ?? renderer.render(host.stage,screen:screen,dialogue:false)
                    let picture = modern ? frame.image.cropping(to:CanvasFieldMap.viewport) ?? frame.image : frame.image
                    Renderer.image(picture,in:shape.rect,context:context);lastPicture = picture
                }
            } catch { errorText = "\(error)" }
        }
        if endingFade > 0 {
            context.setFillColor(CGColor(gray:0,alpha:min(1,endingFade/Self.endingFadeSeconds)));context.fill(shape.rect)
        }
        context.saveGState()
        context.translateBy(x:shape.origin.x,y:shape.origin.y);context.scaleBy(x:shape.scale,y:shape.scale)
        // A sheet carries its own money and covers this corner.
        if modern,overlay.sheet == nil,let screen = screen { drawFieldHUD(screen,in:context) }
        // Only a state the player can act on or must know reaches the window.
        if let text = errorText ?? inputNotice ?? host.notice ?? host.playerStatus {
            CanvasTheme.chip(text,at:CGPoint(x:320,y:376),maximumWidth:600,color:errorText == nil ? CanvasTheme.text : CanvasTheme.danger,in:context)
        }
        if fastForward,host.hasStarted {
            CanvasTheme.chip("빨리 감기 ×\(OriginalBattleView.fastRate)",at:CGPoint(x:580,y:24),maximumWidth:120,in:context)
        }
        context.restoreGState()
    }
    override func keyDown(with event:NSEvent) {
        if screenPlayer != nil { screenInput(escape:event.keyCode == 53);return }
        if fading { return }
        if event.keyCode == 53 || host.frameworkReturn?.outcome == .quit { window?.performClose(nil);return }
        if [36,49,76].contains(event.keyCode),!event.isARepeat {
            inputNotice = nil
            if !host.hasStarted { presentTitleMenu();needsDisplay = true;return }
            do { try host.acknowledge() } catch { recordInputError(error) };needsDisplay = true
        }
    }
    private func recordInputError(_ error:Error) {
        if host.failure != nil { errorText = "\(error)" }
        else { inputNotice = "\(error)" }
    }
    /// OPEN leaves on a mouse button. END has one button loop at the very end.
    private func screenInput(escape:Bool) {
        guard let player = screenPlayer else { return }
        if screenIsOpening || escape { leaveScreen() } else { player.acceptInput() }
    }
    override func mouseDown(with event:NSEvent) {
        if screenPlayer != nil { screenInput(escape:false);return }
        if fading { return }
        // MAIN1E3A8 waits for one input before main exits with code3.
        if host.frameworkReturn?.outcome == .quit { window?.performClose(nil);return }
        inputNotice = nil
        if !host.hasStarted { presentTitleMenu();needsDisplay = true;return }
        do {
            if host.explorationInputReady,[0,1,2].contains(host.vm.state.packedMap>>12) {
                var p = CanvasGeometry(bounds:bounds).canvas(convert(event.locationInWindow,from:nil))
                if modernField {
                    if host.fieldMenuReady,let button = fieldButtons.first(where:{ $0.rect.contains(p) }) {
                        runFieldAction(button.index,at:CGPoint(x:button.rect.minX,y:button.rect.maxY+6));return
                    }
                    p = CanvasFieldMap.mapPoint(canvas:p)
                } else if host.fieldMenuReady,let icons = host.story.screens?.field.icons,
                          let index = icons.firstIndex(where:{ OriginalBattleLayout.rect($0).contains(p) }) {
                    // The original frame's icon cells (DS:3514) open the same handlers.
                    runFieldAction(index,at:CGPoint(x:CGFloat(icons[index][0])-120,y:CGFloat(icons[index][1])));return
                }
                let x = p.x,y = p.y,v = host.stage.viewport
                if host.vm.state.packedMap>>12 == 1 {
                    let cities = host.exploration.cities.filter{$0.chapter == host.vm.state.chapter && $0.worldPositionKnown}
                    if let city = cities.first(where:{ city in
                        guard let cx = city.worldX,let cy = city.worldY else { return false }
                        return CGRect(x:v[0]+cx*32-host.stage.camera[0],y:v[1]+cy*32-host.stage.camera[1],width:32,height:32).contains(CGPoint(x:x,y:y))
                    }) { try host.travel(toCity:city.id) }
                    needsDisplay = true;return
                }
                let actors = host.stage.actors.values.sorted{$0.registration > $1.registration}
                if let actor = actors.first(where:{ actor in
                    guard actor.person != 0 else { return false }
                    let rect = CGRect(x:v[0]+16*actor.position.x-host.stage.camera[0],y:v[1]+16*actor.position.y+8*(actor.position.x&1)-24-host.stage.camera[1],width:32,height:40)
                    return rect.contains(CGPoint(x:x,y:y))
                }) { try host.talk(to:actor.person) }
                else {
                    let gx = Int(floor((x-CGFloat(v[0])+CGFloat(host.stage.camera[0]))/16))
                    let gy = Int(floor((y-CGFloat(v[1])+CGFloat(host.stage.camera[1])-CGFloat(8*(gx&1)))/16))
                    try host.walk(to:GridPoint(x:gx,y:gy))
                }
            } else { try host.acknowledge() }
        } catch { recordInputError(error) }
        needsDisplay = true
    }
}
