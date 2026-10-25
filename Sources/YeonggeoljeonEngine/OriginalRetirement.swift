// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Fresh reads from the same original live-unit slot. Source scripts may change
/// its person while a retirement is suspended; notice.person is provenance.
struct OriginalRetirementContext: Codable, Equatable {
    var runtimeSlot: Int
    var person: Int
    var battleResult: UInt8
    var objectives: [OriginalObjective]
}
enum OriginalRetirementProbeKind: String, Codable {
    case firstObjective, secondObjective, automatic, person, friendlyWildcard
}
struct OriginalRetirementProbe: Codable, Equatable {
    var ordinal: Int
    var kind: OriginalRetirementProbeKind
    var event: OriginalCampaignEvent
}
enum OriginalRetirementProbeResponse: Codable, Equatable {
    case noMatch
    case interpreterReturned(Int)
}
enum OriginalRetirementEffect: Codable, Equatable {
    case battleResult(UInt8)
    case music(Int)
    case unitStatus(Int)
}
enum OriginalRetirementPresentation: Codable, Equatable {
    /// Source79FA uses HEXGRP member(bank+1). There is no replacement quote
    /// when the original byte-person list contains no matching entry.
    case quote(person: Int, bank: Int)
    case leaderDefeat
    case retreated(person: Int)
    case died(person: Int)
}
struct OriginalRetirementSummary: Codable, Equatable {
    var notice: OriginalRetirementNotice
    var handledBySourceScript: Bool
    var probes: Int
}
enum OriginalRetirementStep: Codable, Equatable {
    case probe(OriginalRetirementProbe)
    case effect(OriginalRetirementEffect)
    case presentation(OriginalRetirementPresentation)
    case finished(OriginalRetirementSummary)
}

/// MAIN2BAFE..2BCA4, after the common status4/cache/reference cleanup and the
/// source flag4 suppression gate. Every probe/effect/presentation is stable
/// until explicitly acknowledged. No enemy-elimination result is synthesized.
final class OriginalRetirementOperation: Codable {
    private enum Phase: String, Codable {
        case objectiveLoop, automaticAfterObjectiveMiss, automaticOnly
        case genericGate, wildcardGate, defaultGate, leaderMusic, quote, afterQuote
        case afterLeaderMessage, afterDeathPopup, done
    }
    let notice: OriginalRetirementNotice
    private var phase: Phase = .objectiveLoop
    private var lastStatus = 5
    private var handled = false
    private var leaderDefault = false
    private var probes = 0
    private var pending: OriginalRetirementStep?
    private var probeContinuation: Phase?

