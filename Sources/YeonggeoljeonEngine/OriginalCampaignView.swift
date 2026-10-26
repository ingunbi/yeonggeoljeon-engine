// SPDX-License-Identifier: GPL-3.0-only
import AppKit

final class OriginalCampaignView:NSView,EngineTimedView {
    let host:OriginalCampaignHost
    let renderer:Renderer
    private var timer:Timer?
    private var errorText:String?
    private var inputNotice:String?
    private var presenting = false
    private var battleView:OriginalBattleView?
    private var battleScroll:NSScrollView?
    private var partyNote:NSTextField?
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
        timer = Timer.scheduledTimer(withTimeInterval:1.0/60,repeats:true) { [weak self] _ in self?.tick() }
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
        guard !presenting,errorText == nil else { return }
        do {
            try host.advance(microseconds:16_667)
            needsDisplay = true
            try synchronizeBattle()
            if let choice = host.choice,choice.kind == "choice-skip" || !choice.options.isEmpty { present(choice) }
            if host.saveRequest != nil { presentSave() }
            if host.partySelection != nil { presentParty() }
            if host.retirementPresentation != nil { try presentRetirement() }
            if host.stage.palette == 3,host.stage.dialogue != nil { try presentBattleDialogue() }
            if let value = host.frameworkReturn,value.outcome == .pending,value.asksRetry { try presentRetry() }
            if host.frameworkReturn?.outcome == .restart { restartMain();return }
        } catch { errorText = "\(error)";needsDisplay = true }
    }
    /// main1E5DD shows the selector over the current screen. The native host
    /// keeps the source result; restart and exit belong to this window owner.
    private func presentRetry() throws {
        presenting = true;defer { presenting = false }
        let alert = NSAlert()
        alert.messageText = host.retryPromptText ?? "원작 재시작 선택"
        alert.informativeText = host.retryPromptText == nil ? "원작 문구가 로컬 자료에 없어 엔진 안내문으로 표시합니다." : ""
        alert.addButton(withTitle:"예 (Yes)");alert.addButton(withTitle:"아니요 (No)")
        let result = alert.runModal()
        try host.answerRetryPrompt(result == .alertFirstButtonReturn ? 1 : 0)
        if host.frameworkReturn?.outcome == .quit { battleScroll?.isHidden = true;window?.makeFirstResponder(self) }
        needsDisplay = true
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
            let scroll = NSScrollView(frame:CGRect(x:0,y:0,width:bounds.width,height:bounds.height-40))
            scroll.autoresizingMask = [.width,.height];scroll.hasVerticalScroller = true;scroll.hasHorizontalScroller = true;scroll.documentView = board
            addSubview(scroll);battleView = board;battleScroll = scroll
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
    private func presentBattleDialogue() throws {
        guard let dialogue = host.stage.dialogue else { return }
        presenting = true;defer { presenting = false }
        let alert = NSAlert();alert.messageText = dialogue.speaker;alert.informativeText = dialogue.text
        alert.addButton(withTitle:"계속")
        alert.runModal();try host.acknowledge()
    }
    private func presentRetirement() throws {
        guard let text = host.retirementText else { return }
        presenting = true;defer { presenting = false }
        let alert = NSAlert();alert.messageText = "원작 퇴장 이벤트";alert.informativeText = text;alert.addButton(withTitle:"계속")
        alert.runModal();try host.acknowledgeRetirement()
    }
    private func presentParty() {
        guard let selection = host.partySelection else { return }
        presenting = true;defer { presenting = false;partyNote = nil }
        let alert = NSAlert();alert.messageText = "출전 부대 선택"
        let container = NSView(frame:CGRect(x:0,y:0,width:430,height:350))
        let note = NSTextField(labelWithString:"남은 선택 \(selection.remaining) / 최대 \(selection.capacity)")
        note.frame = CGRect(x:0,y:325,width:430,height:24);container.addSubview(note);partyNote = note
        let scroll = NSScrollView(frame:CGRect(x:0,y:0,width:430,height:318));scroll.hasVerticalScroller = true
        let list = NSView(frame:CGRect(x:0,y:0,width:410,height:max(318,selection.candidates.count*27)))
        for (index,id) in selection.candidates.enumerated() {
            guard let person = try? host.people.person(id) else { continue }
            let button = NSButton(checkboxWithTitle:"\(person.name) · Lv \(person.level)",target:self,action:#selector(partyToggled(_:)))
            button.tag = id;button.frame = CGRect(x:8,y:list.bounds.height-CGFloat(index+1)*27,width:390,height:25)
            button.state = selection.selectedSlots.contains(id) ? .on : .off
            button.isEnabled = !selection.selectedSlots.prefix(selection.fixedCount).contains(id);list.addSubview(button)
        }
        scroll.documentView = list;container.addSubview(scroll);alert.accessoryView = container;alert.addButton(withTitle:"출전")
        if alert.runModal() == .alertFirstButtonReturn {
            do { try host.confirmParty() } catch { errorText = "\(error)" }
        }
    }
    @objc private func partyToggled(_ sender:NSButton) {
        do { try host.toggleParty(person:sender.tag) }
        catch { NSSound.beep();partyNote?.stringValue = "\(error)" }
        if let selection = host.partySelection {
            sender.state = selection.selectedSlots.contains(sender.tag) ? .on : .off
            partyNote?.stringValue = "남은 선택 \(selection.remaining) / 최대 \(selection.capacity)"
        }
    }
    private func present(_ choice:CampaignVMChoice) {
        presenting = true;defer { presenting = false }
        let alert = NSAlert();alert.messageText = choice.prompt.isEmpty ? "선택" : choice.prompt
        if choice.kind == "choice-skip" {
            alert.addButton(withTitle:"예 (Yes)");alert.addButton(withTitle:"아니요 (No)")
            let result = alert.runModal()
            do {
                if result == .alertFirstButtonReturn { try host.choose(1) }
                else if result == .alertSecondButtonReturn { try host.choose(0) }
            } catch { errorText = "\(error)" }
            return
        }
        let selector = NSPopUpButton(frame:CGRect(x:0,y:0,width:360,height:28))
        selector.addItems(withTitles:choice.options);alert.accessoryView = selector
        alert.addButton(withTitle:"선택")
        if alert.runModal() == .alertFirstButtonReturn {
            do { try host.choose(selector.indexOfSelectedItem) } catch { errorText = "\(error)" }
        }
    }
    private func ask(_ text:String,detail:String = "") -> Bool {
        let alert = NSAlert();alert.messageText = text;alert.informativeText = detail
        alert.addButton(withTitle:"예 (Yes)");alert.addButton(withTitle:"아니요 (No)")
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// Source3D (MAIN22A62..22AA1): Yes opens the save destination; a
    /// cancelled or failed save asks the decline check, whose No retries.
    /// The written file is native engine state, not an original MSAVE slot.
    private func presentSave() {
        presenting = true;defer { presenting = false }
        let framework = host.framework
        let question = framework?.savePrompt?.text ?? "여기서 저장할까요?"
        if ask(question,detail:"자체 엔진 형식으로 저장합니다. 원작 세이브 슬롯과는 다른 파일입니다.") {
            while true {
                do {
                    let snapshot = try host.resumeSnapshot()
                    let panel = NSSavePanel();panel.allowedContentTypes = [.json];panel.directoryURL = try Self.savesDirectory()
                    let state = host.vm.state
                    panel.nameFieldStringValue = "chapter\(state.chapter)-\(state.member)-\(state.block)-\(Int(Date().timeIntervalSince1970)).json"
                    if panel.runModal() == .OK,let url = panel.url {
                        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
                        try encoder.encode(snapshot).write(to:url,options:.atomic)
                        break
                    }
                } catch {
                    let alert = NSAlert();alert.messageText = "저장하지 못했습니다.";alert.informativeText = "\(error)";alert.runModal()
                }
                if ask(framework?.saveDeclinePrompt?.text ?? "저장하지 않고 진행할까요?") { break }
            }
        }
        do { try host.completeSaveRequest() } catch { errorText = "\(error)" }
    }
    /// MAIN CF5:C050 menu after the title. Item0 starts, item1 resumes a
    /// native save, item2 (CF5:BFDE settings) is not restored, and item3
    /// returns to the opening, as exit code0 runs OPEN before MAIN again.
    private func presentTitleMenu() {
        presenting = true;defer { presenting = false }
        let items = host.framework?.titleMenu?.map(\.text) ?? ["새로 시작","이어하기","기능설정","오프닝"]
        let alert = NSAlert();alert.messageText = "영걸전"
        for item in items { alert.addButton(withTitle:item) }
        let chosen = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        do {
            switch chosen {
            case 0: try host.acknowledge()
            case 1:
                guard let resumed = try Self.chooseResume(data:host.data) else { return }
                replace(with:try OriginalCampaignView(host:resumed))
            case 2:
                let notice = NSAlert();notice.messageText = "기능설정(CF5:BFDE)은 아직 복원하지 않았습니다.";notice.runModal()
            case 3: replace(with:try OriginalCampaignView(data:host.data))
            default: return
            }
        } catch { recordInputError(error) }
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
            let frame = try host.ending.map { try renderer.renderEnding($0) } ?? renderer.render(host.stage)
            Renderer.image(frame.image,in:CGRect(x:(bounds.width-640*scale)/2,y:0,width:640*scale,height:400*scale),context:context)
        } catch { errorText = "\(error)" }
        let text:String
        if let error = errorText { text = error }
        else if let notice = inputNotice { text = notice }
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
