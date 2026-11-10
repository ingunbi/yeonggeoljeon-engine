// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Synthetic temporary files only; no original files or player saves.
func suspendSaveStoreSelfTests() throws {
    var checks = 0
    func check(_ condition:@autoclosure() throws -> Bool,_ message:String) throws {
        guard try condition() else { throw EngineError.invalid("Suspend save regression: \(message)") }
        checks += 1
    }
    func rejects(_ operation:() throws -> Void) -> Bool { do { try operation();return false } catch { return true } }
    struct Payload:Codable,Equatable { var turn:Int;var rng:UInt32 }
    enum TestFailure:Error { case rejected }
    struct FailingPayload:Codable {
        init() {}
        init(from decoder:Decoder) throws { throw TestFailure.rejected }
        func encode(to encoder:Encoder) throws { throw TestFailure.rejected }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("suspend-tests-"+UUID().uuidString,isDirectory:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let store = SuspendSaveStore(directory:root),other = SuspendSaveStore(directory:root)
    try check(try store.entry() == nil,"a fresh store has no continuation")
    try check(rejects { _ = try store.resume(as:Payload.self) { $0 } },"missing save is rejected")
    let ordinary = root.appendingPathComponent("slots",isDirectory:true)
    try FileManager.default.createDirectory(at:ordinary,withIntermediateDirectories:true)
    let ordinaryNames = ["slot-0.json","auto.json","quick.json","battle-start.json"]
    for name in ordinaryNames { try Data(name.utf8).write(to:ordinary.appendingPathComponent(name)) }
    let first = Payload(turn:4,rng:0x12345678)
    let entry = try store.write(first,title:"synthetic battle",date:Date(timeIntervalSince1970:123))
    try check(try store.entry() == entry,"metadata is committed with the snapshot")
    let initialBytes = try Data(contentsOf:store.fileURL)
    let initialJSON = try JSONSerialization.jsonObject(with:initialBytes) as! [String:Any]
    try check((initialJSON["header"] as? [String:Any])?["format"] as? Int == 2,"new suspend envelopes use the old-reader safety revision")
    try check(rejects { _ = try store.write(FailingPayload(),title:"failed") },"encoding failure is reported")
    try check(try Data(contentsOf:store.fileURL) == initialBytes,"encoding failure preserves the previous continuation")
    try check(rejects { _ = try store.resume(as:Payload.self) { _ -> Int in throw TestFailure.rejected } },"failed reconstruction is reported")
    try check(try Data(contentsOf:store.fileURL) == initialBytes,"failed reconstruction does not consume the save")
    try check(rejects { _ = try store.resume(as:Payload.self,expectedID:UUID()) { $0 } },"stale confirmation cannot consume another save")
    try check(try store.entry() == entry,"stale confirmation keeps the current save")
    let restored = try store.resume(as:Payload.self,expectedID:entry.id) { payload in
        try check(payload == first,"turn and RNG survive the round trip")
        try check(rejects { _ = try other.resume(as:Payload.self) { $0 } },"another store cannot consume an in-flight continuation")
        try check(rejects { _ = try other.write(Payload(turn:5,rng:9),title:"racing save") },"a racing save cannot replace an in-flight continuation")
        return payload
    }
    try check(restored == first && (try store.entry()) == nil,"only a successfully prepared continuation is consumed")
    try check(rejects { _ = try store.resume(as:Payload.self) { $0 } },"a second load cannot reuse the consumed save")
    try check(try ordinaryNames.allSatisfy { try Data(contentsOf:ordinary.appendingPathComponent($0)) == Data($0.utf8) },
              "ordinary numbered, automatic, quick, and battle-start saves remain byte-identical")
    _ = try store.write(first,title:"first")
    let second = Payload(turn:8,rng:17),secondEntry = try store.write(second,title:"second")
    try check(try store.entry() == secondEntry && store.resume(as:Payload.self) { $0 } == second,"the single slot atomically replaces an older continuation")

    // This is the revision gate of the previous reader. An old Codable
    // payload would otherwise ignore newly added extras and consume the file.
    func legacyRevisionOneRead(_ bytes:Data) throws {
        let json = try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
        guard let header = json["header"] as? [String:Any],header["format"] as? Int == 1,
              header["kind"] as? String == "native-engine-suspend" else { throw SuspendSaveStore.Failure.unsupported }
    }
    var expanded = try nativeSaveTestResume()
    var extras = CampaignExtras();try extras.setFavorite(0,enabled:true)
    try extras.setItemProtection(personID:0,itemID:4,enabled:true,protectUse:true)
    expanded.extras = extras
    let expandedEntry = try store.write(expanded,title:"synthetic extras")
    let expandedBytes = try Data(contentsOf:store.fileURL)
    try check(rejects { try legacyRevisionOneRead(expandedBytes) },"revision-one readers reject the new envelope before consuming newer campaign data")
    try check(try Data(contentsOf:store.fileURL) == expandedBytes,"legacy rejection leaves the one-use file untouched")
    let expandedResult = try store.resume(as:OriginalCampaignResume.self,expectedID:expandedEntry.id) { $0 }
    try check(expandedResult.extras == extras && (try store.entry()) == nil,"new-reader resumption preserves campaign extras and consumes once")

    _ = try store.write(first,title:"legacy compatibility")
    var legacyJSON = try JSONSerialization.jsonObject(with:Data(contentsOf:store.fileURL)) as! [String:Any]
    var legacyHeader = legacyJSON["header"] as! [String:Any];legacyHeader["format"] = 1;legacyJSON["header"] = legacyHeader
    let legacyBytes = try JSONSerialization.data(withJSONObject:legacyJSON)
    try legacyBytes.write(to:store.fileURL)
    try legacyRevisionOneRead(legacyBytes)
    try check(try store.entry() != nil && store.resume(as:Payload.self) { $0 } == first,"revision-one files retain read and consume compatibility")

    var futureJSON = legacyJSON,futureHeader = legacyHeader
    futureHeader["format"] = 3;futureJSON["header"] = futureHeader;futureJSON["snapshot"] = ["future":"unrecognized payload"]
    let futureBytes = try JSONSerialization.data(withJSONObject:futureJSON);try futureBytes.write(to:store.fileURL)
    var preparedFuture = false,unsupportedFuture = false
    do { _ = try store.resume(as:Payload.self) { payload in preparedFuture = true;return payload } }
    catch SuspendSaveStore.Failure.unsupported { unsupportedFuture = true }
    try check(unsupportedFuture && !preparedFuture,"future format is classified before payload decoding or reconstruction")
    try check(try Data(contentsOf:store.fileURL) == futureBytes,"unsupported future continuation stays untouched")
    _ = try store.write(first,title:"valid")
    let goodBytes = try Data(contentsOf:store.fileURL)
    var json = try JSONSerialization.jsonObject(with:goodBytes) as! [String:Any]
    var header = json["header"] as! [String:Any];header["kind"] = "native-engine-resume";json["header"] = header
    let foreign = try JSONSerialization.data(withJSONObject:json)
    try foreign.write(to:store.fileURL)
    try check(rejects { _ = try store.resume(as:Payload.self) { $0 } },"ordinary resume kind is rejected in the suspend slot")
    try check(try Data(contentsOf:store.fileURL) == foreign,"unsupported save is retained for recovery")
    let broken = Data("{broken".utf8);try broken.write(to:store.fileURL)
    try check(rejects { _ = try store.resume(as:Payload.self) { $0 } },"truncated or corrupt JSON is rejected")
    try check(try Data(contentsOf:store.fileURL) == broken,"corrupt save is not consumed")
    try check(rejects { _ = try store.write(first,title:String(repeating:"x",count:513)) },"unbounded metadata is rejected")
    try check(try Data(contentsOf:store.fileURL) == broken,"rejected metadata leaves the prior file intact")
    try goodBytes.write(to:store.fileURL)
    let attributes = try FileManager.default.attributesOfItem(atPath:store.fileURL.path)
    try check((attributes[.type] as? FileAttributeType) == .typeRegular,"save is a regular atomic file")
    // A sparse oversized file checks the input limit without allocating it.
    let handle = try FileHandle(forWritingTo:store.fileURL)
    try handle.truncate(atOffset:UInt64(SuspendSaveStore.maximumBytes+1));try handle.close()
    try check(rejects { _ = try store.resume(as:Payload.self) { $0 } },"oversized input is rejected before decoding")
    try check(FileManager.default.fileExists(atPath:store.fileURL.path),"oversized input is retained")
    print("Suspend save store self-tests passed: \(checks)")
}
