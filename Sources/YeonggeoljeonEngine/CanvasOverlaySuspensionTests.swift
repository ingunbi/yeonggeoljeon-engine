// SPDX-License-Identifier: GPL-3.0-only
import AppKit

func canvasOverlaySuspensionSelfTests() throws {
    var checks = 0
    func check(_ condition:Bool,_ reason:String) throws {
        guard condition else { throw EngineError.invalid("Overlay suspension regression: \(reason)") };checks += 1
    }
    let overlay = CanvasOverlayView(frame:CGRect(x:0,y:0,width:640,height:400))
    func key(_ code:UInt16) {
        overlay.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,
            windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!)
    }
    var chosen:[Int?] = []
    overlay.show(CanvasMenu(title:"Synthetic pending choice",options:[.init(label:"First"),.init(label:"Second")],cancellable:true) { chosen.append($0) })
    overlay.setSuspended(true)
    key(125);key(36);key(53)
    try check(chosen.isEmpty && overlay.selector?.selected == 0,"covered choice cannot navigate, accept or cancel")
    try check(!overlay.acceptsFirstResponder && overlay.active,"covered choice remains present without taking focus")
    overlay.setSuspended(false);key(125);key(36)
    try check(chosen.count == 1 && chosen[0] == 1 && !overlay.active,"resumed choice keeps its original callback")

    var lines = 0
    overlay.show(CanvasNotice(speaker:"Synthetic speaker",text:"A waiting line",portrait:nil) { lines += 1 })
    overlay.setSuspended(true);overlay.skipNotice();key(36)
    try check(lines == 0 && overlay.notice != nil,"covered dialogue is not acknowledged by skip or Enter")
    overlay.setSuspended(false);overlay.skipNotice()
    try check(lines == 1 && !overlay.active,"resuming dialogue permits its single original acknowledgement")

    var notices = 0
    let began = Date()
    overlay.show(CanvasNotice(speaker:"",text:"Synthetic timed result",portrait:nil,timeout:10) { notices += 1 })
    overlay.setSuspended(true,now:began)
    overlay.setSuspended(true,now:began.addingTimeInterval(60))
    overlay.advanceTimedNotice(now:began.addingTimeInterval(120))
    try check(notices == 0 && overlay.active,"timed message cannot expire while covered")
    overlay.setSuspended(false,now:began.addingTimeInterval(120))
    overlay.advanceTimedNotice(now:began.addingTimeInterval(125))
    try check(notices == 0,"repeat suspension preserves the first pause and remaining duration")
    overlay.advanceTimedNotice(now:began.addingTimeInterval(135))
    overlay.advanceTimedNotice(now:began.addingTimeInterval(140))
    try check(notices == 1 && !overlay.active,"expired message resumes and dismisses exactly once")

    var timedSheetAnswers:[Int?] = []
    let sheetStart = Date()
    overlay.show(CanvasSheet(portrait:nil,speaker:"",line:"Synthetic timed sheet",badge:("",""),rows:[],mode:.timed,
        onChoose:{ timedSheetAnswers.append($0) }))
    overlay.setSuspended(true,now:sheetStart)
    overlay.advanceTimedNotice(now:sheetStart.addingTimeInterval(30))
    overlay.setSuspended(false,now:sheetStart.addingTimeInterval(30))
    overlay.advanceTimedNotice(now:sheetStart.addingTimeInterval(31))
    try check(timedSheetAnswers.isEmpty,"timed sheet also retains its remaining duration")
    overlay.advanceTimedNotice(now:sheetStart.addingTimeInterval(34))
    try check(timedSheetAnswers.count == 1 && timedSheetAnswers[0] == 0,"timed sheet resumes its original continuation")

    weak var released:CanvasOverlayView?
    do {
        let temporary = CanvasOverlayView(frame:.zero);released = temporary
        temporary.show(CanvasNotice(speaker:"",text:"Timed",portrait:nil,timeout:10) {})
        temporary.setSuspended(true)
    }
    try check(released == nil,"a paused overlay is not retained by its timer")
    print("Canvas overlay suspension self-tests passed: \(checks)")
}
