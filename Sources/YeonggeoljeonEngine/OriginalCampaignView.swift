// SPDX-License-Identifier: GPL-3.0-only
import AppKit

final class OriginalCampaignView:NSView,EngineTimedView {
    let host:OriginalCampaignHost
    let renderer:Renderer
    private var timer:Timer?
    private var errorText:String?
    private var inputNotice:String?
    private var battleView:OriginalBattleView?
    private var battleScroll:NSScrollView?
    /// In-game selectors and waiting lines drawn above the stage and battle.
    private let overlay = CanvasOverlayView()
    private var imageCache:[String:CGImage] = [:]
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    convenience init(data:DataSet) throws {
        let c = Calendar.current.dateComponents([.day,.hour,.minute,.second],from:Date())
        func bcd(_ n:Int?) -> UInt8 { let v = n ?? 0;return UInt8(((v/10)<<4)|(v%10)) }
        try self.init(host:OriginalCampaignHost(data:data,rng:OriginalRNG.clockSeed(dayByte:bcd(c.day),hourByte:bcd(c.hour),minuteByte:bcd(c.minute),secondByte:bcd(c.second))))
    }
    init(host:OriginalCampaignHost) throws {
        self.host = host
        renderer = try Renderer(host.data)
        super.init(frame:CGRect(x:0,y:0,width:960,height:640))
        overlay.frame = bounds;overlay.autoresizingMask = [.width,.height];addSubview(overlay)
        overlay.restoreFocus = { [weak self] in
            guard let self = self else { return }
            if let board = self.battleView,self.battleScroll?.isHidden == false { self.window?.makeFirstResponder(board) }
            else { self.window?.makeFirstResponder(self) }
            self.needsDisplay = true
        }
        timer = Timer.scheduledTimer(withTimeInterval:1.0/60,repeats:true) { [weak self] _ in self?.tick() }
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
    /// The two-button selector shows Yes before No (MAIN164A9..165C4) with
    /// MARK member0 pictures; the answer is the source value (Yes1, No0).
    private func yesNo(_ text:String,_ answer:@escaping (Bool) -> Void) {
        let palette = host.stage.palette
        let yes = image(host.story.choiceButtonImage(value:1,palette:palette))
        let no = image(host.story.choiceButtonImage(value:0,palette:palette))
        overlay.show(CanvasMenu(title:text,options:[.init(label:"예",image:yes),.init(label:"아니요",image:no)],
                                horizontal:true) { index in answer(index == 0) })
    }
    /// Native saves live outside the app bundle and the original GAME folder.
    static func savesDirectory() throws -> URL {
        let base = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
        let folder = base.appendingPathComponent("Yeonggeoljeon Engine",isDirectory:true).appendingPathComponent("Saves",isDirectory:true)
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
    func stop() { timer?.invalidate();timer = nil }
    private func tick() {
        guard !overlay.active,errorText == nil else { return }
        do {
            try host.advance(microseconds:16_667)
            needsDisplay = true
            try synchronizeBattle()
            if host.frameworkReturn?.outcome == .restart { restartMain();return }
            if let value = host.frameworkReturn,value.outcome == .pending,value.asksRetry { presentRetry() }
            else if host.saveRequest != nil { presentSave() }
            else if let choice = host.choice,choice.kind == "choice-skip" || !choice.options.isEmpty { present(choice) }
            else if host.partySelection != nil { presentParty() }
            else if host.retirementPresentation != nil { presentRetirement() }
            else if host.stage.palette == 3,host.stage.dialogue != nil { presentBattleDialogue() }
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
            if self.host.frameworkReturn?.outcome == .quit { self.battleScroll?.isHidden = true;self.window?.makeFirstResponder(self) }
        }
    }
    /// Exit code4 makes HERO.COM execute MAIN again. The engine replaces this
    /// campaign host with a new one; MAIN's own title menu is not restored.
    private func restartMain() {
        do { replace(with:try OriginalCampaignView(data:host.data)) }
        catch { errorText = "\(error)";needsDisplay = true }
    }
    private func synchronizeBattle() throws {
        guard host.ending == nil,host.frameworkReturn?.outcome != .quit,host.stage.palette == 3,let session = host.battle else {
            battleScroll?.isHidden = true;return
        }
        if battleView?.session !== session {
            battleScroll?.removeFromSuperview()
            let board = try OriginalBattleView(session:session,background:battleBackground(session.definition,root:host.data.root),sprites:OriginalBattleSpriteRenderer(root:host.data.root))
            board.onHook = { [weak self] value in guard let self = self else { return false };return try self.host.beginTurnHook(value) }
            board.onRetirement = { [weak self] value in
                guard let self = self else { return false }
                return try self.host.beginRetirement(value)
            }
            board.inputReady = { [weak self] in self?.host.battleInputReady == true }
            board.menuTexts = host.framework?.battleMenu
            let scroll = NSScrollView(frame:CGRect(x:0,y:0,width:bounds.width,height:bounds.height-40))
            scroll.autoresizingMask = [.width,.height];scroll.hasVerticalScroller = true;scroll.hasHorizontalScroller = true;scroll.documentView = board
            addSubview(scroll,positioned:.below,relativeTo:overlay);battleView = board;battleScroll = scroll
            window?.makeFirstResponder(board)
        }
        battleScroll?.isHidden = false
        if host.battleInputReady,let board = battleView {
            if session.turns.stage == .unstarted { try board.start() }
            else if board.suspended { try board.resumeSourceFlow() }
            if board.flow.canLeaveBattle { try host.finishBattleLoop() }
        }
        battleView?.needsDisplay = true
    }
    private func presentBattleDialogue() {
        guard let dialogue = host.stage.dialogue else { return }
        overlay.show(CanvasNotice(speaker:dialogue.speaker,text:dialogue.text,portrait:portrait(dialogue.person,palette:host.stage.palette)) { [weak self] in
            guard let self = self else { return }
            self.act { try self.host.acknowledge() }
        })
    }
    private func presentRetirement() {
        guard let text = host.retirementText else { return }
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
        let rows = selection.candidates.compactMap { id in (try? host.people.person(id)).map { (id,$0) } }
        var options = rows.map { id,person in
            CanvasMenu.Option(label:"\(person.name) · Lv \(person.level)",enabled:!fixed.contains(id),checked:chosen.contains(id))
        }
        options.append(.init(label:"출전"))
        let status = footer ?? "남은 선택 \(selection.remaining) / 최대 \(selection.capacity)"
        overlay.show(CanvasMenu(title:"출전 부대 선택",options:options,selected:selected,footer:status) { [weak self] index in
            guard let self = self,let index = index else { return }
            if index == rows.count { self.act { try self.host.confirmParty() };return }
            do { try self.host.toggleParty(person:rows[index].0);self.presentParty(selected:index,keepScroll:true) }
            catch {
                NSSound.beep()
                let full = self.host.partySelection.map { $0.remaining == 0 && !chosen.contains(rows[index].0) } ?? false
                self.presentParty(selected:index,footer:full ? "남은 선택이 없습니다. 최대 \(selection.capacity)명입니다." : "\(error)",keepScroll:true)
            }
        },keepScroll:keepScroll)
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
    private func writeNativeSave() -> Bool {
        do {
            let snapshot = try host.resumeSnapshot()
            let panel = NSSavePanel();panel.allowedContentTypes = [.json];panel.directoryURL = try Self.savesDirectory()
            let state = host.vm.state
            panel.nameFieldStringValue = "chapter\(state.chapter)-\(state.member)-\(state.block)-\(Int(Date().timeIntervalSince1970)).json"
            guard panel.runModal() == .OK,let url = panel.url else { return false }
            let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
            try encoder.encode(snapshot).write(to:url,options:.atomic)
            return true
        } catch {
            let alert = NSAlert();alert.messageText = "저장하지 못했습니다.";alert.informativeText = "\(error)";alert.runModal()
            return false
        }
    }
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
            if writeNativeSave() { complete();return }
            yesNo(framework?.saveDeclinePrompt?.text ?? "저장하지 않고 진행할까요?") { yes in yes ? complete() : attempt() }
        }
        yesNo(framework?.savePrompt?.text ?? "여기서 저장할까요?") { yes in yes ? attempt() : complete() }
    }
    /// MAIN CF5:C050 menu after the title. Item0 starts, item1 resumes a
    /// native save, item2 (CF5:BFDE settings) is not restored, and item3
    /// returns to the opening, as exit code0 runs OPEN before MAIN again.
    private func presentTitleMenu() {
        let items = host.framework?.titleMenu?.map(\.text) ?? ["새로 시작","이어하기","기능설정","오프닝"]
        overlay.show(CanvasMenu(title:"",options:items.map { .init(label:$0) },cancellable:true) { [weak self] chosen in
            guard let self = self,let chosen = chosen else { return }
            do {
                switch chosen {
                case 0: try self.host.acknowledge()
                case 1:
                    guard let resumed = try Self.chooseResume(data:self.host.data) else { return }
                    self.replace(with:try OriginalCampaignView(host:resumed))
                case 2:
                    self.overlay.show(CanvasNotice(speaker:"",text:"기능설정(CF5:BFDE)은 아직 복원하지 않았습니다.",portrait:nil) { [weak self] in
                        self?.presentTitleMenu()
                    })
                case 3: self.replace(with:try OriginalCampaignView(data:self.host.data))
                default: return
                }
            } catch { self.recordInputError(error) }
            self.needsDisplay = true
        })
    }
    /// MAIN's field menu (input code23, DS:3636/36E2 -> CF5:F382). The
    /// engine opens it with a secondary click; the original key binding is
    /// not established. Quit, load and save have native counterparts.
    override func rightMouseDown(with event:NSEvent) {
        guard host.fieldMenuReady,!overlay.active else { super.rightMouseDown(with:event);return }
        let labels = host.framework?.fieldMenu?.items.map(\.text) ?? OriginalFieldMenuTexts.actions
        let options = labels.enumerated().map { CanvasMenu.Option(label:$0.element,
            enabled:["quit","load","save"].contains(OriginalFieldMenuTexts.actions[$0.offset])) }
        overlay.show(CanvasMenu(title:"",options:options,cancellable:true) { [weak self] index in
            guard let self = self,let index = index else { return }
            self.fieldMenuChosen(OriginalFieldMenuTexts.actions[index])
        })
    }
    private func fieldMenuChosen(_ action:String) {
        guard host.fieldMenuReady else { return }
        switch action {
        case "quit":
            yesNo(host.framework?.fieldMenu?.quitConfirm.text ?? "게임을 종료할까요?") { [weak self] yes in
                guard yes,let self = self else { return }
                do { try self.host.fieldQuit() } catch { self.recordInputError(error) }
            }
        case "save": _ = writeNativeSave()
        case "load":
            do {
                guard let resumed = try Self.chooseResume(data:host.data) else { return }
                replace(with:try OriginalCampaignView(host:resumed))
            } catch { recordInputError(error) }
        default: return
        }
        needsDisplay = true
    }
    private func replace(with next:OriginalCampaignView) {
        guard let window = window else { return }
        stop();window.contentView = next;window.makeFirstResponder(next)
    }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.black.setFill();bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = min(bounds.width/640,(bounds.height-40)/400)
        do {
            let frame = try host.ending.map { try renderer.renderEnding($0) } ?? renderer.render(host.stage,screen:host.fieldScreenState())
            Renderer.image(frame.image,in:CGRect(x:(bounds.width-640*scale)/2,y:0,width:640*scale,height:400*scale),context:context)
        } catch { errorText = "\(error)" }
        let text:String
        if let error = errorText { text = error }
        else if let notice = inputNotice ?? host.notice { text = notice }
        else if let choice = host.choice { text = "원작 선택지 입력 대기 · \(choice.id)" }
        else { text = host.status }
        (text as NSString).draw(in:CGRect(x:12,y:bounds.height-35,width:bounds.width-24,height:32),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.lightGray])
    }
    override func keyDown(with event:NSEvent) {
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
    override func mouseDown(with event:NSEvent) {
        // MAIN1E3A8 waits for one input before main exits with code3.
        if host.frameworkReturn?.outcome == .quit { window?.performClose(nil);return }
        inputNotice = nil
        if !host.hasStarted { presentTitleMenu();needsDisplay = true;return }
        do {
            if host.explorationInputReady,[0,1,2].contains(host.vm.state.packedMap>>12) {
                let scale = min(bounds.width/640,(bounds.height-40)/400)
                let p = convert(event.locationInWindow,from:nil)
                let x = (p.x-(bounds.width-640*scale)/2)/scale,y = p.y/scale,v = host.stage.viewport
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
