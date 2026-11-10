// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// An opt-in, caller-selected LOCAL catalog. No shipped original event text,
/// guessed conditions, VM queries, predicate execution, or event dispatch.
enum ReviewedEventHints {
    enum Level:String,Codable,CaseIterable {case off,light,detailed
        var title:String {switch self {case .off:return "끔";case .light:return "가벼운 힌트";case .detailed:return "조건 자세히"}}
    }
    enum Judgment:String {case met = "충족",unmet = "미충족",unknown = "현재 판단 불가"}
    struct Evidence:Codable,Equatable {
        var relativeFile:String;var byteOffset:Int;var byteLength:Int;var reviewNote:String
    }
    enum Condition:Codable,Equatable {
        case turnAtLeast(Int),turnAtMost(Int)
        case visiblePersonAt(person:Int,x:Int,y:Int)
        /// Caller must supply only an already-public, reviewed fact. Missing
        /// facts remain unknown; this does not read raw campaign flags.
        case knownFact(key:String,expected:Bool)
        case unsupported(description:String)
        func evaluate(_ context:Context) -> Judgment {
            switch self {
            case .turnAtLeast(let turn):return context.turn >= turn ? .met : .unmet
            case .turnAtMost(let turn):return context.turn <= turn ? .met : .unmet
            case .visiblePersonAt(let person,let x,let y):
                guard let cell = context.visiblePeople[person] else {return .unknown};return cell == GridPoint(x:x,y:y) ? .met : .unmet
            case .knownFact(let key,let expected):guard let actual = context.knownFacts[key] else {return .unknown};return actual == expected ? .met : .unmet
            case .unsupported:return .unknown
            }
        }
        var description:String {
            switch self {
            case .turnAtLeast(let turn):return "\(turn)턴 이상"
            case .turnAtMost(let turn):return "\(turn)턴 이하"
            case .visiblePersonAt(let person,let x,let y):return "공개 장수 #\(person)의 위치 (\(x), \(y))"
            case .knownFact(let key,let expected):return key+" = "+(expected ? "참" : "거짓")
            case .unsupported(let description):return "미지원 조건: "+description
            }
        }
        var valid:Bool {
            switch self {
            case .turnAtLeast(let value),.turnAtMost(let value):return (1...65535).contains(value)
            case .visiblePersonAt(let person,let x,let y):return (0..<384).contains(person) && (0..<256).contains(x) && (0..<256).contains(y)
            case .knownFact(let key,_):return !key.isEmpty && key.count <= 120
            case .unsupported(let description):return !description.isEmpty && description.count <= 500
            }
        }
    }
    struct Completion:Codable,Equatable {
        var recordID:String;var sourceOffset:Int;var opcode:Int;var status:Int
        func matches(_ value:OriginalCampaignInterpreterReturn) -> Bool {recordID == value.recordID && sourceOffset == value.sourceOffset && opcode == value.opcode && status == value.status}
        var valid:Bool {!recordID.isEmpty && recordID.count <= 120 && sourceOffset >= 0 && (0...255).contains(opcode) && (0...8).contains(status)}
    }
    struct Hint:Codable,Equatable {
        var id:String;var battleID:String
        /// Both texts require explicit review. Light text must omit hidden
        /// participants, conditions and outcomes; never derive it from detail.
        var lightText:String;var detailedText:String
        var conditions:[Condition];var evidence:[Evidence]
        var publicTargetPerson:Int?
        var completion:Completion? = nil
        /// Reviewed exact public objective text; never inferred from a hint.
        var objectiveText:String? = nil
    }
    struct Catalog:Codable,Equatable {
        var format:Int = 1;var sourceIdentity:String;var reviewed:Bool
        var hints:[Hint]
        func validate() throws {
            guard format == 1,reviewed,SourceCatalogIdentity.valid(sourceIdentity),hints.count <= 1024,Set(hints.map(\.id)).count == hints.count else {throw EngineError.invalid("검토된 이벤트 힌트 자료의 형식 또는 자료 식별값이 올바르지 않습니다.")}
            for hint in hints {
                if let text = hint.objectiveText,text.isEmpty || text.count > 2000 {throw EngineError.invalid("검토된 목표 문구가 올바르지 않습니다.")}
                guard !hint.id.isEmpty,hint.id.count <= 120,!hint.battleID.isEmpty && hint.battleID.count <= 120,!hint.lightText.isEmpty,hint.lightText.count <= 2000,
                      !hint.detailedText.isEmpty,hint.detailedText.count <= 8000,!hint.conditions.isEmpty,hint.conditions.count <= 64,hint.conditions.allSatisfy(\.valid),
                      !hint.evidence.isEmpty,hint.evidence.count <= 32,hint.publicTargetPerson.map({(0..<384).contains($0)}) ?? true else {throw EngineError.invalid("힌트의 검토 문구·조건·근거가 누락되었거나 잘못되었습니다.")}
                guard hint.completion?.valid ?? true else {throw EngineError.invalid("힌트 완료 사건 식별값이 올바르지 않습니다.")}
                for evidence in hint.evidence {
                    guard !evidence.relativeFile.isEmpty,!evidence.relativeFile.hasPrefix("/"),!evidence.relativeFile.split(separator:"/").contains(".."),
                          evidence.byteOffset >= 0,evidence.byteLength > 0,evidence.byteLength <= 1_048_576,evidence.byteOffset <= Int.max-evidence.byteLength,
                          !evidence.reviewNote.isEmpty,evidence.reviewNote.count <= 2000 else {throw EngineError.invalid("힌트 근거의 로컬 파일 위치 또는 검토 설명이 올바르지 않습니다.")}
                }
            }
        }
        /// Explicit local metadata selected by file or caller data directory;
        /// no scan, network, public fallback, or original-file extraction.
        static func load(from url:URL) throws -> Catalog {
            guard url.isFileURL else {throw EngineError.invalid("로컬에서 직접 선택한 검토 자료만 열 수 있습니다.")}
            let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
            guard let size = attributes[.size] as? NSNumber,size.intValue <= 4_194_304 else {throw EngineError.invalid("이벤트 힌트 자료가 허용 크기를 넘었습니다.")}
            let value = try JSONDecoder().decode(Catalog.self,from:Data(contentsOf:url));try value.validate();return value
        }
    }
    struct Progress:Codable,Equatable {
        var sourceIdentity:String;var discovered:[String] = [];var completed:[String] = []
        mutating func recordDiscovered(_ id:String) {
            guard !id.isEmpty,id.count <= 120,!discovered.contains(id) else {return}
            if discovered.count == 1024 {let old = discovered.removeFirst();completed.removeAll {$0 == old}}
            discovered.append(id)
        }
        /// Host calls only after an identified committed VM event; never from
        /// predicate projection or opening this UI.
        mutating func recordCompleted(_ id:String) {recordDiscovered(id);if discovered.contains(id),!completed.contains(id) {completed.append(id)}}
        func validate() throws {guard SourceCatalogIdentity.valid(sourceIdentity),discovered.count <= 1024,completed.count <= 1024,Set(discovered).count == discovered.count,Set(completed).isSubset(of:Set(discovered)),Set(completed).count == completed.count,discovered.allSatisfy({!$0.isEmpty && $0.count <= 120}) else {throw EngineError.invalid("이벤트 힌트 발견 기록이 올바르지 않습니다.")}}
    }
    struct Context:Equatable {
        var sourceIdentity:String;var battleID:String;var turn:Int
        var visiblePeople:[Int:GridPoint] = [:];var knownFacts:[String:Bool] = [:]
    }
    struct Entry:Equatable {
        var id:String;var text:String;var judgment:Judgment?;var conditions:[String]
        var discovered:Bool;var completed:Bool;var target:GridPoint?
    }
    struct Result {var entries:[Entry];var explanation:String}
    /// Only call for a COMMITTED interpreter/invocation return. Exact source
    /// identity + load identity + reviewed terminal return prevents a redraw,
    /// a condition match, or an intermediate duel opcode from marking success.
    static func completedIDs(catalog:Catalog?,sourceIdentity:String,battleID:String,returned:OriginalCampaignInterpreterReturn) -> [String] {
        guard let catalog,catalog.sourceIdentity == sourceIdentity,(try? catalog.validate()) != nil else {return []}
        return catalog.hints.filter {$0.battleID == battleID && $0.completion?.matches(returned) == true}.map(\.id)
    }
    static func project(catalog:Catalog?,context:Context,level:Level,progress:Progress?) -> Result {
        guard level != .off else {return .init(entries:[],explanation:"이벤트 힌트가 꺼져 있습니다.")}
        guard let catalog else {return .init(entries:[],explanation:"검토된 로컬 힌트 자료가 선택되지 않았습니다. 확인되지 않은 이벤트는 추측해 안내하지 않습니다.")}
        guard (try? catalog.validate()) != nil,catalog.sourceIdentity == context.sourceIdentity else {return .init(entries:[],explanation:"힌트 자료가 현재 원본 자료와 맞지 않거나 검토 형식이 올바르지 않습니다.")}
        let saved:Progress?
        if let progress,progress.sourceIdentity == context.sourceIdentity,(try? progress.validate()) != nil {saved = progress} else {saved = nil}
        let entries = catalog.hints.filter {$0.battleID == context.battleID}.map {hint -> Entry in
            let judgments = hint.conditions.map {$0.evaluate(context)}
            let verdict:Judgment = judgments.contains(.unmet) ? .unmet : judgments.contains(.unknown) ? .unknown : .met
            return .init(id:hint.id,text:level == .light ? hint.lightText : hint.detailedText,judgment:level == .detailed ? verdict : nil,
                conditions:level == .detailed ? zip(hint.conditions,judgments).map {$0.description+" · "+$1.rawValue} : [],
                discovered:saved?.discovered.contains(hint.id) ?? false,completed:saved?.completed.contains(hint.id) ?? false,
                target:level == .detailed ? hint.publicTargetPerson.flatMap {context.visiblePeople[$0]} : nil)
        }
        return .init(entries:entries,explanation:entries.isEmpty ? "현재 전투에서 지원하는 검토된 힌트가 없습니다." : "확인된 조건만 읽기 전용으로 표시합니다. 충족 표시는 이벤트 완료를 뜻하지 않습니다.")
    }
}

