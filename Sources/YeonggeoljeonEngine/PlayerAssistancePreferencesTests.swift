// SPDX-License-Identifier: GPL-3.0-only
import AppKit

func playerAssistancePreferencesSelfTests() throws {
    var checks = 0
    func check(_ value:@autoclosure() throws -> Bool,_ message:String) throws {guard try value() else {throw EngineError.invalid("Player assistance regression: "+message)};checks += 1}
    func rejects(_ body:() throws -> Void) -> Bool {do {try body();return false} catch {return true}}
    func key(_ code:UInt16,_ flags:NSEvent.ModifierFlags = []) -> NSEvent {NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!}
    let encoder = JSONEncoder(),decoder = JSONDecoder()
    var controls = AppControlPreferences()
    try check(try decoder.decode(AppControlPreferences.self,from:Data("{}".utf8)) == controls,"old preferences receive supported default controls")
    controls.textPercent = 150;controls.patternedRanges = true
    try controls.set(.log,context:.battle,chord:.init(keyCode:12))
    try check(try decoder.decode(AppControlPreferences.self,from:encoder.encode(controls)) == controls,"custom controls and legibility choices round-trip")
    try check(controls.remappedEvent(key(12),context:.battle)?.keyCode == 37 && controls.remappedEvent(key(37),context:.battle) == nil,"the new key works and the replaced key stops invoking the old action")
    let before = controls
    try check(rejects {try controls.set(.log,context:.battle,chord:.init(keyCode:6))} && controls == before,"colliding battle shortcuts reject atomically")
    try check(rejects {try controls.set(.log,context:.battle,chord:.init(keyCode:12,modifiers:4))},"Command and Control are reserved")
    try check(controls.remappedEvent(key(12,.command),context:.battle) == nil && controls.remappedEvent(key(12),context:.textInput) == nil,"OS shortcuts and text typing are never treated as game commands")
    try check(controls.remappedEvent(key(48,.shift),context:.battle)?.modifierFlags.contains(.shift) == true,"Shift-Tab retains reverse traversal")
    try check(controls.remappedEvent(key(2,.shift),context:.battle)?.modifierFlags.contains(.shift) == true,"Shift-D retains threat clear semantics")
    try check(controls.command(for:key(49),context:.list) == .confirm && controls.command(for:key(49),context:.battle) == .wait,"Space confirm and battle wait have different contexts")
    try check(rejects {try controls.set(.focusButtons,context:.list,chord:.init(keyCode:49))},"default confirm aliases participate in collision detection")
    try check(controls.command(for:key(45),context:.battle) == .battleAnnotations && controls.command(for:key(17),context:.battle) == .areaStrategyAdvice,"new battle helper keys participate in the same mapping")
    let malformed = try decoder.decode(AppControlPreferences.self,from:Data("{\"textPercent\":999,\"bindings\":\"broken\"}".utf8))
    try check(malformed.textPercent == 100 && malformed.bindings == AppControlPreferences.defaults && !malformed.recoveryNotices.isEmpty,"corrupt preferences recover with an explanation")
    let future = try decoder.decode(AppControlPreferences.self,from:Data("{\"format\":99,\"textPercent\":150}".utf8))
    try check(future.textPercent == 100 && !future.recoveryNotices.isEmpty,"unknown preference version does not apply arbitrary bindings")
    try AppControlRuntime.withPreferences(controls) {
        let samples = CanvasRangePattern.Kind.allCases.map {kind -> Data in
            let bitmap = CGContext(data:nil,width:32,height:32,bitsPerComponent:8,bytesPerRow:128,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            bitmap.setFillColor(CGColor(gray:0.3,alpha:1));bitmap.fill(CGRect(x:0,y:0,width:32,height:32))
            CanvasRangePattern.draw(kind:kind,in:CGRect(x:0,y:0,width:32,height:32),context:bitmap)
            return Data(bytes:bitmap.data!,count:4096)
        }
        try check(Set(samples).count == 4,"four range patterns remain distinct on an identical monochrome background")
        let overlay = CanvasOverlayView(frame:CGRect(x:0,y:0,width:640,height:400))
        var called = false
        let body = Array(repeating:"긴 상세 설명은 모든 줄에 접근할 수 있어야 합니다.",count:35).joined(separator:"\n")
        overlay.show(CanvasSheet(portrait:nil,speaker:"150% 글자 검사",line:"확대 글자와 긴 목록",badge:("",""),rows:(0..<40).map {.init(label:"합성 장수 \($0)",value:"아직 사용하지 않음",detail:.init(heading:"길게 읽기",body:body))},mode:.list,buttons:["보기 바꾸기","비교 후보 변경","되돌아가기","모든 값 초기화"],hint:"PageUp·PageDown으로 상세를 읽습니다.",fullCanvas:true,onButton:{_ in called = true},onChoose:{_ in called = true}))
        let panel = overlay.sheetPanelRect!
        let buttons = (0..<4).compactMap {overlay.sheetButtonRect($0)}
        try check(buttons.count == 4 && buttons.allSatisfy {panel.contains($0)},"150 percent buttons wrap inside the canvas")
        try check(buttons.enumerated().allSatisfy {index,rect in buttons.enumerated().allSatisfy {$0.offset == index || !rect.intersects($0.element)}},"wrapped footer buttons never overlap")
        let firstRow = overlay.sheetRowRect(0)!,detail = overlay.sheetDetailViewport!
        try check(panel.contains(firstRow) && panel.contains(detail) && firstRow.height >= 50,"expanded rows and detail viewport stay within their panel")
        overlay.keyDown(with:key(119));try check(overlay.detailScroll > 0 && !called,"End reveals long details without confirming an action")
        overlay.keyDown(with:key(115));try check(overlay.detailScroll == 0,"Home returns to the detail beginning")
        for _ in 0..<39 {overlay.keyDown(with:key(125))}
        try check(overlay.sheetRowRect(39) != nil && overlay.sheetRowRect(0) == nil && !called,"keyboard navigation reaches rows outside the enlarged visible page")
        overlay.keyDown(with:key(53));try check(called && !overlay.active,"cancel closes only the reference sheet")
    }
    var tutorial = TutorialGuidance.Preferences()
    var context = TutorialGuidance.Context(safeToPresent:false,selectingAreaStrategy:true)
    try check(TutorialGuidance.next(context:context,preferences:tutorial) == nil,"tutorials yield to dialogue animation and save overlays")
    context.safeToPresent = true
    try check(TutorialGuidance.next(context:context,preferences:tutorial) == .areaStrategy,"a current safe situation offers its relevant topic")
    tutorial.acknowledge(.areaStrategy)
    try check(TutorialGuidance.next(context:context,preferences:tutorial) == nil,"acknowledged topics do not repeat")
    context.selectingAreaStrategy = false;context.mayCancelMove = true
    try check(TutorialGuidance.next(context:context,preferences:tutorial) == .moveCancellation,"old situations are not replayed after the boundary changes")
    tutorial.acknowledge(.moveCancellation,mute:true)
    try check(try decoder.decode(TutorialGuidance.Preferences.self,from:encoder.encode(tutorial)) == tutorial,"tutorial seen and muted choices round-trip independently of game progress")
    tutorial.reset();try check(tutorial.seen.isEmpty && tutorial.muted.isEmpty,"all guidance can be enabled again")
    tutorial.enabled = false;try check(TutorialGuidance.next(context:context,preferences:tutorial) == nil,"turning guidance off preserves the same input context")
    let identity = try SourceCatalogIdentity.digest(["synthetic":"event source"])
    let completion = ReviewedEventHints.Completion(recordID:"synthetic-record",sourceOffset:30,opcode:19,status:5)
    let hint = ReviewedEventHints.Hint(id:"synthetic-event",battleID:"0:0:5",lightText:"가벼운 합성 힌트",detailedText:"검증한 합성 조건",conditions:[.turnAtLeast(3),.visiblePersonAt(person:1,x:2,y:3)],evidence:[.init(relativeFile:"synthetic.bin",byteOffset:10,byteLength:8,reviewNote:"합성 입력 검토")],publicTargetPerson:1,completion:completion)
    let catalog = ReviewedEventHints.Catalog(sourceIdentity:identity,reviewed:true,hints:[hint]);try catalog.validate()
    var hintContext = ReviewedEventHints.Context(sourceIdentity:identity,battleID:"0:0:5",turn:3)
    let initial = hintContext
    try check(ReviewedEventHints.project(catalog:catalog,context:hintContext,level:.off,progress:nil).entries.isEmpty,"default-off reveals no event existence or location")
    let light = ReviewedEventHints.project(catalog:catalog,context:hintContext,level:.light,progress:nil).entries[0]
    try check(light.text == hint.lightText && light.conditions.isEmpty && light.judgment == nil && light.target == nil,"light hints do not leak detailed conditions or locations")
    try check(ReviewedEventHints.project(catalog:catalog,context:hintContext,level:.detailed,progress:nil).entries[0].judgment == .unknown,"a missing public person is unknown rather than guessed absent")
    hintContext.visiblePeople[1] = .init(x:2,y:3)
    let detailed = ReviewedEventHints.project(catalog:catalog,context:hintContext,level:.detailed,progress:nil).entries[0]
    try check(detailed.judgment == .met && detailed.target == .init(x:2,y:3) && !detailed.completed,"meeting projected conditions neither executes nor completes an event")
    hintContext.turn = 2;try check(ReviewedEventHints.project(catalog:catalog,context:hintContext,level:.detailed,progress:nil).entries[0].judgment == .unmet,"known unmet conditions are distinct from unknown")
    hintContext.battleID = "1:0:5";try check(ReviewedEventHints.project(catalog:catalog,context:hintContext,level:.detailed,progress:nil).entries.isEmpty,"reused map identities cannot show another chapter's event")
    hintContext = initial;hintContext.sourceIdentity = String(repeating:"b",count:64)
    try check(ReviewedEventHints.project(catalog:catalog,context:hintContext,level:.detailed,progress:nil).entries.isEmpty,"source mismatch blocks every catalog hint")
    var progress = ReviewedEventHints.Progress(sourceIdentity:identity)
    let saved = progress
    let returned = OriginalCampaignInterpreterReturn(recordID:"synthetic-record",sourceOffset:30,opcode:19,status:5)
    let completed = ReviewedEventHints.completedIDs(catalog:catalog,sourceIdentity:identity,battleID:"0:0:5",returned:returned)
    try check(completed == [hint.id],"only the exact reviewed committed terminal return matches completion")
    try check(ReviewedEventHints.completedIDs(catalog:catalog,sourceIdentity:identity,battleID:"0:0:5",returned:.init(recordID:returned.recordID,sourceOffset:29,opcode:51,status:1)).isEmpty,"intermediate duel display completion is not event completion")
    progress.recordCompleted(hint.id);progress.recordCompleted(hint.id)
    try check(progress.completed == [hint.id] && saved.completed.isEmpty,"completion is deduplicated and older snapshots cannot inherit later discovery")
    try check(try decoder.decode(ReviewedEventHints.Progress.self,from:encoder.encode(progress)) == progress,"event discovery is a snapshot value")
    var invalid = catalog;invalid.reviewed = false
    try check(rejects {try invalid.validate()} && ReviewedEventHints.project(catalog:invalid,context:initial,level:.detailed,progress:nil).entries.isEmpty,"unreviewed catalogs cannot enter the hint UI")
    try check(try decoder.decode(ReviewedEventHints.Catalog.self,from:encoder.encode(catalog)) == catalog,"synthetic reviewed catalogs round-trip")
    var hintExtras = CampaignExtras();hintExtras.eventHints = progress
    hintExtras.retryJourney = CampaignJourneyCheckpoint(journal:hintExtras.journal,dialogueHistory:hintExtras.dialogueHistory,eventHints:progress)
    var hintSave = try nativeSaveTestResume(money:10);hintSave.extras = hintExtras
    let hintRestored = try decoder.decode(OriginalCampaignResume.self,from:encoder.encode(hintSave))
    try check(hintRestored.extras?.eventHints == progress && hintRestored.extras?.retryJourney?.eventHints == progress,
              "hint discovery and retry boundary share the same native save transaction")
    let legacyExtras = try decoder.decode(CampaignExtras.self,from:Data("{}".utf8))
    try check(legacyExtras.eventHints == nil,"an old save cannot inherit discoveries from the current game")
    var boundedProgress = progress
    for index in 0..<1030 {boundedProgress.recordCompleted("synthetic-\(index)")}
    try boundedProgress.validate()
    try check(boundedProgress.discovered.count == 1024 && boundedProgress.completed.count == 1024,
              "successive local catalogs cannot exceed the saved discovery bound")
    let record = OriginalCampaignRecord(id:"synthetic-record",chapter:0,member:0,block:0,ordinal:0,kind:3,inverted:false,rawKind:3,
        words:[7,0,0],group:.init(base:0,count:1,repeating:true),instructions:[
            .init(opcode:19,offset:30,kind:"next-phase",arguments:[],commands:[])])
    let eventVM = try CampaignVM(program:.init(format:1,records:[record],sourceDigest:identity))
    let beforeQuery = eventVM.snapshot()
    _ = ReviewedEventHints.project(catalog:catalog,context:hintContext,level:.detailed,progress:progress)
    try check(eventVM.snapshot() == beforeQuery,"projecting a hint never dispatches a source event")
    try check(try !eventVM.queryInvocation(event:.init(kind:3,arguments:[99])),"an unmet synthetic source predicate is not invoked")
    try check(try eventVM.queryInvocation(event:.init(kind:3,arguments:[7])),"a matching synthetic source predicate begins normally")
    guard case .invocationReturn(let committed) = try eventVM.advance() else {throw EngineError.invalid("Synthetic event did not commit its terminal return")}
    try check(ReviewedEventHints.completedIDs(catalog:catalog,sourceIdentity:identity,battleID:"0:0:5",returned:committed) == [hint.id],
              "completion uses the committed synthetic VM return rather than UI projection")
    print("Player assistance preferences self-tests passed: \(checks)")
}
