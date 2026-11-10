// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum CampaignSaveLabels {
    /// The original battle headings store prefixes such as 서 and 제1.
    static func chapter(_ index:Int,sourceLabels:[String]) -> String {
        if sourceLabels.indices.contains(index) {
            let label = sourceLabels[index].trimmingCharacters(in:.whitespacesAndNewlines)
            if !label.isEmpty { return label.hasSuffix("장") ? label : label+"장" }
        }
        return index == 0 ? "서장" : index > 0 ? "\(index)장" : "장 정보 없음"
    }
}

/// An automatic save is remembered only after its write succeeds. A failed
/// destination gets a bounded retry rate, including when the scene changes.
struct CampaignAutosave {
    enum Result {
        case skipped
        case saved(recovered:Bool)
        case failed(Error,notify:Bool)
    }
    static let retrySeconds:TimeInterval = 10
    private(set) var savedKey:String?
    private var retryAfter:TimeInterval = 0
    private var failed = false

    mutating func attempt(key:String,now:TimeInterval,write:() throws -> Void) -> Result {
        guard key != savedKey,now >= retryAfter else { return .skipped }
        do {
            try write()
            let recovered = failed
            savedKey = key;retryAfter = 0;failed = false
            return .saved(recovered:recovered)
        } catch {
            let notify = !failed
            failed = true;retryAfter = now+Self.retrySeconds
            return .failed(error,notify:notify)
        }
    }
}

/// Escape belongs to the current interaction. Only an already completed
/// source quit may close the window; an active campaign never exits on it.
enum CampaignEscapeRoute:Equatable {
    case overlay,fieldMenu,titleMenu,closeCompleted,ignore

    static func resolve(overlayActive:Bool,completedQuit:Bool,started:Bool,fieldReady:Bool) -> Self {
        if overlayActive { return .overlay }
        if completedQuit { return .closeCompleted }
        if !started { return .titleMenu }
        return fieldReady ? .fieldMenu : .ignore
    }
}
