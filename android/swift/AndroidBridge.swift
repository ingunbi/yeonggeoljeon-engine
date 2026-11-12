// SPDX-License-Identifier: GPL-3.0-only
// C entry points the Android app calls through a small JNI layer. The game
// itself is the same engine and touch store as the iPad app; this file only
// turns its state into JSON and pixels and its inputs into method calls.
#if os(Android)
import Foundation

// MARK: Main-actor escape (Android has no main run loop; the app calls from one game thread)
private func onGameThread<T>(_ body:@MainActor () -> T) -> T {
    typealias Plain = () -> T
    return withoutActuallyEscaping(body) {escaping in unsafeBitCast(escaping,to:Plain.self)()}
}

private var store:IPadGameStore?
private var battleRenderer:AndroidBattleRenderer?
private var imageRegistry:[String:CGImage] = [:]
private var fieldBuffer:UnsafeMutablePointer<UInt8>?
private var imageBuffers:[String:UnsafeMutablePointer<UInt8>] = [:]
private var battleBuffer:UnsafeMutablePointer<UInt8>?
private var battleRevision = -1
private var lastBattleSize = (0,0)

private func keep(_ image:CGImage?) -> String? {
    guard let image else {return nil}
    let key = "i\(UInt(bitPattern:ObjectIdentifier(image).hashValue))"
    if imageRegistry[key] == nil {
        if imageRegistry.count > 400 {imageRegistry.removeAll();for (_,p) in imageBuffers {p.deallocate()};imageBuffers.removeAll()}
        imageRegistry[key] = image
    }
    return key
}
private func actionJSON(_ action:IPadAction) -> [String:Any] {
    ["id":action.id,"title":action.title,"subtitle":action.subtitle,"enabled":action.enabled]
}
private func panelJSON(_ panel:IPadPanel) -> [String:Any] {
    var value:[String:Any] = ["title":panel.title,"body":panel.body,"dialogue":panel.style == .dialogue,"actions":panel.actions.map(actionJSON)]
    if let key = keep(panel.portrait) {value["portrait"] = key}
    return value
}
private func sideJSON(_ side:IPadCombatSide) -> [String:Any] {
    var value:[String:Any] = ["name":side.name,"classLevel":side.classLevel,"valueLabel":side.valueLabel,"value":side.value,"troops":side.troops,
                              "maximum":side.maximum,"morale":side.morale,"extraLabel":side.extraLabel,"extraText":side.extraText]
    if let key = keep(side.portrait) {value["portrait"] = key}
    return value
}
private func cString(_ text:String) -> UnsafeMutablePointer<CChar> {
    let bytes = Array(text.utf8CString);let out = UnsafeMutablePointer<CChar>.allocate(capacity:bytes.count)
    out.initialize(from:bytes,count:bytes.count);return out
}
private func pointer(_ text:UnsafePointer<CChar>?) -> String {text.map {String(cString:$0)} ?? ""}

@_cdecl("yg_free") public func yg_free(_ pointer:UnsafeMutablePointer<CChar>?) {pointer?.deallocate()}

/// Creates the game. `data` holds the prepared GameData folder, `saves` the save folder.
@_cdecl("yg_create") public func yg_create(_ data:UnsafePointer<CChar>?,_ saves:UnsafePointer<CChar>?) -> Int32 {
    let dataURL = URL(fileURLWithPath:pointer(data),isDirectory:true),saveURL = URL(fileURLWithPath:pointer(saves),isDirectory:true)
    return onGameThread {
        let value = IPadGameStore(dataRoot:dataURL,saveRoot:saveURL,startsTimer:false,enablesAudio:true)
        store = value;value.setActive(true)
        return value.data == nil ? 0 : 1
    }
}
@_cdecl("yg_tick") public func yg_tick() {onGameThread {store?.tick()}}
@_cdecl("yg_set_active") public func yg_set_active(_ value:Int32) {onGameThread {store?.setActive(value != 0)}}
@_cdecl("yg_revision") public func yg_revision() -> Int32 {onGameThread {Int32(truncatingIfNeeded:store?.revision ?? 0)}}

@_cdecl("yg_state") public func yg_state() -> UnsafeMutablePointer<CChar>? {
    onGameThread {
        guard let game = store else {return cString("{}")}
        var state:[String:Any] = ["header":game.header,"status":game.status,"speed":game.speedFactor,
                                  "skipping":game.skipping,"auto":game.dialogueAuto,"started":game.host?.hasStarted == true,
                                  "fieldIsMap":game.fieldIsMap,"actions":game.actions.map(actionJSON)]
        if let message = game.error {state["error"] = message}
        if let prompt = game.prompt {state["prompt"] = panelJSON(prompt)}
        if let menu = game.menu {state["menu"] = panelJSON(menu)}
        if let banner = game.cueBanner {state["banner"] = ["text":banner.text,"waits":banner.waits] as [String:Any]}
        if let info = game.unitInfo {
            var unit:[String:Any] = ["name":info.name,"className":info.className,"level":info.level,"troops":info.troops,"maxTroops":info.maxTroops,
                                     "morale":info.morale,"mp":info.mp,"maxMP":info.maxMP,"terrain":info.terrain,"enemy":info.enemy,"confused":info.confused]
            if let key = keep(info.portrait) {unit["portrait"] = key}
            state["unit"] = unit
        }
        if let combat = game.combatState {
            var value:[String:Any] = ["left":sideJSON(combat.left),"right":sideJSON(combat.right),"lines":combat.lines,
                                      "gauges":combat.gauges.map {[$0.value,$0.maximum]}]
            if let notice = combat.notice {value["notice"] = notice}
            if let key = keep(combat.image) {value["image"] = key}
            state["combat"] = value
        }
        if let battle = game.session {
            // The map picture only changes by itself while an action plays or the source drives a phase.
            state["busy"] = !game.animator.isIdle || game.combatPlayer != nil || game.flow?.acceptsManualInput != true
            state["idle"] = Int(game.idlePhase);state["mode"] = "battle";state["battle"] = ["cols":battle.width,"rows":battle.height] as [String:Any]
        } else {state["mode"] = game.host?.hasStarted == true ? "field" : "title"}
        let data = (try? JSONSerialization.data(withJSONObject:state)) ?? Data("{}".utf8)
        return cString(String(decoding:data,as:UTF8.self))
    }
}

