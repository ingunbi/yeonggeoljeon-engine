// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One request owns the confirmation and any deferred suspend boundary.
/// Repeated OS close requests must not create another save or callback.
struct CampaignTerminationGate {
    enum Phase:Equatable { case idle,confirming,waitingForSave,approved }
    enum Choice { case save,discard,cancel }
    private(set) var phase:Phase = .idle
    mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        phase = .confirming;return true
    }
    mutating func choose(_ choice:Choice) {
        guard phase == .confirming else { return }
        switch choice {
        case .save:phase = .waitingForSave
        case .discard:phase = .approved
        case .cancel:phase = .idle
        }
    }
    @discardableResult mutating func finishSave(success:Bool) -> Bool {
        guard phase == .waitingForSave else { return false }
        phase = success ? .approved : .idle;return success
    }
    mutating func cancel() { if phase != .approved { phase = .idle } }
    mutating func consumeApproval() -> Bool {
        guard phase == .approved else { return false }
        phase = .idle;return true
    }
}
