// SPDX-License-Identifier: GPL-3.0-only
import AppKit

struct FrameEvidence: Codable {
    var file: String; var event: String; var snapshot: Snapshot
    var pixelChecksumFNV1a64: String; var actors: [ActorRenderProof]
}
struct Verification: Codable {
    var format = 1; var engine = "YeonggeoljeonEngine"
    var verificationKind = "deterministic offscreen rendering; no OS keyboard/mouse events"
    var status: String; var scene: String; var titleAvailable: Bool
    var resourcesProvenance: JSONValue?; var sceneProvenance: JSONValue?
    var limitations: [String]; var frames: [FrameEvidence]; var trace: [TraceEntry]
    var finalState: Snapshot
}

func verify(_ data: DataSet, output: URL) throws {
    let output = try verificationDirectory(output,excluding:data.root)
    let renderer = try Renderer(data), runtime = Runtime(data)
    var frames: [FrameEvidence] = [], sequence = 0
    func capture(_ event: String) throws {
        let name = String(format:"%02d-%@.png",sequence,event); sequence += 1
        let frame = try renderer.render(runtime,evidence:true)
        try frame.writePNG(output.appendingPathComponent(name))
        frames.append(FrameEvidence(file:name,event:event,snapshot:runtime.snapshot(),pixelChecksumFNV1a64:frame.checksum,actors:frame.actors))
    }
    try capture(data.resources.title == nil ? "title-unavailable" : "original-title")
    runtime.acknowledge()
    var firstDialogue = false, firstMove = false, firstRemoval = false
    var previousPeople = Set(runtime.actors.keys), steps = 0
    // Bound derives from source command count plus at most the full31x20 route
    // for each movement. It is an audit work limit, never silent success.
    let maxSteps = max(1,data.scene.commands.count) * (31*20+2)
    while runtime.mode != "ended" && steps < maxSteps {
        steps += 1
        if let batch = runtime.batch {
            if !firstMove {
                runtime.advance(microseconds:min(batch.duration-batch.elapsed,max(1,batch.step+batch.step/2)))
                if runtime.batch != nil { try capture("movement"); firstMove = true }
            } else { runtime.advance(microseconds:batch.duration-batch.elapsed) }
        } else if runtime.dialogue != nil {
            if !firstDialogue { try capture("first-dialogue"); firstDialogue = true }
            runtime.acknowledge()
        } else { runtime.advance(microseconds:50_000) }
        let current = Set(runtime.actors.keys)
        if !firstRemoval && !previousPeople.subtracting(current).isEmpty {
            try capture("actor-exit"); firstRemoval = true
        }
        previousPeople = current
    }
    guard runtime.mode == "ended" else { throw EngineError.invalid("Verification work limit reached before the explicit source boundary") }
    try capture("last-supported-scene")
    let status = runtime.verifiedBoundary ? (runtime.termination == .unsupportedBoundary ? "reached declared unsupported boundary" : "reached explicit source boundary") : "failed"
    let result = Verification(status:status,scene:data.scene.id,titleAvailable:data.resources.title != nil,
        resourcesProvenance:data.resources.provenance,sceneProvenance:data.scene.provenance,
        limitations:["No OS input events were sent; this does not verify Finder launch or keyboard/mouse delivery.",
                     "Korean text uses a macOS font; the original DOS font is not restored.",
                     "Town positions advance in discrete source grid cells; smooth interpolation is not claimed.",
                     "Walking sprite phase currently follows cell parity; exact DOS phase/terminal-frame timing is not verified.",
                     "Prop rendering uses source object foot-depth ordering, not a verified per16x16-cell occlusion driver.",
                     "The bounded exported scene is supported; unknown commands stop explicitly.",
                     "No save/progress store is read or written."],
        frames:frames,trace:runtime.trace,finalState:runtime.snapshot())
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
    try encoder.encode(result).write(to:output.appendingPathComponent("verification.json"),options:.atomic)
    guard runtime.verifiedBoundary else { throw EngineError.invalid("Runtime verification failed: \(runtime.endReason ?? "unknown")") }
    print("Verified \(frames.count) offscreen frames; boundary: \(runtime.endReason ?? "unknown")")
}