private func copyPixels(_ image:CGImage,into slot:inout UnsafeMutablePointer<UInt8>?,_ width:UnsafeMutablePointer<Int32>?,_ height:UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<UInt8> {
    slot?.deallocate()
    let out = UnsafeMutablePointer<UInt8>.allocate(capacity:max(1,image.pixels.count))
    image.pixels.withUnsafeBufferPointer {out.initialize(from:$0.baseAddress!,count:$0.count)}
    slot = out;width?.pointee = Int32(image.width);height?.pointee = Int32(image.height)
    return out
}
@_cdecl("yg_field_image") public func yg_field_image(_ width:UnsafeMutablePointer<Int32>?,_ height:UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<UInt8>? {
    onGameThread {
        guard let image = store?.fieldImage else {return nil}
        return copyPixels(image,into:&fieldBuffer,width,height)
    }
}
@_cdecl("yg_image") public func yg_image(_ key:UnsafePointer<CChar>?,_ width:UnsafeMutablePointer<Int32>?,_ height:UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<UInt8>? {
    onGameThread {
        let id = pointer(key)
        guard let image = imageRegistry[id] else {return nil}
        var slot = imageBuffers[id]
        let out = copyPixels(image,into:&slot,width,height)
        imageBuffers[id] = out;return out
    }
}
/// The battle map drawn at 32 pixels a cell. Returns nil when no battle is on.
@_cdecl("yg_battle_image") public func yg_battle_image(_ width:UnsafeMutablePointer<Int32>?,_ height:UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<UInt8>? {
    onGameThread {
        guard let game = store,let session = game.session,let data = game.data else {return nil}
        if battleRenderer == nil {battleRenderer = AndroidBattleRenderer()}
        guard let image = battleRenderer?.render(session:session,data:data,selectedSlot:game.selectedSlot,highlighted:game.highlighted,animation:game.animator,idlePhase:game.idlePhase) else {return nil}
        return copyPixels(image,into:&battleBuffer,width,height)
    }
}

// MARK: Inputs
@_cdecl("yg_perform") public func yg_perform(_ scope:Int32,_ id:UnsafePointer<CChar>?) {
    let name = pointer(id)
    onGameThread {
        guard let game = store else {return}
        let list:[IPadAction]
        switch scope {
        case 0:list = game.prompt?.actions ?? []
        case 1:list = game.menu?.actions ?? []
        default:list = game.actions
        }
        list.first {$0.id == name}?.perform()
    }
}
@_cdecl("yg_field_tap") public func yg_field_tap(_ x:Double,_ y:Double) {onGameThread {store?.fieldTapped(CGPoint(x:x,y:y))}}
@_cdecl("yg_field_scroll") public func yg_field_scroll(_ dx:Int32,_ dy:Int32) {onGameThread {store?.scrollField(tilesX:Int(dx),tilesY:Int(dy))}}
@_cdecl("yg_cell_tap") public func yg_cell_tap(_ x:Int32,_ y:Int32) {onGameThread {store?.cellTapped(GridPoint(x:Int(x),y:Int(y)))}}
@_cdecl("yg_advance_dialogue") public func yg_advance_dialogue() {onGameThread {store?.advanceDialogue()}}
@_cdecl("yg_toggle_skip") public func yg_toggle_skip() {onGameThread {store?.toggleSkip()}}
@_cdecl("yg_toggle_auto") public func yg_toggle_auto() {onGameThread {if let game = store {game.dialogueAuto.toggle();if game.dialogueAuto {game.skipping = false}}}}
@_cdecl("yg_cycle_speed") public func yg_cycle_speed() {onGameThread {store?.cycleSpeed()}}
@_cdecl("yg_show_menu") public func yg_show_menu() {onGameThread {store?.showMenu()}}
@_cdecl("yg_close_menu") public func yg_close_menu() {onGameThread {store?.closeMenu()}}
@_cdecl("yg_show_unit") public func yg_show_unit() {onGameThread {store?.showSelectedUnit()}}
@_cdecl("yg_skip_combat") public func yg_skip_combat() {onGameThread {store?.skipCombatHold()}}
@_cdecl("yg_end_combat") public func yg_end_combat() {onGameThread {store?.endCombat()}}
@_cdecl("yg_dismiss_banner") public func yg_dismiss_banner() {onGameThread {store?.dismissCueNotice()}}
@_cdecl("yg_clear_error") public func yg_clear_error() {onGameThread {store?.error = nil}}
@_cdecl("yg_audio_pull") public func yg_audio_pull(_ out:UnsafeMutablePointer<Float>?,_ count:Int32) {
    guard let out else {return}
    onGameThread {
        if let game = store {game.pullAudio(out,count:Int(count))} else {out.update(repeating:0,count:Int(count))}
    }
}
@_cdecl("yg_audio_rate") public func yg_audio_rate() -> Int32 {Int32(OPL2Chip.sampleRate)}
#endif
