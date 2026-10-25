// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct CampaignTransition: Codable {
    var kind: String
    var target: String?
    var battleID: String?
    var reason: String?
    var source: JSONValue?
}

struct CampaignCoverage: Codable {
    var chapters: Int
    var members: Int
    var blocks: Int
    var records: Int
    var framedCompleteRecords: Int
    var framingFailures: Int
    var supportedPreviewRecords: Int
    var partialPreviewRecords: Int
    var dataOnlyRecords: Int
    var unconditionalRecords: Int
}

struct CampaignRecord: Codable {
    var id: String
    var label: String
    var chapter: Int
    var member: Int
    var block: Int
    var record: Int
    var conditionUnconditional: Bool
    var conditionStatus: String
    var executionStatus: String
    var scene: Scene?
    var transitions: [CampaignTransition]?
    var source: JSONValue?
}

struct CampaignCatalog: Codable {
    var format: Int
    var records: [CampaignRecord]
    var coverage: CampaignCoverage?
    var limitations: [String]?

    static func load(from url: URL) throws -> CampaignCatalog {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value > 0,
              size.int64Value <= 64 * 1024 * 1024 else {
            throw EngineError.invalid("Campaign catalog exceeds its supported input bound")
        }
        let catalog = try JSONDecoder().decode(CampaignCatalog.self, from: Data(contentsOf: url))
        try catalog.validate()
        return catalog
    }

    func validate() throws {
        guard format == 1, records.count <= 16384 else {
            throw EngineError.invalid("Unsupported campaign catalog format or record count")
        }
        var identities = Set<String>()
        for record in records {
            guard !record.id.isEmpty, identities.insert(record.id).inserted,
                  record.chapter >= 0, record.member >= 0, record.block >= 0, record.record >= 0,
                  ["supported-record", "partial-record", "data-only"].contains(record.executionStatus) else {
                throw EngineError.invalid("Invalid or duplicate campaign record identity")
            }
            if record.executionStatus == "data-only", record.scene != nil {
                throw EngineError.invalid("A data-only campaign record must not imply an executable preview")
            }
            if record.executionStatus != "data-only", record.scene == nil {
                throw EngineError.invalid("A campaign preview record is missing its scene")
            }
        }
        if let coverage = coverage {
            guard coverage.records == records.count,
                  coverage.framedCompleteRecords + coverage.framingFailures == coverage.records,
                  coverage.supportedPreviewRecords + coverage.partialPreviewRecords + coverage.dataOnlyRecords == coverage.records else {
                throw EngineError.invalid("Campaign catalog coverage does not match its record population")
            }
        }
    }
}

struct CampaignBattleResult: Codable, Equatable {
    var battleID: String
    var outcome: String
    var policyOrigin: String
    var committedToOriginalProgress: Bool
    var developmentOverride: Bool
}

struct CampaignSnapshot: Codable, Equatable {
    var selectedRecordID: String?
    var selectionOrigin: String
    var status: String
    var completedPreviewRecords: [String]
    var pendingBattleID: String?
    var battleResults: [CampaignBattleResult]
    var sourceFlags: [String: Int]
}

/// The current router owns explicit research-record selection, not the original
/// trigger dispatcher. Unknown conditions and experimental battle results must
/// not silently become original campaign progress.
final class CampaignSession {
    let catalog: CampaignCatalog
    private var state = CampaignSnapshot(selectedRecordID: nil, selectionOrigin: "none", status: "idle",
                                         completedPreviewRecords: [], pendingBattleID: nil,
                                         battleResults: [], sourceFlags: [:])

    init(catalog: CampaignCatalog) { self.catalog = catalog }

    func snapshot() -> CampaignSnapshot { state }

    func selectRecord(id: String, allowConditionalPreview: Bool = false) throws -> Scene {
        try catalog.validate()
        guard state.pendingBattleID == nil else {
            throw EngineError.invalid("Campaign record selection cannot abandon a pending battle result")
        }
        guard let record = catalog.records.first(where: { $0.id == id }) else {
            throw EngineError.invalid("Campaign record does not exist: \(id)")
        }
        guard record.conditionUnconditional || allowConditionalPreview else {
            throw EngineError.invalid("Campaign condition is not implemented; this record cannot be automatically selected")
        }
        guard let scene = record.scene, record.executionStatus != "data-only" else {
            throw EngineError.invalid("Campaign record requires unsupported source context or commands")
        }
        state.selectedRecordID = id
        state.selectionOrigin = record.conditionUnconditional ? "explicit-record-preview" : "explicit-conditional-preview"
        state.status = "previewing"
        return scene
    }

    func finishRecord(termination: Termination) {
        guard let id = state.selectedRecordID, state.status == "previewing" else { return }
        switch termination {
        case .sourceBoundary:
            if !state.completedPreviewRecords.contains(id) { state.completedPreviewRecords.append(id) }
            state.status = "source-record-boundary; automatic successor not established"
        case .unsupportedBoundary:
            state.status = "unsupported-source-boundary"
        case .runtimeFailure:
            state.status = "runtime-failure"
        case .unexpectedEOF:
            state.status = "unexpected-eof"
        }
    }