protocol EngineTimedView { func stop() }
final class GameView: NSView,EngineTimedView {
    let runtime: Runtime; let renderer: Renderer
    var onBoundary:((Termination)->Void)?
    private var boundaryDelivered = false
    private var timer: Timer?
    private var lastTick = DispatchTime.now().uptimeNanoseconds
    private var lastTraceCount = 0
    private var failure: String?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(data: DataSet) throws {
        runtime = Runtime(data); renderer = try Renderer(data)
        super.init(frame:CGRect(x:0,y:0,width:960,height:600))
        timer = Timer.scheduledTimer(withTimeInterval:1.0/60.0,repeats:true) { [weak self] _ in self?.tick() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func stop() { timer?.invalidate(); timer = nil }
    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let delta = min(Int64((now-lastTick)/1000),250_000); lastTick = now
        runtime.advance(microseconds:delta)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        for entry in runtime.trace.dropFirst(lastTraceCount) {
            if let bytes = try? encoder.encode(entry), let line = String(data:bytes,encoding:.utf8) {
                FileHandle.standardError.write(Data((line+"\n").utf8))
            }
        }
        lastTraceCount = runtime.trace.count; needsDisplay = true
        if !boundaryDelivered, let termination = runtime.termination {
            boundaryDelivered = true; onBoundary?(termination)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        do {
            let frame = try renderer.render(runtime)
            let scale = min(bounds.width/640,bounds.height/400)
            let rect = CGRect(x:(bounds.width-640*scale)/2,y:(bounds.height-400*scale)/2,width:640*scale,height:400*scale)
            Renderer.image(frame.image,in:rect,context:context)
        } catch {
            if failure == nil { failure = "\(error)"; FileHandle.standardError.write(Data(("Render failure: \(error)\n").utf8)) }
            ("화면 자료를 표시할 수 없습니다." as NSString).draw(at:NSPoint(x:24,y:24),withAttributes:[.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.white])
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.performClose(nil) }
        else if [36,49,76].contains(event.keyCode), !event.isARepeat { runtime.acknowledge(); needsDisplay = true }
    }
    override func mouseDown(with event: NSEvent) { runtime.acknowledge(); needsDisplay = true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    var data:DataSet?
    var researchWindows:[NSWindow] = []
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowWillClose(_ notification:Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        (closing.contentView as? EngineTimedView)?.stop()
        researchWindows.removeAll { $0 === closing }
        if window === closing { window = nil }
    }
    func installMenu() {
        let menu = NSMenu(), application = NSMenuItem()
        menu.addItem(application)
        let appMenu = NSMenu(); application.submenu = appMenu
        appMenu.addItem(withTitle:"종료",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let research = NSMenuItem(title:"연구",action:nil,keyEquivalent:"")
        let submenu = NSMenu(title:"연구"); research.submenu = submenu; menu.addItem(research)
        let play = NSMenuItem(title:"원작 캠페인 실행 연구…",action:#selector(playOriginalCampaign),keyEquivalent:"n");play.target = self;submenu.addItem(play)
        let restored = NSMenuItem(title:"원작 전투 복원 검증…",action:#selector(browseRestoredBattles),keyEquivalent:"b"); restored.target = self; submenu.addItem(restored)
        let battle = NSMenuItem(title:"이전 실험 규칙 연구…",action:#selector(browseBattles),keyEquivalent:""); battle.target = self; submenu.addItem(battle)
        let campaign = NSMenuItem(title:"캠페인 분석…",action:#selector(browseCampaign),keyEquivalent:"g"); campaign.target = self; submenu.addItem(campaign)
        NSApplication.shared.mainMenu = menu
    }
    private func error(_ error:Error) {
        let alert = NSAlert(); alert.messageText = "요청한 연구 항목을 실행할 수 없습니다."; alert.informativeText = "\(error)"; alert.runModal()
    }
    private func show(_ view:NSView,title:String,size:NSSize = NSSize(width:1000,height:700)) {
        let window = NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.title = title; window.contentView = view; window.center(); researchWindows.append(window)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
    }
    private func showBrowser(_ controller:RecordBrowser,title:String) {
        let window = NSWindow(contentViewController:controller)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.title = title; window.styleMask.insert(.resizable); window.center()
        researchWindows.append(window); window.makeKeyAndOrderFront(nil)
    }
    @objc func browseBattles() {
        guard let data = data else { return }
        do {
            let catalog = try BattleCatalog.load(from:data.root.appendingPathComponent("battles.json"))
            let controller = RecordBrowser(titles:catalog.battles.map { "\($0.id) · \($0.name ?? "") · \($0.units.count) slots" },
                details:"원작 배치 자료를 읽은 전투 목록입니다. 현재 전투 창은 명시적으로 선택한 실험 규칙만 지원하며 원작 전투 수식·AI·목표를 재현하지 않습니다.") { [weak self] row in
                    let alert = NSAlert(); alert.messageText = "실험 규칙으로 전투를 열까요?"
                    alert.informativeText = "이동·공격·턴 처리를 검증하는 연구 모드입니다. 유닛 수치·피해·AI·승패 조건은 원작과 다릅니다."
                    alert.addButton(withTitle:"실험 전투 시작"); alert.addButton(withTitle:"취소")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    do { try self?.showBattle(catalog.battles[row]) } catch { self?.error(error) }
                }
            showBrowser(controller,title:"전투 연구 목록")
        } catch { self.error(error) }
    }
    @objc func browseRestoredBattles() {
        guard let data = data else { return }
        do {
            let source = try OriginalGameData(root:data.root)
            let controller = RecordBrowser(titles:source.battles.battles.map { "\($0.id) · 원작 배치 프로그램" },
                details:"복원한 원작 수치·이동·공격·반격·경험치·지원 AI를 검증합니다. 초기 플래그가 비어 있는 독립 상태이며 캠페인 진행을 대신하지 않습니다. 미복원 원작 명령에서는 멈춥니다.") { [weak self] row in
                    do { try self?.showOriginalBattle(source.battles.battles[row].id) } catch { self?.error(error) }
                }
            showBrowser(controller,title:"원작 전투 복원 검증")
        } catch { self.error(error) }
    }
    @objc func playOriginalCampaign() {
        guard let data = data else { return }
        do { show(try OriginalCampaignView(data:data),title:"원작 캠페인 복원",size:NSSize(width:960,height:640)) }
        catch { self.error(error) }
    }
    func showOriginalBattle(_ id:String) throws {
        guard let data = data else { return }
        let c = Calendar.current.dateComponents([.day,.hour,.minute,.second],from:Date())
        func bcd(_ n:Int?) -> UInt8 { let v = n ?? 0;return UInt8(((v/10)<<4)|(v%10)) }
        let rng = OriginalRNG.clockSeed(dayByte:bcd(c.day),hourByte:bcd(c.hour),minuteByte:bcd(c.minute),secondByte:bcd(c.second))
        let source = try OriginalGameData(root:data.root),session = try source.isolatedBattle(id,rng:rng)
        let board = try OriginalBattleView(session:session,background:battleBackground(session.definition,root:data.root))
        let scroll = NSScrollView(frame:CGRect(x:0,y:0,width:1100,height:740))
        scroll.hasVerticalScroller = true;scroll.hasHorizontalScroller = true;scroll.documentView = board
        try board.start();show(scroll,title:"원작 전투 복원 · \(id)")
        scroll.window?.makeFirstResponder(board)
    }
    func showBattle(_ definition:BattleDefinition) throws {
        let session = try BattleSession(definition:definition,policy:.experimentalV1)
        let board = BattleBoardView(session:session,background:try data.flatMap { try battleBackground(definition,root:$0.root) })
        let scroll = NSScrollView(frame:CGRect(x:0,y:0,width:1000,height:700))
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.documentView = board
        show(scroll,title:"실험 전투 · \(definition.id)")
        scroll.window?.makeFirstResponder(board)
    }
    @objc func browseCampaign() {
        guard let data = data else { return }
        do {
            let catalog = try CampaignCatalog.load(from:data.root.appendingPathComponent("campaign.json"))
            let controller = RecordBrowser(titles:catalog.records.map { "\($0.id) · \($0.label) · \($0.executionStatus) · \($0.conditionStatus)" },
                details:"전체 원작 시나리오에서 읽은 기록 목록입니다. 목록 해독과 전체 캠페인의 자동 진행은 별개입니다. 미해석 조건·명령·지도에서는 멈춥니다.") { [weak self] row in
                    do {
                        let session = CampaignSession(catalog:catalog), record = catalog.records[row]
                        var conditionalPreview = false
                        if !record.conditionUnconditional {
                            let alert = NSAlert(); alert.messageText = "조건을 평가하지 않고 기록을 미리 볼까요?"
                            alert.informativeText = "분석용 미리보기입니다. 원작 캠페인의 진행 조건이 충족된 것으로 처리하거나 다음 장면으로 자동 진행하지 않습니다."
                            alert.addButton(withTitle:"분석 미리보기"); alert.addButton(withTitle:"취소")
                            guard alert.runModal() == .alertFirstButtonReturn else { return }
                            conditionalPreview = true
                        }
                        let scene = try session.selectRecord(id:record.id,allowConditionalPreview:conditionalPreview)
                        let selected = try data.replacingScene(scene), view = try GameView(data:selected)
                        view.onBoundary = { termination in session.finishRecord(termination:termination) }
                        view.runtime.acknowledge()
                        self?.show(view,title:"캠페인 기록 · \(record.id)",size:NSSize(width:960,height:600))
                    } catch { self?.error(error) }
                }
            showBrowser(controller,title:"캠페인 분석 목록")
        } catch { self.error(error) }
    }
}

struct EngineOptions {
    var data:URL?, output:URL?, battleID:String?, campaignRecord:String?
    var verify = false, tests = false, verifyBattle = false, verifyCampaign = false,verifyVM = false
    var listBattles = false, listCampaign = false, experimental = false
}
func arguments() throws -> EngineOptions {
    let args = Array(CommandLine.arguments.dropFirst()); var i = 0
    var options = EngineOptions()
    var seen = Set<String>()
    while i < args.count {
        guard seen.insert(args[i]).inserted else { throw EngineError.invalid("Duplicate argument: \(args[i])") }
        switch args[i] {
        case "--verify": options.verify = true
        case "--self-test": options.tests = true
        case "--verify-battle": options.verifyBattle = true
        case "--verify-campaign": options.verifyCampaign = true
        case "--verify-vm":options.verifyVM = true
        case "--list-battles": options.listBattles = true
        case "--list-campaign": options.listCampaign = true
        case "--experimental-rules": options.experimental = true
        case "--data", "--output", "--battle", "--campaign-record":
            let key = args[i]; i += 1
            guard i < args.count else { throw EngineError.invalid("Missing value for \(key)") }
            if key == "--data" { options.data = URL(fileURLWithPath:args[i],isDirectory:true) }
            else if key == "--output" { options.output = URL(fileURLWithPath:args[i],isDirectory:true) }
            else if key == "--battle" { options.battleID = args[i] }
            else { options.campaignRecord = args[i] }
        default: throw EngineError.invalid("Unknown argument: \(args[i])")
        }; i += 1
    }
    let verificationModes = [options.verify,options.verifyBattle,options.verifyCampaign,options.verifyVM].filter{$0}.count
    guard verificationModes <= 1, !(options.battleID != nil && options.campaignRecord != nil),
          !(options.listBattles && options.listCampaign),
          !(options.tests && (verificationModes > 0 || options.battleID != nil || options.campaignRecord != nil || options.listBattles || options.listCampaign)) else {
        throw EngineError.invalid("Choose one engine action per invocation")
    }
    let listing = options.listBattles || options.listCampaign
    guard !(listing && (verificationModes > 0 || options.battleID != nil || options.campaignRecord != nil || options.experimental || options.output != nil)),
          !(options.verify && options.battleID != nil),
          !((options.verifyCampaign || options.verifyVM) && (options.battleID != nil || options.campaignRecord != nil)),
          !(options.experimental && options.battleID == nil),
          !(options.output != nil && verificationModes == 0),
          !(options.tests && (options.data != nil || options.output != nil || options.experimental)) else {
        throw EngineError.invalid("Arguments select incompatible engine actions")
    }
    if options.verifyBattle && options.battleID == nil { throw EngineError.invalid("--verify-battle requires an explicit --battle ID") }
    return options
}

do {
    let options = try arguments()
    if options.tests {
        try selfTests();try battleSelfTests();try campaignSelfTests();try campaignVMSelfTests()
        try originalCombatSelfTests();try originalAISelfTests();try originalTurnSelfTests();try originalIntegrationSelfTests()
        try originalScriptBattleSelfTests();try originalStrategyAISelfTests();try originalStrategiesSelfTests()
        try originalScriptActionSelfTests();exit(0)
    }
    guard let root = options.data ?? Bundle.main.resourceURL?.appendingPathComponent("GameData",isDirectory:true) else {
        throw EngineError.invalid("Use --data PATH or an app bundle containing Resources/GameData")
    }
    var data = try DataSet(root:root)
    if options.listBattles {
        let catalog = try BattleCatalog.load(from:data.root.appendingPathComponent("battles.json"))
        for battle in catalog.battles { print("\(battle.id)\t\(battle.units.count) slots\t\(battle.name ?? "")") }
        exit(0)
    }
    if options.listCampaign {
        let catalog = try CampaignCatalog.load(from:data.root.appendingPathComponent("campaign.json"))
        for record in catalog.records { print("\(record.id)\t\(record.executionStatus)\t\(record.conditionStatus)\t\(record.label)") }
        exit(0)
    }
    if let id = options.campaignRecord {
        let catalog = try CampaignCatalog.load(from:data.root.appendingPathComponent("campaign.json"))
        data = try data.replacingScene(CampaignSession(catalog:catalog).selectRecord(id:id))
    }
    let app = NSApplication.shared
    if options.verify || options.verifyBattle || options.verifyCampaign || options.verifyVM {
        guard let output = options.output else { throw EngineError.invalid("Verification requires --output PATH") }
        app.setActivationPolicy(.prohibited)
        if options.verifyBattle, let id = options.battleID {
            let catalog = try BattleCatalog.load(from:data.root.appendingPathComponent("battles.json"))
            guard let battle = catalog.battles.first(where:{$0.id == id}) else { throw EngineError.invalid("Unknown source battle ID: \(id)") }
            if options.experimental { try verifyBattle(battle,policy:.experimentalV1,input:data.root,output:output) }
            else { try verifyOriginalBattle(id,data:data,output:output) }
        } else if options.verifyVM { try verifyOriginalCampaignHost(data,output:output) }
        else if options.verifyCampaign {
            let catalog = try CampaignCatalog.load(from:data.root.appendingPathComponent("campaign.json"))
            try verifyCampaign(catalog,data:data,output:output)
        } else { try verify(data,output:output) }
    } else {
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate(); app.delegate = delegate; delegate.data = data; delegate.installMenu()
        if let id = options.battleID {
            let catalog = try BattleCatalog.load(from:data.root.appendingPathComponent("battles.json"))
            guard let battle = catalog.battles.first(where:{$0.id == id}) else { throw EngineError.invalid("Unknown source battle ID: \(id)") }
            if options.experimental { try delegate.showBattle(battle) } else { try delegate.showOriginalBattle(id) }
            app.activate(ignoringOtherApps:true)
            app.run(); withExtendedLifetime(delegate) {}; exit(0)
        }
        let view = try GameView(data:data)
        let window = NSWindow(contentRect:view.frame,styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.delegate = delegate
        window.title = "영걸전 연구 엔진"; window.contentView = view; window.contentMinSize = NSSize(width:640,height:400)
        window.center(); delegate.window = window
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view); app.activate(ignoringOtherApps:true)
        if options.campaignRecord != nil { view.runtime.acknowledge() }
        app.run(); withExtendedLifetime(delegate) {}
    }
} catch {
    FileHandle.standardError.write(Data(("YeonggeoljeonEngine: \(error)\n").utf8)); exit(2)
}
