// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Typed synthetic state for file-format tests, never a caller's campaign.
/// It is intentionally independent of decoded game tables and host loading.
func nativeSaveTestResume(money:Int = 1) throws -> OriginalCampaignResume {
    let data = try DataSet(resources:Resources(format:1,maps:[:],actors:[:]),
        scene:Scene(format:1,id:"synthetic-slot",name:"synthetic",width:640,height:400,coordinateSystem:"town",commands:[]))
    let stage = Runtime(data,hostDriven:true)
    let checkpoint = OriginalCampaignCheckpoint(vm:OriginalCampaignState(),people:[],roster:OriginalRoster(),
        rng:OriginalRNG(state:123),money:money,stage:stage.snapshot(),liveUnits:nil,turns:nil,battleValue24:nil)
    return OriginalCampaignResume(checkpoint:checkpoint,saveOffset:nil,controllerInvocationPending:false,controllerIdle:true,
        controllerAfterInvocationFacings:[],currentEventPerson:nil,carryover:nil,retryCheckpoint:nil,retryHost:nil,
        uncertainReturnContext:nil,limitations:["Synthetic file-format fixture; not a complete game host."])
}

func nativeSaveSlotsSelfTests() throws {
    var checks = 0
    func check(_ condition:@autoclosure() throws -> Bool,_ message:String) throws {
        guard try condition() else { throw EngineError.invalid("Native slot regression: \(message)") };checks += 1
    }
    func rejects(_ operation:() throws -> Void) -> Bool { do { try operation();return false } catch { return true } }
    func rejects(_ failure:OriginalSaveSlots.Failure,_ operation:() throws -> Void) -> Bool {
        do { try operation();return false }
        catch let value as OriginalSaveSlots.Failure { return value == failure }
        catch { return false }
    }
    enum InjectedFailure:Error { case write }
    struct Unencodable:Encodable { func encode(to encoder:Encoder) throws { throw InjectedFailure.write } }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("native-slot-tests-"+UUID().uuidString,isDirectory:true)
    defer { try? fm.removeItem(at:root) }
    let directory = root.appendingPathComponent("slots",isDirectory:true)
    let store = OriginalSaveSlots(directory:directory),key = OriginalSaveSlots.SlotKey.numbered(0)
    let first = try nativeSaveTestResume(money:10),second = try nativeSaveTestResume(money:20),third = try nativeSaveTestResume(money:30)
    let when = Date(timeIntervalSince1970:100)
    func bytes(_ url:URL) throws -> Data { try Data(contentsOf:url) }
    func alter(_ url:URL,_ transform:(inout [String:Any]) -> Void) throws {
        var object = try JSONSerialization.jsonObject(with:bytes(url)) as! [String:Any]
        transform(&object);try JSONSerialization.data(withJSONObject:object).write(to:url,options:.atomic)
    }
    try check(try store.inspections().allSatisfy { $0.status == .empty && !$0.canLoad },"five slots start empty")
    try check(!fm.fileExists(atPath:directory.path),"read-only inspection creates no directory or lock file")
    try check(rejects(.invalidSlot) { _ = try store.inspect(.numbered(-1)) },"negative slots are rejected")
    try check(rejects(.invalidSlot) { _ = try store.read(slot:5) },"out-of-range reads are rejected")
    try check(rejects { try store.write(Unencodable(),title:"bad",slot:0) },"encoding failure is reported")
    try check(!fm.fileExists(atPath:directory.path),"encoding failure creates no managed files")
    try check(rejects { try store.write(["arbitrary":1],title:"bad",slot:0) },"non-resume payloads cannot become successful saves")
    var suspended = first
    suspended.suspension = OriginalCampaignSuspension(presentation:RuntimeSuspension(pendingCommands:[],dialogueRemaining:0,registration:0,hostMaps:[:],hostActors:nil),
        battle:nil,wasWaiting:true,controllerEvent:nil,pendingCache:[],pendingBattleCommands:[],wanderers:[],wanderDice:OriginalRNG(state:9),wanderTime:0,sounds:[])
    try check(rejects(.unsupported) { try store.write(suspended,title:"suspend cannot be copied",slot:0) },
              "ordinary write rejects a suspended payload instead of making it reusable")

    try fm.createDirectory(at:directory,withIntermediateDirectories:true)
    let legacy = directory.appendingPathComponent("slot-0.json"),label = directory.appendingPathComponent("slot-0.label.json")
    try JSONEncoder().encode(first).write(to:legacy)
    let legacyBytes = try bytes(legacy)
    let noLabel = try store.inspect(key)
    try check(noLabel.status == .metadataDamaged && noLabel.canLoad && noLabel.entry?.title == "제목 정보 없음",
              "legacy body without a label is recoverable, not empty")
    try check(try store.read(slot:0).checkpoint.money == 10,"missing metadata does not hide valid progress")
    try Data("broken label".utf8).write(to:label)
    try check(try store.inspect(key).status == .metadataDamaged,"corrupt legacy metadata is distinct from empty")
    try JSONEncoder().encode(OriginalSaveSlots.Entry(title:"legacy",date:when)).write(to:label)
    let labelBytes = try bytes(label)
    try check(try store.inspect(key).status == .ready && store.inspect(key).isLegacy,"valid legacy pairs remain readable")
    try check(!fm.fileExists(atPath:store.storageDirectory.path),"inspecting legacy pairs does not migrate them")

    try store.write(second,title:"second",slot:0,date:when)
    let current = try store.fileURL(for:key),backup = try store.backupURL(for:key)
    let secondBytes = try bytes(current)
    try check(current.deletingLastPathComponent() == store.storageDirectory,"new saves use a path older builds never address")
    try check(try bytes(legacy) == legacyBytes && bytes(label) == labelBytes,"migration leaves both old files byte-identical")
    try check(try store.inspect(key).status == .ready && !store.inspect(key).isLegacy && store.read(slot:0).checkpoint.money == 20,
              "new envelopes take precedence and contain typed progress")
    try check(try OriginalSaveSlots.readFile(from:backup).checkpoint.money == 10,"first migration preserves the previous good state")
    try check(try store.inspect(key).backupEntry?.title == "legacy" && store.inspect(key).canRestoreLegacy,
              "normal and explicit legacy recovery candidates are visible")
    try check(store.entries()[0] == .init(title:"second",date:when),"legacy entry API still returns metadata")
    try check(rejects { _ = try OriginalCampaignResume.read(from:current) },"old bare-resume readers reject the new envelope")
    try check(try OriginalSaveSlots.readFile(from:current).checkpoint.money == 20,"file picker helper accepts exported/new envelopes")
    try check(try OriginalSaveSlots.readFile(from:legacy).checkpoint.money == 10,"file picker helper retains bare legacy compatibility")

    try store.write(third,title:"third",slot:0,date:when)
    try check(try OriginalSaveSlots.readFile(from:backup).checkpoint.money == 20,"overwriting rotates exactly the previous normal state")
    let goodCurrent = try bytes(current),goodBackup = try bytes(backup)
    let failBackup = OriginalSaveSlots(directory:directory,operations:.init(writeAtomically:{ data,url in
        if url == backup { throw InjectedFailure.write };try data.write(to:url,options:.atomic)
    }))
    try check(rejects { try failBackup.write(first,title:"will fail",slot:0) },"backup write failure aborts save")
    try check(try bytes(current) == goodCurrent && bytes(backup) == goodBackup,"backup failure preserves both prior complete files")
    let failCommit = OriginalSaveSlots(directory:directory,operations:.init(writeAtomically:{ data,url in
        if url == current { throw InjectedFailure.write };try data.write(to:url,options:.atomic)
    }))
    try check(rejects { try failCommit.write(first,title:"will fail",slot:0) },"current replacement failure is reported")
    try check(try bytes(current) == goodCurrent && store.read(slot:0).checkpoint.money == 30,"failed current commit keeps the running slot intact")
    try check(try OriginalSaveSlots.readFile(from:backup).checkpoint.money == 30,"failed final commit still leaves a complete normal recovery copy")
    try check(rejects { try store.write(first,title:String(repeating:"x",count:513),slot:0) },"unbounded metadata is rejected before writes")
    try check(try bytes(current) == goodCurrent,"invalid metadata preserves current bytes")

    var nestedSaveRejected = false,nestedRestoreRejected = false,nestedExportRejected = false
    let competing = OriginalSaveSlots(directory:directory)
    let withLockProbe = OriginalSaveSlots(directory:directory,operations:.init(writeAtomically:{ data,url in
        nestedSaveRejected = rejects(.busy) { try competing.write(first,title:"race",slot:0) }
        nestedRestoreRejected = rejects(.busy) { _ = try competing.restoreBackup(key) }
        nestedExportRejected = rejects(.busy) { _ = try competing.exportBackup(key,to:root.appendingPathComponent("race.json")) }
        try data.write(to:url,options:.atomic)
    }))
    try withLockProbe.write(second,title:"locked",slot:0,date:when)
    try check(nestedSaveRejected && nestedRestoreRejected && nestedExportRejected,"independent instances cannot race a save, restore, or export")
    try check(!fm.fileExists(atPath:root.appendingPathComponent("race.json").path),"rejected concurrent export writes nothing")

    try alter(current) { $0["entry"] = ["title":7] }
    try check(try store.inspect(key).status == .metadataDamaged && store.inspect(key).canLoad,
              "envelope metadata damage still exposes readable progress")
    try check(try store.read(slot:0).checkpoint.money == 20,"metadata damage does not alter payload")
    try alter(current) { $0["payload"] = ["money":99] }
    try check(try store.inspect(key).status == .dataDamaged && !store.inspect(key).canLoad,"structurally broken payload is not a successful slot")
    try check(rejects { _ = try store.read(slot:0) },"broken modern payload never silently loads the legacy state")
    let brokenCurrent = try bytes(current)
    let restored = try store.restoreBackup(key)
    try check(try store.read(slot:0).checkpoint.money == 30,"explicit restore uses the last good copy")
    try check(restored.preservedDirectory != nil,"recovery reports the displaced-file folder")
    try check(try bytes(restored.preservedDirectory!.appendingPathComponent(current.lastPathComponent)) == brokenCurrent,
              "recovery preserves the exact damaged bytes")
    try check(try bytes(legacy) == legacyBytes && bytes(label) == labelBytes,"recovery never modifies legacy pairs")
    _ = try store.restoreLegacy(key)
    try check(try store.read(slot:0).checkpoint.money == 10,"legacy recovery requires an explicit operation")

    try store.write(third,title:"future base",slot:0,date:when)
    try alter(current) { $0["format"] = 999 }
    let futureBytes = try bytes(current)
    try check(try store.inspect(key).status == .unsupported && !store.inspect(key).canLoad,"future envelope versions are identified")
    try check(rejects(.unsupported) { try store.write(first,title:"no downgrade",slot:0) },"saving cannot overwrite a future envelope")
    try check(rejects(.unsupported) { _ = try store.restoreBackup(key) },"backup recovery cannot overwrite a future envelope")
    try check(rejects(.unsupported) { _ = try store.restoreLegacy(key) },"legacy recovery cannot downgrade a future envelope")
    try check(try bytes(current) == futureBytes,"unsupported file remains byte-identical after rejected operations")
    let savedBackup = try bytes(backup)
    try secondBytes.write(to:current,options:.atomic)
    try alter(backup) { $0["format"] = 999 }
    let futureBackup = try bytes(backup)
    try check(rejects(.unsupported) { _ = try store.backup(key) },"a future backup cannot be silently downgraded")
    try check(try bytes(backup) == futureBackup && bytes(current) == secondBytes,"future backup refusal preserves both files")
    try savedBackup.write(to:backup,options:.atomic)
    try alter(backup) { $0["entry"] = ["date":"bad"] }
    try check(try store.inspect(key).canRestoreBackup,"backup metadata damage still offers its valid payload")
    _ = try store.restoreBackup(key)
    try check(try store.read(slot:0).checkpoint.money == 10,"backup with damaged metadata recovers progress with fallback title")
    try savedBackup.write(to:backup,options:.atomic)
    try secondBytes.write(to:current,options:.atomic)
    try alter(current) { object in var payload = object["payload"] as! [String:Any];payload["format"] = 999;object["payload"] = payload }
    try check(try store.inspect(key).status == .unsupported,"future payload versions are also identified")
    try secondBytes.write(to:current,options:.atomic)

    let exported = root.appendingPathComponent("ordinary-backup.json")
    _ = try store.exportBackup(key,to:exported)
    try check(try OriginalSaveSlots.readFile(from:exported).checkpoint.money == 20,"exports are complete directly readable envelopes")
    let exportBytes = try bytes(exported)
    try check(rejects(.destinationExists) { _ = try store.exportBackup(key,to:exported) },"export requires a new destination name")
    try check(try bytes(exported) == exportBytes,"failed duplicate export does not replace the destination")
    let failedExport = root.appendingPathComponent("failed-export.json")
    let exportFailure = OriginalSaveSlots(directory:directory,operations:.init(writeAtomically:{ data,url in
        if url.lastPathComponent.hasPrefix(".native-save-export-") { throw InjectedFailure.write }
        try data.write(to:url,options:.atomic)
    }))
    try check(rejects { _ = try exportFailure.exportBackup(key,to:failedExport) },"staged export failure is reported")
    try check(!fm.fileExists(atPath:failedExport.path) && (try fm.contentsOfDirectory(atPath:root.path)).allSatisfy { !$0.hasPrefix(".native-save-export-") },
              "failed export leaves neither partial target nor staged files")
    try check(rejects(.unsafeDestination) { _ = try store.exportBackup(key,to:root.appendingPathComponent("suspend.json")) },
              "exports cannot recreate a consumed suspend slot")
    try check(rejects(.unsafeDestination) { _ = try store.exportBackup(key,to:directory.appendingPathComponent("other.json")) },
              "exports cannot overwrite any managed ordinary-slot path")
    let suspendFile = root.appendingPathComponent("suspend.json"),sentinel = Data("unconsumed-suspend-sentinel".utf8)
    try sentinel.write(to:suspendFile)
    _ = try store.backup(key);_ = try store.restoreBackup(key)
    try check(try bytes(suspendFile) == sentinel,"ordinary backup and restoration leave suspension bytes unchanged")
    try fm.removeItem(at:suspendFile)
    _ = try store.restoreBackup(key)
    try check(!fm.fileExists(atPath:suspendFile.path),"ordinary recovery cannot resurrect a consumed suspension")

    try store.write(first,title:"auto",named:.auto,date:when)
    try store.write(second,title:"battle",named:.battleStart,date:when)
    try store.write(third,title:"old quick",named:.quick,date:when)
    try check(try store.read(.auto).checkpoint.money == 10 && store.read(.battleStart).checkpoint.money == 20 && store.read(.quick).checkpoint.money == 30,
              "all ordinary named slots keep their existing read/write API")
    try check(store.entries().compactMap { $0 }.count == 1,"named slots do not occupy numbered slots")
    let orphanLabel = directory.appendingPathComponent("slot-1.label.json")
    try JSONEncoder().encode(OriginalSaveSlots.Entry(title:"orphan",date:when)).write(to:orphanLabel)
    try check(try store.inspect(.numbered(1)).status == .dataDamaged,"a label without progress is damaged, not an empty slot")

    try Data("{truncated".utf8).write(to:current,options:.atomic)
    let malformed = try bytes(current)
    try check(try store.inspect(key).status == .dataDamaged && !store.inspect(key).canLoad,"truncated JSON is reported as progress damage")
    let badRestore = OriginalSaveSlots(directory:directory,operations:.init(writeAtomically:{ data,url in
        if url == current { throw InjectedFailure.write };try data.write(to:url,options:.atomic)
    }))
    try check(rejects { _ = try badRestore.restoreBackup(key) },"failed recovery commit is reported")
    try check(try bytes(current) == malformed && store.inspect(key).canRestoreBackup,"failed recovery keeps current bytes and valid backup")
    let handle = try FileHandle(forWritingTo:current)
    try handle.truncate(atOffset:UInt64(OriginalSaveSlots.maximumBytes+1));try handle.close()
    try check(try store.inspect(key).status == .dataDamaged && !store.inspect(key).canLoad,"oversized files are rejected before decoding")
    try check(fm.fileExists(atPath:current.path),"oversized files are retained")
    try check(rejects(.invalidSlot) { _ = try store.backup(.numbered(5)) },"backup rejects arbitrary slot names and out-of-range numbers")
    let external = root.appendingPathComponent("external",isDirectory:true)
    let linkedRoot = root.appendingPathComponent("linked-store",isDirectory:true)
    try fm.createDirectory(at:external,withIntermediateDirectories:true)
    try fm.createDirectory(at:linkedRoot,withIntermediateDirectories:true)
    let linkedStore = OriginalSaveSlots(directory:linkedRoot)
    try fm.createSymbolicLink(at:linkedStore.storageDirectory,withDestinationURL:external)
    try check(rejects { try linkedStore.write(first,title:"blocked path",slot:0) },"managed storage refuses a symlink directory")
    try check(try fm.contentsOfDirectory(atPath:external.path).isEmpty,"rejected managed symlink never writes outside the store")
    let aliasRoot = root.appendingPathComponent("root-alias",isDirectory:true)
    try fm.createSymbolicLink(at:aliasRoot,withDestinationURL:directory)
    let aliasStore = OriginalSaveSlots(directory:aliasRoot)
    try aliasStore.write(first,title:"root alias",slot:2)
    try check(try aliasStore.read(slot:2).kind == first.kind,"trusted root aliases support first managed-directory creation")
    let internalRoot = root.appendingPathComponent("internal-link-store",isDirectory:true)
    let internalTarget = internalRoot.appendingPathComponent("elsewhere",isDirectory:true)
    try fm.createDirectory(at:internalTarget,withIntermediateDirectories:true)
    let internalStore = OriginalSaveSlots(directory:internalRoot)
    try fm.createSymbolicLink(at:internalStore.storageDirectory,withDestinationURL:internalTarget)
    try check(rejects {try internalStore.write(first,title:"internal link",slot:0)},"managed symlinks inside the root are also refused")
    let lockedRoot = root.appendingPathComponent("lock-link-store",isDirectory:true)
    try fm.createDirectory(at:lockedRoot,withIntermediateDirectories:true)
    let lockTarget = root.appendingPathComponent("lock-target"),lockSentinel = Data("lock target must remain".utf8)
    try lockSentinel.write(to:lockTarget)
    try fm.createSymbolicLink(at:lockedRoot.appendingPathComponent(".native-slots.lock"),withDestinationURL:lockTarget)
    try check(rejects { try OriginalSaveSlots(directory:lockedRoot).write(first,title:"bad lock",slot:0) },"a symlink lock is rejected")
    try check(try bytes(lockTarget) == lockSentinel,"a rejected lock preserves its target bytes")
    let practice = OriginalSaveSlots(directory:root.appendingPathComponent("practice/slots"),practiceMode:true)
    var practiceSave = first;practiceSave.kind = "native-engine-practice"
    try practice.write(practiceSave,title:"practice",slot:0)
    let practiceFile = try practice.fileURL(for:key)
    try check(try practice.read(slot:0).kind == "native-engine-practice","practice has a separately tagged ordinary slot")
    try check(rejects(.unsupported) {_ = try OriginalSaveSlots.readFile(from:practiceFile)},"ordinary file import refuses a practice envelope")
    try check(rejects(.unsupported) {try store.write(practiceSave,title:"bad import",slot:2)},"ordinary slot refuses a practice payload")
    try check(rejects(.unsupported) {try practice.write(first,title:"bad scope",slot:2)},"practice slots require explicit practice tagging")
    practiceSave.checkpoint.money = 45
    try practice.write(practiceSave,title:"practice new",slot:0)
    _ = try practice.restoreBackup(key)
    try check(try practice.read(slot:0).checkpoint.money == 10,"practice backup restores only its own previous state")
    print("Native save slots self-tests passed: \(checks)")
}
