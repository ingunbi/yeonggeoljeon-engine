// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Synthetic save/exit presentation; no game data, saves or persisted settings.
func canvasOverlayLayoutSelfTests(renderingTo output:URL? = nil) throws {
    if let output {try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)}
    var checks = 0
    func check(_ valid:Bool,_ message:String) throws {guard valid else {throw EngineError.invalid("Layout QA: "+message)};checks += 1}
    func render(_ view:CanvasOverlayView,name:String) throws {
        guard let output else {return}
        let width = Int(view.bounds.width),height = Int(view.bounds.height)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        let cg = NSGraphicsContext.current!.cgContext
        cg.setFillColor(CGColor(gray:0.10,alpha:1));cg.fill(view.bounds)
        cg.translateBy(x:0,y:view.bounds.height);cg.scaleBy(x:1,y:-1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext:cg,flipped:true)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))
    }
    let labels = ["저장 후 종료","저장 없이 종료","취소"]
    let explanation = "별도 한 칸에 현재 진행을 저장한 뒤 종료합니다. 기존 중단 저장은 덮어쓰며, 이어하기에 성공하면 소모됩니다. 진행 중인 행동·선택을 마친 뒤 저장합니다."
    for percent in [100,125,150] {
        var preferences = AppControlPreferences();preferences.textPercent = percent
        try AppControlRuntime.withPreferences(preferences) {
            for size in [CGSize(width:640,height:400),CGSize(width:960,height:600),CGSize(width:1440,height:900)] {
                let view = CanvasOverlayView(frame:CGRect(origin:.zero,size:size))
                view.viewport = CGRect(x:0,y:0,width:640,height:400)
                view.show(CanvasMenu(title:"게임을 종료하시겠습니까?",options:labels.map {.init(label:$0)},horizontal:true,cancellable:true,footer:explanation,onChoose:{_ in}))
                let panel = view.menuPanelRect!,description = view.menuDescriptionRect!,buttons = (0..<3).compactMap {view.menuOptionRect($0)}
                try check(buttons.count == 3 && buttons.allSatisfy {panel.contains($0)},"exit actions stay in panel")
                try check(buttons.allSatisfy {!description.intersects($0)},"exit description is separate from actions")
                for (index,button) in buttons.enumerated() {
                    let width = CanvasTheme.textWidth(labels[index],font:CanvasTheme.font(13,.bold))
                    try check(button.width >= width+31,"exit button keeps sixteen-pixel side padding")
                }
                let bodyHeight = ceil((explanation as NSString).boundingRect(with:CGSize(width:description.width,height:10000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:CanvasTheme.attributes(CanvasTheme.font(13),CanvasTheme.muted)).height)
                try check(description.height >= bodyHeight,"full exit explanation fits at each text scale")
                try render(view,name:"exit-\(percent)-\(Int(size.width))")
                view.viewport = CanvasOverlayView.fieldViewport
                view.show(CanvasSheet(portrait:nil,speaker:"게임 불러오기",line:"일반·중단·자동·원작 저장을 선택해 이어합니다.",badge:("",""),rows:[
                    .init(label:"중단 저장 · 1회 이어하기",value:"2026. 11. 9. 14:29",detail:.init(heading:"합성 전투",body:"중단한 지점부터 이어합니다. 성공하면 소모됩니다. 일반 저장과 백업에는 영향을 주지 않습니다.")),
                    .init(label:"일반 슬롯 1",value:"2026. 11. 9. 14:29"),.init(label:"일반 슬롯 2",value:"비어 있음"),
                    .init(label:"일반 슬롯 3",value:"진행 읽기 실패 · 파일 보존됨"),.init(label:"전투 시작",value:"2026. 11. 9. 14:29"),
                    .init(label:"더 긴 저장 목록 이름과 상태 설명",value:"긴 값도 제목에 겹쳐 그리지 않습니다")],mode:.list,hint:"↑↓ 이동 · Enter 선택 · Esc 뒤로",onChoose:{_ in}))
                for row in 0..<6 {
                    guard let boxes = view.sheetRowTextRects(row),let rect = view.sheetRowRect(row) else {continue}
                    try check(!boxes.label.intersects(boxes.value),"save row title and date own disjoint rectangles")
                    try check(rect.contains(boxes.label) && (boxes.value.isEmpty || rect.contains(boxes.value)),"both save fields stay within their row")
                }
                try render(view,name:"saves-\(percent)-\(Int(size.width))")
            }
        }
    }
    print("Canvas overlay layout self-tests passed: \(checks)")
}
