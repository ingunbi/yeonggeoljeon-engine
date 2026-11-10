// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreImage

final class OriginalCampaignView:NSView,EngineTimedView {
    let host:OriginalCampaignHost
    let renderer:Renderer
    private let saveRootOverride:URL?
    private let practiceContext:PracticeHostContext?
    private var practiceCompleted = false
    var onPracticeReturn:(()->Void)?
    private var onPracticeList:(()->Void)?
    private var practiceMode:Bool {practiceContext != nil}
    private var archiveCoordinator:BattleArchiveCoordinator?
    private var timer:Timer?
    private var errorText:String?
    private var inputNotice:String?
    private var battleSaveToast:(text:String,deadline:TimeInterval)?
    private var autosaveNotice:String?
    private var battleSaveNotice:String?
    private var pendingResumeBrief = false
    private var suspendRequested = false
    private var suspendPromptActive = false
    private var pauseCoordinator = PauseCoordinator()
    private var pauseObservers:[NSObjectProtocol] = []
    private func refreshPause() {
        pauseCoordinator.set(.inactiveApp,settings.pauseInBackground && NSApp?.isActive == false)
        pauseCoordinator.set(.minimizedWindow,settings.pauseInBackground && window?.isMiniaturized == true)
        pauseCoordinator.set(.savePrompt,suspendPromptActive)
        pauseCoordinator.finishingSave = suspendRequested
        let paused = pauseCoordinator.paused
        overlay.setSuspended(paused);battleView?.setOverlaySuspended(paused)
        audio?.setPaused(paused)
        if paused {
            fastForwardHeld = false
            if !suspendPromptActive { battleView?.externalStatus = "일시정지됨 · 게임 메뉴에서 재개할 수 있습니다." }
        } else if battleView?.externalStatus?.hasPrefix("일시정지됨") == true { battleView?.externalStatus = nil }
        needsDisplay = true
    }
    @objc func togglePause(_ sender:Any?) {
        pauseCoordinator.set(.userPause,!pauseCoordinator.reasons.contains(.userPause));refreshPause()
    }
    @objc func openBattleHistory(_ sender:Any?) { showJournal(history:true) }
    @objc func openCampaignJourney(_ sender:Any?) { showJournal(history:false) }
    @objc func openEventHints(_ sender:Any?) {
        withManagement {ui,close in
            ui.showEventHints(onLocate:{[weak self] point in close();self?.battleView?.focusAssistancePoint(point)},onClose:close)
        }
    }
    @objc func openControlSettings(_ sender:Any?) {
        withManagement {_,close in AppControlSettingsUI.present(overlay:saveOverlay,onClose:close)}
    }
    private func withManagement(_ show:(CampaignManagementUI,@escaping ()->Void)->Void) {
        guard !suspendPromptActive,!fading else {return}
        let previous = window?.firstResponder
        suspendPromptActive = true;refreshPause();saveOverlay.isHidden = false
        let close:()->Void = { [weak self,weak previous] in
            guard let self else {return}
            self.saveOverlay.isHidden = true;self.suspendPromptActive = false;self.refreshPause()
            if let previous {self.window?.makeFirstResponder(previous)}
        }
        show(CampaignManagementUI(host:host,overlay:saveOverlay,portrait:{[weak self] in self?.personPortrait($0)},
            onError:{[weak self] in self?.recordInputError($0)}),close)
        window?.makeFirstResponder(saveOverlay)
    }
    private func recorder() throws -> BattleArchiveCoordinator {
        if let archiveCoordinator {return archiveCoordinator}
        let value = BattleArchiveCoordinator(data:host.data,root:try currentSaveDirectory().appendingPathComponent("battle-archives",isDirectory:true))
        archiveCoordinator = value;return value
    }
    private func recordAcceptedInput(_ input:OriginalPlayInput) {
        guard !practiceMode,host.extras.battleArchives.active != nil else {return}
        do {try recorder().accepted(input:input,progress:&host.extras.battleArchives)}
        catch {archiveCoordinator?.failed(error,progress:&host.extras.battleArchives);inputNotice = "이번 전투 녹화가 중단되었습니다. 다시 보기에서 이유를 확인할 수 있습니다."}
    }
    private func recordBoundary() {
        guard !practiceMode,host.extras.battleArchives.active != nil else {return}
        do {try recorder().checkpoint(host:host,progress:&host.extras.battleArchives)}
        catch {archiveCoordinator?.failed(error,progress:&host.extras.battleArchives)}
    }
    @objc func openBattleReplays(_ sender:Any?) {showArchives(practice:false)}
    @objc func openPracticeBattles(_ sender:Any?) {showArchives(practice:true)}
    private func showArchives(practice:Bool) {
        guard !practiceMode else {return}
        do {
            let coordinator = try recorder()
            withManagement {ui,close in
                ui.showBattleArchives(coordinator:coordinator,practice:practice,onPractice:{[weak self] context in
                    close();self?.beginPractice(context)
                },onClose:close)
            }
        } catch {recordInputError(error,message:"전투 기록을 열지 못했습니다.")}
    }
    private func beginPractice(_ context:PracticeHostContext) {
        guard let delegate = NSApp?.delegate as? AppDelegate else {return}
        do {
            let child = try OriginalCampaignView(host:context.host,practiceContext:context)
            let wasPaused = pauseCoordinator.reasons.contains(.userPause)
            pauseCoordinator.set(.userPause,true);refreshPause()
            child.onPracticeReturn = { [weak self] in
                guard let self else {return}
                self.pauseCoordinator.set(.userPause,wasPaused);self.refreshPause()
                self.window?.makeKeyAndOrderFront(nil)
            }
            let returnToParent = child.onPracticeReturn
            child.onPracticeList = { [weak self] in
                returnToParent?();self?.showArchives(practice:true)
            }
            delegate.showPractice(child,title:context.title)
        } catch {recordInputError(error,message:"연습 전투를 열지 못했습니다.")}
    }
    private func retryPractice() {
        guard let context = practiceContext else {return}
        let wasCompleted = practiceCompleted
        let restoreOriginalScreen:()->Void = { [weak self] in
            guard let self else {return}
            if wasCompleted,let session = self.host.battle {
                self.practiceCompleted = false;self.finishPractice(session)
            } else if !self.host.hasStarted {self.presentTitleMenu()}
        }
        withManagement {ui,close in
            ui.preparePracticeRetry(context,onCancel:{close();restoreOriginalScreen()}) { [weak self] fresh in
                guard let self else {return}
                close()
                do {self.replace(with:try OriginalCampaignView(host:fresh.host,practiceContext:fresh))}
                catch {
                    self.recordInputError(error,message:"연습 전투를 다시 시작하지 못했습니다.")
                    self.suspendAlert("연습 재시작 실패",text:"현재 연습 진행은 유지됩니다.",afterDismiss:restoreOriginalScreen)
                }
            }
        }
    }
    private func finishPractice(_ session:OriginalBattleSession) {
        guard !practiceCompleted else {return}
        practiceCompleted = true;pauseCoordinator.set(.userPause,true)
        let result = session.turns.result == 2 ? "승리" : session.turns.result == 1 ? "총퇴각" : "패배·종료"
        saveDialog("연습 결과 · \(result)",text:"\(session.definition.name ?? "전투") · \(min(session.turns.roundIndex+1,session.header.turnLimit))턴\n본편의 장수·물품·금·기록에는 반영되지 않습니다.",buttons:["다시 연습","연습 목록","본편으로"]) {[weak self] index in
            guard let self else {return}
            if index == 0 {self.retryPractice()}
            else {
                if index == 1,let onPracticeList = self.onPracticeList {self.onPracticeReturn = onPracticeList}
                self.window?.performClose(nil)
            }
        }
    }
    private func showJournal(history:Bool) {
        guard host.hasStarted,!suspendPromptActive,!fading else { return }
        let previous = window?.firstResponder
        suspendPromptActive = true;refreshPause();saveOverlay.isHidden = false
        let close:(Int?) -> Void = { [weak self,weak previous] _ in
            guard let self = self else { return }
            self.saveOverlay.isHidden = true;self.suspendPromptActive = false;self.refreshPause()
            if let previous = previous { self.window?.makeFirstResponder(previous) }
        }
        let reference = CampaignManagementUI(host:host,overlay:saveOverlay,
            portrait:{ [weak self] person in self?.portrait(person,palette:self?.host.stage.palette ?? 0) },
            onError:{ [weak self] error in self?.recordInputError(error,message:"기록을 열지 못했습니다.") })
        if history {reference.showAccumulatedBattles(onClose:{close(nil)})}
        else {reference.showJourney(onClose:{close(nil)})}
        window?.makeFirstResponder(saveOverlay)
    }
    @objc func toggleBackgroundPause(_ sender:Any?) {
        var value = OriginalSettings.current;value.pauseInBackground.toggle();OriginalSettings.current = value
    }