    init(notice: OriginalRetirementNotice) throws {
        guard notice.sequence >= 0, (0..<45).contains(notice.runtimeSlot), (0..<384).contains(notice.person) else {
            throw BattleError.invalid("Original retirement notice has no source slot/person identity")
        }
        self.notice = notice
    }
    private func context(_ value: OriginalRetirementContext) throws {
        guard value.runtimeSlot == notice.runtimeSlot, (0..<384).contains(value.person),
              value.objectives.count <= 2, value.objectives.allSatisfy({ [7,8].contains($0.eventKind) && (0...65535).contains($0.person) }) else {
            throw BattleError.invalid("Original retirement lost its live source slot or objective facts")
        }
    }
    private func probe(_ kind: OriginalRetirementProbeKind, event: OriginalCampaignEvent,
                       continuation: Phase) -> OriginalRetirementStep {
        let value = OriginalRetirementProbe(ordinal: probes, kind: kind, event: event)
        probes += 1
        probeContinuation = continuation
        pending = .probe(value)
        return pending!
    }
    private func emit(_ value: OriginalRetirementStep) -> OriginalRetirementStep {
        pending = value
        return value
    }
    func advance(context value: OriginalRetirementContext) throws -> OriginalRetirementStep {
        guard notice.sequence >= 0, (0..<45).contains(notice.runtimeSlot), (0..<384).contains(notice.person),
              probes >= 0, (0...8).contains(lastStatus) else {
            throw BattleError.invalid("Original retirement checkpoint quantities are invalid")
        }
        try context(value)
        if let pending = pending {
            if case .probe(let probe) = pending {
                guard probeContinuation != nil, probe.ordinal == probes - 1 else {
                    throw BattleError.invalid("Original retirement checkpoint lost its pending probe identity")
                }
            } else if probeContinuation != nil {
                throw BattleError.invalid("Original retirement checkpoint mixed a probe and presentation")
            }
            return pending
        }
        while true {
            switch phase {
            case .objectiveLoop:
                guard [5,6].contains(lastStatus), value.battleResult == 0 else { phase = .genericGate;continue }
                // Source86B8 tests the first enabled pair before the second.
                if let objective = value.objectives.first(where: { $0.eventKind == 7 && $0.enabled && $0.person == value.person }) {
                    return probe(.firstObjective, event: .init(kind: objective.eventKind, arguments: []), continuation: .objectiveLoop)
                }
                if let objective = value.objectives.first(where: { $0.eventKind == 8 && $0.enabled && $0.person == value.person }) {
                    return probe(.secondObjective, event: .init(kind: objective.eventKind, arguments: []), continuation: .objectiveLoop)
                }
                phase = .automaticOnly
            case .automaticAfterObjectiveMiss:
                return probe(.automatic, event: .automatic, continuation: .objectiveLoop)
            case .automaticOnly:
                guard [5,6].contains(lastStatus) else { phase = .genericGate;continue }
                // This inner source loop does not repeat its result guard.
                return probe(.automatic, event: .automatic, continuation: .automaticOnly)
            case .genericGate:
                if value.battleResult != 0 { phase = .defaultGate;continue }
                return probe(.person, event: .init(kind: 12, arguments: [value.person]), continuation: .defaultGate)
            case .wildcardGate:
                if value.runtimeSlot >= 15 { phase = .defaultGate;continue }
                return probe(.friendlyWildcard, event: .init(kind: 12, arguments: [0x400]), continuation: .defaultGate)
            case .defaultGate:
                if handled { phase = .done;continue }
                leaderDefault = value.person == 0
                if leaderDefault {
                    phase = .leaderMusic
                    return emit(.effect(.battleResult(3)))
                }
                phase = .quote
            case .leaderMusic:
                phase = .quote
                return emit(.effect(.music(4)))
            case .quote:
                phase = .afterQuote
                return emit(.presentation(.quote(person: value.person, bank: leaderDefault ? 1 : 0)))
            case .afterQuote:
                if leaderDefault && value.person == 0 {
                    phase = .afterLeaderMessage
                    return emit(.presentation(.leaderDefeat))
                }
                phase = .afterLeaderMessage
            case .afterLeaderMessage:
                if value.battleResult == 3 { phase = .done;continue }
                if leaderDefault {
                    phase = .afterDeathPopup
                    return emit(.presentation(.died(person: value.person)))
                }
                phase = .done
                return emit(.presentation(.retreated(person: value.person)))
            case .afterDeathPopup:
                phase = .done
                return emit(.effect(.unitStatus(5)))
            case .done:
                return .finished(.init(notice: notice, handledBySourceScript: handled, probes: probes))
            }
        }
    }
    /// Called only after the selected source interpreter invocation has really
    /// returned, including its dialogue/choice waits. Found is not completed.
    func resumeProbe(_ probe: OriginalRetirementProbe, response: OriginalRetirementProbeResponse) throws {
        guard pending == .probe(probe), let continuation = probeContinuation else {
            throw BattleError.invalid("Original retirement probe acknowledgement does not match its pending source lookup")
        }
        switch response {
        case .noMatch:
            switch probe.kind {
            case .firstObjective,.secondObjective: phase = .automaticAfterObjectiveMiss
            case .automatic: phase = .genericGate
            case .person: phase = .wildcardGate
            case .friendlyWildcard: phase = .defaultGate
            }
        case .interpreterReturned(let status):
            guard (0...8).contains(status) else { throw BattleError.invalid("Original interpreter returned an unknown source status") }
            if probe.kind != .automatic { handled = true }
            lastStatus = status
            phase = continuation
        }
        pending = nil
        probeContinuation = nil
    }
    func acknowledge(_ step: OriginalRetirementStep) throws {
        guard let pending = pending, pending == step else {
            throw BattleError.invalid("Original retirement acknowledgement does not match its pending source effect")
        }
        if case .probe = pending { throw BattleError.invalid("Original retirement probe requires its explicit source response") }
        self.pending = nil
    }
}

struct OriginalRetirementQuote: Codable, Equatable { var person: Int; var text: String }
struct OriginalRetirementQuoteBank: Codable, Equatable { var bank: Int; var entries: [OriginalRetirementQuote] }
struct OriginalRetirementMessages: Codable, Equatable { var leaderDefeat: String; var retreated: String; var died: String }
struct OriginalRetirementCatalog: Codable, Equatable {
    var format: Int
    var quoteBanks: [OriginalRetirementQuoteBank]
    var messages: OriginalRetirementMessages
    static func load(from url: URL) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard result.format == 1, result.quoteBanks.count == 2,
              Set(result.quoteBanks.map(\.bank)) == Set([0,1]),
              result.quoteBanks.allSatisfy({ $0.entries.allSatisfy({ (0..<255).contains($0.person) }) }),
              result.messages.retreated.components(separatedBy: "%s").count == 2,
              result.messages.died.components(separatedBy: "%s").count == 2 else {
            throw EngineError.invalid("Original retirement text catalog has no matching source structure")
        }
        return result
    }
    func text(for presentation: OriginalRetirementPresentation, personName: String? = nil) throws -> String? {
        switch presentation {
        case .quote(let person, let bank):
            guard [0,1].contains(bank), (0..<384).contains(person) else { throw BattleError.invalid("Original retirement quote lookup identity") }
            // Preserve the original first-match lookup, including an absent or
            // explicitly empty quote. No substitute dialogue is created.
            return quoteBanks.first(where: { $0.bank == bank })?.entries.first(where: { $0.person == person })?.text
        case .leaderDefeat: return messages.leaderDefeat
        case .retreated,.died:
            guard let name = personName else { throw BattleError.invalid("Original retirement popup requires its source person name") }
            let template: String
            if case .retreated = presentation { template = messages.retreated } else { template = messages.died }
            return template.replacingOccurrences(of: "%s", with: name)
        }
    }
}
