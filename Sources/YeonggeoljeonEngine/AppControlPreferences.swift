// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(AppKit)
import AppKit
#endif

struct AppControlPreferences:Codable,Equatable {
    enum Context:String,Codable,CaseIterable {case dialogue,list,field,battle,textInput
        var title:String {switch self {case .dialogue:return "대사";case .list:return "목록";case .field:return "필드";case .battle:return "전투";case .textInput:return "문자 입력"}}
    }
    enum Command:String,Codable,CaseIterable {
        case up,down,left,right,confirm,cancel,focusButtons,nextUnit,wait,log,auto,skip,suspend,resume
        case threat,objectives,roster,conditions,recovery,movePreview,growth,pinThreat,damageDetails,battleMapZoom
        case battleAnnotations,battleFavorites,areaStrategyAdvice,cooperativePlan,pageUp,pageDown,firstPage,lastPage
        var title:String {
            switch self {
            case .up:return "위로";case .down:return "아래로";case .left:return "왼쪽";case .right:return "오른쪽"
            case .confirm:return "확인";case .cancel:return "취소·뒤로";case .focusButtons:return "버튼 초점";case .nextUnit:return "다음 부대";case .wait:return "대기"
            case .log:return "대사 기록";case .auto:return "대사 자동 넘김";case .skip:return "대사 건너뛰기";case .suspend:return "중단 저장";case .resume:return "중단 이어하기"
            case .battleAnnotations:return "전술 메모";case .battleFavorites:return "명령 즐겨찾기";case .areaStrategyAdvice:return "범위 책략 후보";case .cooperativePlan:return "협동 공격 계획"
            case .pageUp:return "상세 위로";case .pageDown:return "상세 아래로";case .firstPage:return "상세 처음";case .lastPage:return "상세 끝"
            case .threat:return "적 위협";case .objectives:return "목표 추적";case .roster:return "부대 목록";case .conditions:return "상태 설명";case .recovery:return "회복 수단"
            case .movePreview:return "이동 미리보기";case .growth:return "성장 예상";case .pinThreat:return "적 위협 고정";case .damageDetails:return "전투 계산";case .battleMapZoom:return "지도 배율"
            }
        }
        var canonical:UInt16 {
            switch self {
            case .up:return 126;case .down:return 125;case .left:return 123;case .right:return 124;case .confirm:return 36;case .cancel:return 53
            case .focusButtons,.nextUnit:return 48;case .wait:return 49;case .log:return 37;case .auto:return 0;case .skip:return 1;case .suspend:return 96;case .resume:return 101
            case .battleAnnotations:return 45;case .battleFavorites:return 11;case .areaStrategyAdvice:return 17;case .cooperativePlan:return 8
            case .pageUp:return 116;case .pageDown:return 121;case .firstPage:return 115;case .lastPage:return 119
            case .threat:return 2;case .objectives:return 31;case .roster:return 15;case .conditions:return 34;case .recovery:return 4;case .movePreview:return 9
            case .growth:return 5;case .pinThreat:return 35;case .damageDetails:return 3;case .battleMapZoom:return 6
            }
        }
        var acceptsReverseShift:Bool {[.up,.down,.left,.right,.focusButtons,.nextUnit,.threat].contains(self)}
    }
    struct Chord:Codable,Equatable,Hashable {
        var keyCode:UInt16
        /// Only Shift (1) and Option (2). Command/Control are reserved for the
        /// OS, menu bar and held fast-forward; they cannot be game bindings.
        var modifiers:Int = 0
        init(keyCode:UInt16,modifiers:Int = 0) {self.keyCode = keyCode;self.modifiers = modifiers}
        #if canImport(AppKit)
        init(_ event:NSEvent) {
            keyCode = event.keyCode;modifiers = (event.modifierFlags.contains(.shift) ? 1 : 0)|(event.modifierFlags.contains(.option) ? 2 : 0)
            if !event.modifierFlags.intersection([.command,.control]).isEmpty {modifiers |= 4}
        }
        #endif
        var valid:Bool {keyCode < 128 && (0...3).contains(modifiers)}
        var label:String {
            let special:[UInt16:String] = [36:"Return",76:"Enter",49:"Space",53:"Esc",48:"Tab",123:"←",124:"→",125:"↓",126:"↑",96:"F5",101:"F9",51:"Delete",116:"PageUp",121:"PageDown",115:"Home",119:"End"]
            let letters:[UInt16:String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M"]
            return (modifiers&2 != 0 ? "⌥" : "")+(modifiers&1 != 0 ? "⇧" : "")+(special[keyCode] ?? letters[keyCode] ?? "키 \(keyCode)")
        }
    }
    struct Binding:Codable,Equatable {var context:Context;var command:Command;var chord:Chord}
    var format = 1
    var textPercent = 100
    var patternedRanges = false
    /// Only the tactical scale is a preference; overview/camera are transient.
    var battleMapMode = BattleMapViewMode.standard
    var bindings = Self.defaults
    var recoveryNotices:[String] = []
    static let textPercents = [100,125,150]
    static var defaults:[Binding] {
        var values:[Binding] = []
        for context in [Context.dialogue,.list,.field,.battle] {
            var commands:[Command] = context == .dialogue ? [.confirm,.cancel] : [.up,.down,.left,.right,.confirm,.cancel]
            if context == .list {commands.append(.focusButtons)}
            if [.list,.dialogue].contains(context) {commands += [.pageUp,.pageDown,.firstPage,.lastPage]}
            if context != .list {commands += [.log,.auto,.skip,.suspend,.resume]}
            if context == .battle {commands += [.nextUnit,.wait,.threat,.objectives,.roster,.conditions,.recovery,.movePreview,.growth,.pinThreat,.damageDetails,.battleMapZoom,.battleAnnotations,.battleFavorites,.areaStrategyAdvice,.cooperativePlan]}
            values += commands.map {.init(context:context,command:$0,chord:.init(keyCode:$0.canonical))}
        }
        return values
    }
    private enum CodingKeys:String,CodingKey {case format,textPercent,patternedRanges,bindings,battleMapMode}
    init() {}
    init(from decoder:Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        let version = (try? c.decodeIfPresent(Int.self,forKey:.format)) ?? 1
        if version != 1 {recoveryNotices.append("지원하지 않는 조작 설정을 기본값으로 복원했습니다.");return}
        let percent = (try? c.decodeIfPresent(Int.self,forKey:.textPercent)) ?? 100
        textPercent = Self.textPercents.contains(percent) ? percent : 100
        if textPercent != percent {recoveryNotices.append("글자 크기를 기본값으로 복원했습니다.")}
        patternedRanges = (try? c.decodeIfPresent(Bool.self,forKey:.patternedRanges)) ?? false
        let mapMode = (try? c.decodeIfPresent(BattleMapViewMode.self,forKey:.battleMapMode)) ?? .standard
        battleMapMode = mapMode == .overview ? .standard : mapMode
        if c.contains(.bindings) {
            if let stored = try? c.decode([Binding].self,forKey:.bindings) {
                var next = Self.defaults
                for binding in stored {
                    if let index = next.firstIndex(where:{$0.context == binding.context && $0.command == binding.command}) {next[index] = binding}
                }
                if Self.validBindings(next) {bindings = next}
                else {recoveryNotices.append("충돌하거나 잘못된 키 배치를 기본값으로 복원했습니다.")}
            } else {recoveryNotices.append("읽을 수 없는 키 배치를 기본값으로 복원했습니다.")}
        }
    }
    private static func validBindings(_ values:[Binding])->Bool {
        guard values.count == defaults.count,values.allSatisfy({$0.chord.valid}) else {return false}
        var actions = Set<String>(),keys = Set<String>()
        for value in values {
            guard defaults.contains(where:{$0.context == value.context && $0.command == value.command}),
                  actions.insert(value.context.rawValue+":"+value.command.rawValue).inserted,
                  keys.insert("\(value.context.rawValue):\(value.chord.keyCode):\(value.chord.modifiers)").inserted else {return false}
            if value.command.acceptsReverseShift,value.chord.modifiers&1 == 0,
               !keys.insert("\(value.context.rawValue):\(value.chord.keyCode):\(value.chord.modifiers|1)").inserted {return false}
            if value.command == .confirm,value.chord == .init(keyCode:36) {
                for code in value.context == .battle ? [76] : [49,76] {
                    if !keys.insert("\(value.context.rawValue):\(code):0").inserted {return false}
                }
            }
        }
        return true
    }
    mutating func set(_ command:Command,context:Context,chord:Chord) throws {
        guard chord.valid,let index = bindings.firstIndex(where:{$0.context == context && $0.command == command}) else {throw EngineError.invalid("이 화면에서 지정할 수 없는 키입니다. Command·Control 조합은 예약되어 있습니다.")}
        var next = bindings;next[index].chord = chord
        guard Self.validBindings(next) else {throw EngineError.invalid("같은 화면의 다른 명령과 키가 겹칩니다.")}
        bindings = next
    }
    mutating func reset(_ command:Command,context:Context) throws {try set(command,context:context,chord:.init(keyCode:command.canonical))}
    /// Formats conventional help labels at display time after remapping.
    func displayHint(_ text:String,context:Context) -> String {
        let names:[(String,Command)] = [("PageDown",.pageDown),("PageUp",.pageUp),("Home",.firstPage),("End",.lastPage),("Enter",.confirm),("Esc",.cancel),("Tab",context == .battle ? .nextUnit : .focusButtons)]
        var result = text.replacingOccurrences(of:"↑↓",with:shortcutLabel(command:.up,context:context)+shortcutLabel(command:.down,context:context))
        for (old,command) in names where bindings.contains(where:{$0.context == context && $0.command == command}) {result = result.replacingOccurrences(of:old,with:shortcutLabel(command:command,context:context))}
        return result
    }
    func shortcutLabel(command:Command,context:Context)->String {bindings.first {$0.context == context && $0.command == command}?.chord.label ?? "지정 없음"}
    func command(for chord:Chord,context:Context)->Command? {resolved(chord,context:context)?.command}
    #if canImport(AppKit)
    func command(for event:NSEvent,context:Context)->Command? {command(for:Chord(event),context:context)}
    #endif
    private func resolved(_ chord:Chord,context:Context)->Binding? {
        guard context != .textInput,chord.valid else {return nil}
        if let exact = bindings.first(where:{$0.context == context && $0.chord == chord}) {return exact}
        if chord.modifiers == 1,let reverse = bindings.first(where:{$0.context == context && $0.chord == .init(keyCode:chord.keyCode) && $0.command.acceptsReverseShift}) {return reverse}
        if [49,76].contains(chord.keyCode),chord.modifiers == 0,context != .battle,
           let confirm = bindings.first(where:{$0.context == context && $0.command == .confirm && $0.chord == .init(keyCode:36)}) {return confirm}
        if chord.keyCode == 76,chord.modifiers == 0,let confirm = bindings.first(where:{$0.context == context && $0.command == .confirm && $0.chord == .init(keyCode:36)}) {return confirm}
        return nil
    }
    #if canImport(AppKit)
    func remappedEvent(_ event:NSEvent,context:Context)->NSEvent? {
        guard context != .textInput else {return nil}
        let chord = Chord(event)
        guard chord.valid else {return nil}
        guard let binding = resolved(chord,context:context) else {
            if [.list,.dialogue].contains(context) {return nil}
            let old = Self.defaults.contains {$0.context == context && $0.chord.keyCode == event.keyCode}
            return old && chord.valid ? nil : event
        }
        let flags:NSEvent.ModifierFlags = binding.command.acceptsReverseShift && event.modifierFlags.contains(.shift) && binding.chord.modifiers&1 == 0 ? [.shift] : []
        return NSEvent.keyEvent(with:event.type,location:event.locationInWindow,modifierFlags:flags,timestamp:event.timestamp,windowNumber:event.windowNumber,
            context:nil,characters:event.characters ?? "",charactersIgnoringModifiers:event.charactersIgnoringModifiers ?? "",isARepeat:event.isARepeat,keyCode:binding.command.canonical)
    }
    #endif
}

enum AppControlRuntime {
    private static var cached:AppControlPreferences?
    static var current:AppControlPreferences {if let cached {return cached};let value = OriginalSettings.current.controls;cached = value;return value}
    static func update(_ value:AppControlPreferences) {cached = value}
    static func withPreferences<T>(_ value:AppControlPreferences,_ body:() throws -> T) rethrows -> T {
        let before = current;update(value);defer {update(before)};return try body()
    }
}
