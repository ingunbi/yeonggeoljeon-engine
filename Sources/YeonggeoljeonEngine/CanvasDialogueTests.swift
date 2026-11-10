// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Must run first in a fresh --self-test process: persisted non-default reading
/// settings used to notify an overlay while shared was still initializing.
func dialoguePaceStartupSelfTests() throws {
    var checks = 0
    func check(_ condition:Bool,_ reason:String) throws {
        guard condition else { throw EngineError.invalid("Dialogue pace startup regression: \(reason)") };checks += 1
    }
    let defaults = UserDefaults.standard,domain = UserDefaults.argumentDomain
    let previous = defaults.volatileDomain(forName:domain)
    func stage(_ settings:OriginalSettings) throws {
        var values = previous
        values["originalSettings"] = try JSONEncoder().encode(settings)
        defaults.setVolatileDomain(values,forName:domain)
    }
    var initial = OriginalSettings();initial.autoAdvance = true;initial.autoSpeed = 2
    try stage(initial)
    // Register a real overlay before touching the singleton, matching app startup.
    let overlay = CanvasOverlayView(frame:CGRect(x:0,y:0,width:640,height:400))
    var observed:[(Bool,Int)] = []
    let observer = NotificationCenter.default.addObserver(forName:DialoguePace.changed,object:nil,queue:.main) { _ in
        let pace = DialoguePace.shared
        observed.append((pace.auto,pace.speed))
    }
    defer {
        NotificationCenter.default.removeObserver(observer)
        defaults.setVolatileDomain(previous,forName:domain)
        NotificationCenter.default.post(name:OriginalSettings.changed,object:nil)
        withExtendedLifetime(overlay) {}
    }
    let pace = DialoguePace.shared
    try check(pace.auto && pace.speed == 2,"cold startup loads non-default values without recursive initialization")
    try check(observed.isEmpty,"initial loading does not publish a partially initialized singleton")

    var updated = initial;updated.autoAdvance = false;updated.autoSpeed = 0
    try stage(updated)
    NotificationCenter.default.post(name:OriginalSettings.changed,object:nil)
    try check(!pace.auto && pace.speed == 0,"subsequent settings reload updates both values")
    try check(observed.count == 1 && observed[0].0 == false && observed[0].1 == 0,
              "reload publishes exactly once after both values are ready")
    NotificationCenter.default.post(name:OriginalSettings.changed,object:nil)
    try check(observed.count == 1,"unchanged settings do not emit duplicate pace updates")
    print("Dialogue pace startup self-tests passed: \(checks)")
}

/// Synthetic dialogue transitions, including the final line before a selector.
func canvasDialogueSelfTests() throws {
    var checks = 0
    func check(_ condition:Bool,_ reason:String) throws {
        guard condition else { throw EngineError.invalid("Canvas dialogue regression: \(reason)") };checks += 1
    }
    let pace = DialoguePace.shared,previousSkip = DialoguePace.shared.skipping
    defer { pace.skipping = previousSkip }
    pace.skipping = false
    let overlay = CanvasOverlayView(frame:CGRect(x:0,y:0,width:640,height:400))
    let longLine = String(repeating:"synthetic text ",count:100)
    var dismissed = 0
    overlay.show(CanvasNotice(speaker:"synthetic",text:longLine,onDismiss:{ dismissed += 1 }))
    try check((overlay.visibleNoticeCharacterCount ?? longLine.count) < longLine.count,
              "ordinary dialogue still reveals gradually")
    pace.skipping = true
    try check(overlay.visibleNoticeCharacterCount == longLine.count && dismissed == 0,
              "enabling skip reveals the current line without acknowledging it")
    pace.skipping = false
    try check(overlay.visibleNoticeCharacterCount == longLine.count && dismissed == 0,
              "stopping skip cannot rewind an already revealed line to blank")
    overlay.skipNotice()
    try check(dismissed == 1 && overlay.notice == nil,"the revealed line acknowledges exactly once")

    pace.skipping = true
    var completed:[Int] = []
    let lines = (0..<7).map { "synthetic opening line \($0)" }
    func show(_ index:Int) {
        if index == lines.count {
            overlay.show(CanvasMenu(title:"synthetic conditions",options:[.init(label:"continue")]) { _ in })
        } else {
            overlay.show(CanvasNotice(speaker:"speaker \(index)",text:lines[index],onDismiss:{
                completed.append(index);show(index+1)
            }))
        }
    }
    show(0)
    for index in lines.indices {
        try check(overlay.notice?.text == lines[index] && overlay.visibleNoticeCharacterCount == lines[index].count,
                  "skipped line \(index) is fully visible on its very first frame")
        try check(completed == Array(0..<index),"a new line waits for its own acknowledgement")
        overlay.skipNotice()
    }
    try check(completed == Array(lines.indices) && overlay.notice == nil && overlay.selector != nil,
              "the final line hands off to the next selector without leaving a stale bubble")
    pace.skipping = false
    overlay.skipNotice()
    try check(overlay.selector != nil && completed.count == lines.count && overlay.visibleNoticeCharacterCount == nil,
              "ending skip preserves the decision and does not replay a stale callback")
    print("Canvas dialogue self-tests passed: \(checks)")
}