#if canImport(AppKit)
enum ReviewedEventHintsUI {
    static func sheet(catalog:ReviewedEventHints.Catalog?,context:ReviewedEventHints.Context,level:ReviewedEventHints.Level,
                      progress:ReviewedEventHints.Progress?,selected:Int = 0,onLevel:@escaping(ReviewedEventHints.Level)->Void,
                      onSelectCatalog:@escaping()->Void,onLocate:@escaping(GridPoint)->Void,onClose:@escaping()->Void) -> CanvasSheet {
        let result = ReviewedEventHints.project(catalog:catalog,context:context,level:level,progress:progress)
        let rows = result.entries.enumerated().map {offset,entry in CanvasSheet.Row(label:"힌트 \(offset+1)",value:entry.completed ? "완료" : entry.judgment?.rawValue ?? "",
            detail:.init(heading:"검토된 이벤트 힌트",body:entry.text,list:entry.conditions))}
        return CanvasSheet(portrait:nil,speaker:"선택형 이벤트 힌트",line:result.explanation,badge:("표시",level.title),rows:rows,selected:selected,mode:.list,
            detail:rows.isEmpty ? .init(heading:"이벤트 힌트",body:result.explanation) : nil,buttons:["표시 수준","검토 자료 선택","돌아가기"],
            hint:"지도 찾기는 자세한 힌트의 현재 공개 대상만 지원합니다.",fullCanvas:true,onRowButton:{button,_ in
                if button == 0 {let values = ReviewedEventHints.Level.allCases;onLevel(values[(values.firstIndex(of:level)!+1)%values.count])}
                else if button == 1 {onSelectCatalog()} else {onClose()}
            },onChoose:{index in guard let index,result.entries.indices.contains(index),let point = result.entries[index].target else {onClose();return};onLocate(point)})
    }
}
#endif
