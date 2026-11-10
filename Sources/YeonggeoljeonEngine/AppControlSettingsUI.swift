// SPDX-License-Identifier: GPL-3.0-only
import AppKit

enum AppControlSettingsUI {
    static func present(overlay:CanvasOverlayView,selected:Int = 0,onClose:@escaping()->Void) {
        let settings = OriginalSettings.current,controls = settings.controls
        var sheet = CanvasSheet(portrait:nil,speaker:"조작과 가독성",line:controls.recoveryNotices.isEmpty ? "화면별 키 · 범위 무늬 "+(controls.patternedRanges ? "켬" : "끔") : controls.recoveryNotices.joined(separator:" "),
            badge:("글자 크기","\(controls.textPercent)%"),rows:controls.bindings.map {binding in
                .init(label:binding.context.title+" · "+binding.command.title,value:binding.chord.label,
                    detail:.init(heading:binding.command.title,body:"선택하면 키를 바꾸거나 이 항목만 복원할 수 있습니다.\n검색·이름 입력 중에는 게임 명령이 실행되지 않습니다.",
                        list:["Command·Control 조합은 시스템·메뉴·빠른 진행용으로 예약되어 있습니다.","같은 화면에서 겹치는 키는 저장하지 않습니다.","범위 무늬: "+CanvasRangePattern.Kind.allCases.map(\.label).joined(separator:" / ")],facts:[("화면",binding.context.title),("현재 키",binding.chord.label)],rangePatternPreview:true))
            },selected:min(max(0,selected),max(0,controls.bindings.count-1)),mode:.list,buttons:["글자 크기","범위 무늬", "전체 복원","닫기"],
            hint:"Tab 버튼 · 새 키는 항목 선택 후 입력 · Esc 돌아가기",fullCanvas:true,onChoose:{index in
                guard let index,controls.bindings.indices.contains(index) else {onClose();return}
                let binding = controls.bindings[index]
                overlay.show(CanvasMenu(title:binding.context.title+" · "+binding.command.title,options:[.init(label:"새 키 입력"),.init(label:"이 항목 기본값"),.init(label:"취소")],cancellable:true) {choice in
                    do {
                        var value = OriginalSettings.current
                        if choice == 0,let chord = capture(title:binding.command.title,current:binding.chord.label) {try value.controls.set(binding.command,context:binding.context,chord:chord);OriginalSettings.current = value}
                        if choice == 1 {try value.controls.reset(binding.command,context:binding.context);OriginalSettings.current = value}
                        present(overlay:overlay,selected:index,onClose:onClose)
                    } catch {
                        overlay.show(CanvasNotice(speaker:"키를 지정할 수 없습니다",text:"\(error)",portrait:nil) {present(overlay:overlay,selected:index,onClose:onClose)})
                    }
                })
            })
        sheet.onButton = {button in
            var value = OriginalSettings.current
            switch button {
            case 0:
                let scales = AppControlPreferences.textPercents,index = scales.firstIndex(of:value.controls.textPercent) ?? 0
                value.controls.textPercent = scales[(index+1)%scales.count]
            case 1:value.controls.patternedRanges.toggle()
            case 2:value.controls = AppControlPreferences()
            default:onClose();return
            }
            OriginalSettings.current = value;present(overlay:overlay,selected:selected,onClose:onClose)
        }
        overlay.show(sheet)
    }
    private static func capture(title:String,current:String)->AppControlPreferences.Chord? {
        let alert = NSAlert();alert.messageText = title+"의 새 키";alert.informativeText = "현재: "+current+"\n새 키나 Shift·Option 조합을 누르고 확인하세요. 취소 버튼을 누르면 유지됩니다."
        let label = NSTextField(labelWithString:"새 키를 눌러 주세요.");label.frame = NSRect(x:0,y:0,width:340,height:28);alert.accessoryView = label
        alert.addButton(withTitle:"확인");alert.addButton(withTitle:"취소")
        var captured:AppControlPreferences.Chord?
        let monitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) {event in
            guard event.window === alert.window else {return event}
            let chord = AppControlPreferences.Chord(event);captured = chord
            label.stringValue = chord.valid ? chord.label : "Command·Control 조합은 지정할 수 없습니다."
            return nil
        }
        defer {if let monitor {NSEvent.removeMonitor(monitor)}}
        guard alert.runModal() == .alertFirstButtonReturn else {return nil}
        return captured
    }
}
