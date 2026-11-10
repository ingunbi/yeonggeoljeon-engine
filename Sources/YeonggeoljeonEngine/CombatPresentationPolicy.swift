// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Selects pictures from an already resolved combat snapshot. It never asks
/// the session to forecast or execute an action, or changes source option bits.
struct CombatPresentationPolicy:Equatable {
    enum Mode:String,Codable,CaseIterable {
        case all,important,first,none
        var label:String {
            switch self {
            case .all:return "전부"
            case .important:return "중요 교전"
            case .first:return "입장 후 첫 교전"
            case .none:return "생략"
            }
        }
    }

    var mode:Mode
    var importantPersonIDs:Set<Int>
    var showsDuels:Bool

    init(mode:Mode,importantPersonIDs:Set<Int> = [],showsDuels:Bool = true) {
        self.mode = mode
        self.importantPersonIDs = Set(importantPersonIDs.filter { (0..<384).contains($0) })
        self.showsDuels = showsDuels
    }

    /// `hasPresentedCombat` belongs to the view's lifetime, not the campaign.
    /// Reopening a suspended battle may show its first picture again; neither
    /// that cursor nor the choice changes the already resolved source action.
    func showsCombat(_ snapshot:OriginalCombatSnapshot,hasPresentedCombat:Bool) -> Bool {
        // An unfamiliar presentation stays on the established display path.
        guard (1...3).contains(snapshot.kind) else { return true }
        switch mode {
        case .all:return true
        case .none:return false
        case .first:return !hasPresentedCombat
        case .important:
            if importantPersonIDs.contains(snapshot.attackerPerson) || importantPersonIDs.contains(snapshot.targetPerson) { return true }
            if snapshot.targetTroops > 0 && snapshot.damage >= snapshot.targetTroops { return true }
            if isLowFriendly(slot:snapshot.attackerSlot,troops:snapshot.attackerTroops,maximum:snapshot.attackerMaxTroops) { return true }
            // Damage is a committed result, not a prediction. Healing uses a
            // negative value and must not manufacture a critical-health event.
            let remaining = snapshot.damage > 0 ? max(0,snapshot.targetTroops-snapshot.damage) : snapshot.targetTroops
            return isLowFriendly(slot:snapshot.targetSlot,troops:remaining,maximum:snapshot.targetMaxTroops)
        }
    }

    private func isLowFriendly(slot:Int,troops:Int,maximum:Int) -> Bool {
        (0..<15).contains(slot) && troops > 0 && maximum > 0 && troops <= maximum/4
    }

    /// The original non-enlarged result cues. The caller retains subsequent
    /// experience, retirement and script cues once, in their original order.
    func abbreviatedCues(for snapshot:OriginalCombatSnapshot) -> [OriginalBattleCue] {
        var cues:[OriginalBattleCue] = [.number(slot:snapshot.targetSlot,value:snapshot.damage,color:7,passes:3)]
        if snapshot.kind == 2 && snapshot.damage == 0 { cues.append(.notice(.strategyFailed(person:snapshot.attackerPerson))) }
        return cues
    }
}
