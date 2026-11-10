// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func campaignTerminationSelfTests() throws {
    func check(_ value:Bool,_ message:String) throws {
        guard value else { throw EngineError.invalid("Termination test: \(message)") }
    }
    var gate = CampaignTerminationGate()
    try check(gate.begin(),"initial request")
    try check(!gate.begin(),"duplicate confirmation rejected")
    gate.choose(.save)
    try check(!gate.consumeApproval(),"queued save is not a completed save")
    try check(!gate.begin(),"OS request during queued save rejected")
    gate.cancel()
    try check(!gate.finishSave(success:true),"cancelled callback cannot authorize exit")
    try check(gate.begin(),"retry after cancellation")
    gate.choose(.save)
    try check(!gate.finishSave(success:false),"write failure keeps game")
    try check(!gate.consumeApproval(),"failed save never approves exit")
    try check(gate.begin(),"retry after failure")
    gate.choose(.save)
    try check(gate.finishSave(success:true),"completed write approves exit")
    try check(gate.consumeApproval(),"approval delivered once")
    try check(!gate.consumeApproval(),"approval cannot be reused")
    try check(gate.begin(),"new request")
    gate.choose(.discard)
    try check(gate.consumeApproval(),"explicit discard allows exit")
    try check(gate.begin(),"new cancellation")
    gate.choose(.cancel)
    try check(gate.phase == .idle && !gate.consumeApproval(),"cancel preserves session")
    print("PASS: campaign termination request ownership and save failure boundaries")
}
