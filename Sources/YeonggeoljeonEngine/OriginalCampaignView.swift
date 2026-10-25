// SPDX-License-Identifier: GPL-3.0-only
import AppKit

final class OriginalCampaignView:NSView,EngineTimedView {
    let host:OriginalCampaignHost
    let renderer:Renderer
    private var timer:Timer?
    private var errorText:String?
    private var presenting = false
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    init(data:DataSet) throws {
        let c = Calendar.current.dateComponents([.day,.hour,.minute,.second],from:Date())
        func bcd(_ n:Int?) -> UInt8 { let v = n ?? 0;return UInt8(((v/10)<<4)|(v%10)) }
        host = try OriginalCampaignHost(data:data,rng:OriginalRNG.clockSeed(dayByte:bcd(c.day),hourByte:bcd(c.hour),minuteByte:bcd(c.minute),secondByte:bcd(c.second)))
        renderer = try Renderer(data)
        super.init(frame:CGRect(x:0,y:0,width:960,height:640))
        timer = Timer.scheduledTimer(withTimeInterval:1.0/60,repeats:true) { [weak self] _ in self?.tick() }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func stop() { timer?.invalidate();timer = nil }
    private func tick() {
        guard !presenting,errorText == nil else { return }
        do {
            try host.advance(microseconds:16_667)
            needsDisplay = true
            if let choice = host.choice,choice.kind == "choice-skip" || !choice.options.isEmpty { present(choice) }
            if host.saveRequest != nil { presentSave() }
        } catch { errorText = "\(error)";needsDisplay = true }
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
    private func presentSave() {
        presenting = true;defer { presenting = false }
        let alert = NSAlert();alert.messageText = "현재 자체 엔진 상태를 내보낼까요?"
        alert.informativeText = "원작 저장 파일과 다른 연구용 JSON 형식입니다. 이어하기 복원은 아직 지원하지 않습니다."
        alert.addButton(withTitle:"저장 없이 계속");alert.addButton(withTitle:"상태 내보내기…")
        let result = alert.runModal()
        do {
            if result == .alertSecondButtonReturn {
                let panel = NSSavePanel();panel.nameFieldStringValue = "engine-state.json"
                guard panel.runModal() == .OK,let url = panel.url else { return }
                let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                try encoder.encode(host.snapshot()).write(to:url,options:.atomic)
            }
            try host.completeSaveRequest()
        } catch { errorText = "\(error)" }
    }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.black.setFill();bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = min(bounds.width/640,(bounds.height-40)/400)
        do {
            let frame = try renderer.render(host.stage)
            Renderer.image(frame.image,in:CGRect(x:(bounds.width-640*scale)/2,y:0,width:640*scale,height:400*scale),context:context)
        } catch { errorText = "\(error)" }
        let text:String
        if let error = errorText { text = error }
        else if let choice = host.choice { text = "원작 선택지 입력 대기 · \(choice.id)" }
        else { text = host.status }
        (text as NSString).draw(in:CGRect(x:12,y:bounds.height-35,width:bounds.width-24,height:32),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.lightGray])
    }
    override func keyDown(with event:NSEvent) {
        if event.keyCode == 53 { window?.performClose(nil);return }
        if [36,49,76].contains(event.keyCode),!event.isARepeat {
            do { try host.acknowledge() } catch { errorText = "\(error)" };needsDisplay = true
        }
    }
    override func mouseDown(with event:NSEvent) {
        do {
            if host.waiting != nil,host.vm.state.packedMap>>12 != 1 {
                let scale = min(bounds.width/640,(bounds.height-40)/400)
                let p = convert(event.locationInWindow,from:nil)
                let x = (p.x-(bounds.width-640*scale)/2)/scale,y = p.y/scale,v = host.stage.viewport
                let actors = host.stage.actors.values.sorted{$0.registration > $1.registration}
                if let actor = actors.first(where:{ actor in
                    let rect = CGRect(x:v[0]+16*actor.position.x-host.stage.camera[0],y:v[1]+16*actor.position.y+8*(actor.position.x&1)-24-host.stage.camera[1],width:32,height:40)
                    return rect.contains(CGPoint(x:x,y:y))
                }) { _ = try host.dispatch(OriginalCampaignEvent(kind:3,arguments:[actor.person])) }
            } else { try host.acknowledge() }
        } catch { errorText = "\(error)" }
        needsDisplay = true
    }
}
