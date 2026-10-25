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
    let fm = FileManager.default
    let output = output.standardizedFileURL.resolvingSymlinksInPath()
    guard output != data.root, !data.root.path.hasPrefix(output.path + "/"), !output.path.hasPrefix(data.root.path + "/") else {
        throw EngineError.invalid("Verification output must not contain the input data directory")
    }
    if fm.fileExists(atPath:output.path), !(try fm.contentsOfDirectory(atPath:output.path)).isEmpty {
        throw EngineError.invalid("Verification output is not empty; existing evidence is preserved")
    }
    try fm.createDirectory(at:output,withIntermediateDirectories:true)
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

final class GameView: NSView {
    let runtime: Runtime; let renderer: Renderer
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
        if event.keyCode == 53 { NSApplication.shared.terminate(nil) }
        else if [36,49,76].contains(event.keyCode), !event.isARepeat { runtime.acknowledge(); needsDisplay = true }
    }
    override func mouseDown(with event: NSEvent) { runtime.acknowledge(); needsDisplay = true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

func arguments() throws -> (data: URL?, output: URL?, verify: Bool, tests: Bool) {
    let args = Array(CommandLine.arguments.dropFirst()); var i = 0
    var data: URL?, output: URL?; var verify = false, tests = false
    while i < args.count {
        switch args[i] {
        case "--verify": verify = true
        case "--self-test": tests = true
        case "--data", "--output":
            let key = args[i]; i += 1
            guard i < args.count else { throw EngineError.invalid("Missing value for \(key)") }
            if key == "--data" { data = URL(fileURLWithPath:args[i],isDirectory:true) }
            else { output = URL(fileURLWithPath:args[i],isDirectory:true) }
        default: throw EngineError.invalid("Unknown argument: \(args[i])")
        }; i += 1
    }
    return (data,output,verify,tests)
}

do {
    let options = try arguments()
    if options.tests { try selfTests(); exit(0) }
    guard let root = options.data ?? Bundle.main.resourceURL?.appendingPathComponent("GameData",isDirectory:true) else {
        throw EngineError.invalid("Use --data PATH or an app bundle containing Resources/GameData")
    }
    let data = try DataSet(root:root)
    let app = NSApplication.shared
    if options.verify {
        guard let output = options.output else { throw EngineError.invalid("--verify requires --output PATH") }
        app.setActivationPolicy(.prohibited)
        try verify(data,output:output)
    } else {
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate(); app.delegate = delegate
        let view = try GameView(data:data)
        let window = NSWindow(contentRect:view.frame,styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "영걸전 연구 엔진"; window.contentView = view; window.contentMinSize = NSSize(width:640,height:400)
        window.center(); delegate.window = window
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view); app.activate(ignoringOtherApps:true)
        app.run(); withExtendedLifetime(delegate) {}
    }
} catch {
    FileHandle.standardError.write(Data(("YeonggeoljeonEngine: \(error)\n").utf8)); exit(2)
}
