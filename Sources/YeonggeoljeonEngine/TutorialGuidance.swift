// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// App guidance observes the current input boundary; it never queues a game
/// command or keeps a stale pointer into a previous battle or selection.
enum TutorialGuidance {
    enum Topic:String,Codable,CaseIterable {
        case areaStrategy,confusion,moveCancellation,unavailableCommand,recovery
        var title:String {switch self {case .areaStrategy:return "사거리와 적용 범위";case .confusion:return "부대 상태 살펴보기";case .moveCancellation:return "이동 후 취소";case .unavailableCommand:return "명령을 쓸 수 없는 이유";case .recovery:return "현재 가능한 회복 수단"}}
        var destination:Destination {switch self {case .areaStrategy:return .strategies;case .confusion:return .conditions;case .moveCancellation:return .controls;case .unavailableCommand:return .refusal;case .recovery:return .recovery}}
        func body(controls:AppControlPreferences = AppControlRuntime.current) -> String {
            switch self {
            case .areaStrategy:return "사거리는 대상을 고를 수 있는 칸이고, 적용 범위는 선택한 대상 주변에서 효과를 받는 칸입니다. 책략 설명의 두 격자를 함께 확인하세요. 실제 대상과 사용 조건은 선택 화면에서 다시 확인할 수 있습니다."
            case .confusion:return "상태가 붙은 부대는 현재 행동 제한과 회복 방법을 확인할 수 있습니다. 상태 설명(\(controls.shortcutLabel(command:.conditions,context:.battle)))을 열어 해당 부대에 표시된 상태를 살펴보세요."
            case .moveCancellation:return "지금은 이동을 확정하기 전으로 되돌릴 수 있는 단계입니다. 취소(\(controls.shortcutLabel(command:.cancel,context:.battle))) 후 도착 칸을 다시 고를 수 있습니다. 공격이나 책략 등 행동을 확정한 뒤에는 같은 취소가 되지 않습니다."
            case .unavailableCommand:return "사용할 수 없는 명령은 이유를 확인한 뒤 다시 선택할 수 있습니다. MP·거리·지형·상태 등 현재 화면에 표시되는 제한을 살펴보세요. 이 안내를 닫아도 명령은 실행되지 않습니다."
            case .recovery:return "회복 수단(\(controls.shortcutLabel(command:.recovery,context:.battle)))은 현재 동료의 책략과 소지품을 모아 보여 줍니다. 보유 여부와 지금 사용할 수 있는지는 서로 다를 수 있으니 사용 조건도 확인하세요."
            }
        }
    }
    enum Destination {case strategies,conditions,controls,refusal,recovery}
    struct Preferences:Codable,Equatable {
        var enabled = true
        var seen:[Topic] = []
        var muted:[Topic] = []
        init() {}
        private enum CodingKeys:String,CodingKey {case enabled,seen,muted}
        init(from decoder:Decoder) throws {
            let c = try decoder.container(keyedBy:CodingKeys.self)
            enabled = (try? c.decodeIfPresent(Bool.self,forKey:.enabled)) ?? true
            seen = ((try? c.decodeIfPresent([String].self,forKey:.seen)) ?? []).compactMap(Topic.init(rawValue:))
            muted = ((try? c.decodeIfPresent([String].self,forKey:.muted)) ?? []).compactMap(Topic.init(rawValue:))
            seen = Topic.allCases.filter {seen.contains($0)};muted = Topic.allCases.filter {muted.contains($0)}
        }
        mutating func acknowledge(_ topic:Topic,mute:Bool = false) {if !seen.contains(topic) {seen.append(topic)};if mute && !muted.contains(topic) {muted.append(topic)}}
        mutating func reset() {seen = [];muted = []}
    }
    struct Context:Equatable {
        /// Must be an idle player-command boundary, without a dialogue,
        /// animation, skip, practice replay, save dialog, or other overlay.
        var safeToPresent:Bool
        var selectingAreaStrategy = false
        var confusedPublicUnit = false
        var mayCancelMove = false
        var unavailableReason:String? = nil
        var recoveryUseful = false
        var activeTopics:[Topic] {
            var values:[Topic] = []
            if selectingAreaStrategy {values.append(.areaStrategy)}
            if confusedPublicUnit {values.append(.confusion)}
            if mayCancelMove {values.append(.moveCancellation)}
            if let reason = unavailableReason,!reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {values.append(.unavailableCommand)}
            if recoveryUseful {values.append(.recovery)}
            return values
        }
    }
    static func next(context:Context,preferences:Preferences) -> Topic? {
        guard context.safeToPresent,preferences.enabled else {return nil}
        return context.activeTopics.first {!preferences.seen.contains($0) && !preferences.muted.contains($0)}
    }
}

#if canImport(AppKit)
enum TutorialGuidanceUI {
    static func present(_ topic:TutorialGuidance.Topic,overlay:CanvasOverlayView,reason:String? = nil,
                        onDetails:@escaping(TutorialGuidance.Destination)->Void,onClose:@escaping()->Void) {
        let body = topic.body()+((topic == .unavailableCommand && reason != nil) ? "\n\n현재 제한: "+(reason ?? "") : "")
        overlay.show(CanvasSheet(portrait:nil,speaker:"상황별 도움말",line:topic.title,badge:("",""),rows:[],mode:.buttons,
            detail:.init(heading:topic.title,body:body),buttons:["알겠습니다","다시 보지 않기","자세히","닫기"],fullCanvas:true,onChoose:{choice in
                var settings = OriginalSettings.current;settings.tutorials.acknowledge(topic,mute:choice == 1);OriginalSettings.current = settings
                if choice == 2 {onDetails(topic.destination)} else {onClose()}
            }))
    }
    static func library(overlay:CanvasOverlayView,selected:Int = 0,onDetails:@escaping(TutorialGuidance.Destination)->Void,onClose:@escaping()->Void) {
        let prefs = OriginalSettings.current.tutorials
        let rows = TutorialGuidance.Topic.allCases.map {topic in CanvasSheet.Row(label:topic.title,value:prefs.muted.contains(topic) ? "끔" : prefs.seen.contains(topic) ? "읽음" : "아직 읽지 않음",detail:.init(heading:topic.title,body:topic.body()))}
        overlay.show(CanvasSheet(portrait:nil,speaker:"상황별 초보 안내",line:"안내를 다시 읽거나 표시 이력을 초기화할 수 있습니다.",badge:("자동 안내",prefs.enabled ? "켬" : "끔"),rows:rows,selected:selected,mode:.list,buttons:[prefs.enabled ? "자동 안내 끄기" : "자동 안내 켜기","이력 초기화","돌아가기"],fullCanvas:true,onRowButton:{button,row in
            var settings = OriginalSettings.current
            if button == 0 {settings.tutorials.enabled.toggle()} else if button == 1 {settings.tutorials.reset()} else {onClose();return}
            OriginalSettings.current = settings;library(overlay:overlay,selected:row,onDetails:onDetails,onClose:onClose)
        },onChoose:{index in
            guard let index,TutorialGuidance.Topic.allCases.indices.contains(index) else {onClose();return}
            present(TutorialGuidance.Topic.allCases[index],overlay:overlay,onDetails:onDetails,onClose:{library(overlay:overlay,selected:index,onDetails:onDetails,onClose:onClose)})
        }))
    }
}
#endif
