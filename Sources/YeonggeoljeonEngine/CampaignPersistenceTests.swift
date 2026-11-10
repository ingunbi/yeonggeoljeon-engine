// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func campaignPersistenceSelfTests() throws {
    var checks = 0
    func check(_ condition:@autoclosure() -> Bool,_ message:String) throws {
        guard condition() else { throw EngineError.invalid("Campaign persistence regression: \(message)") }
        checks += 1
    }
    enum WriteFailure:Error { case unavailable }
    var autosave = CampaignAutosave(),writes = 0
    func writeFailure() throws { writes += 1;throw WriteFailure.unavailable }
    if case .failed(_,let notify) = autosave.attempt(key:"town",now:100,write:writeFailure) {
        try check(notify,"the first failed save is reported")
    } else { throw EngineError.invalid("Failed autosave was accepted") }
    try check(autosave.savedKey == nil,"failure does not mark the scene as saved")
    _ = autosave.attempt(key:"town",now:101,write:writeFailure)
    _ = autosave.attempt(key:"world",now:109,write:writeFailure)
    try check(writes == 1,"neither another frame nor another map bypasses retry backoff")
    if case .failed(_,let notify) = autosave.attempt(key:"town",now:110,write:writeFailure) {
        try check(!notify,"continued failure does not repeat the player notification")
    } else { throw EngineError.invalid("Autosave did not retry after backoff") }
    if case .saved(let recovered) = autosave.attempt(key:"town",now:120,write:{ writes += 1 }) {
        try check(recovered,"recovery is reported after the destination works again")
    } else { throw EngineError.invalid("Autosave failed to recover in the same scene") }
    try check(autosave.savedKey == "town" && writes == 3,"only the successful write commits the scene key")
    _ = autosave.attempt(key:"town",now:121,write:{ writes += 1 })
    try check(writes == 3,"an already saved scene does not rewrite every frame")
    if case .saved(let recovered) = autosave.attempt(key:"world",now:122,write:{ writes += 1 }) {
        try check(!recovered,"the next scene saves immediately after recovery")
    } else { throw EngineError.invalid("New scene was not saved") }
    if case .failed(_,let notify) = autosave.attempt(key:"palace",now:123,write:writeFailure) {
        try check(notify && autosave.savedKey == "world","a later failure is reported and keeps the previous successful save")
    } else { throw EngineError.invalid("Later failure was accepted") }

    try check(CampaignEscapeRoute.resolve(overlayActive:true,completedQuit:false,started:true,fieldReady:true) == .overlay,
              "an open menu handles Escape before the field does")
    try check(CampaignEscapeRoute.resolve(overlayActive:false,completedQuit:false,started:true,fieldReady:true) == .fieldMenu,
              "Escape opens the menu in an idle field")
    try check(CampaignEscapeRoute.resolve(overlayActive:false,completedQuit:false,started:true,fieldReady:false) == .ignore,
              "Escape during movement or script execution never closes the campaign")
    try check(CampaignEscapeRoute.resolve(overlayActive:false,completedQuit:false,started:false,fieldReady:false) == .titleMenu,
              "Escape with no campaign shows the title menu")
    try check(CampaignEscapeRoute.resolve(overlayActive:false,completedQuit:true,started:true,fieldReady:false) == .closeCompleted,
              "the completed source quit may close its window")
    let flags = [0x80,0x80,0x80]+Array(repeating:0x81,count:381)
    try check(flags.filter { OriginalPeople.isCompanion(flags:$0,leaderFlags:flags[0]) }.count == 3,
              "save summaries count the leader's joined force, not every living person in the catalogue")
    try check(!OriginalPeople.isCompanion(flags:0,leaderFlags:0x80) && OriginalPeople.isCompanion(flags:0x85,leaderFlags:0x85) &&
              !OriginalPeople.isCompanion(flags:0x80,leaderFlags:0x85),"companion eligibility respects membership and the saved leader's force")
    try check(CampaignSaveLabels.chapter(0,sourceLabels:["서","제1"]) == "서장" &&
              CampaignSaveLabels.chapter(1,sourceLabels:["서","제1"]) == "제1장",
              "saved chapter zero is the prologue, followed by source chapter one")
    try check(CampaignSaveLabels.chapter(1,sourceLabels:["서장","제1장"]) == "제1장" &&
              CampaignSaveLabels.chapter(0,sourceLabels:[]) == "서장" && CampaignSaveLabels.chapter(2,sourceLabels:[]) == "2장",
              "complete chapter labels do not duplicate their suffix and absent labels preserve source numbering")
    print("Campaign persistence self-tests passed: \(checks)")
}
