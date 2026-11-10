// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func battleArchiveSelfTests() throws {
    var checks = 0
    func check(_ value:@autoclosure() throws -> Bool,_ reason:String) throws {
        guard try value() else {throw EngineError.invalid("Battle archive regression: "+reason)};checks += 1
    }
    func rejects(_ body:() throws->Void)->Bool {do {try body();return false} catch {return true}}
    let fm = FileManager.default,root = fm.temporaryDirectory.appendingPathComponent("battle-archive-tests-"+UUID().uuidString).resolvingSymlinksInPath()
    try fm.createDirectory(at:root,withIntermediateDirectories:true);defer {try? fm.removeItem(at:root)}
    let dataFolder = root.appendingPathComponent("data"),archiveFolder = root.appendingPathComponent("archives")
    try fm.createDirectory(at:dataFolder,withIntermediateDirectories:true)
    try Data("synthetic rules".utf8).write(to:dataFolder.appendingPathComponent("rules.json"))
    let cancelled = BattleArchiveCancellation();cancelled.cancel()
    do {_ = try BattleReplayIdentity.data(at:dataFolder,cancellation:{try cancelled.check()});throw EngineError.invalid("Cancelled hash was started")}
    catch BattleArchiveCancellation.Cancelled.requested {checks += 1}
    let duringHash = BattleArchiveCancellation()
    var callbacks = 0
    do {
        _ = try BattleReplayIdentity.data(at:dataFolder,cancellation:{try duringHash.check()},progress:{_,_ in callbacks += 1;duringHash.cancel()})
        throw EngineError.invalid("Cancelled hash continued")
    } catch BattleArchiveCancellation.Cancelled.requested {checks += 1}
    try check(callbacks == 1,"cancellation interrupts data hashing before later progress callbacks")
    let sharedCancellation = BattleArchiveCancellation(),signal = DispatchSemaphore(value:0)
    DispatchQueue.global().async {sharedCancellation.cancel();signal.signal()}
    try check(signal.wait(timeout:.now()+2) == .success && sharedCancellation.isCancelled,"worker cancellation flag is synchronized across queues")
    try check(try Data(contentsOf:dataFolder.appendingPathComponent("rules.json")) == Data("synthetic rules".utf8),"cancelled verification never writes source data")
    let hash = try BattleReplayIdentity.data(at:dataFolder)
    try check(hash.count == 64 && hash == (try BattleReplayIdentity.data(at:dataFolder)),"data identity is deterministic")
    try Data("changed rules".utf8).write(to:dataFolder.appendingPathComponent("rules.json"))
    try check(hash != (try BattleReplayIdentity.data(at:dataFolder)),"changed rules invalidate identity")
    let alias = dataFolder.appendingPathComponent("alias.json")
    try fm.createSymbolicLink(at:alias,withDestinationURL:dataFolder.appendingPathComponent("rules.json"))
    try check(rejects {_ = try BattleReplayIdentity.data(at:dataFolder)},"data identity refuses symbolic links")
    try fm.removeItem(at:alias)
    var resume = try nativeSaveTestResume()
    resume.battleStart = .init(battleID:"synthetic-replay",terrain:[],pictureTiles:nil,scriptActions:.init())
    let start = BattleReplayStart(resume:resume,terrainChanges:[],pictureChanges:[],hasPictures:false)
    let attempt = UUID(),recording = UUID()
    var archive = BattleReplayArchive(dataDigest:hash,recordingID:recording,attemptID:attempt,battleID:"synthetic-replay",title:"합성 전투",start:start,initialDigest:hash)
    let store = BattleArchiveStore(root:archiveFolder)
    try store.write(archive)
    try check(try store.read(recording).recordingID == recording,"bounded archive writes and reads independently")
    let untouched = try Data(contentsOf:store.url(recording))
    var bad = archive;bad.format = 99
    try check(rejects {try store.write(bad)},"future recording format is rejected")
    bad = archive;bad.rules = "future"
    try check(rejects {try store.write(bad)},"unknown rules version is rejected")
    bad = archive;bad.inputVersion = 99
    try check(rejects {try store.write(bad)},"future input version is rejected")
    bad = archive;bad.complete = true
    try check(rejects {try store.write(bad)},"incomplete recording cannot claim completion")
    bad = archive;bad.checkpoints = [.init(cursor:1,round:0,digest:hash)]
    try check(rejects {try store.write(bad)},"a checkpoint cannot point past the recorded input cursor")
    bad = archive;bad.inputs = [.init(kind:.worldCity,city:2)]
    try check(rejects {try store.write(bad)},"battle archives do not replay unrelated campaign travel")
    try check(try Data(contentsOf:store.url(recording)) == untouched,"failed validation leaves prior archive bytes intact")
    let synthetic = try DataSet(root:dataFolder,resources:Resources(format:1,maps:[:],actors:[:]),scene:Scene(format:1,id:"archive-tests",name:"synthetic",width:640,height:400,coordinateSystem:"town",commands:[]))
    let coordinator = BattleArchiveCoordinator(data:synthetic,root:archiveFolder)
    var progress = BattleArchiveProgress();progress.recordingEnabled = true
    progress.active = .init(recordingID:recording,attemptID:attempt,battleID:archive.battleID,cursor:0)
    let first = OriginalPlayInput(kind:.battleMove,slot:0,x:2,y:3)
    try coordinator.accepted(input:first,progress:&progress)
    let savedCursor = progress
    try coordinator.accepted(input:.init(kind:.battleCancelMove,slot:0),progress:&progress)
    try check(progress.active?.recordingID == recording && progress.active?.cursor == 2,"normal continuation appends without changing attempt/recording")
    var repeated = savedCursor
    let continuedBytes = try Data(contentsOf:store.url(recording))
    try coordinator.accepted(input:.init(kind:.battleCancelMove,slot:0),progress:&repeated)
    try check(repeated.active == progress.active && (try Data(contentsOf:store.url(recording))) == continuedBytes,
        "same accepted input at an older cursor reuses the existing recording without appending or rewriting")
    var old = savedCursor
    try coordinator.accepted(input:.init(kind:.battleWait,slot:0),progress:&old)
    let branch = try store.read(old.active!.recordingID)
    try check(branch.recordingID != recording && branch.attemptID == attempt && branch.parentRecordingID == recording && branch.forkCursor == 1,
              "only a different command after an older cursor forks recording; campaign attempt is preserved")
    try check(branch.inputs == [first,.init(kind:.battleWait,slot:0)] && (try store.read(recording)).inputs == [first,.init(kind:.battleCancelMove,slot:0)],
              "a branch copies exactly its common prefix and never joins another future")
    let encoded = try BattleReplayIdentity.encode(old),decoded = try JSONDecoder().decode(BattleArchiveProgress.self,from:encoded)
    try check(decoded == old,"saved active cursor survives suspension roundtrip")
    var missing = progress;missing.active!.cursor = 8
    try check(rejects {try coordinator.accepted(input:.init(kind:.battleWait,slot:0),progress:&missing)},"a missing recorded tail fails explicitly")
    archive = try store.read(recording);archive.result = 2;archive.finalDigest = hash;archive.complete = true
    archive.checkpoints = [.init(cursor:2,round:0,digest:hash)];try store.write(archive)
    try check(try store.read(recording).complete,"completion requires an indexed final hash")
    var completedPrefix = savedCursor
    let completedBytes = try Data(contentsOf:store.url(recording))
    try coordinator.accepted(input:.init(kind:.battleCancelMove,slot:0),progress:&completedPrefix)
    try check(completedPrefix.active?.recordingID == recording && completedPrefix.active?.cursor == 2 && (try Data(contentsOf:store.url(recording))) == completedBytes,
        "a matching input also reuses a completed recording after an older save")
    let afterFinish = progress
    try coordinator.accepted(input:.init(kind:.battleWait,slot:0),progress:&progress)
    try check(progress.active?.recordingID != afterFinish.active?.recordingID && progress.active?.attemptID == attempt,"continuing a saved completed cursor creates a new branch")
    let outside = root.appendingPathComponent("untouched.json");try Data("keep".utf8).write(to:outside)
    let linkID = UUID();try fm.createSymbolicLink(at:store.url(linkID),withDestinationURL:outside)
    try check(rejects {_ = try store.read(linkID)},"archive reader refuses symlink targets")
    var linked = archive;linked.recordingID = linkID
    try check(rejects {try store.write(linked)},"archive writer refuses symlink targets")
    try check(try Data(contentsOf:outside) == Data("keep".utf8),"archive rejection preserves outside data")
    let badBytes = Data("{invalid".utf8);try badBytes.write(to:store.url(linkID),options:.atomic)
    try check(rejects {_ = try store.read(linkID)},"malformed archive cannot be opened")
    let normal = OriginalSaveSlots(directory:root.appendingPathComponent("normal-slots"))
    try normal.write(try nativeSaveTestResume(),title:"본편",slot:0)
    let normalBytes = try Data(contentsOf:normal.fileURL(for:.numbered(0)))
    let beforeNormal = fm.fileExists(atPath:root.appendingPathComponent("suspend.json").path)
    _ = try store.read(recording)
    try check(try Data(contentsOf:normal.fileURL(for:.numbered(0))) == normalBytes && fm.fileExists(atPath:root.appendingPathComponent("suspend.json").path) == beforeNormal,
              "archive access does not call normal or suspend save storage")
    let legacy = try JSONDecoder().decode(BattleArchiveProgress.self,from:Data("{\"recordingEnabled\":true,\"completed\":[]}".utf8))
    try check(legacy.trashed.isEmpty && legacy.retentionCount == 64 && legacy.recordingEnabled,"old progress defaults recovery references and explicit retention without schema loss")
    let reference = BattleArchiveReference(recordingID:recording,attemptID:attempt,battleID:archive.battleID,title:archive.title,result:2,turns:1,inputCount:2)
    var cleanup = BattleArchiveProgress();cleanup.completed = [reference];cleanup.active = afterFinish.active
    let cleanupBefore = cleanup
    try check(rejects {try coordinator.moveToTrash(recording,progress:&cleanup)} && cleanup == cleanupBefore && (try Data(contentsOf:store.url(recording))) == completedBytes,
        "current recording cannot be moved and failure preserves references and bytes")
    cleanup.active = nil
    let parentBeforeTrash = try Data(contentsOf:store.url(recording)),branchBytes = try Data(contentsOf:store.url(branch.recordingID))
    try coordinator.moveToTrash(recording,progress:&cleanup)
    let trash = try store.trashEntries().first {$0.recordingID == recording}!
    let trashFile = store.trashRoot.appendingPathComponent(recording.uuidString.lowercased()+".replay.json")
    try check(!fm.fileExists(atPath:store.url(recording).path) && (try Data(contentsOf:trashFile)) == parentBeforeTrash && cleanup.completed.isEmpty && cleanup.trashed == [reference],
        "cleanup moves original bytes to recoverable trash before changing save-owned references")
    try check((try Data(contentsOf:store.url(branch.recordingID))) == branchBytes && (try store.read(branch.recordingID)).parentRecordingID == recording,
        "removing a parent recording leaves its independent branch prefix and payload intact")
    try check(rejects {try store.write(archive)},"a stale writer cannot silently resurrect a trashed recording")
    let recoveryState = try JSONDecoder().decode(BattleArchiveProgress.self,from:BattleReplayIdentity.encode(cleanup))
    try check(recoveryState == cleanup,"recovery references and retention survive atomic campaign save roundtrip")
    try Data("tamper".utf8).write(to:trashFile,options:.atomic)
    let beforeTamperRestore = cleanup
    try check(rejects {try coordinator.restore(trash,progress:&cleanup)} && cleanup == beforeTamperRestore && !fm.fileExists(atPath:store.url(recording).path),
        "restore refuses changed bytes before modifying references or writing the active archive")
    try parentBeforeTrash.write(to:trashFile,options:.atomic)
    try Data("collision".utf8).write(to:store.url(recording),options:.atomic)
    try check(rejects {try coordinator.restore(trash,progress:&cleanup)} && (try Data(contentsOf:store.url(recording))) == Data("collision".utf8),
        "restore never overwrites an existing active file")
    try fm.removeItem(at:store.url(recording))
    try coordinator.restore(trash,progress:&cleanup)
    try check(cleanup.completed == [reference] && cleanup.trashed.isEmpty && (try Data(contentsOf:store.url(recording))) == parentBeforeTrash,
        "known archive restoration recovers its reference and exact bytes")
    try coordinator.moveToTrash(recording,progress:&cleanup)
    let secondTrash = try store.trashEntries().first {$0.recordingID == recording}!
    var olderSave = BattleArchiveProgress();olderSave.completed = [reference]
    try coordinator.restore(secondTrash,progress:&olderSave)
    try check(olderSave.completed == [reference] && olderSave.trashed.isEmpty,"an older save can restore its existing reference without duplicating a victory")
    try coordinator.restoreReference(recording,progress:&cleanup)
    try check(cleanup.completed == [reference] && cleanup.trashed.isEmpty,"another save's physical restoration reconciles only this save's retained recovery reference")
    var foreign = archive;foreign.recordingID = UUID();foreign.attemptID = UUID();try store.write(foreign)
    var unknowingSave = BattleArchiveProgress()
    try coordinator.moveToTrash(foreign.recordingID,progress:&unknowingSave)
    let foreignTrash = try store.trashEntries().first {$0.recordingID == foreign.recordingID}!
    try coordinator.restore(foreignTrash,progress:&unknowingSave)
    try check(unknowingSave.completed.isEmpty && unknowingSave.trashed.isEmpty,"restoring another save's file never imports future victories or unlocks practice")
    var future = archive;future.recordingID = UUID();future.rules = "future-rules"
    let futureBytes = try BattleReplayIdentity.encode(future);try futureBytes.write(to:store.url(future.recordingID))
    try coordinator.moveToTrash(future.recordingID,progress:&unknowingSave)
    let futureTrash = try store.trashEntries().first {$0.recordingID == future.recordingID}!
    try coordinator.restore(futureTrash,progress:&unknowingSave)
    try check((try Data(contentsOf:store.url(future.recordingID))) == futureBytes && rejects {_ = try store.read(future.recordingID)},
        "future-version bytes can be safely moved and restored but remain incompatible and unmodified")
    var missingReference = reference;missingReference.recordingID = UUID()
    var missingProgress = BattleArchiveProgress();missingProgress.completed = [missingReference]
    try coordinator.moveToTrash(missingReference.recordingID,progress:&missingProgress)
    try check(missingProgress.completed.isEmpty && missingProgress.trashed == [missingReference] && !fm.fileExists(atPath:store.url(missingReference.recordingID).path),
        "missing-file cleanup preserves its reference without fabricating a recording")
    var retention = BattleArchiveProgress();retention.retentionCount = 10
    retention.completed = (0..<12).map {index in var ref = reference;ref.recordingID = UUID();ref.turns = index+1;return ref}
    retention.active = .init(recordingID:retention.completed[0].recordingID,attemptID:attempt,battleID:archive.battleID,cursor:0)
    let beforePlan = retention,candidates = coordinator.cleanupCandidates(retention)
    try check(candidates == Array(retention.completed[1...2]).map(\.recordingID) && retention == beforePlan,
        "retention planning is explicit, stable, oldest-first and excludes the active cursor")
    var invalidRetention = retention;invalidRetention.retentionCount = 0
    try check(rejects {try invalidRetention.validate()},"unknown retention values are rejected")
    let unsafeRoot = root.appendingPathComponent("unsafe-archives"),unsafeStore = BattleArchiveStore(root:unsafeRoot)
    try unsafeStore.write(archive)
    let foreignDirectory = root.appendingPathComponent("outside-trash");try fm.createDirectory(at:foreignDirectory,withIntermediateDirectories:true)
    try fm.createSymbolicLink(at:unsafeStore.trashRoot,withDestinationURL:foreignDirectory)
    try check(rejects {try unsafeStore.moveToTrash(recording,active:nil)} && (try Data(contentsOf:unsafeStore.url(recording))) == parentBeforeTrash && (try fm.contentsOfDirectory(atPath:foreignDirectory.path)).isEmpty,
        "a symlinked recovery directory is rejected before moving or writing any payload")
    try check((try Data(contentsOf:normal.fileURL(for:.numbered(0)))) == normalBytes && fm.fileExists(atPath:root.appendingPathComponent("suspend.json").path) == beforeNormal,
        "cleanup and restoration leave main campaign normal and suspend save paths untouched")
    print("Battle archive self-tests passed: \(checks)")
}