    func requestBattle(id: String) throws {
        guard state.pendingBattleID == nil, let selected = state.selectedRecordID,
              let record = catalog.records.first(where: { $0.id == selected }),
              record.transitions?.contains(where: { $0.battleID == id }) == true else {
            throw EngineError.invalid("Battle request has no matching selected source-record identity")
        }
        state.pendingBattleID = id
        state.status = "research-battle-request; original trigger reachability not established"
    }

    @discardableResult
    func resumeAfterBattle(id: String, outcome: String, policyOrigin: String,
                           allowDevelopmentOverride: Bool = false) throws -> CampaignSnapshot {
        guard state.pendingBattleID == id, ["victory", "defeat", "draw"].contains(outcome) else {
            throw EngineError.invalid("Battle result identity or outcome does not match the pending request")
        }
        let verifiedOriginal = policyOrigin == "original-verified"
        state.battleResults.append(CampaignBattleResult(battleID: id, outcome: outcome,
            policyOrigin: policyOrigin, committedToOriginalProgress: false,
            developmentOverride: !verifiedOriginal && allowDevelopmentOverride))
        state.pendingBattleID = nil
        if !verifiedOriginal {
            state.status = allowDevelopmentOverride ? "experimental-development-result; source flags unchanged" : "experimental-result-isolated; source progress blocked"
        } else {
            // A verified combat outcome is still insufficient to invent the
            // source's flag/trigger mapping. Preserve the fact, stop here.
            state.status = "verified-result-retained; source flag mapping unsupported"
        }
        return state
    }
}

func campaignSelfTests() throws {
    var count = 0
    func check(_ predicate: @autoclosure () -> Bool, _ name: String) throws {
        guard predicate() else { throw EngineError.invalid("Campaign self-test failed: \(name)") }
        count += 1
    }
    func rejects(_ fragment: String, _ action: () throws -> Void) throws {
        do { try action() }
        catch EngineError.invalid(let reason) {
            try check(reason.lowercased().contains(fragment.lowercased()), "rejection retains \(fragment) reason")
            return
        }
        throw EngineError.invalid("Campaign self-test expected a rejection containing \(fragment)")
    }
    func syntheticScene(_ id: String) -> Scene {
        Scene(format: 1, id: id, name: "synthetic", width: 640, height: 400,
              coordinateSystem: "town", commands: [Command("end")])
    }
    let selected = CampaignRecord(id: "synthetic:0", label: "synthetic", chapter: 0, member: 0, block: 0,
        record: 0, conditionUnconditional: true, conditionStatus: "synthetic-unconditional",
        executionStatus: "supported-record", scene: syntheticScene("synthetic:0"),
        transitions: [CampaignTransition(kind: "battle-map-selection", battleID: "synthetic-battle")])
    var conditional = selected
    conditional.id = "synthetic:1"; conditional.conditionUnconditional = false
    var unsupported = selected
    unsupported.id = "synthetic:2"; unsupported.executionStatus = "data-only"; unsupported.scene = nil
    let catalog = CampaignCatalog(format: 1, records: [selected, conditional, unsupported])
    let session = CampaignSession(catalog: catalog)
    _ = try session.selectRecord(id: selected.id)
    session.finishRecord(termination: .sourceBoundary)
    try check(session.snapshot().completedPreviewRecords == [selected.id], "source end records one preview boundary")
    try check(session.snapshot().sourceFlags.isEmpty, "source end does not invent campaign flags")
    try check(session.snapshot().selectedRecordID == selected.id, "source end does not choose the next record")
    try rejects("condition") { _ = try session.selectRecord(id: conditional.id) }
    _ = try session.selectRecord(id: conditional.id, allowConditionalPreview: true)
    try check(session.snapshot().selectionOrigin == "explicit-conditional-preview", "manual preview retains distinct origin")
    try rejects("unsupported") { _ = try session.selectRecord(id: unsupported.id) }
    _ = try session.selectRecord(id: selected.id)
    try session.requestBattle(id: "synthetic-battle")
    try rejects("pending") { _ = try session.selectRecord(id: selected.id) }
    try rejects("identity") { _ = try session.resumeAfterBattle(id: "wrong", outcome: "victory", policyOrigin: "experimentalV1") }
    let isolated = try session.resumeAfterBattle(id: "synthetic-battle", outcome: "victory", policyOrigin: "experimentalV1")
    try check(isolated.sourceFlags.isEmpty && isolated.battleResults[0].committedToOriginalProgress == false, "experimental result cannot become original progress")
    try check(isolated.status.contains("isolated"), "experimental outcome origin remains visible")
    try session.requestBattle(id: "synthetic-battle")
    let override = try session.resumeAfterBattle(id: "synthetic-battle", outcome: "defeat", policyOrigin: "experimentalV1", allowDevelopmentOverride: true)
    try check(override.sourceFlags.isEmpty && override.battleResults.last?.developmentOverride == true, "development override does not fabricate source flags")
    var duplicate = catalog
    duplicate.records.append(selected)
    try rejects("duplicate") { try duplicate.validate() }
    let roundtrip = try JSONDecoder().decode(CampaignSnapshot.self, from: JSONEncoder().encode(session.snapshot()))
    try check(roundtrip == session.snapshot(), "campaign snapshot retains isolated result provenance")
    print("Campaign self-tests passed: \(count)")
}