    private var terminationGate = CampaignTerminationGate()
    private var terminationCompletion:((Bool) -> Void)?
    private var suspendStatus:String? {
        guard suspendRequested else { return nil }
        return terminationCompletion == nil ? "중단 저장 대기 중 · 현재 진행·선택이 끝나면 저장합니다. F5: 취소" : "저장 후 종료 대기 중 · 현재 행동·선택을 마쳐 주세요. F5: 종료 취소"
    }
    private var battleView:OriginalBattleView?
    /// In-game selectors and waiting lines drawn above the stage and battle.
    private let overlay = CanvasOverlayView()
    /// Save confirmations cover, rather than replace, the current dialogue or
    /// selector so cancellation can return to the exact same callback.
    private let saveOverlay = CanvasOverlayView()
    private var settings = OriginalSettings.current
    private lazy var combatArt:OriginalCombatArt? = (try? OriginalCombatCatalog.load(from:host.data.root.appendingPathComponent("combat-view.json"))).flatMap { try? OriginalCombatArt(catalog:$0) }
    private var imageCache:[String:CGImage] = [:]
    private var presentationObserver:NSObjectProtocol?
    private var scalingObserver:NSObjectProtocol?
    private lazy var audio:OriginalAudio? = (try? OriginalMusicCatalog.load(from:host.data.root.appendingPathComponent("music.json"))).map { OriginalAudio(catalog:$0) }
    /// Each shop list remembers its row while the visit moves between them.
    private var shopCursor:[OriginalShopList:Int] = [:]
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    convenience init(data:DataSet,saveRootOverride:URL? = nil,practiceContext:PracticeHostContext? = nil) throws {
        let c = Calendar.current.dateComponents([.day,.hour,.minute,.second],from:Date())
        func bcd(_ n:Int?) -> UInt8 { let v = n ?? 0;return UInt8(((v/10)<<4)|(v%10)) }
        try self.init(host:OriginalCampaignHost(data:data,rng:OriginalRNG.clockSeed(dayByte:bcd(c.day),hourByte:bcd(c.hour),minuteByte:bcd(c.minute),secondByte:bcd(c.second))),saveRootOverride:saveRootOverride,practiceContext:practiceContext)
    }
    init(host:OriginalCampaignHost,saveRootOverride:URL? = nil,practiceContext:PracticeHostContext? = nil) throws {
        self.host = host
        if let path = OriginalSettings.current.eventHintCatalogPath {
            do {try host.selectEventHints(from:URL(fileURLWithPath:path))}
            catch {host.eventHintCatalogError = String(describing:error)}
        }
        self.practiceContext = practiceContext;self.saveRootOverride = practiceContext?.saveRoot ?? saveRootOverride
        host.announcesItems = true
        host.presentsDuels = true
        host.citizensWander = true
        renderer = try Renderer(host.data)
        super.init(frame:CGRect(x:0,y:0,width:1024,height:640))
        curtain.frame = bounds;curtain.autoresizingMask = [.width,.height];addSubview(curtain)
        overlay.frame = bounds;overlay.autoresizingMask = [.width,.height];addSubview(overlay)
        saveOverlay.frame = bounds;saveOverlay.autoresizingMask = [.width,.height]
        saveOverlay.viewport = CGRect(x:0,y:0,width:640,height:400)
        saveOverlay.isHidden = true;saveOverlay.wantsLayer = true
        saveOverlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
        addSubview(saveOverlay)
        overlay.onSound = { [weak self] id in self?.audio?.playEffect(id) }
        saveOverlay.onSound = { [weak self] id in self?.audio?.playEffect(id) }
        overlay.onLineControl = { [weak self] control in self?.lineControl(control) }
        NotificationCenter.default.addObserver(forName:OriginalSettings.changed,object:nil,queue:.main) { [weak self] _ in self?.applySettings() }
        for name in [NSApplication.didBecomeActiveNotification,NSApplication.didResignActiveNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification] {
            pauseObservers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in self?.refreshPause() })
        }
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
        scalingObserver = NotificationCenter.default.addObserver(forName:CanvasGeometry.scalingChanged,object:nil,queue:.main) { [weak self] _ in
            self?.redrawAll()
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
    deinit { pauseObservers.forEach(NotificationCenter.default.removeObserver);presentationObserver.map(NotificationCenter.default.removeObserver);scalingObserver.map(NotificationCenter.default.removeObserver) }
    /// The canvas, the battle view and the overlay all scale through CanvasGeometry.
    private func redrawAll() {
        func mark(_ view:NSView) { view.needsDisplay = true;view.subviews.forEach(mark) }
        mark(self)
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor,scale != CanvasGeometry.backingScale { CanvasGeometry.backingScale = scale;redrawAll() }
    }
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
    private func currentSaveDirectory() throws -> URL {
        if let root = saveRootOverride {try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);return root}
        return try Self.savesDirectory()
    }
    private func scopedSnapshot(_ snapshot:OriginalCampaignResume)->OriginalCampaignResume {
        var result = snapshot
        if practiceMode {result.kind = "native-engine-practice"}
        return result
    }
    private func resumedView(_ snapshot:OriginalCampaignResume) throws -> OriginalCampaignView {
        guard snapshot.kind == (practiceMode ? "native-engine-practice" : "native-engine-resume") else {
            throw EngineError.invalid("본편 저장과 연습 저장은 서로 불러올 수 없습니다.")
        }
        return try OriginalCampaignView(host:OriginalCampaignHost.resume(data:host.data,from:snapshot,allowPractice:practiceMode),saveRootOverride:saveRootOverride,practiceContext:practiceContext)
    }
    /// Asks for a native resume file and returns a host continuing after its
    /// source3D prompt, or nil when the panel is cancelled.
    static func chooseResume(data:DataSet) throws -> OriginalCampaignHost? {
        let panel = NSOpenPanel();panel.allowedContentTypes = [.json];panel.allowsMultipleSelection = false
        panel.directoryURL = try savesDirectory();panel.message = "자체 엔진 저장 파일을 고르세요."
        guard panel.runModal() == .OK,let url = panel.url else { return nil }
        return try OriginalCampaignHost.resume(data:data,from:OriginalSaveSlots.readFile(from:url))
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func stop() {
        if terminationCompletion != nil { cancelPendingTermination() }
        timer?.invalidate();timer = nil;audio?.shutDown()
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor);keyMonitor = nil }
    }
    func closed() {stop();let callback = onPracticeReturn;onPracticeReturn = nil;callback?()}
    /// Engine additions. Held Control runs the game four times as fast, L
    /// opens the dialogue log, A turns auto advance on or off, S skips to the
    /// next decision, and F5 and F9 suspend and resume the separate one-use slot.
    private func shortcut(_ event:NSEvent) -> Bool {
        if event.type == .flagsChanged {
            guard !pauseCoordinator.paused else { fastForwardHeld = false;return false }
            fastForwardHeld = event.modifierFlags.contains(.control);needsDisplay = true
            return false
        }
        guard !suspendPromptActive else { return false }
        guard !event.isARepeat,event.modifierFlags.intersection([.command,.control]).isEmpty,
              !(window?.firstResponder is NSTextView) else { return false }
        let context:AppControlPreferences.Context = overlay.active ? (overlay.notice != nil || overlay.brief != nil ? .dialogue : .list) : battleView?.isHidden == false ? (battleView?.controlContext ?? .battle) : .field
        switch settings.controls.command(for:event,context:context) {
        case .log:return presentLog()
        case .auto:guard host.hasStarted else { return false };lineControl(.auto);return true
        case .skip:guard host.hasStarted else { return false };lineControl(.skip);return true
        case .suspend:quickSave(nil);return true
        case .resume:quickLoad(nil);return true
        default:return false
        }
    }
    @objc func toggleFastForward(_ sender:Any?) {
        guard !suspendPromptActive else { return }
        fastForwardLocked.toggle();needsDisplay = true
        (sender as? NSMenuItem)?.state = fastForwardLocked ? .on : .off
    }
    @objc func openDialogueLog(_ sender:Any?) { _ = presentLog() }
    @objc func toggleAutoAdvance(_ sender:Any?) { lineControl(.auto) }
    @objc func toggleSkip(_ sender:Any?) { if host.hasStarted { lineControl(.skip) } }
    @objc func validateMenuItem(_ item:NSMenuItem) -> Bool {
        guard !suspendPromptActive else { return false }
        switch item.action {
        case #selector(quickSave(_:)):
            item.title = suspendRequested ? "중단 저장 예약 취소" : "중단 저장 후 타이틀로…"
            return host.hasStarted && host.ending == nil && !suspendPromptActive
        case #selector(toggleAutoAdvance(_:)):item.state = DialoguePace.shared.auto ? .on : .off
        case #selector(toggleSkip(_:)):item.state = DialoguePace.shared.skipping ? .on : .off
        default:break
        }
        return true
    }
    /// The reading controls on a line, from a click, a key or the menu.
    private func lineControl(_ control:CanvasOverlayView.LineControl) {
        guard !suspendPromptActive else { return }
        let pace = DialoguePace.shared
        switch control {
        case .log:_ = presentLog()
        case .auto:pace.auto.toggle()
        case .skip:pace.skipping.toggle()
        }
        needsDisplay = true
    }
    /// Lines the player has read, newest last. The source keeps none.
    private func presentLog() -> Bool {
        // From an open line, the line comes back when the log closes.
        guard !suspendPromptActive,host.hasStarted,!overlay.active || overlay.notice != nil else { return false }
        let previous = window?.firstResponder
        suspendPromptActive = true;refreshPause();saveOverlay.isHidden = false
        let close:()->Void = { [weak self,weak previous] in
            guard let self else {return}
            self.saveOverlay.isHidden = true;self.suspendPromptActive = false;self.refreshPause()
            if let previous {self.window?.makeFirstResponder(previous)}
        }
        CampaignManagementUI(host:host,overlay:saveOverlay,portrait:{[weak self] in self?.personPortrait($0)},
            onError:{[weak self] in self?.recordInputError($0)}).showDialogueHistory(onClose:close)
        window?.makeFirstResponder(saveOverlay)
        return true
    }
    @objc func quickSave(_ sender:Any?) {
        guard !suspendPromptActive else { return }
        if suspendRequested {
            suspendRequested = false;cancelPendingTermination();inputNotice = "중단 저장 예약을 취소했습니다.";needsDisplay = true;return
        }
        guard host.hasStarted,!practiceCompleted,host.ending == nil,host.frameworkReturn?.outcome != .quit,screenPlayer == nil,errorText == nil else {
            suspendAlert("중단 저장",text:"게임을 진행하는 동안 사용할 수 있습니다. 타이틀과 종료 화면은 저장하지 않습니다.");return
        }
        suspendConfirmation("중단 저장하고 쉬시겠습니까?",
            text:"일반 저장과 별도의 한 칸에 저장하고 타이틀로 돌아갑니다. 이어하기에 성공하면 소모되며, 기존 중단 저장은 덮어씁니다.\n\n진행 중인 행동·선택이 끝나면 저장합니다. F5로 예약을 취소할 수 있습니다.",button:"중단 저장") { [weak self] accepted in
            guard accepted,let self = self else { return }
            self.suspendRequested = true;DialoguePace.shared.skipping = false
            self.inputNotice = nil;self.needsDisplay = true
            _ = self.completeSuspendIfReady()
        }
    }
    var requiresTerminationProtection:Bool {
        host.hasStarted && host.frameworkReturn?.outcome != .quit && !practiceCompleted
    }
    /// The app delegate waits for this single callback before approving close.
    @discardableResult func requestProtectedTermination(_ completion:@escaping (Bool) -> Void) -> Bool {
        guard !suspendPromptActive,!fading,terminationCompletion == nil,terminationGate.begin() else { return false }
        terminationCompletion = completion
        let canSave = host.hasStarted && host.ending == nil && host.frameworkReturn?.outcome != .quit && screenPlayer == nil && errorText == nil
        let buttons = canSave ? ["저장 후 종료","저장 없이 종료","취소"] : ["저장 없이 종료","취소"]
        let explanation = canSave ? "별도 한 칸에 현재 진행을 저장한 뒤 종료합니다. 기존 중단 저장은 덮어쓰며, 이어하기에 성공하면 소모됩니다. 진행 중인 행동·선택을 마친 뒤 저장합니다." : "현재 화면에서는 중단 저장할 수 없습니다. 저장 없이 종료하거나 돌아갈 수 있습니다."
        saveDialog("게임을 종료하시겠습니까?",text:explanation,buttons:buttons) { [weak self] answer in
            guard let self = self else { return }
            if canSave,answer == 0 {
                self.terminationGate.choose(.save);self.suspendRequested = true
                DialoguePace.shared.skipping = false;self.inputNotice = nil;self.needsDisplay = true
                _ = self.completeSuspendIfReady()
            } else if answer == (canSave ? 1 : 0) {
                self.terminationGate.choose(.discard);self.suspendRequested = false
                self.finishPendingTermination(approved:self.terminationGate.consumeApproval())
            } else {
                self.terminationGate.choose(.cancel);self.finishPendingTermination(approved:false)
            }
        }
        return true
    }
    func explainMultipleCampaignExit() {
        suspendAlert("진행 중인 게임 창이 여러 개입니다",text:"중단 저장은 한 칸이므로 여러 게임을 함께 저장할 수 없습니다. 각 게임 창에서 저장 여부를 선택해 닫아 주세요. 현재 진행은 유지됩니다.")
    }
    private func finishPendingTermination(approved:Bool) {
        let callback = terminationCompletion;terminationCompletion = nil
        callback?(approved)
    }
    private func cancelPendingTermination() {
        guard terminationCompletion != nil else { return }
        suspendRequested = false;terminationGate.cancel();finishPendingTermination(approved:false)
    }
    /// All save/load confirmation and failure messages use the engine menu.
    /// The covered layers keep their callbacks and frozen reading countdowns.
    private func saveDialog(_ title:String,text:String,buttons:[String],_ completion:@escaping (Int?) -> Void) {
        guard !suspendPromptActive else { return }
        let previous = window?.firstResponder
        suspendPromptActive = true
        refreshPause()
        var menu = CanvasMenu(title:title,options:buttons.map { .init(label:$0) },horizontal:true,cancellable:true,footer:text) { [weak self,weak previous] answer in
            guard let self = self else { return }
            self.saveOverlay.isHidden = true;self.suspendPromptActive = false
            self.refreshPause()
            if let previous = previous { self.window?.makeFirstResponder(previous) }
            else if self.overlay.active { self.window?.makeFirstResponder(self.overlay) }
            else if let battle = self.battleView,!battle.isHidden { battle.restoreKeyboardFocus() }
            else { self.window?.makeFirstResponder(self) }
            completion(answer)
        }
        menu.cancelsOnOutsideClick = false
        saveOverlay.show(menu)
    }
    private func suspendConfirmation(_ title:String,text:String,button:String,_ completion:@escaping (Bool) -> Void) {
        saveDialog(title,text:text,buttons:[button,"취소"]) { completion($0 == 0) }
    }
    private func suspendAlert(_ title:String,text:String,afterDismiss:@escaping () -> Void = {}) {
        saveDialog(title,text:text,buttons:["확인"]) { _ in afterDismiss() }
    }
    private func suspendStore() throws -> SuspendSaveStore { SuspendSaveStore(directory:try currentSaveDirectory()) }
    /// The host and flow own the save boundary; presentation must also finish
    /// its outstanding cues before their continuation can be discarded.
    @discardableResult private func completeSuspendIfReady() -> Bool {
        guard suspendRequested,!suspendPromptActive,!fading,screenPlayer == nil,window != nil else { return false }
        guard battleView?.isAnimating != true,battleView?.isInCombatView != true,battleView?.isPlayingDuel != true else { return false }
        var next:OriginalCampaignView?
        do {
            guard let rawSnapshot = try host.suspendSnapshot(battleFlow:battleView?.flow) else { return false }
            let snapshot = scopedSnapshot(rawSnapshot)
            if terminationCompletion != nil {
                try suspendStore().write(snapshot,title:host.stage.palette == 3 ? (host.battle?.definition.name ?? slotTitle) : slotTitle)
                suspendRequested = false
                _ = terminationGate.finishSave(success:true)
                finishPendingTermination(approved:terminationGate.consumeApproval())
                return true
            }
            let title = try OriginalCampaignView(data:host.data,saveRootOverride:saveRootOverride,practiceContext:practiceContext);next = title
            try suspendStore().write(snapshot,title:host.stage.palette == 3 ? (host.battle?.definition.name ?? slotTitle) : slotTitle)
            suspendRequested = false;replace(with:title);title.presentTitleMenu();title.fadeIn()
            return true
        } catch {
            next?.stop();suspendRequested = false
            _ = terminationGate.finishSave(success:false);finishPendingTermination(approved:false)
            recordInputError(error,message:"중단 저장하지 못했습니다. 현재 게임은 그대로입니다. 저장 공간을 확인하고 다시 시도하세요.")
            suspendAlert("중단 저장 실패",text:"현재 게임은 그대로 진행할 수 있습니다. 저장 공간과 폴더 권한을 확인하고 다시 시도하세요.")
            return false
        }
    }
    @objc func quickLoad(_ sender:Any?) {
        guard !suspendPromptActive,!fading,terminationCompletion == nil,window != nil else { return }
        do {
            let store = try suspendStore()
            guard let entry = try store.entry() else { suspendAlert("중단 저장 없음",text:"F5 또는 게임 메뉴의 ‘중단 저장 후 타이틀로’로 저장할 수 있습니다. 이전 빠른 저장은 일반 불러오기 목록에 남아 있습니다.");return }
            suspendConfirmation("중단한 게임을 이어할까요?",text:"\(entry.title)\n\n이어하기에 성공하면 이 중단 저장은 소모됩니다. 현재 플레이 중이라면 그 진행을 대신합니다.",button:"이어하기") { [weak self] accepted in
                guard accepted,let self = self else { return }
                do { try self.resumeSuspended(store,entry:entry) }
                catch { self.presentSuspendLoadError(error) }
            }
        } catch {
            presentSuspendLoadError(error)
        }
    }
    private func presentSuspendLoadError(_ error:Error,afterDismiss:@escaping () -> Void = {}) {
        recordInputError(error,message:"중단 저장을 불러오지 못했습니다. 파일은 소모하지 않았습니다.")
        suspendAlert("이어하기 실패",text:"중단 저장을 불러오지 못했습니다. 저장 파일은 소모하지 않았으며 현재 게임도 그대로입니다.",afterDismiss:afterDismiss)
    }
    private func resumeSuspended(_ store:SuspendSaveStore,entry:SuspendSaveStore.Entry) throws {
        guard window != nil else { throw EngineError.invalid("Suspend resume needs an attached game window") }
        var prepared:OriginalCampaignView?
        do {
            let next = try store.resume(as:OriginalCampaignResume.self,expectedID:entry.id) { snapshot in
                guard snapshot.suspension != nil else { throw EngineError.invalid("Suspend slot has no suspension payload") }
                let view = try self.resumedView(snapshot)
                prepared = view
                try view.synchronizeBattle(prepareOnly:true)
                return view
            }
            suspendRequested = false;replace(with:next);next.pendingResumeBrief = true;next.fadeIn()
        } catch { prepared?.stop();throw error }
    }
    /// An engine addition: an idle field writes the autosave whenever its
    /// scene or map changes since the last one.
    private func autosave() {
        let state = host.vm.state
        let key = "\(state.chapter):\(state.member):\(state.block):\(state.groupBase):\(state.packedMap)"
        let result = autosaveState.attempt(key:key,now:ProcessInfo.processInfo.systemUptime) {
            try saveSlots().write(scopedSnapshot(try host.resumeSnapshot()),title:slotTitle,named:.auto)
        }
        switch result {
        case .skipped:break
        case .saved(let recovered):
            autosaveNotice = nil
            if recovered { inputNotice = "자동 저장이 다시 정상적으로 완료되었습니다." }
        case .failed(let error,let notify):
            if notify {
                autosaveNotice = "자동 저장하지 못했습니다. 저장 폴더와 남은 공간을 확인해 주세요. 잠시 후 다시 시도합니다."
                FileHandle.standardError.write(Data("자동 저장 실패: \(error)\n".utf8))
            }
        }
    }
    /// Capture once before the first turn. If the disk write fails, keep that
    /// immutable snapshot while the player continues and retry its write later.
    private func captureBattleStart(_ session:OriginalBattleSession) {
        guard session.turns.stage == .unstarted else { return }
        let id = ObjectIdentifier(session)
        guard battleStartCapturedSession != id else { return }
        do {
            guard var snapshot = try host.battleStartSnapshot() else { return }
            if !practiceMode,host.extras.battleArchives.recordingEnabled {
                do {try recorder().begin(start:snapshot,progress:&host.extras.battleArchives)}
                catch {archiveCoordinator?.failed(error,progress:&host.extras.battleArchives)}
            }
            snapshot.extras = host.extras
            battleStartCapturedSession = id
            pendingBattleStart = (id,scopedSnapshot(snapshot),session.definition.name ?? slotTitle)
            retryBattleStartSave()
        } catch {
            battleStartCapturedSession = id;pendingBattleStart = nil
            battleSaveNotice = "전투 시작을 자동 저장하지 못했습니다. 현재 전투는 그대로 진행할 수 있습니다."
            FileHandle.standardError.write(Data("전투 시작 저장 준비 실패: \(error)\n".utf8))
        }
    }
    private func retryBattleStartSave() {
        guard let pending = pendingBattleStart else { return }
        let result = battleStartSaveState.attempt(key:String(describing:pending.session),now:ProcessInfo.processInfo.systemUptime) {
            try saveSlots().write(pending.snapshot,title:pending.title,named:.battleStart)
        }
        switch result {
        case .skipped:break
        case .saved:
            battleStartSavedSession = pending.session;pendingBattleStart = nil;battleSaveNotice = nil
            let text = "전투 시작 자동 저장 · 불러오기에서 이 전투의 첫 턴부터 재개할 수 있습니다."
            inputNotice = text;battleSaveToast = (text,ProcessInfo.processInfo.systemUptime+3)
        case .failed(let error,let notify):
            if notify {
                battleSaveNotice = "전투 시작을 자동 저장하지 못했습니다. 저장 폴더를 확인해 주세요. 잠시 후 다시 시도합니다."
                FileHandle.standardError.write(Data("전투 시작 자동 저장 실패: \(error)\n".utf8))
            }
        }
    }
    /// Word +A bit 8 greys the palette; the filter sits over the whole canvas.
    private func applySettings() {
        settings = OriginalSettings.current
        wantsLayer = true;layerUsesCoreImageFilters = true
        contentFilters = settings.monochrome ? [CIFilter(name:"CIPhotoEffectMono")].compactMap { $0 } : []
        audio?.volume = settings.volume
        refreshPause()
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
    private var autosaveState = CampaignAutosave()
    private var battleStartSaveState = CampaignAutosave()
    private var battleStartCapturedSession:ObjectIdentifier?
    private var battleStartSavedSession:ObjectIdentifier?
    private var pendingBattleStart:(session:ObjectIdentifier,snapshot:OriginalCampaignResume,title:String)?
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
        guard !suspendPromptActive else { return }
        if completeSuspendIfReady() { return }
        if practiceMode,!practiceCompleted,host.hasStarted,
           (host.ending != nil || host.frameworkReturn != nil || host.stage.palette != 3),let session = host.battle {
            finishPractice(session);return
        }
        refreshPause()
        guard !pauseCoordinator.paused else { return }
        if let toast = battleSaveToast,ProcessInfo.processInfo.systemUptime >= toast.deadline {
            if inputNotice == toast.text { inputNotice = nil;needsDisplay = true }
            battleSaveToast = nil
        }
        if let player = screenPlayer { advanceScreen(player);return }
        if fading { advanceFade();return }
        if pendingResumeBrief {
            pendingResumeBrief = false
            if settings.showResumeBrief {
                saveDialog("이어서 할 일",text:ResumeBrief.text(host),buttons:["계속"]) { _ in }
                return
            }
        }
        if host.frameworkReturn?.outcome == .quit { startQuitScreen() }
        if let session = host.ending,advanceEnding(session) { return }
        // 2CB4:125E plays song 18 for the duel and 1824 restores the one before.
        if host.ending == nil { audio?.select(host.battle?.scriptActions.duel?.active == true ? 18 : host.vm.state.currentMusic) }
        retryBattleStartSave()
        battleView?.externalStatus = errorText ?? suspendStatus ?? inputNotice ?? battleSaveNotice ?? autosaveNotice ?? host.notice ?? host.playerStatus ?? (practiceMode ? "연습 전투 · 본편에 반영되지 않음" : nil)
        let pace = DialoguePace.shared
        if pace.skipping,skipReachedDecision { pace.skipping = false }
        battleView?.fastForward = fastForward || pace.skipping
        // Fast-forward reads a line for a tenth of a second, then moves on;
        // skip closes every line at once.
        if fastForward || pace.skipping,host.hasStarted {
            skipTicks += 1
            if pace.skipping || skipTicks >= 6 {
                skipTicks = 0
                if overlay.notice != nil { overlay.skipNotice() }
                battleView?.skipLines()
            }
        }
        guard !overlay.active,errorText == nil else { return }
        if let edge = edgeScroll {
            edgeTicks += 1
            if edgeTicks >= 4 { edgeTicks = 0;scrollWorld(edge.dx,edge.dy) }
        } else { edgeTicks = 0 }
        do {
            let rate = pace.skipping ? Double(Self.skipRate) : fastForward ? Double(OriginalBattleView.fastRate) : 1
            battleView?.duelStage = host.duelStage
            if let steps = host.duelSteps,let board = battleView,!board.isPlayingDuel {
                board.playDuel(steps) { [weak self] in self?.host.finishDuelSteps() }
            }
            if let cues = host.battleCues,let board = battleView,!board.isAnimating {
                board.playScriptCues(cues) { [weak self] in self?.host.finishBattleCues() }
            }
            battleView?.advanceAnimation(rate*settings.battleRate/60)
            for id in host.takeSounds() { audio?.playEffect(id) }
            try host.advance(microseconds:Int64(16_667*settings.timeScale*rate))
            needsDisplay = true
            // MAIN fades around a battle (research/original-map-transitions.md): from
            // the field out, black, the battle, in and a held fade (0x1E297, 0x272A7);
            // a chained or restarted battle without the black; leaving, out and black
            // until the field's own 05 (C456 at 0x1E36A).
            let closing = host.ending != nil || host.frameworkReturn?.outcome == .quit
            if !closing,host.stage.palette == 3,let session = host.battle,battleView?.session !== session {
                // Reaching a new battlefield ends the previous scene's skip.
                // Its opening lines must wait for a fresh player decision;
                // skip can still be enabled again within this battle.
                pace.skipping = false
                battleView?.fastForward = fastForward
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
            else if host.stage.dialogue != nil,host.battleCues == nil,battleView?.isAnimating != true { presentDialogue() }
        } catch { errorText = "\(error)";needsDisplay = true }
    }
    /// Skip runs the game this many times as fast.
    static let skipRate = 8
    /// Skip stops where the player has something to decide: a question or
    /// list, a battle command, or an idle town or world map.
    private var skipReachedDecision:Bool {
        if !host.hasStarted || screenPlayer != nil || host.ending != nil || errorText != nil || fading { return true }
        if overlay.active,overlay.notice == nil { return true }
        if let board = battleView,!board.isHidden { return board.awaitsCommand || board.asksPlayer }
        return host.explorationInputReady && host.stage.dialogue == nil
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
        if practiceMode {retryPractice();return}
        do { let next = try OriginalCampaignView(data:host.data,saveRootOverride:saveRootOverride);replace(with:next);next.presentTitleMenu() }
        catch { errorText = "\(error)";needsDisplay = true }
    }
    /// Engine menu: MAIN's slot list, from the title or an idle field.
    @objc func openLoad(_ sender:Any?) {
        guard !suspendPromptActive,terminationCompletion == nil,screenPlayer == nil,!fading,
              !overlay.active || (!host.hasStarted && !titleSubmenu) else { return }
        if let battle = battleView,!battle.isHidden,!battle.awaitsCommand {
            inputNotice = "진행 중인 행동·선택이 끝나면 불러오기를 열 수 있습니다.";needsDisplay = true;return
        }
        presentSlots(saving:false) { [weak self] _ in
            guard let self = self,!self.host.hasStarted else { return }
            self.presentTitleMenu()
        }
    }
    /// Engine menu: the field menu's save, wherever the field menu could open.
    @objc func openSave(_ sender:Any?) {
        guard !suspendPromptActive,terminationCompletion == nil else { return }
        guard host.fieldMenuReady,!overlay.active,!fading else { inputNotice = saveUnavailableMessage;needsDisplay = true;return }
        presentSlots(saving:true) { _ in }
    }
    private var saveUnavailableMessage:String {
        if let battle = host.battle {
            return battleStartSavedSession == ObjectIdentifier(battle)
                ? "전투 도중에는 F5로 중단 저장할 수 있습니다. 일반 불러오기의 ‘전투 시작’은 첫 턴부터 재개합니다."
                : "전투 도중에는 F5로 중단 저장할 수 있습니다. 일반 슬롯은 마을·세계지도에서 저장합니다."
        }
        return "일반 슬롯은 이동·대화가 끝난 뒤 저장합니다. 지금 중단하려면 F5를 누르세요."
    }
    /// Engine menu: leave the game for MAIN's title menu, after a question.
    @objc func returnToTitle(_ sender:Any?) {
        if practiceMode {window?.performClose(nil);return}
        guard !suspendPromptActive,host.hasStarted,!overlay.active,screenPlayer == nil,!fading else { return }
        yesNo("진행 중인 게임을 그만두고 타이틀로 돌아갈까요?") { [weak self] yes in
            guard yes else { return }
            self?.fadeThrough { [weak self] in
                guard let self = self else { return }
                do { let next = try OriginalCampaignView(data:self.host.data,saveRootOverride:self.saveRootOverride);self.replace(with:next);next.fadeIn();next.presentTitleMenu() }
                catch { self.errorText = "\(error)";self.needsDisplay = true }
            }
        }
    }
    private func synchronizeBattle(prepareOnly:Bool = false) throws {
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
            board.inputReady = { [weak self] in self?.host.battleInputReady == true && self?.pauseCoordinator.paused == false }
            board.menuTexts = host.framework?.battleMenu
            board.objective = { [weak self] in (self?.host.vm.state.chapter ?? 0,self?.host.vm.state.objectiveText) }
            board.objectiveProgress = { [weak self] in
                guard let self,let text = self.host.vm.state.objectiveText else {return []}
                return self.host.reviewedObjectiveProgress(publicText:text)
            }
            board.announcesPhases = true
            board.confirmsTurnEnd = true
            board.animatesActions = true
            board.settingsTexts = host.framework?.settings
            board.combatArt = combatArt
            board.portraitImage = { [weak self] person in self?.portrait(person,palette:3) }
            board.soundBusy = { [weak self] in self?.audio?.effectPlaying ?? false }
            board.stopSound = { [weak self] in self?.audio?.stopEffect() }
            if !session.restoredSourceOptions { session.sourceOptionsWord = settings.battleWord }
            board.onSound = { [weak self] id in self?.audio?.playEffect(id) }
            board.onLineControl = { [weak self] control in self?.lineControl(control) }
            board.onSuspend = { [weak self] in self?.quickSave(nil) }
            board.onLoad = { [weak self] in self?.openLoad(nil) }
            board.onManageInventory = { [weak self] in self?.withManagement {ui,close in ui.showInventory(onClose:close)} }
            board.onControlSettings = { [weak self] in self?.openControlSettings(nil) }
            board.onEventHints = { [weak self] in self?.openEventHints(nil) }
            board.onMapViewPreferenceChanged = { mode in
                var value = OriginalSettings.current;value.controls.battleMapMode = mode;OriginalSettings.current = value
            }
            board.allowsAutomaticGuidance = { [weak self] in
                guard let self else {return false}
                return !self.practiceMode && !DialoguePace.shared.skipping && !self.suspendPromptActive && !self.pauseCoordinator.paused
            }
            board.annotations = { [weak self] in self?.host.extras.annotations }
            board.onAnnotationsChanged = { [weak self] value in try value.validate();self?.host.extras.annotations = value }
            board.onAcceptedInput = { [weak self] in self?.recordAcceptedInput($0) }
            board.onRecordingBoundary = { [weak self] in self?.recordBoundary() }
            board.favoriteCommands = { [weak self] person in self?.host.extras.commandFavorites.actions(for:person) ?? [] }
            board.favoriteCommandsSourceIssue = { [weak self] in
                guard let self else {return "현재 자료를 확인할 수 없습니다."}
                return self.host.extras.commandFavorites.sourceIssue(for:self.host.currentAssistanceSourceIdentity)
            }
            board.onResetFavoriteSource = { [weak self] in
                guard let self else {return}
                do {
                    guard let identity = self.host.currentAssistanceSourceIdentity else {throw EngineError.invalid("현재 자료를 확인할 수 없습니다.")}
                    try self.host.extras.commandFavorites.reset(forSource:identity)
                } catch {self.recordInputError(error,message:"즐겨찾기를 초기화하지 못했습니다.")}
            }
            board.onFavoriteCommandsChanged = { [weak self] person,actions in
                guard let self,let identity = self.host.currentAssistanceSourceIdentity else {throw EngineError.invalid("현재 자료를 확인할 수 없습니다.")}
                try self.host.extras.commandFavorites.set(person:person,actions:actions,sourceIdentity:identity)
            }
            board.foregroundFavorites = { [weak self] in Set(self?.host.extras.favoritePeople ?? []) }
            board.onItemDiscardRefusal = { [weak self] person,item in
                self?.host.extras.protects(personID:person,itemID:item,operation:.discard) == true ? "보호된 도구는 버릴 수 없습니다. 도구 관리에서 보호를 해제해 주세요." : nil
            }
            board.onItemTransfer = { [weak self] from,to,item in
                do { try self?.host.extras.transferProtection(from:from,to:to,item:item) }
                catch { self?.recordInputError(error,message:"도구 보호 정보를 전달하지 못했습니다.") }
            }
            board.onItemUseRefusal = { [weak self] person,item in
                self?.host.extras.protects(personID:person,itemID:item,operation:.use) == true ? "사용 보호된 도구입니다. 도구 관리에서 보호를 해제해 주세요." : nil
            }
            board.presentation = CanvasPresentation.current
            board.frame = bounds
            addSubview(board,positioned:.below,relativeTo:curtain);battleView = board
            window?.makeFirstResponder(board)
            if prepareOnly { board.prepareSuspendedPresentation() }
            else { board.restorePendingMovementCommand() }
        }
        battleView?.isHidden = false;overlay.viewport = battleView?.layoutFacts.viewportRect ?? overlay.viewport
        // Construct the resumed presentation before consuming the slot, but
        // do not start a turn, dispatch a hook or write an automatic save yet.
        if prepareOnly { return }
        battleView?.duelStage = host.duelStage
        if let dialogue = host.stage.dialogue,host.duelStage == nil,host.duelSteps == nil {
            _ = battleView?.focusSpeaker(dialogue.person)
        }
        if let steps = host.duelSteps,let board = battleView,!board.isPlayingDuel {
            board.playDuel(steps) { [weak self] in self?.host.finishDuelSteps() }
        }
        if let cues = host.battleCues,let board = battleView,!board.isAnimating {
            board.playScriptCues(cues) { [weak self] in self?.host.finishBattleCues() }
        }
        battleView?.announcePhase()
        if host.battleInputReady,let board = battleView {
            if session.turns.stage == .unstarted {
                // Opening walks and duels belong to the script before the
                // first turn. Finish them before capturing or starting it.
                guard host.battleCues == nil,host.duelSteps == nil,!board.isAnimating,!board.isPlayingDuel else { return }
                captureBattleStart(session);try board.start()
            }
            else if board.suspended { try board.resumeSourceFlow() }
            if board.flow.canLeaveBattle {
                if practiceMode {finishPractice(session);return}
                if host.extras.battleArchives.active != nil {
                    do {try recorder().finish(host:host,progress:&host.extras.battleArchives)}
                    catch {archiveCoordinator?.failed(error,progress:&host.extras.battleArchives)}
                }
                let previousCount = host.extras.journal.summaries.count
                try host.finishBattleLoop()
                if host.extras.journal.summaries.count > previousCount {
                    inputNotice = "전투 결과를 누적 전적에 기록했습니다. 게임 메뉴에서 확인할 수 있습니다."
                    battleSaveToast = (inputNotice!,ProcessInfo.processInfo.systemUptime+4)
                }
            }
        }
        battleView?.needsDisplay = true
    }
    private static let pictureViewport = CGRect(x:16,y:16,width:608,height:368)
    private func hideBattle() { battleView?.clearSpeakerFocus();battleView?.isHidden = true;overlay.viewport = fieldOverlay }
    /// Modern windows have the whole canvas; original frames keep the map window.
    private var fieldOverlay:CGRect {
        CanvasPresentation.current == .modern ? CGRect(x:8,y:8,width:624,height:384) : CanvasOverlayView.fieldViewport
    }
    private var modernField:Bool { CanvasPresentation.current == .modern && host.fieldScreenState() != nil }
    /// A framed map keeps its window; a full picture gives the line the whole canvas.
    private func presentDialogue() {
        guard let dialogue = host.stage.dialogue else { return }
        if !dialogue.text.isEmpty {
            do {
                let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
                let signature = "\(host.vm.state.chapter):\(host.vm.state.packedMap):\(host.vm.state.currentRecordID ?? ""):\(host.vm.state.instructionIndex):"+(try encoder.encode(dialogue)).base64EncodedString()
                try host.extras.dialogueHistory.present(person:dialogue.person,speaker:dialogue.speaker,text:dialogue.text,
                    chapter:host.vm.state.chapter,map:host.vm.state.packedMap,record:host.vm.state.currentRecordID,signature:signature)
            } catch {recordInputError(error)}
        }
        if host.stage.palette == 3,let board = battleView {
            _ = board.focusSpeaker(dialogue.person)
        } else if host.stage.palette != 3 {
            overlay.viewport = host.fieldScreenState() != nil ? fieldOverlay : Self.pictureViewport
        }
        // A timed box (source 0B, 0E) closes by itself; narration sits where dialogue does.
        var line = CanvasNotice(speaker:dialogue.speaker,text:dialogue.text,portrait:portrait(dialogue.person,palette:host.stage.palette),timeout:dialogue.closesAfter) { [weak self] in
            guard let self = self else { return }
            self.battleView?.clearSpeakerFocus()
            self.host.extras.dialogueHistory.finishPresentation()
            self.act { try self.host.acknowledge() }
        }
        line.placeAtTop = host.stage.palette == 3 && (battleView?.speakerInLowerHalf == true)
        line.narration = dialogue.closesAfter == nil && dialogue.speaker.isEmpty && line.portrait == nil
        overlay.show(line)
    }
    /// A visit stays in one window. Each blocking call of the source routine
    /// changes the merchant's line, the list and what answers it.
    private var managementUI:CampaignManagementUI {
        CampaignManagementUI(host:host,overlay:overlay,portrait:{[weak self] in self?.personPortrait($0)},
            onError:{[weak self] in self?.recordInputError($0)})
    }
    private func presentShop() {
        guard let shop = host.shop,let prompt = host.shopPrompt,let money = host.money else { return }
        if case .receiverConfirm(let item,let person) = shop.phase {
            managementUI.showShopPurchase(item:item,person:person) { [weak self] accepted in
                guard let self else {return}
                self.act {try self.host.answerShop(accepted ? 1 : 0)}
                if self.errorText == nil {self.presentShop()}
            }
            return
        }
        let catalog = host.shopCatalog,person = catalog.merchant.person,list = shop.list
        let rows = (try? shopRows(shop,money:money)) ?? []
        if case .stock = shop.list,!rows.isEmpty {
            do {try host.observeCurrentShopStock()} catch {recordInputError(error)}
        }
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
        var sheet = CanvasSheet(portrait:portrait(person,palette:host.stage.palette),speaker:(try? host.people.person(person).name) ?? "",
            line:line,badge:("소지금","\(money)"),rows:rows,selected:min(shopCursor[list] ?? 0,max(0,rows.count-1)),mode:mode,
            buttons:prompt.kind == .ask ? ["예","아니요"] : [],hint:hint) { [weak self] value in
            guard let self = self else { return }
            if prompt.kind == .top || prompt.kind == .list,let value = value { self.shopCursor[list] = value }
            let answer = prompt.kind == .ask ? (value == 0 ? 1 : 0) : value
            self.act { try self.host.answerShop(answer) }
            if self.host.shop == nil { self.shopCursor.removeAll() }
            else if self.errorText == nil { self.presentShop() }
        }
        if prompt.kind == .top {
            sheet.buttons = ["일괄 구매·판매"]
            sheet.hint = "↑↓ 이동 · Enter 선택 · Tab 일괄 거래 · Esc 나가기"
            sheet.onButton = { [weak self] _ in
                self?.managementUI.showBulkShop { [weak self] in self?.presentShop() }
            }
        }
        overlay.show(sheet)
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
                let protected = host.extras.protects(personID:person,itemID:item,operation:.sell)
                return .init(label:itemName(item),value:protected ? "보호됨" : "\(price)",
                             detail:itemDetail(item,facts:[("판매가","\(price)"),("판매 후","\(min(10000,money+price))"),
                                ("보호",protected ? "소지품 통합 보기에서 해제할 수 있습니다." : "없음")]),enabled:!protected)
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
        overlay.show(fieldSheet(title:texts.personInfo,line:texts.people,rows:rows,selected:selected,hint:"↑↓ 장수 선택 · ↩ 책략·성장·비교 · esc 닫기") { [weak self] index in
            guard let self,let index = index,people.indices.contains(index) else { return }
            self.managementUI.showOfficerActions(person:people[index],onStrategies:{ [weak self] in
                self?.presentStrategyLearning(person:people[index],peopleIndex:index)
            },onClose:{ [weak self] in self?.presentPeople(selected:index) })
        })
    }
    /// Read-only engine guide. It uses the current class's source learning
    /// table and returns to the same companion without issuing a host command.
    private func presentStrategyLearning(person id:Int,peopleIndex:Int,selected:Int = 0) {
        do {
            guard let levels = host.source.movement.strategyLevelRequirements,
                  let costs = host.source.movement.strategyMPCosts,
                  let commands = host.story.screens?.battle.commands else {
                throw EngineError.invalid("Original strategy learning data is unavailable")
            }
            let person = try host.people.person(id)
            guard commands.classNames.indices.contains(person.classID) else {
                throw EngineError.invalid("Original strategy learning class is unavailable")
            }
            let sheet = try StrategyLearningGuide.sheet(person:person,levels:levels,costs:costs,
                names:commands.strategyNames,profile:host.source.movement,terrainNames:commands.terrain.names,
                className:commands.classNames[person.classID],portrait:personPortrait(id),selected:selected) { [weak self] row in
                guard let self = self else { return }
                if let row = row { self.presentStrategyLearning(person:id,peopleIndex:peopleIndex,selected:row) }
                else { self.presentPeople(selected:peopleIndex) }
            }
            overlay.show(sheet)
        } catch {
            recordInputError(error)
            overlay.show(CanvasNotice(speaker:"책략 습득표",text:"현재 병과의 책략 습득 자료를 읽을 수 없습니다.",portrait:nil) { [weak self] in
                self?.presentPeople(selected:peopleIndex)
            })
        }
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
            guard others.indices.contains(index) else {return}
            self.managementUI.showTransfer(giver:giver,receiver:others[index],item:item,
                onCancel:{ [weak self] in self?.presentExchange(giver:giver,item:item,selected:index) },
                onSuccess:{ [weak self] in self?.presentExchange(giver:giver) })
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
        let information = CanvasPresentation.current == .modern ? "\(texts.personInfo) · 책략" : texts.personInfo
        overlay.show(CanvasMenu(title:"",options:[.init(label:information),.init(label:texts.itemExchange),.init(label:"소지품 통합 보기"),
            .init(label:"장수 비교"),.init(label:"주력 장수 지정"),.init(label:"주변 찾기"),
            .init(label:"방문 상점 판매품"),.init(label:"장수·물품·책략 검색")],cancellable:true,anchor:point) { [weak self] index in
            guard let self else {return}
            switch index {
            case 0:self.presentPeople()
            case 1:self.presentExchange()
            case 2:self.managementUI.showInventory(onClose:{})
            case 3:self.managementUI.showComparison(onClose:{})
            case 4:self.managementUI.showFavorites(onClose:{})
            case 5:self.managementUI.showNearby(onClose:{})
            case 6:self.managementUI.showObservedShops(onClose:{})
            case 7:self.managementUI.showInfoSearch(onClose:{})
            default:break
            }
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
            guard yes else { self.act { try self.host.answerItemOffer(slot:nil,declined:true);self.recordAcceptedInput(.init(kind:.itemOffer)) };return }
            let items = (try? self.host.people.person(offer.person).itemIDs) ?? []
            let rows = items.map {item -> CanvasSheet.Row in
                let protected = self.host.extras.protects(personID:offer.person,itemID:item,operation:.discard)
                return CanvasSheet.Row(label:self.itemName(item),value:protected ? "보호됨" : "",detail:self.itemDetail(item,facts:[]),enabled:!protected)
            }
            self.overlay.show(self.fieldSheet(title:"",line:texts.giftChoose,rows:rows) { [weak self] index in
                self?.act { try self?.host.answerItemOffer(slot:index);self?.recordAcceptedInput(.init(kind:.itemOffer,slot:index)) }
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
        rows.append(contentsOf:[.init(label:"출전 준비 점검"),.init(label:"편성 프리셋"),.init(label:"주력 장수 지정"),.init(label:"출전")])
        overlay.show(fieldSheet(title:"출전 부대 선택",line:footer ?? "함께 나갈 장수를 고르세요.",badge:("남은 선택","\(selection.remaining) / \(selection.capacity)"),
                               rows:rows,selected:selected,hint:"↑↓ 이동 · ↩ 선택") { [weak self] index in
            guard let self = self,let index = index else { self?.presentParty(selected:selected,keepScroll:true);return }
            if index >= people.count {
                let back:()->Void = { [weak self] in self?.presentParty(selected:index,keepScroll:true) }
                switch index-people.count {
                case 0:self.managementUI.showPartyReview(onClose:back)
                case 1:self.managementUI.showPresets(onClose:back)
                case 2:self.managementUI.showFavorites(onClose:back)
                default:self.act {try self.host.confirmParty()}
                }
                return
            }
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
                self.act { try self.host.choose(yes ? 1 : 0);self.recordAcceptedInput(.init(kind:.choice,index:yes ? 1 : 0)) }
            }
            return
        }
        overlay.show(CanvasMenu(title:choice.prompt,options:choice.options.map { .init(label:$0) }) { [weak self] index in
            guard let self = self,let index = index else { return }
            self.act { try self.host.choose(index);self.recordAcceptedInput(.init(kind:.choice,index:index)) }
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
            self.act { try self.host.completeSaveRequest();self.recordAcceptedInput(.init(kind:.saveSkip)) }
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
    /// The engine title screen sets its buttons under the picture band (see
    /// drawRemakeTitle); the original frames use MAIN's window.
    private static let titleAnchor = CGPoint(x:320,y:228)
    /// Engine rows over MAIN's four title actions, plus an explicit quit.
    private static let modernTitle:[(label:String,icon:String)] = [("새 게임","play.fill"),("이어하기","tray.and.arrow.up.fill"),
        ("환경 설정","slider.horizontal.3"),("오프닝 보기","film.fill"),("종료","power")]
    private func titleMenu(_ choose:@escaping (Int?) -> Void = { _ in }) -> CanvasMenu {
        let items = host.framework?.titleMenu?.map(\.text) ?? ["새로 시작","이어하기","기능설정","오프닝"]
        let art = originalMenu("title")
        let options:[CanvasMenu.Option] = art == nil
            ? Self.modernTitle.map { CanvasMenu.Option(label:$0.label,icon:$0.icon,destructive:$0.label == "종료") }
            : items.map { .init(label:$0) }
        var menu = CanvasMenu(title:"",options:options,cancellable:true,anchor:Self.titleAnchor,style:art ?? .title,onChoose:choose)
        menu.cancelsOnOutsideClick = false
        return menu
    }
    /// MAIN CF5:C050 menu after the title. Item0 starts, item1 resumes a
    /// native slot, item2 opens the options, and item3
    /// returns to the opening, as exit code0 runs OPEN before MAIN again.
    /// A cancel ends the game through the exit screen (main 0x1E605, 1E3A8).
    func presentTitleMenu() {
        if practiceMode {
            overlay.show(CanvasMenu(title:"연습 전투 · 본편에 반영되지 않음",options:[.init(label:"중단한 연습 이어하기"),.init(label:"이 전투 다시 시작"),.init(label:"연습 저장 불러오기"),.init(label:"본편 창으로 돌아가기")]) { [weak self] index in
                guard let self else {return}
                switch index {
                case 0:self.quickLoad(nil)
                case 1:self.retryPractice()
                case 2:self.presentSlots(saving:false) {[weak self] _ in self?.presentTitleMenu()}
                default:self.window?.performClose(nil)
                }
            });return
        }
        titleSubmenu = false
        overlay.viewport = CGRect(x:0,y:0,width:640,height:400)
        overlay.show(titleMenu { [weak self] chosen in
            guard let self = self else { return }
            // The engine's 종료 row ends the game the way a cancel does.
            guard let chosen = chosen,chosen < 4 else {
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
                    let next = try OriginalCampaignView(data:self.host.data,saveRootOverride:self.saveRootOverride)
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
    /// One field setting row: its choices, the current one and how to store a choice.
    private func settingChoices(_ action:String) -> (labels:[String],current:Int,apply:(inout OriginalSettings,Int) -> Void)? {
        guard let texts = host.framework?.settings else { return nil }
        let value = OriginalSettings.current
        switch action {
        case "speed":return (texts.speed,value.speed,{ $0.speed = $1 })
        case "scroll":
            // MAIN22832: 소 to 극대 move the world view 1, 2, 4 or 8 tiles a step.
            let steps = OriginalSettings.scrollSteps
            return (texts.scroll ?? steps.map { "\($0)" },steps.firstIndex(of:value.scroll) ?? 0,{ $0.scroll = steps[$1] })
        case "monitor":return (texts.monitor,value.monochrome ? 1 : 0,{ $0.monochrome = $1 == 1 })
        case "bgm":return (texts.onOff,OriginalAudio.musicEnabled ? 0 : 1,{ _,index in OriginalAudio.musicEnabled = index == 0 })
        case "sound":return (texts.onOff,OriginalAudio.effectsEnabled ? 0 : 1,{ _,index in OriginalAudio.effectsEnabled = index == 0 })
        case "volume":
            let levels:[Float] = [1,0.75,0.5,0.25]
            return (levels.map { "\(Int($0*100))%" },levels.firstIndex(of:value.volume) ?? 0,{ $0.volume = levels[$1] })
        case "resume-brief":return (["끔","켬"],value.showResumeBrief ? 1 : 0,{ $0.showResumeBrief = $1 == 1 })
        case "background-pause":return (["끔","켬"],value.pauseInBackground ? 1 : 0,{ $0.pauseInBackground = $1 == 1 })
        case "auto":return Self.autoChoices(value)
        default:return nil
        }
    }
    private func changeSetting(_ action:String,by delta:Int) {
        guard let choice = settingChoices(action),!choice.labels.isEmpty else { return }
        var value = OriginalSettings.current
        choice.apply(&value,(choice.current+delta+choice.labels.count)%choice.labels.count)
        OriginalSettings.current = value;needsDisplay = true
    }
    /// Engine row: auto advance off or at one of its speeds.
    static func autoChoices(_ value:OriginalSettings) -> (labels:[String],current:Int,apply:(inout OriginalSettings,Int) -> Void) {
        (["끔"]+DialoguePace.speedLabels,value.autoAdvance ? value.autoSpeed+1 : 0,{ settings,index in
            settings.autoAdvance = index > 0;if index > 0 { settings.autoSpeed = index-1 }
        })
    }
    private static let fieldIcons = ["suspend":"pause.circle.fill","auto":"text.bubble.fill","quit":"power","scroll":"arrow.up.and.down.and.arrow.left.and.right","speed":"gauge.with.dots.needle.67percent",
        "load":"folder.fill","save":"tray.and.arrow.down.fill","monitor":"display","bgm":"music.note","sound":"speaker.wave.2.fill",
        "volume":"slider.horizontal.3","music-time":"music.note.list"]
    private func openFieldMenu(at point:CGPoint,selected:Int? = nil) {
        let labels = host.framework?.fieldMenu?.items.map(\.text) ?? OriginalFieldMenuTexts.actions
        let actions = OriginalFieldMenuTexts.actions,modern = CanvasPresentation.current == .modern
        // Settings show their current choice and change in place; the engine
        // layout lists save and load first and the quit row last.
        let order = modern ? ["save","load","scroll","speed","monitor","bgm","sound","volume","music-time","quit"].compactMap { actions.firstIndex(of:$0) } : Array(actions.indices)
        var rows = order.map { (action:actions[$0],label:labels[$0]) }
        if modern { rows.insert(("suspend","중단 저장 후 타이틀로"),at:0) }
        if modern,let speed = rows.firstIndex(where:{ $0.action == "speed" }) { rows.insert(("auto","대사 자동 넘기기"),at:speed+1) }
        let options = rows.map { row -> CanvasMenu.Option in
            let action = row.action
            var option = CanvasMenu.Option(label:row.label,enabled:host.framework?.settings != nil || ["suspend","quit","load","save","auto"].contains(action))
            if let choice = settingChoices(action),choice.labels.indices.contains(choice.current) { option.value = choice.labels[choice.current] }
            if modern {
                option.icon = Self.fieldIcons[action];option.destructive = action == "quit"
                option.separatorBefore = ["scroll","quit"].contains(action)
            }
            return option
        }
        var menu = CanvasMenu(title:"",options:options,selected:selected ?? 0,cancellable:true,anchor:point) { [weak self] index in
            guard let self = self,let index = index else { return }
            let action = rows[index].action
            if self.settingChoices(action) != nil { self.changeSetting(action,by:1);self.openFieldMenu(at:point,selected:index);return }
            self.fieldMenuChosen(action)
        }
        menu.onAdjust = { [weak self] index,delta in
            guard let self = self,self.settingChoices(rows[index].action) != nil else { return }
            self.changeSetting(rows[index].action,by:delta);self.openFieldMenu(at:point,selected:index)
        }
        overlay.show(menu,keepScroll:true)
    }
    private func fieldMenuChosen(_ action:String) {
        guard host.fieldMenuReady else { return }
        switch action {
        case "suspend":quickSave(nil)
        case "scroll","speed","monitor","bgm","sound","volume","music-time":openSetting(action) { }
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
        case "scroll":
            // MAIN22832: 소 to 극대 move the world view 1, 2, 4 or 8 tiles a step.
            let steps = OriginalSettings.scrollSteps
            labels = texts.scroll ?? steps.map { "\($0)" };current = steps.firstIndex(of:value.scroll) ?? 0;apply = { value.scroll = steps[$0] }
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
    /// The engine title's settings: MAIN's three rows with their values,
    /// changed in place, and a row back to the title buttons.
    private static let titleSettingIcons = ["monitor":"display","bgm":"music.note","sound":"speaker.wave.2.fill","auto":"text.bubble.fill"]
    private func presentModernTitleSettings(selected:Int = 0) {
        titleSubmenu = true;needsDisplay = true
        let actions = Self.titleSettings+["auto","background-pause","resume-brief"]
        let labels = actions.map { action in
            action == "resume-brief" ? "이어하기 후 진행 요약" : action == "background-pause" ? "다른 앱 사용 중 일시정지" : action == "auto" ? "대사 자동 넘기기" : host.framework?.fieldMenu?.items.first(where:{ $0.action == action })?.text ?? action
        }
        var options = actions.enumerated().map { index,action -> CanvasMenu.Option in
            var option = CanvasMenu.Option(label:labels[index],icon:Self.titleSettingIcons[action])
            if let choice = settingChoices(action),choice.labels.indices.contains(choice.current) { option.value = choice.labels[choice.current] }
            return option
        }
        options.append(.init(label:"돌아가기",icon:"chevron.backward"))
        var menu = CanvasMenu(title:"",options:options,selected:selected,cancellable:true,anchor:Self.titleAnchor,style:.title) { [weak self] index in
            guard let self = self else { return }
            guard let index = index,actions.indices.contains(index) else { self.presentTitleMenu();return }
            self.changeSetting(actions[index],by:1);self.presentModernTitleSettings(selected:index)
        }
        menu.onAdjust = { [weak self] index,delta in
            guard let self = self,actions.indices.contains(index) else { return }
            self.changeSetting(actions[index],by:delta);self.presentModernTitleSettings(selected:index)
        }
        menu.cancelsOnOutsideClick = false
        overlay.show(menu,keepScroll:true)
    }
    private func presentTitleSettings(selected:Int = 0) {
        titleSubmenu = true
        let original = originalMenu("settings") != nil
        if !original { presentModernTitleSettings(selected:selected);return }
        overlay.show(titleSettingsMenu(selected:selected) { [weak self] index in
            guard let self = self else { return }
            guard let index = index else { self.presentTitleMenu();return }
            self.openSetting(Self.titleSettings[index],behind:original ? [self.titleMenu(),self.titleSettingsMenu(selected:index)] : []) { [weak self] in
                self?.presentTitleSettings(selected:index)
            }
        },behind:original ? [titleMenu()] : [])
    }
    private func saveSlots() throws -> OriginalSaveSlots {
        OriginalSaveSlots(directory:try currentSaveDirectory().appendingPathComponent("slots",isDirectory:true),practiceMode:practiceMode)
    }
    /// MSAVE's slot title is the HUD caption DS:DB4C (0x1E80B); the engine
    /// adds the place when the source has written no caption yet.
    private var slotTitle:String {
        if let caption = host.stage.caption,!caption.isEmpty { return caption }
        let state = host.vm.state
        let place = host.fieldScreenState()?.territory ?? host.battle?.definition.name ?? ""
        return "\(saveChapterLabel(state.chapter)) \(place)"
    }
    private func saveChapterLabel(_ index:Int) -> String {
        CampaignSaveLabels.chapter(index,sourceLabels:host.story.screens?.battle.commands.conditions.chapterLabels ?? [])
    }
    private func resumeDetail(_ title:String,resume:OriginalCampaignResume?) -> CanvasSheet.Detail {
        guard let saved = resume?.checkpoint else { return .init(heading:title) }
        var facts:[(label:String,value:String)] = [("장",saveChapterLabel(saved.vm.chapter))]
        if let city = saved.vm.currentCity,
           let name = host.exploration.cities.first(where:{ $0.chapter == saved.vm.chapter && $0.id == city })?.name {
            facts.append(("위치",name))
        }
        if let leader = saved.people.first(where:{ $0.id == 0 }) {
            facts.append(("주인공","\(leader.name) Lv \(leader.level)"))
        }
        if let money = saved.money { facts.append(("금","\(money)")) }
        if let leader = saved.people.first(where:{ $0.id == 0 }) {
            let companions = saved.people.filter { OriginalPeople.isCompanion(flags:$0.sourceFlags,leaderFlags:leader.sourceFlags) }.count
            facts.append(("일행","\(companions)명"))
        }
        let body = resume?.battleStart != nil ? "이 전투의 첫 턴부터 다시 시작합니다. 전투 도중의 진행은 저장되지 않습니다." : ""
        return .init(heading:title,body:body,facts:facts,portrait:personPortrait(0))
    }
    private func originalSlotDetail(_ slot:OriginalSaveCatalog.Slot) -> CanvasSheet.Detail {
        var facts:[(label:String,value:String)] = [("장",saveChapterLabel(slot.script.chapter))]
        if let name = host.exploration.cities.first(where:{ $0.chapter == slot.script.chapter && $0.id == slot.player.city })?.name {
            facts.append(("위치",name))
        }
        if let leader = slot.people.first {
            let name = (try? host.people.person(0).name) ?? "유비"
            facts.append(("주인공","\(name) Lv \(leader.level)"))
        }
        facts.append(("금","\(slot.player.money)"))
        if let leader = slot.people.first {
            let companions = slot.people.filter { OriginalPeople.isCompanion(flags:$0.flags,leaderFlags:leader.flags) }.count
            facts.append(("일행","\(companions)명"))
        }
        return .init(heading:slot.title,body:"원작에서 저장한 진행입니다. 불러온 뒤의 진행은 일반 저장 슬롯에 저장됩니다. 원작 저장은 변경하지 않습니다.",facts:facts,portrait:personPortrait(0))
    }
    /// The slot dialog CF5:B58C serves saving (0x100) and loading alike. The
    /// callback says whether a slot was written; a load replaces this view.
    private func slotStatus(_ info:OriginalSaveSlots.Inspection,dates:DateFormatter) -> String {
        switch info.status {
        case .empty:return "비어 있음"
        case .ready:return info.entry.map { dates.string(from:$0.date) } ?? "저장됨"
        case .metadataDamaged:return "제목 정보 손상 · 진행 확인"
        case .dataDamaged:return "진행 읽기 실패 · 파일 보존됨"
        case .unsupported:return "지원하지 않는 저장 버전"
        }
    }
    private func inspectedDetail(_ info:OriginalSaveSlots.Inspection,resume:OriginalCampaignResume?) -> CanvasSheet.Detail {
        var detail = resumeDetail(info.entry?.title ?? "저장 상태",resume:resume)
        if !info.message.isEmpty { detail.body += (detail.body.isEmpty ? "" : "\n\n") + info.message }
        if info.canRestoreBackup { detail.body += "\n마지막 정상본을 ‘일반 저장 관리’에서 복구할 수 있습니다." }
        return detail
    }
    private func presentSlots(saving:Bool,_ done:@escaping (Bool) -> Void) {
        let slots:OriginalSaveSlots,inspections:[OriginalSaveSlots.Inspection]
        do { slots = try saveSlots();inspections = try slots.inspections() }
        catch {
            suspendAlert("저장 폴더를 열 수 없습니다",text:"저장 위치와 권한을 확인해 주세요. 현재 진행은 유지됩니다.\n\(error.localizedDescription)") { done(false) };return
        }
        if !host.hasStarted { titleSubmenu = true }
        let dates = DateFormatter();dates.dateStyle = .short;dates.timeStyle = .short
        enum Target { case slot(Int),named(OriginalSaveSlots.Named),suspend(SuspendSaveStore.Entry),original(OriginalSaveCatalog.Slot),file,folder,manage,none }
        var rows = inspections.enumerated().map { index,info in
            CanvasSheet.Row(label:"일반 슬롯 \(index+1)",value:slotStatus(info,dates:dates),
                detail:inspectedDetail(info,resume:info.canLoad ? try? slots.read(slot:index) : nil),enabled:saving || info.status != .empty)
        }
        var targets:[Target] = inspections.indices.map { .slot($0) }
        if !saving {
            do {
                if let entry = try suspendStore().entry() {
                    rows.insert(.init(label:"중단 저장",value:dates.string(from:entry.date),
                        detail:.init(heading:entry.title,body:"중단한 지점부터 이어합니다. 성공하면 소모됩니다. 일반 저장과 백업에는 영향을 주지 않습니다.")),at:0)
                    targets.insert(.suspend(entry),at:0)
                }
            } catch {
                rows.insert(.init(label:"중단 저장",value:"읽을 수 없음 · 파일 보존됨",enabled:false),at:0);targets.insert(.none,at:0)
            }
            for name in OriginalSaveSlots.Named.allCases {
                guard let info = try? slots.inspect(.named(name)),info.status != .empty else { continue }
                let label:String
                switch name { case .auto:label = "자동 저장";case .quick:label = "이전 빠른 저장";case .battleStart:label = "전투 시작" }
                rows.append(.init(label:label,value:slotStatus(info,dates:dates),detail:inspectedDetail(info,resume:info.canLoad ? try? slots.read(name) : nil)))
                targets.append(.named(name))
            }
        }
        let originals = saving || practiceMode ? nil : try? OriginalSaveCatalog.load(root:host.data.root)
        for slot in originals?.slots ?? [] {
            let date = slot.date
            rows.append(.init(label:"원작 슬롯 \(slot.slot+1)",value:String(format:"%02d/%02d/%02d %02d:%02d",date.year,date.month,date.day,date.hour,date.minute),detail:originalSlotDetail(slot)))
            targets.append(.original(slot))
        }
        for refused in originals?.refused ?? [] {
            rows.append(.init(label:"원작 슬롯 \(refused.slot+1)",value:"읽을 수 없음",enabled:false));targets.append(.none)
        }
        if !saving && !practiceMode { rows.append(.init(label:"파일에서 불러오기"));targets.append(.file) }
        rows.append(.init(label:"저장 폴더 열기"));targets.append(.folder)
        rows.append(.init(label:"일반 저장 관리",detail:.init(heading:"백업과 복구",body:"일반 슬롯의 정상본을 백업하거나 복구합니다. 중단 저장과 원작 저장은 대상에서 제외합니다.")));targets.append(.manage)
        let title = (practiceMode ? "연습 · " : "")+(saving ? "게임 저장" : "게임 불러오기")
        let guidance = saving ? "일반 저장 · 마을과 세계지도에서 저장합니다." : "일반·중단·자동·원작 저장을 선택해 이어합니다."
        overlay.show(fieldSheet(title:title,line:guidance,rows:rows,selected:rows.firstIndex(where:\.enabled) ?? 0) { [weak self] index in
            guard let self = self else { return }
            guard let index = index,targets.indices.contains(index) else { done(false);return }
            let back:() -> Void = { [weak self] in self?.presentSlots(saving:saving,done) }
            switch targets[index] {
            case .folder:
                do {
                    guard NSWorkspace.shared.open(try self.currentSaveDirectory()) else { throw EngineError.invalid("Finder에서 저장 폴더를 열지 못했습니다.") }
                    back()
                } catch { self.suspendAlert("폴더 열기 실패",text:error.localizedDescription,afterDismiss:back) }
                return
            case .manage:self.presentSaveManagement(slots,back:back);return
            default:break
            }
            do {
                if saving {
                    guard case .slot(let slot) = targets[index] else { done(false);return }
                    let info = try slots.inspect(.numbered(slot))
                    if info.status == .unsupported {
                        self.suspendAlert("이 저장은 덮어쓸 수 없습니다",text:info.message,afterDismiss:back);return
                    }
                    let write = { [weak self] in
                        guard let self = self else { return }
                        do { try slots.write(self.scopedSnapshot(try self.host.resumeSnapshot()),title:self.slotTitle,slot:slot);done(true) }
                        catch { self.suspendAlert("저장 실패",text:"현재 진행과 기존 정상본은 유지됩니다.\n\(error.localizedDescription)",afterDismiss:back) }
                    }
                    if info.status == .empty { write() }
                    else { self.saveDialog("이 슬롯에 저장할까요?",text:"기존 진행을 새 진행으로 교체합니다. 읽을 수 있는 기존 정상본은 백업으로 보존합니다.",buttons:["저장","취소"]) { answer in if answer == 0 { write() } else { back() } } }
                } else {
                    let data = self.host.data,rng = self.host.rng
                    switch targets[index] {
                    case .suspend(let entry):
                        self.suspendConfirmation("중단한 게임을 이어할까요?",text:"\(entry.title)\n\n성공하면 중단 저장은 소모됩니다. 현재 플레이 중이라면 그 진행을 대신합니다.",button:"이어하기") { [weak self] accepted in
                            guard let self = self else { return }
                            if accepted {
                                do { try self.resumeSuspended(self.suspendStore(),entry:entry) }
                                catch { self.presentSuspendLoadError(error,afterDismiss:back) }
                            } else { back() }
                        }
                    case .slot(let slot):
                        let info = try slots.inspect(.numbered(slot))
                        guard info.canLoad else { self.suspendAlert("불러올 수 없는 저장",text:info.message,afterDismiss:back);return }
                        self.loadThroughFade(done) { try self.resumedView(slots.read(slot:slot)) }
                    case .named(let name):
                        let info = try slots.inspect(.named(name))
                        guard info.canLoad else { self.suspendAlert("불러올 수 없는 저장",text:info.message,afterDismiss:back);return }
                        self.loadThroughFade(done) { try self.resumedView(slots.read(name)) }
                    case .original(let slot):self.loadThroughFade(done) { try OriginalCampaignView(host:try OriginalCampaignHost.importOriginal(data:data,slot:slot,rng:rng),saveRootOverride:self.saveRootOverride) }
                    case .file:
                        if let resumed = try Self.chooseResume(data:self.host.data) { self.replace(with:try OriginalCampaignView(host:resumed,saveRootOverride:self.saveRootOverride)) } else { back() }
                    case .none,.folder,.manage:done(false)
                    }
                }
            } catch { self.suspendAlert("불러오기 실패",text:"현재 진행은 유지됩니다.\n\(error.localizedDescription)",afterDismiss:back) }
        })
    }
    private func presentSaveManagement(_ slots:OriginalSaveSlots,back:@escaping () -> Void) {
        do {
            let infos = try slots.inspections()
            let rows = infos.enumerated().map { index,info in
                CanvasSheet.Row(label:"일반 슬롯 \(index+1)",value:info.entry?.title ?? "저장 정보 없음",
                    detail:inspectedDetail(info,resume:nil),enabled:info.canLoad || info.canRestoreBackup || info.canRestoreLegacy)
            }
            overlay.show(fieldSheet(title:"일반 저장 관리",line:"중단 저장은 백업·복구 대상이 아닙니다.",rows:rows) { [weak self] index in
                guard let self = self else { return }
                guard let index = index,infos.indices.contains(index) else { back();return }
                self.presentSlotManagement(slots,key:.numbered(index),title:"일반 슬롯 \(index+1)") { [weak self] in self?.presentSaveManagement(slots,back:back) }
            })
        } catch { suspendAlert("저장 관리 오류",text:error.localizedDescription,afterDismiss:back) }
    }
    private func presentSlotManagement(_ slots:OriginalSaveSlots,key:OriginalSaveSlots.SlotKey,title:String,back:@escaping () -> Void) {
        do {
            let info = try slots.inspect(key)
            let rows:[CanvasMenu.Option] = [.init(label:"현재 정상본 백업",enabled:info.canLoad),.init(label:"백업 파일 내보내기",enabled:info.canLoad),.init(label:"마지막 정상본 복구",enabled:info.canRestoreBackup),.init(label:"이전 형식 저장 복구",enabled:info.canRestoreLegacy),.init(label:"돌아가기")]
            overlay.show(CanvasMenu(title:title,options:rows,cancellable:true,footer:info.backupEntry.map { "복구할 정상본: \($0.title)" } ?? "보관된 정상본이 없습니다.") { [weak self] action in
                guard let self = self else { return }
                guard let action = action,action < 4 else { back();return }
                let report = { [weak self] (title:String,message:String) in self?.suspendAlert(title,text:message,afterDismiss:back) }
                do {
                    switch action {
                    case 0:
                        _ = try slots.backup(key);report("백업 완료","현재 정상 저장을 별도 보관했습니다.")
                    case 1:
                        let panel = NSSavePanel();panel.allowedContentTypes = [.json];panel.nameFieldStringValue = "영걸전-일반저장-백업.json"
                        guard panel.runModal() == .OK,let url = panel.url else { back();return }
                        _ = try slots.exportBackup(key,to:url);report("내보내기 완료","저장 목록의 ‘파일에서 불러오기’로 읽을 수 있습니다.")
                    case 2:
                        self.saveDialog("마지막 정상본으로 복구할까요?",text:"현재 슬롯 파일을 보존한 뒤 백업된 진행으로 복구합니다.",buttons:["복구","취소"]) { [weak self] answer in
                            guard let self = self else { return }
                            guard answer == 0 else { back();return }
                            do { _ = try slots.restoreBackup(key);report("복구 완료","현재 슬롯 파일은 보존했고 마지막 정상본을 복구했습니다.") }
                            catch { self.suspendAlert("복구 실패",text:error.localizedDescription,afterDismiss:back) }
                        }
                    default:
                        self.saveDialog("이전 형식의 저장을 복구할까요?",text:"현재 슬롯 파일은 보존하고 이전 버전에서 남긴 진행을 새 형식으로 복구합니다. 진행 시점이 더 오래되었을 수 있습니다.",buttons:["복구","취소"]) { [weak self] answer in
                            guard let self = self else { return }
                            guard answer == 0 else { back();return }
                            do { _ = try slots.restoreLegacy(key);report("복구 완료","이전 형식의 저장을 복구했습니다. 원본 저장 파일은 보존했습니다.") }
                            catch { self.suspendAlert("복구 실패",text:error.localizedDescription,afterDismiss:back) }
                        }
                    }
                } catch { self.suspendAlert("저장 관리 실패",text:error.localizedDescription,afterDismiss:back) }
            })
        } catch { suspendAlert("저장 관리 오류",text:error.localizedDescription,afterDismiss:back) }
    }
    /// A load reaches the map through C456 as well: black, then the new screen fades in.
    private func loadThroughFade(_ done:@escaping (Bool) -> Void,_ make:@escaping () throws -> OriginalCampaignView) {
        fadeThrough { [weak self] in
            guard let self = self else { return }
            do { let next = try make();self.replace(with:next);next.pendingResumeBrief = true;next.fadeIn() }
            catch { self.recordInputError(error,message:"불러오지 못했습니다.");done(false) }
        }
    }
    private func replace(with next:OriginalCampaignView) {
        guard let window = window else { return }
        next.onPracticeReturn = onPracticeReturn;onPracticeReturn = nil
        next.onPracticeList = onPracticeList;onPracticeList = nil
        DialoguePace.shared.skipping = false
        stop();window.contentView = next
        if next.overlay.active { window.makeFirstResponder(next.overlay) }
        else if let board = next.battleView,!board.isHidden { board.restoreKeyboardFocus() }
        else { window.makeFirstResponder(next) }
    }
    /// Modern field buttons from the right edge, in DS:3636 order.
    var fieldButtons:[(index:Int,label:String,rect:CGRect)] {
        guard let texts = fieldTexts else { return [] }
        var right:CGFloat = 628
        var result:[(index:Int,label:String,rect:CGRect)] = []
        for (index,label) in [(3,"메뉴"),(0,texts.storyInfo),(2,texts.wholeMap),(1,texts.people)] {
            let width = ceil((label as NSString).size(withAttributes:CanvasTheme.attributes(CanvasTheme.font(12,.semibold),CanvasTheme.text)).width)+26
            result.append((index,label,CGRect(x:right-width,y:12,width:width,height:28)))
            right -= width+6
        }
        return result
    }
    /// Modern field: who leads, where they are, and what they carry, over the map.
    /// The card carries the source caption (the chapter title, DS:DB4C) above
    /// the territory, so a long title never runs under the field buttons.
    private func drawFieldHUD(_ screen:OriginalFieldScreenState,in context:CGContext) {
        let caption = host.stage.caption ?? "",captionStyle = CanvasTheme.attributes(CanvasTheme.font(10.5,.semibold),CanvasTheme.accent)
        let captionWidth = caption.isEmpty ? 0 : ceil((caption as NSString).size(withAttributes:captionStyle).width)
        let top:CGFloat = caption.isEmpty ? 0 : 18
        let card = CGRect(x:12,y:12,width:min(312,max(196,captionWidth+74)),height:62+top)
        CanvasTheme.panel(card,in:context)
        if let picture = image(screen.portraitImage) {
            let box = CGRect(x:card.minX+8,y:card.midY-24,width:38,height:48)
            CanvasTheme.fill(box.insetBy(dx:-1,dy:-1),CGColor(red:0.04,green:0.05,blue:0.07,alpha:0.9),radius:6,in:context)
            context.saveGState();CanvasTheme.rounded(box,5,in:context);context.clip()
            Renderer.image(picture,in:box,context:context);context.restoreGState()
            CanvasTheme.stroke(box.insetBy(dx:-0.5,dy:-0.5),CanvasTheme.accentBorder,radius:5.5,in:context)
        }
        let textX = card.minX+54
        if !caption.isEmpty {
            let badgeW = min(card.width-62,captionWidth+12)
            let badge = CGRect(x:textX,y:card.minY+7,width:badgeW,height:15)
            CanvasTheme.fill(badge,CGColor(red:0.93,green:0.74,blue:0.32,alpha:0.14),radius:4,in:context)
            let paragraph = NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
            var style = captionStyle;style[.paragraphStyle] = paragraph
            (caption as NSString).draw(in:CGRect(x:textX+6,y:card.minY+8,width:badgeW-12,height:14),withAttributes:style)
        }
        ((screen.territory ?? "") as NSString).draw(in:CGRect(x:textX,y:card.minY+7+top,width:card.width-62,height:20),
            withAttributes:CanvasTheme.attributes(CanvasTheme.font(14.5,.bold),CanvasTheme.text))
        let statsY = card.minY+31+top
        let lvBadge = CGRect(x:textX,y:statsY,width:48,height:18)
        CanvasTheme.card(lvBadge,radius:4,in:context)
        ("Lv.\(screen.level ?? 0)" as NSString).draw(in:CGRect(x:lvBadge.minX,y:lvBadge.minY+2,width:lvBadge.width,height:14),
            withAttributes:CanvasTheme.attributes(CanvasTheme.number(11),CanvasTheme.accent,alignment:.center))
        let goldBadge = CGRect(x:lvBadge.maxX+5,y:statsY,width:max(78,card.maxX-lvBadge.maxX-13),height:18)
        CanvasTheme.card(goldBadge,radius:4,in:context)
        ("금 \(screen.money ?? 0)" as NSString).draw(in:CGRect(x:goldBadge.minX+7,y:goldBadge.minY+2,width:goldBadge.width-14,height:14),
            withAttributes:CanvasTheme.attributes(CanvasTheme.number(11),CanvasTheme.text))
        if host.fieldMenuReady {
            for button in fieldButtons {
                let hovered = hoveredFieldButton == button.index
                CanvasTheme.pill(button.rect,active:hovered,in:context)
                CanvasTheme.drawSingleLine(button.label,in:button.rect.insetBy(dx:8,dy:0),font:CanvasTheme.font(12,.semibold),
                    color:hovered ? CanvasTheme.onAccent : CanvasTheme.text,alignment:.center,context:context)
            }
        }
    }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.black.setFill();bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let screen = host.fieldScreenState(),modern = CanvasPresentation.current == .modern && screen != nil
        // Whole device pixels per source pixel: the engine field's map is 1.25 canvas units.
        let unit:CGFloat = screenPlayer == nil && modern && host.ending == nil ? 1.25 : 1
        if unit != CanvasGeometry.sourcePixel { CanvasGeometry.sourcePixel = unit;DispatchQueue.main.async { [weak self] in self?.redrawAll() } }
        let shape = CanvasGeometry(bounds:bounds)
        if let player = screenPlayer,let image = player.image() { Renderer.image(image,in:shape.rect,context:context);return }
        // MAIN draws no picture behind its title menu (A7E8 clears to colour 0);
        // the engine layout keeps the opening's title picture there.
        let blankTitle = !host.hasStarted && host.ending == nil && CanvasPresentation.current == .original
        let remakeTitle = !host.hasStarted && host.ending == nil && CanvasPresentation.current == .modern
        if remakeTitle { drawRemakeTitle(in:context,shape:shape) }
        if !blankTitle,!remakeTitle {
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
        if screen != nil { drawWorldGuides(in:context);drawTownHover(in:context);drawWalkMarker(in:context) }
        // A sheet carries its own money and covers this corner.
        if modern,overlay.sheet == nil,let screen = screen { drawFieldHUD(screen,in:context) }
        if screen != nil { drawHoverTag(in:context) }
        // Only a state the player can act on or must know reaches the window.
        if let text = errorText ?? suspendStatus ?? inputNotice ?? battleSaveNotice ?? autosaveNotice ?? host.notice ?? host.playerStatus {
            CanvasTheme.chip(text,at:CGPoint(x:320,y:376),maximumWidth:600,color:errorText == nil ? CanvasTheme.text : CanvasTheme.danger,in:context)
        }
        if DialoguePace.shared.skipping,host.hasStarted {
            CanvasTheme.chip("건너뛰는 중 · S 멈춤",at:CGPoint(x:560,y:24),maximumWidth:160,color:CanvasTheme.accent,in:context)
        } else if fastForward,host.hasStarted {
            CanvasTheme.chip("빨리 감기 ×\(OriginalBattleView.fastRate)",at:CGPoint(x:580,y:24),maximumWidth:120,in:context)
        }
        context.restoreGState()
    }
    // MARK: Engine title screen
    private var remakeBackdrop:CGImage?
    /// A title sub-list (settings) is open, where Esc goes back instead of quitting.
    private var titleSubmenu = false
    private static func blurred(_ image:CGImage,radius:Double) -> CGImage? {
        let input = CIImage(cgImage:image).clampedToExtent()
        guard let filter = CIFilter(name:"CIGaussianBlur") else { return nil }
        filter.setValue(input,forKey:kCIInputImageKey);filter.setValue(radius,forKey:kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to:CGRect(x:0,y:0,width:image.width,height:image.height)) else { return nil }
        return CIContext().createCGImage(output,from:output.extent)
    }
    private func fillGradient(_ rect:CGRect,_ colors:[CGColor],vertical:Bool = true,in context:CGContext) {
        guard let gradient = CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors as CFArray,locations:nil) else { return }
        context.saveGState();context.clip(to:rect)
        context.drawLinearGradient(gradient,start:CGPoint(x:rect.minX,y:rect.minY),end:vertical ? CGPoint(x:rect.minX,y:rect.maxY) : CGPoint(x:rect.maxX,y:rect.minY),options:[])
        context.restoreGState()
    }
    /// Engine presentation of MAIN's title: its picture blurred across the
    /// window, its logo at full size on top, a crisp band of the blossoms,
    /// and the title buttons (the overlay) under it. Original frames keep
    /// MAIN's black screen and window.
    private func drawRemakeTitle(in context:CGContext,shape:CanvasGeometry) {
        guard let title = image(host.data.resources.title) else { return }
        if remakeBackdrop == nil { remakeBackdrop = Self.blurred(title,radius:12) }
        if let backdrop = remakeBackdrop {
            let cover = max(bounds.width/640,bounds.height/400)*1.06
            let size = CGSize(width:640*cover,height:400*cover)
            context.saveGState();context.interpolationQuality = .high
            context.translateBy(x:bounds.midX-size.width/2,y:bounds.midY+size.height/2);context.scaleBy(x:1,y:-1)
            context.draw(backdrop,in:CGRect(origin:.zero,size:size))
            context.restoreGState()
        }
        context.setFillColor(CGColor(red:0.03,green:0.04,blue:0.07,alpha:0.64));context.fill(bounds)
        context.saveGState()
        context.translateBy(x:shape.origin.x,y:shape.origin.y);context.scaleBy(x:shape.scale,y:shape.scale)
        fillGradient(CGRect(x:-400,y:220,width:1440,height:400),[CGColor(red:0.02,green:0.03,blue:0.06,alpha:0),CGColor(red:0.02,green:0.03,blue:0.08,alpha:0.75)],in:context)
        // The blossoms above MAIN's logo, as a wide band with soft edges.
        // MAIN's picture leaves rows 0..39 black; the band starts under them.
        let band = CGRect(x:0,y:140,width:640,height:80)
        if let strip = title.cropping(to:CGRect(x:0,y:44,width:640,height:80)) { Renderer.image(strip,in:band,context:context) }
        let shade = CGColor(red:0.03,green:0.04,blue:0.07,alpha:0.55),clear = CGColor(red:0.03,green:0.04,blue:0.07,alpha:0)
        fillGradient(CGRect(x:0,y:band.minY,width:640,height:14),[shade,clear],in:context)
        fillGradient(CGRect(x:0,y:band.maxY-14,width:640,height:14),[clear,shade],in:context)
        let edge = CGColor(red:0.03,green:0.04,blue:0.07,alpha:0.85)
        fillGradient(CGRect(x:0,y:band.minY,width:28,height:band.height),[edge,clear],vertical:false,in:context)
        fillGradient(CGRect(x:612,y:band.minY,width:28,height:band.height),[clear,edge],vertical:false,in:context)
        let gold = CGColor(red:0.91,green:0.75,blue:0.40,alpha:0.7),goldClear = CGColor(red:0.91,green:0.75,blue:0.40,alpha:0)
        for y in [band.minY,band.maxY-1] { fillGradient(CGRect(x:0,y:y,width:640,height:1),[goldClear,gold,gold,goldClear],vertical:false,in:context) }
        // MAIN's logo box at its own size.
        // The box runs over columns 73..564 and rows 143..253 of the picture.
        if let logo = title.cropping(to:CGRect(x:73,y:143,width:492,height:111)) {
            context.saveGState()
            context.setShadow(offset:CGSize(width:0,height:4),blur:14,color:CGColor(gray:0,alpha:0.7))
            Renderer.image(logo,in:CGRect(x:74,y:6,width:492,height:111),context:context)
            context.restoreGState()
        }
        // The romanised title, letter-spaced, and the engine's tag.
        let subtitle = NSAttributedString(string:"SANGOKUSHI  EIKETSUDEN",attributes:[.font:NSFont(name:"Times New Roman Bold",size:10) ?? CanvasTheme.font(10,.bold),
            .foregroundColor:NSColor(red:0.93,green:0.86,blue:0.70,alpha:0.95),.kern:4.2])
        let tag = NSAttributedString(string:"REMAKE",attributes:[.font:CanvasTheme.font(7.5,.heavy),.foregroundColor:CanvasTheme.onAccent,.kern:2.2])
        let subtitleWidth = ceil(subtitle.size().width),tagWidth = ceil(tag.size().width)+14,gap:CGFloat = 10
        let left = 320-(subtitleWidth+gap+tagWidth)/2
        subtitle.draw(at:CGPoint(x:left,y:122))
        let pill = CGRect(x:left+subtitleWidth+gap,y:122,width:tagWidth,height:13)
        CanvasTheme.fill(pill,CanvasTheme.accentFill,radius:6.5,in:context)
        tag.draw(at:CGPoint(x:pill.minX+7,y:pill.minY+2))
        // Key hints and the original's credit along the foot.
        var x:CGFloat = 12
        for (key,meaning) in [("↑↓","선택"),("Return","결정"),("Esc",titleSubmenu ? "뒤로" : "종료")] {
            let keyText = NSAttributedString(string:key,attributes:[.font:CanvasTheme.font(8.5,.semibold),.foregroundColor:CanvasTheme.text])
            let cap = CGRect(x:x,y:384,width:ceil(keyText.size().width)+10,height:12)
            CanvasTheme.stroke(cap,CGColor(gray:1,alpha:0.35),radius:3,in:context)
            keyText.draw(at:CGPoint(x:cap.minX+5,y:cap.minY+0.5))
            let label = NSAttributedString(string:meaning,attributes:[.font:CanvasTheme.font(8.5),.foregroundColor:CanvasTheme.muted])
            label.draw(at:CGPoint(x:cap.maxX+4,y:cap.minY+0.5));x = cap.maxX+4+ceil(label.size().width)+12
        }
        ("원작 © 1995 KOEI · 영걸전 엔진" as NSString).draw(in:CGRect(x:300,y:384,width:328,height:12),
            withAttributes:CanvasTheme.attributes(CanvasTheme.font(8.5),CanvasTheme.muted,alignment:.right))
        context.restoreGState()
    }
    override func keyDown(with event:NSEvent) {
        guard !pauseCoordinator.paused else { return }
        if overlay.active {overlay.keyDown(with:event);return}
        guard let event = settings.controls.remappedEvent(event,context:.field) else {return}
        if screenPlayer != nil { screenInput(escape:event.keyCode == 53);return }
        if fading { return }
        if event.keyCode == 53 {
            guard !event.isARepeat else { return }
            switch CampaignEscapeRoute.resolve(overlayActive:overlay.active,completedQuit:host.frameworkReturn?.outcome == .quit,
                                               started:host.hasStarted,fieldReady:host.fieldMenuReady) {
            case .overlay:overlay.keyDown(with:event)
            case .fieldMenu:openFieldMenu(at:CGPoint(x:320,y:52))
            case .titleMenu:presentTitleMenu()
            case .closeCompleted:window?.performClose(nil)
            case .ignore:break
            }
            return
        }
        if host.frameworkReturn?.outcome == .quit { window?.performClose(nil);return }
        let arrows:[UInt16:(Int,Int)] = [123:(-1,0),124:(1,0),125:(0,1),126:(0,-1)]
        if let step = arrows[event.keyCode],host.vm.state.packedMap>>12 == 1,host.explorationInputReady,!overlay.active { scrollWorld(step.0,step.1);return }
        if [36,49,76].contains(event.keyCode),!event.isARepeat {
            inputNotice = nil
            if !host.hasStarted { presentTitleMenu();needsDisplay = true;return }
            do { try host.acknowledge() } catch { recordInputError(error) };needsDisplay = true
        }
    }
    /// A refused input (a blocked cell, a gated moment) stays off the screen:
    /// it goes to the console for development, and `message` reaches the
    /// player only where they need to know, such as a save that failed. A
    /// stopped campaign still shows its reason.
    private func recordInputError(_ error:Error,message:String? = nil) {
        if host.failure != nil { errorText = "\(error)";return }
        FileHandle.standardError.write(Data("입력 거부: \(error)\n".utf8))
        inputNotice = message
    }
    /// OPEN leaves on a mouse button. END has one button loop at the very end.
    private func screenInput(escape:Bool) {
        guard let player = screenPlayer else { return }
        if screenIsOpening || escape { leaveScreen() } else { player.acceptInput() }
    }
    /// A settlement actor's sprite box in source map pixels.
    private func actorRect(_ actor:ActorState) -> CGRect {
        let v = host.stage.viewport,camera = host.stage.camera
        return CGRect(x:v[0]+16*actor.position.x-camera[0],y:v[1]+16*actor.position.y+8*(actor.position.x&1)-24-camera[1],width:32,height:40)
    }
    /// The topmost actor other than the player under a point in source map pixels.
    private func talkTarget(at point:CGPoint) -> ActorState? {
        host.stage.actors.values.sorted{$0.registration > $1.registration}.first { $0.person != 0 && actorRect($0).contains(point) }
    }
    /// The person under the pointer on an idle town or palace map. Engine addition:
    /// the window names who a click would talk to.
    private var hoveredPerson:Int? { didSet { if hoveredPerson != oldValue { needsDisplay = true } } }
    private var hoveredFieldButton:Int? { didSet { if hoveredFieldButton != oldValue { needsDisplay = true } } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self))
    }
    /// The world map scrolls while the pointer rests at the map window's edge
    /// (MAIN's eight scroll directions, seg0:4F8E); arrows scroll a step too.
    private var edgeScroll:(dx:Int,dy:Int)?
    private var edgeTicks = 0
    private func edgeDirection(_ p:CGPoint) -> (dx:Int,dy:Int)? {
        // The modern map fills the canvas, so the letterbox beyond it counts as
        // edge; in original frames only the map window does, not the side panel.
        let area = modernField ? CGRect(x:0,y:0,width:640,height:400) : CanvasFieldMap.viewport,margin:CGFloat = 12
        guard modernField || area.contains(p) else { return nil }
        let dx = p.x < area.minX+margin ? -1 : p.x > area.maxX-margin ? 1 : 0
        let dy = p.y < area.minY+margin ? -1 : p.y > area.maxY-margin ? 1 : 0
        return dx == 0 && dy == 0 ? nil : (dx,dy)
    }
    private func scrollWorld(_ dx:Int,_ dy:Int) {
        if host.scrollWorld(dx:dx,dy:dy,step:settings.scroll) { needsDisplay = true }
    }
    override func mouseMoved(with event:NSEvent) {
        let canvasP = CanvasGeometry(bounds:bounds).canvas(convert(event.locationInWindow,from:nil))
        let world = host.explorationInputReady && host.vm.state.packedMap>>12 == 1 && !overlay.active && !fading
        edgeScroll = world ? edgeDirection(canvasP) : nil
        hoveredFieldButton = modernField && host.fieldMenuReady && !overlay.active && !fading
            ? fieldButtons.first(where:{ $0.rect.contains(canvasP) })?.index : nil
        // A city or a person the pointer can act on shows the pointing hand.
        defer {
            let door = hoveredTownCell.flatMap(townMarker) != nil
            (hoveredCity != nil || hoveredPerson != nil || hoveredFieldButton != nil || door ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        var cityHit:Int?
        if world,hoveredFieldButton == nil {
            var p = canvasP
            if modernField { p = CanvasFieldMap.mapPoint(canvas:p) }
            cityHit = selectableCities.first { cityRect($0)?.contains(p) == true }?.id
        }
        if cityHit != hoveredCity { hoveredCity = cityHit;needsDisplay = true }
        guard host.explorationInputReady,[0,2].contains(host.vm.state.packedMap>>12),!overlay.active,!fading,hoveredFieldButton == nil else {
            hoveredPerson = nil;if hoveredTownCell != nil { hoveredTownCell = nil;needsDisplay = true };return
        }
        var p = canvasP
        if modernField { p = CanvasFieldMap.mapPoint(canvas:p) }
        hoveredPerson = talkTarget(at:p).map(\.person)
        let target = hoveredPerson == nil ? townTarget(atMap:p) : nil
        if target != hoveredTownCell { hoveredTownCell = target;needsDisplay = true }
    }
    /// The settlement cell under the pointer, or the door or path it means
    /// (OriginalTownPointer), for a point in map pixels on screen.
    private var hoveredTownCell:GridPoint?
    private func townTarget(atMap point:CGPoint) -> GridPoint? {
        guard let map = host.stage.currentMap,let width = map.walkWidth,let height = map.walkHeight,let walk = map.walkBytes else { return nil }
        let v = host.stage.viewport,camera = host.stage.camera
        return OriginalTownPointer.target(at:CGPoint(x:point.x-CGFloat(v[0])+CGFloat(camera[0]),y:point.y-CGFloat(v[1])+CGFloat(camera[1])),
                                          walk:walk,width:width,height:height)
    }
    private func townMarker(_ cell:GridPoint) -> Int? {
        guard let map = host.stage.currentMap,let width = map.walkWidth,let walk = map.walkBytes,walk.indices.contains(cell.y*width+cell.x) else { return nil }
        let marker = walk[cell.y*width+cell.x]
        return marker == 127 || marker&0x80 != 0 ? nil : marker
    }
    /// A diamond on the cell the pointer would walk to; a door also says where it leads.
    private func drawTownHover(in context:CGContext) {
        guard let cell = hoveredTownCell,hoveredPerson == nil,host.explorationInputReady,!overlay.active,!fading,
              [0,2].contains(host.vm.state.packedMap>>12) else { return }
        let v = host.stage.viewport,camera = host.stage.camera,c = OriginalTownPointer.center(cell)
        let mid = canvasPoint(map:CGPoint(x:CGFloat(v[0])+c.x-CGFloat(camera[0]),y:CGFloat(v[1])+c.y-CGFloat(camera[1])))
        let scale = (canvasPoint(map:CGPoint(x:16,y:0)).x-canvasPoint(map:.zero).x)/16
        let half = CGSize(width:16*scale,height:8*scale)
        let marker = townMarker(cell)
        context.saveGState()
        context.move(to:CGPoint(x:mid.x,y:mid.y-half.height));context.addLine(to:CGPoint(x:mid.x+half.width,y:mid.y))
        context.addLine(to:CGPoint(x:mid.x,y:mid.y+half.height));context.addLine(to:CGPoint(x:mid.x-half.width,y:mid.y));context.closePath()
        context.setFillColor(marker == nil ? CGColor(gray:1,alpha:0.16) : CanvasTheme.accentFill.copy(alpha:0.28) ?? CanvasTheme.accentFill)
        context.setStrokeColor(marker == nil ? CGColor(gray:1,alpha:0.7) : CanvasTheme.accentFill);context.setLineWidth(1.5)
        context.drawPath(using:.fillStroke)
        context.restoreGState()
        if let marker = marker {
            let label = marker == 124 ? "마을 밖으로" : marker == 125 ? "나가기" : "들어가기"
            CanvasTheme.chip(label,at:CGPoint(x:mid.x,y:max(14,mid.y-half.height-14)),maximumWidth:120,color:CanvasTheme.accent,in:context)
        }
    }
    override func mouseExited(with event:NSEvent) { hoveredPerson = nil;hoveredCity = nil;hoveredFieldButton = nil;hoveredTownCell = nil;edgeScroll = nil }
    // Engine guides over the field: the cities the player can pick now, the
    // march to the one under the pointer, and where a town click is walking.
    private var hoveredCity:Int?
    private var walkMarker:(point:GridPoint,start:Date)?
    /// Cities the native flags let the player pick (flags&3 == 3, as a world city input requires).
    private var selectableCities:[OriginalCity] {
        let state = host.vm.state
        guard state.packedMap>>12 == 1,let flags = state.cityFlags,state.cityFlagsChapter == state.chapter else { return [] }
        return host.exploration.destinations(chapter:state.chapter,flags:flags)
    }
    /// A city's 32-pixel icon cell in map pixels, as the click test uses it.
    private func cityRect(_ city:OriginalCity) -> CGRect? {
        guard let cx = city.worldX,let cy = city.worldY else { return nil }
        let v = host.stage.viewport,camera = host.stage.camera
        return CGRect(x:v[0]+cx*32-camera[0],y:v[1]+cy*32-camera[1],width:32,height:32)
    }
    private func canvasPoint(map point:CGPoint) -> CGPoint { modernField ? CanvasFieldMap.canvasPoint(map:point) : point }
    private func canvasRect(map rect:CGRect) -> CGRect {
        let a = canvasPoint(map:rect.origin),b = canvasPoint(map:CGPoint(x:rect.maxX,y:rect.maxY))
        return CGRect(x:a.x,y:a.y,width:b.x-a.x,height:b.y-a.y)
    }
    private func drawWorldGuides(in context:CGContext) {
        guard host.vm.state.packedMap>>12 == 1,host.explorationInputReady,host.stage.visible,!host.stage.leaving else { return }
        let cities = selectableCities
        guard !cities.isEmpty else { return }
        context.saveGState()
        context.clip(to:modernField ? CGRect(x:0,y:0,width:640,height:400) : CanvasFieldMap.viewport)
        let v = host.stage.viewport,camera = host.stage.camera
        func cell(_ point:GridPoint) -> CGPoint {
            canvasPoint(map:CGPoint(x:v[0]+16*point.x+16-camera[0],y:v[1]+16*point.y+16-camera[1]))
        }
        // The march the source would plan to the hovered city (MAIN25D9E route).
        if let id = hoveredCity,
           let plan = try? OriginalExplorationInput.worldCity(catalog:host.exploration,state:host.vm.state,stage:host.stage,cityID:id,enabled:true) {
            var points = plan.route.map { cell($0.position) }
            if let player = host.stage.actors[plan.playerPerson] { points.insert(cell(player.position),at:0) }
            if points.count > 1 {
                context.setLineCap(.round);context.setLineJoin(.round)
                context.setStrokeColor(CGColor(gray:0,alpha:0.45));context.setLineWidth(5)
                context.addLines(between:points);context.strokePath()
                context.setStrokeColor(CGColor(gray:1,alpha:0.92));context.setLineWidth(2.5);context.setLineDash(phase:0,lengths:[1,6])
                context.addLines(between:points);context.strokePath();context.setLineDash(phase:0,lengths:[])
            }
        }
        for city in cities {
            guard let icon = cityRect(city).map(canvasRect) else { continue }
            let hovered = city.id == hoveredCity
            if hovered { CanvasTheme.stroke(icon.insetBy(dx:-2,dy:-2),CanvasTheme.accentFill,radius:6,in:context) }
            let style = CanvasTheme.attributes(CanvasTheme.font(10,.semibold),hovered ? CanvasTheme.onAccent : CanvasTheme.text,alignment:.center)
            let width = ceil((city.name as NSString).size(withAttributes:style).width)+12
            let tag = CGRect(x:icon.midX-width/2,y:icon.maxY+1,width:width,height:15).integral
            CanvasTheme.fill(tag,hovered ? CanvasTheme.accentFill : CGColor(red:0.07,green:0.08,blue:0.11,alpha:0.82),radius:7.5,in:context)
            (city.name as NSString).draw(in:tag.offsetBy(dx:0,dy:1),withAttributes:style)
        }
        context.restoreGState()
    }
    /// A ring under the cell a town click sent the player to, fading out.
    private func drawWalkMarker(in context:CGContext) {
        guard let marker = walkMarker else { return }
        let age = Date().timeIntervalSince(marker.start)
        guard age < 0.7,host.vm.state.packedMap>>12 != 1 else { walkMarker = nil;return }
        let v = host.stage.viewport,camera = host.stage.camera,p = marker.point
        let c = OriginalTownPointer.center(p)
        let mid = canvasPoint(map:CGPoint(x:CGFloat(v[0])+c.x-CGFloat(camera[0]),y:CGFloat(v[1])+c.y-CGFloat(camera[1])))
        let scale = (canvasPoint(map:CGPoint(x:16,y:0)).x-canvasPoint(map:.zero).x)/16
        let grow = CGFloat(1+age*0.5)*scale,alpha = CGFloat(1-age/0.7)
        context.move(to:CGPoint(x:mid.x,y:mid.y-8*grow));context.addLine(to:CGPoint(x:mid.x+16*grow,y:mid.y))
        context.addLine(to:CGPoint(x:mid.x,y:mid.y+8*grow));context.addLine(to:CGPoint(x:mid.x-16*grow,y:mid.y));context.closePath()
        context.setStrokeColor(CanvasTheme.accentFill.copy(alpha:alpha) ?? CanvasTheme.accentFill);context.setLineWidth(2)
        context.strokePath()
    }
    private func drawHoverTag(in context:CGContext) {
        guard let person = hoveredPerson,host.explorationInputReady,!overlay.active,let actor = host.stage.actors[person],
              (0..<384).contains(person),let name = try? host.people.person(person).name,!name.isEmpty else { return }
        let box = actorRect(actor)
        var top = CGPoint(x:box.midX,y:box.minY-2)
        if modernField { top = CanvasFieldMap.canvasPoint(map:top) }
        CanvasTheme.chip(name,at:CGPoint(x:top.x,y:max(14,top.y-10)),maximumWidth:160,in:context)
    }
    override func mouseDown(with event:NSEvent) {
        guard !pauseCoordinator.paused else { return }
        hoveredPerson = nil
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
                if let actor = talkTarget(at:CGPoint(x:x,y:y)) { try host.talk(to:actor.person) }
                else {
                    if let cell = townTarget(atMap:CGPoint(x:x,y:y)) {
                        try host.walk(to:cell)
                        walkMarker = (cell,Date())
                    }
                }
            } else { try host.acknowledge() }
        } catch { recordInputError(error) }
        needsDisplay = true
    }
}
