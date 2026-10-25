// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func originalEndingSelfTests() throws {
    var checks = 0
    func check(_ value: Bool, _ reason: String) throws {
        checks += 1
        if !value { throw EngineError.invalid("Original ending regression: \(reason)") }
    }
    let frame = OriginalEndingFrame(sourceTicks: 20, layers: [.init(asset: "synthetic", x: 1, y: 2)], caption: nil)
    var second = frame; second.sourceTicks = 10
    let frontier = OriginalEndingFrontier(resource: "synthetic", offset: 37, reason: "unrestored following source action")
    let program = OriginalEndingProgram(id: "synthetic", frames: [frame, second], complete: false, frontier: frontier)
    let catalog = OriginalEndingCatalog(format: 1, sourceDigest: String(repeating: "a", count: 64), canvas: [640,400], sourceTicksPerSecond: 100,
        assets: [.init(id: "synthetic", image: "images/synthetic.png", width: 8, height: 16)],
        selections: [.init(value: 1, program: "synthetic", complete: false)], programs: [program])
    let session = try OriginalEndingSession(catalog: catalog, selection: 1)
    try check(session.output == .frame(frame), "initial source frame")
    _ = try session.advance(sourceTicks: 19)
    try check(session.snapshot().elapsedSourceTicks == 19 && session.snapshot().frameIndex == 0, "deadline retains frame")
    let restored = try OriginalEndingSession(catalog: catalog, selection: 1, state: session.snapshot())
    try check(try restored.advance(sourceTicks: 1) == .frame(second), "checkpoint keeps exact deadline")
    try check(try restored.advance(sourceTicks: 100) == .unsupported(frontier), "source EOF remains explicit frontier")
    try check(restored.snapshot().frameIndex == 2 && restored.snapshot().elapsedSourceTicks == 0, "frontier checkpoint is bounded")
    do { _ = try OriginalEndingSession(catalog: catalog, selection: 0); throw EngineError.invalid("unknown ending accepted") }
    catch EngineError.invalid(let reason) where reason.contains("not restored") { checks += 1 }
    var foreign = session.snapshot(); foreign.sourceDigest = String(repeating: "b", count: 64)
    do { _ = try OriginalEndingSession(catalog: catalog, selection: 1, state: foreign); throw EngineError.invalid("foreign checkpoint accepted") }
    catch EngineError.invalid(let reason) where reason.contains("checkpoint") { checks += 1 }
    var invalid = catalog; invalid.programs[0].complete = true
    do { try invalid.validate(); throw EngineError.invalid("EOF ending accepted") }
    catch EngineError.invalid(let reason) where reason.contains("frontier") { checks += 1 }
    var badPath = catalog; badPath.assets[0].image = "../original.png"
    do { try badPath.validate(); throw EngineError.invalid("foreign path accepted") }
    catch EngineError.invalid(let reason) where reason.contains("asset path") { checks += 1 }
    print("Original ending self-tests: \(checks) assertions passed")
}
