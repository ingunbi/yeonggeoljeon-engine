// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(AppKit)
import UniformTypeIdentifiers
#endif

extension OriginalCampaignHost {
    /// Optional reviewed metadata lives alongside the caller-selected data,
    /// never in the public source. Failure disables hints, not the campaign.
    func loadDefaultEventHints() {
        let url = data.root.appendingPathComponent("event-hints.json")
        guard FileManager.default.fileExists(atPath:url.path) else {return}
        do {try selectEventHints(from:url)}
        catch {eventHintCatalog = nil;eventHintCatalogError = String(describing:error)}
    }
    func selectEventHints(from url:URL) throws {
        let catalog = try ReviewedEventHints.Catalog.load(from:url)
        guard catalog.sourceIdentity == vm.program.sourceDigest else {
            throw EngineError.invalid("현재 게임 자료와 일치하지 않는 이벤트 힌트입니다. 기존 진행은 유지됩니다.")
        }
        eventHintCatalog = catalog;eventHintCatalogError = nil
    }
    var eventHintContext:ReviewedEventHints.Context? {
        guard stage.palette == 3,let battle,let identity = vm.program.sourceDigest,
              SourceCatalogIdentity.valid(identity) else {return nil}
        var visible:[Int:GridPoint] = [:]
        for unit in battle.units.values where unit.status == 2 && (!unit.enemy || unit.scriptFlags&0x20 != 0) {
            visible[unit.person] = unit.position
        }
        return .init(sourceIdentity:identity,battleID:battle.definition.id,turn:battle.turns.roundIndex+1,visiblePeople:visible)
    }
    func discoverEventHints(level:ReviewedEventHints.Level) {
        guard let context = eventHintContext else {return}
        let result = ReviewedEventHints.project(catalog:eventHintCatalog,context:context,level:level,progress:extras.eventHints)
        guard !result.entries.isEmpty else {return}
        var progress = extras.eventHints.flatMap {$0.sourceIdentity == context.sourceIdentity ? $0 : nil}
            ?? ReviewedEventHints.Progress(sourceIdentity:context.sourceIdentity)
        for entry in result.entries {progress.recordDiscovered(entry.id)}
        extras.eventHints = progress
    }
    /// Invoked only when the VM commits a terminal return, before its caller
    /// changes maps. A redraw, projected condition, or old save never calls it.
    func recordReviewedEventCompletion(_ returned:OriginalCampaignInterpreterReturn) {
        guard let context = eventHintContext else {return}
        let ids = ReviewedEventHints.completedIDs(catalog:eventHintCatalog,sourceIdentity:context.sourceIdentity,
            battleID:context.battleID,returned:returned)
        guard !ids.isEmpty else {return}
        var progress = extras.eventHints.flatMap {$0.sourceIdentity == context.sourceIdentity ? $0 : nil}
            ?? ReviewedEventHints.Progress(sourceIdentity:context.sourceIdentity)
        for id in ids {progress.recordCompleted(id)}
        extras.eventHints = progress
    }
}

#if canImport(AppKit)
extension CampaignManagementUI {
    func showEventHints(onLocate:@escaping(GridPoint)->Void,onClose:@escaping()->Void) {
        guard let context = host.eventHintContext else {
            overlay.show(CanvasNotice(speaker:"이벤트 힌트",text:"전투 중에 확인할 수 있습니다.",portrait:nil,onDismiss:onClose));return
        }
        let level = OriginalSettings.current.eventHintLevel
        host.discoverEventHints(level:level)
        let back = {self.showEventHints(onLocate:onLocate,onClose:onClose)}
        var sheet = ReviewedEventHintsUI.sheet(catalog:host.eventHintCatalog,context:context,level:level,
            progress:host.extras.eventHints,onLevel:{level in
                var settings = OriginalSettings.current;settings.eventHintLevel = level;OriginalSettings.current = settings;back()
            },onSelectCatalog:{
                let picker = NSOpenPanel();picker.title = "검토된 이벤트 힌트 선택"
                picker.canChooseDirectories = false;picker.allowsMultipleSelection = false;picker.allowedContentTypes = [.json]
                guard picker.runModal() == .OK,let url = picker.url else {back();return}
                do {
                    try self.host.selectEventHints(from:url)
                    var settings = OriginalSettings.current;settings.eventHintCatalogPath = url.path;OriginalSettings.current = settings
                    back()
                } catch {self.failure(error,returning:back)}
            },onLocate:onLocate,onClose:onClose)
        if level != .off,let error = host.eventHintCatalogError {sheet.line = "힌트 자료를 열지 못했습니다. 전투는 계속할 수 있습니다.\n"+error}
        overlay.show(sheet)
    }
}
#endif
