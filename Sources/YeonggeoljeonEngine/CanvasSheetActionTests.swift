// SPDX-License-Identifier: GPL-3.0-only
import AppKit

func canvasSheetActionSelfTests() throws {
    var checks = 0
    func check(_ condition:Bool,_ reason:String) throws {
        guard condition else { throw EngineError.invalid("Sheet action regression: \(reason)") };checks += 1
    }
    let overlay = CanvasOverlayView(frame:CGRect(x:0,y:0,width:640,height:400))
    var rows:[Int?] = [],actions:[Int] = []
    func key(_ code:UInt16,shift:Bool = false) {
        overlay.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:shift ? [.shift] : [],
            timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!)
    }
    func show(_ mode:CanvasSheet.Mode = .list,actionsEnabled:Bool = true) {
        rows = [];actions = []
        overlay.show(CanvasSheet(portrait:nil,speaker:"비교",line:"읽기 후 확정",badge:("",""),
            rows:[.init(label:"능력"),.init(label:"책략")],mode:mode,buttons:["전직","취소"],
            onButton:actionsEnabled ? { actions.append($0) } : nil,onChoose:{ rows.append($0) }))
    }
    show();key(36)
    try check(rows == [0] && actions.isEmpty,"Enter on a comparison row never confirms a consuming action")
    show();key(48);key(36)
    try check(actions == [0] && rows.isEmpty && !overlay.active,"Tab explicitly focuses confirm, invoked once")
    show();key(48);key(48);key(36)
    try check(actions == [1] && rows.isEmpty,"second footer action remains reachable")
    show();key(48,shift:true);key(36)
    try check(actions == [1],"Shift-Tab starts at cancel")
    show();key(48);key(48,shift:true);key(36)
    try check(rows == [0] && actions.isEmpty,"returning from footer to list restores read-only Enter")
    show();key(48);key(125);key(36)
    try check(rows == [1] && actions.isEmpty,"browsing rows leaves action focus")
    show();key(48);key(53)
    try check(rows.count == 1 && rows[0] == nil && actions.isEmpty,"Escape cancels without invoking confirm")
    show();key(48);key(124);key(36)
    try check(actions == [1],"arrow keys choose cancel after focusing actions")
    show(actionsEnabled:false);key(48);key(36)
    try check(rows == [0] && actions.isEmpty,"ordinary lists keep their old keyboard behavior")
    show(.buttons);key(36)
    try check(rows == [0] && actions.isEmpty,"legacy button-only sheets retain their own callback")
    var selectedAction:(Int,Int)?
    overlay.show(CanvasSheet(portrait:nil,speaker:"test",line:"",badge:("",""),rows:[.init(label:"a"),.init(label:"b")],mode:.list,
        buttons:["choose"],onRowButton:{ selectedAction = ($0,$1) },onChoose:{ _ in }))
    key(125);key(48);key(36)
    try check(selectedAction?.0 == 0 && selectedAction?.1 == 1 && !overlay.active,"row action receives the current browsed row after closing")
    print("Canvas sheet action self-tests passed: \(checks)")
}
