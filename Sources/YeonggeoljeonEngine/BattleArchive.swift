// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit

/// References belong to the current save; archive payloads live in their own local directory.
/// Loading an older save therefore cannot unlock later victories.
struct BattleArchiveProgress:Codable,Equatable {
    var recordingEnabled = false
    var active:BattleRecordingCursor?
    var completed:[BattleArchiveReference] = []
    /// Save-owned references only. Restoring an unrelated archive cannot reveal
    /// a victory which had not happened at this save's point in the campaign.
    var trashed:[BattleArchiveReference] = []
    var retentionCount = 64
    var lastFailure:String?
    private enum CodingKeys:String,CodingKey {case recordingEnabled,active,completed,trashed,retentionCount,lastFailure}
    init() {}
    init(from decoder:Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        recordingEnabled = try c.decodeIfPresent(Bool.self,forKey:.recordingEnabled) ?? false
        active = try c.decodeIfPresent(BattleRecordingCursor.self,forKey:.active)
        completed = try c.decodeIfPresent([BattleArchiveReference].self,forKey:.completed) ?? []
        trashed = try c.decodeIfPresent([BattleArchiveReference].self,forKey:.trashed) ?? []
        retentionCount = try c.decodeIfPresent(Int.self,forKey:.retentionCount) ?? 64
        lastFailure = try c.decodeIfPresent(String.self,forKey:.lastFailure)
        try validate()
    }
    func validate() throws {
        guard completed.count <= 64,Set(completed.map(\.recordingID)).count == completed.count,
              trashed.count <= 256,Set(trashed.map(\.recordingID)).count == trashed.count,
              Set(completed.map(\.recordingID)).isDisjoint(with:trashed.map(\.recordingID)),
              [10,20,40,64].contains(retentionCount),
              lastFailure.map({$0.count <= 2048}) ?? true else {throw EngineError.invalid("Battle archive progress is invalid")}
        try active?.validate()
        for value in completed+trashed {try value.validate()}
    }
}
struct BattleRecordingCursor:Codable,Equatable {
    var recordingID:UUID
    var attemptID:UUID
    var battleID:String
    var cursor:Int
    func validate() throws {
        guard !battleID.isEmpty,battleID.count <= 200,(0...BattleReplayArchive.maximumInputs).contains(cursor) else {
            throw EngineError.invalid("Battle recording cursor is invalid")
        }
    }
}
struct BattleArchiveReference:Codable,Equatable {
    var recordingID:UUID
    var attemptID:UUID
    var battleID:String
    var title:String
    var result:Int
    var turns:Int
    var inputCount:Int
    var verified:Bool = false
    func validate() throws {
        guard !battleID.isEmpty,battleID.count <= 200,title.count <= 200,(1...255).contains(result),
              (0...65535).contains(turns),(0...BattleReplayArchive.maximumInputs).contains(inputCount) else {
            throw EngineError.invalid("Battle archive reference is invalid")
        }
    }
}

/// Payload stores runtime values and changed map cells, never a copy of source maps,
/// graphics, audio, dialogue, rule tables or person catalogue names/provenance.
struct BattleReplayStart:Codable {
    struct Cell:Codable {var index:Int;var value:UInt8}
    var resume:OriginalCampaignResume
    var terrainChanges:[Cell]
    var pictureChanges:[Cell]
    var hasPictures:Bool
    static func capture(_ save:OriginalCampaignResume,source:OriginalGameData) throws -> Self {
        guard let start = save.battleStart,save.suspension == nil,
              let definition = source.battles.battles.first(where:{$0.id == start.battleID}),let terrain = definition.tiles,
              terrain.count == start.terrain.count,save.checkpoint.stage.dialogue == nil else {
            throw EngineError.invalid("Replay requires a complete first-turn campaign checkpoint")
        }
        let terrainChanges = start.terrain.enumerated().compactMap {index,value in terrain[index] == Int(value) ? nil : Cell(index:index,value:value)}
        let baseline = definition.pictureTiles ?? []
        let pictures = start.pictureTiles ?? []
        guard pictures.isEmpty || pictures.count == baseline.count else {throw EngineError.invalid("Replay map picture baseline is unavailable")}
        let pictureChanges = pictures.enumerated().compactMap {index,value in baseline[index] == Int(value) ? nil : Cell(index:index,value:value)}
        var stripped = save
        stripped.extras = nil
        stripped.battleStart!.terrain = [];stripped.battleStart!.pictureTiles = nil
        stripped.battleStart!.resultLog = nil
        stripped.limitations = []
        strip(&stripped.checkpoint)
        if var retry = stripped.retryCheckpoint {strip(&retry);stripped.retryCheckpoint = retry}
        return Self(resume:stripped,terrainChanges:terrainChanges,pictureChanges:pictureChanges,hasPictures:start.pictureTiles != nil)
    }
    private static func strip(_ checkpoint:inout OriginalCampaignCheckpoint) {
        checkpoint.people = checkpoint.people.map {var p = $0;p.name = "";p.source = nil;return p}
        checkpoint.stage.dialogue = nil;checkpoint.stage.caption = nil;checkpoint.stage.storyPanel = nil
    }
    func restore(source:OriginalGameData,attemptID:UUID) throws -> OriginalCampaignResume {
        guard let start = resume.battleStart,resume.suspension == nil,resume.extras == nil,
              let definition = source.battles.battles.first(where:{$0.id == start.battleID}),let raw = definition.tiles,
              raw.allSatisfy({(0...255).contains($0)}) else {throw EngineError.invalid("Replay source battle does not match")}
        var result = resume
        func patched(_ values:[Int],_ changes:[Cell]) throws -> [UInt8] {
            guard values.allSatisfy({(0...255).contains($0)}),changes.count <= values.count,
                  Set(changes.map(\.index)).count == changes.count,changes.allSatisfy({values.indices.contains($0.index)}) else {
                throw EngineError.invalid("Replay map changes are invalid")
            }
            var result = values.map(UInt8.init);for cell in changes {result[cell.index] = cell.value};return result
        }
        result.battleStart!.terrain = try patched(raw,terrainChanges)
        result.battleStart!.pictureTiles = hasPictures ? try patched(definition.pictureTiles ?? [],pictureChanges) : nil
        guard hasPictures || pictureChanges.isEmpty else {throw EngineError.invalid("Replay picture changes have no source plane")}
        var log = BattleResultLog();log.attemptID = attemptID;result.battleStart!.resultLog = log
        let names = Dictionary(uniqueKeysWithValues:source.people.people.map {($0.id,$0.name)})
        func hydrate(_ value:inout OriginalCampaignCheckpoint) {
            value.people = value.people.map {var p = $0;p.name = names[p.id] ?? "";p.source = nil;return p}
        }
        hydrate(&result.checkpoint)
        if var retry = result.retryCheckpoint {hydrate(&retry);result.retryCheckpoint = retry}
        return result
    }
}
struct BattleReplayArchive:Codable {
    static let formatVersion = 1
    static let rulesVersion = "native-original-battle-20261109-v1"
    static let maximumInputs = 8192
    static let maximumBytes = 16*1024*1024
    struct Checkpoint:Codable {var cursor:Int;var round:Int;var digest:String}
    var format = formatVersion
    var kind = "native-battle-replay"
    var rules = rulesVersion
    var inputVersion = 2
    var dataDigest:String
    var recordingID:UUID
    var attemptID:UUID
    var parentRecordingID:UUID?
    var forkCursor:Int?
    var battleID:String
    var title:String
    var start:BattleReplayStart
    var initialDigest:String
    var inputs:[OriginalPlayInput] = []
    var checkpoints:[Checkpoint] = []
    var result:Int?
    var finalDigest:String?
    var complete = false
    func validate() throws {
        func digest(_ s:String)->Bool {s.count == 64 && s.allSatisfy({$0.isHexDigit && !$0.isUppercase})}
        guard format == Self.formatVersion,kind == "native-battle-replay",rules == Self.rulesVersion,inputVersion == 2,
              digest(dataDigest),digest(initialDigest),!battleID.isEmpty,battleID.count <= 200,title.count <= 200,
              start.resume.kind == "native-engine-resume",start.resume.format == 1,start.resume.battleStart?.battleID == battleID,inputs.count <= Self.maximumInputs,checkpoints.count <= Self.maximumInputs+1,
              Set(checkpoints.map(\.cursor)).count == checkpoints.count,
              checkpoints.allSatisfy({(0...inputs.count).contains($0.cursor) && (0...65535).contains($0.round) && digest($0.digest)}),
              checkpoints.map(\.cursor) == checkpoints.map(\.cursor).sorted(),
              (parentRecordingID == nil) == (forkCursor == nil),parentRecordingID != recordingID,
              forkCursor.map({(0...inputs.count).contains($0)}) ?? true else {throw EngineError.invalid("Replay version, identity or input index is invalid")}
        for input in inputs {try input.validate();guard Self.supports(input.kind) else {throw EngineError.invalid("Replay contains an unsupported input")}}
        if complete {guard let result,(1...255).contains(result),let finalDigest,digest(finalDigest),checkpoints.last?.cursor == inputs.count,
                           checkpoints.last?.digest == finalDigest else {throw EngineError.invalid("Replay completion checkpoint is missing")}}
        else if finalDigest != nil || result != nil {throw EngineError.invalid("Incomplete replay claims a result")}
    }
    static func supports(_ kind:OriginalPlayInput.Kind)->Bool {
        switch kind {
        case .battleMove,.battleAttack,.battleStrategy,.battleItem,.battleWait,.battleEndTurn,.battleRetreat,.battleQuit,
             .battleCancelMove,.battleGive,.battleDiscard,.battleReleaseAmbush,.battleOptions,.choice,.itemOffer,.saveSkip:return true
        default:return false
        }
    }
}

/// Shared only as a cancellation flag; simulation state never crosses workers
/// until the worker has finished. AppKit is owned by the receiving main thread.
final class BattleArchiveCancellation {
    enum Cancelled:Error {case requested}
    private let lock = NSLock()
    private var cancelled = false
    func cancel() {lock.lock();cancelled = true;lock.unlock()}
    var isCancelled:Bool {lock.lock();defer {lock.unlock()};return cancelled}
    func check() throws {if isCancelled {throw Cancelled.requested}}
}
struct BattleArchiveVerificationProgress {
    enum Phase {case identity,replay}
    var phase:Phase
    var completed:Int
    var total:Int
}

enum BattleReplayIdentity {
    static func digest(_ bytes:Data)->String {SHA256.hash(data:bytes).map {String(format:"%02x",$0)}.joined()}
    static func encode<T:Encodable>(_ value:T) throws -> Data {
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes];return try encoder.encode(value)
    }
    /// Exact caller-selected local data tree. No timestamps or machine paths enter identity.
    static func data(at root:URL,cancellation:(() throws -> Void)? = nil,progress:((Int,Int)->Void)? = nil) throws -> String {
        try cancellation?()
        let manager = FileManager.default
        guard let iterator = manager.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey],options:[.skipsHiddenFiles]) else {
            throw EngineError.invalid("Replay data directory is unavailable")
        }
        var files:[URL] = []
        for case let url as URL in iterator {
            try cancellation?()
            let facts = try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard facts.isSymbolicLink != true else {throw EngineError.invalid("Replay data identity refuses symbolic links")}
            if facts.isRegularFile == true {files.append(url)}
            guard files.count <= 20000 else {throw EngineError.invalid("Replay data file limit exceeded")}
        }
        guard !files.isEmpty else {throw EngineError.invalid("Replay data directory is empty")}
        var total:Int64 = 0;var hasher = SHA256()
        for (index,url) in files.sorted(by:{$0.path < $1.path}).enumerated() {
            try cancellation?();progress?(index,files.count)
            let name = String(url.path.dropFirst(root.path.count+1))
            hasher.update(data:Data((name+"\u{0}").utf8))
            let handle = try FileHandle(forReadingFrom:url);defer {try? handle.close()}
            var fileHash = SHA256()
            while let bytes = try handle.read(upToCount:65536),!bytes.isEmpty {
                try cancellation?()
                total += Int64(bytes.count);guard total <= 1024*1024*1024 else {throw EngineError.invalid("Replay data exceeds the identity work limit")}
                fileHash.update(data:bytes)
            }
            hasher.update(data:Data(fileHash.finalize()))
        }
        try cancellation?();progress?(files.count,files.count)
        return hasher.finalize().map {String(format:"%02x",$0)}.joined()
    }
    /// Gameplay state only. Wall-clock presentation, read-only camera inspection,
    /// archive cursors, log UUIDs and helper records are deliberately excluded.
    static func state(_ host:OriginalCampaignHost) throws -> String {
        var checkpoint = host.snapshot()
        checkpoint.people = checkpoint.people.map {var p = $0;p.name = "";p.source = nil;return p}
        struct State:Encodable {
            var vm:OriginalCampaignState;var people:[OriginalPersonDefinition];var roster:OriginalRoster;var rng:OriginalRNG
            var money:Int?;var units:[OriginalLiveUnit]?;var turns:OriginalTurnState?;var value:Int?
            var terrain:[UInt8]?;var pictures:[UInt8]?;var scripts:OriginalScriptActionState?;var options:Int?
            var markers:[Marker];var movement:[Movement]
            struct Marker:Encodable {var point:GridPoint;var value:UInt8}
            struct Movement:Encodable {var slot:Int;var point:GridPoint}
        }
        var scripts = host.battle?.scriptActions;let markers = scripts?.markers ?? [:];scripts?.markers = [:]
        let origins = host.battle?.suspensionState().movementOrigins ?? [:]
        let value = State(vm:checkpoint.vm,people:checkpoint.people,roster:checkpoint.roster,rng:checkpoint.rng,money:checkpoint.money,
            units:checkpoint.liveUnits,turns:checkpoint.turns,value:checkpoint.battleValue24,
            terrain:host.battle?.terrain,pictures:host.battle?.pictureTiles,scripts:scripts,options:host.battle?.sourceOptionsWord,
            markers:markers.keys.sorted {($0.y,$0.x) < ($1.y,$1.x)}.map {.init(point:$0,value:markers[$0]!)},
            movement:origins.keys.sorted().map {.init(slot:$0,point:origins[$0]!)} )
        return digest(try encode(value))
    }
}

struct BattleArchiveTrashEntry:Codable,Equatable {
    var format = 1
    var kind = "native-battle-archive-trash"
    var recordingID:UUID
    var byteCount:Int
    var digest:String
    var movedAt:Date
    func validate() throws {
        guard format == 1,kind == "native-battle-archive-trash",(1...BattleReplayArchive.maximumBytes).contains(byteCount),
              digest.count == 64,digest.allSatisfy({$0.isHexDigit && !$0.isUppercase}),movedAt.timeIntervalSince1970.isFinite else {
            throw EngineError.invalid("기록 보관함의 복구 정보가 올바르지 않습니다.")
        }
    }
}

/// Archive cleanup never opens normal slots, suspension files, source data or
/// the practice subdirectory. It only renames bounded UUID archive files.
final class BattleArchiveStore {
    struct InventoryItem {var recordingID:UUID;var byteCount:Int;var complete:Bool?}
    let root:URL
    static let maximumDirectoryBytes = 256*1024*1024
    private static let access = NSRecursiveLock()
    init(root:URL) {self.root = root.standardizedFileURL}
    /// Serialize read/modify/write and cleanup across coordinators in this app.
    func transaction<T>(_ work:() throws -> T) rethrows -> T {
        Self.access.lock();defer {Self.access.unlock()};return try work()
    }
    private func safeDirectory(_ directory:URL,create:Bool) throws {
        let fm = FileManager.default
        guard directory.resolvingSymlinksInPath().path == directory.path else {throw EngineError.invalid("Replay directory may not contain symbolic links")}
        if create {try fm.createDirectory(at:directory,withIntermediateDirectories:true)}
        guard directory.resolvingSymlinksInPath().path == directory.path else {throw EngineError.invalid("Replay directory may not contain symbolic links")}
        if fm.fileExists(atPath:directory.path) {
            let info = try directory.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard info.isDirectory == true,info.isSymbolicLink != true else {throw EngineError.invalid("Replay path is not a directory")}
        }
    }
    private func safeRoot(create:Bool) throws {try safeDirectory(root,create:create)}
    func url(_ id:UUID)->URL {root.appendingPathComponent(id.uuidString.lowercased()+".replay.json")}
    var trashRoot:URL {root.appendingPathComponent("archive-trash",isDirectory:true)}
    private func trashURL(_ id:UUID)->URL {trashRoot.appendingPathComponent(id.uuidString.lowercased()+".replay.json")}
    private func metadataURL(_ id:UUID)->URL {trashRoot.appendingPathComponent(id.uuidString.lowercased()+".entry.json")}
    private func bytes(at file:URL,maximum:Int = BattleReplayArchive.maximumBytes) throws -> Data {
        let info = try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard info.isRegularFile == true,info.isSymbolicLink != true,let size = info.fileSize,(1...maximum).contains(size) else {
            throw EngineError.invalid("Replay file is missing, unsafe or exceeds its size limit")
        }
        let value = try Data(contentsOf:file)
        guard (1...maximum).contains(value.count) else {throw EngineError.invalid("Replay file changed beyond its size limit")};return value
    }
    private func archiveIDs(at directory:URL) throws -> [UUID] {
        guard FileManager.default.fileExists(atPath:directory.path) else {return []}
        let files = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
        guard files.count <= 4096 else {throw EngineError.invalid("기록 파일이 너무 많아 정리를 중단했습니다.")}
        return files.compactMap {file in
            let name = file.lastPathComponent,suffix = ".replay.json"
            guard name.hasSuffix(suffix) else {return nil}
            return UUID(uuidString:String(name.dropLast(suffix.count)))
        }.sorted {$0.uuidString < $1.uuidString}
    }
    func read(_ id:UUID) throws -> BattleReplayArchive {
        try transaction {
            try safeRoot(create:false)
            let value = try JSONDecoder().decode(BattleReplayArchive.self,from:bytes(at:url(id)))
            try value.validate();guard value.recordingID == id else {throw EngineError.invalid("Replay filename identity does not match")};return value
        }
    }
    func inventory() throws -> [InventoryItem] {
        try transaction {
            try safeRoot(create:false)
            return try archiveIDs(at:root).map {id in
                let info = try url(id).resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
                guard info.isRegularFile == true,info.isSymbolicLink != true else {throw EngineError.invalid("기록 목록에 안전하지 않은 파일이 있습니다.")}
                return InventoryItem(recordingID:id,byteCount:info.fileSize ?? 0,complete:nil)
            }
        }
    }
    func write(_ value:BattleReplayArchive) throws {
        try transaction {
            try value.validate();let raw = try BattleReplayIdentity.encode(value)
            guard raw.count <= BattleReplayArchive.maximumBytes else {throw EngineError.invalid("Replay file is full; game progress remains available")}
            try safeRoot(create:true);try safeDirectory(trashRoot,create:false)
            guard !FileManager.default.fileExists(atPath:trashURL(value.recordingID).path) else {throw EngineError.invalid("보관함으로 옮긴 기록입니다. 복구한 뒤 기록을 이어 주세요.")}
            let destination = url(value.recordingID)
            if FileManager.default.fileExists(atPath:destination.path) {_ = try bytes(at:destination)}
            var total = raw.count
            for id in try archiveIDs(at:root) where id != value.recordingID {
                let info = try url(id).resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
                guard info.isRegularFile == true,info.isSymbolicLink != true else {throw EngineError.invalid("Replay directory contains an unsafe file")}
                total += info.fileSize ?? 0
            }
            guard total <= Self.maximumDirectoryBytes else {throw EngineError.invalid("Replay storage is full; the current game is not stopped")}
            try raw.write(to:destination,options:.atomic)
        }
    }
    /// Even unreadable or future-version archives may be preserved in trash;
    /// moving them does not decode, upgrade or overwrite their payload.
    @discardableResult func moveToTrash(_ id:UUID,active:UUID?) throws -> BattleArchiveTrashEntry {
        try transaction {
            guard id != active else {throw EngineError.invalid("현재 기록 중인 전투는 정리할 수 없습니다.")}
            try safeRoot(create:false);try safeDirectory(trashRoot,create:true)
            let fm = FileManager.default,source = url(id),destination = trashURL(id),raw = try bytes(at:source)
            guard !fm.fileExists(atPath:destination.path) else {throw EngineError.invalid("보관함에 같은 기록이 있어 덮어쓰지 않았습니다.")}
            let entry = BattleArchiveTrashEntry(recordingID:id,byteCount:raw.count,digest:BattleReplayIdentity.digest(raw),movedAt:Date())
            let metadata = metadataURL(id)
            if fm.fileExists(atPath:metadata.path) {_ = try bytes(at:metadata,maximum:8192)}
            try BattleReplayIdentity.encode(entry).write(to:metadata,options:.atomic)
            try fm.moveItem(at:source,to:destination)
            return entry
        }
    }
    func trashEntries() throws -> [BattleArchiveTrashEntry] {
        try transaction {
            try safeRoot(create:false);try safeDirectory(trashRoot,create:false)
            return try archiveIDs(at:trashRoot).map {id in
                let entry = try JSONDecoder().decode(BattleArchiveTrashEntry.self,from:bytes(at:metadataURL(id),maximum:8192))
                try entry.validate();guard entry.recordingID == id else {throw EngineError.invalid("보관함 기록의 식별자가 다릅니다.")}
                return entry
            }.sorted {$0.movedAt > $1.movedAt}
        }
    }
    func restore(_ entry:BattleArchiveTrashEntry) throws {
        try transaction {
            try entry.validate();try safeRoot(create:false);try safeDirectory(trashRoot,create:false)
            let current = try JSONDecoder().decode(BattleArchiveTrashEntry.self,from:bytes(at:metadataURL(entry.recordingID),maximum:8192))
            guard current == entry else {throw EngineError.invalid("보관함 내용이 바뀌었습니다. 다시 선택해 주세요.")}
            let raw = try bytes(at:trashURL(entry.recordingID))
            guard raw.count == entry.byteCount,BattleReplayIdentity.digest(raw) == entry.digest else {throw EngineError.invalid("보관 기록의 바이트가 달라 복구하지 않았습니다.")}
            guard !FileManager.default.fileExists(atPath:url(entry.recordingID).path) else {throw EngineError.invalid("같은 기록이 이미 있어 덮어쓰지 않았습니다.")}
            let used = try inventory().reduce(0) {$0+$1.byteCount}
            guard used+raw.count <= Self.maximumDirectoryBytes else {throw EngineError.invalid("사용 중인 기록 용량을 먼저 정리해 주세요.")}
            try FileManager.default.moveItem(at:trashURL(entry.recordingID),to:url(entry.recordingID))
            // Keep the tiny receipt. A later move may replace it only while
            // there is no payload in trash; it never overwrites archive bytes.
        }
    }
}

final class BattleArchiveCoordinator {
    let data:DataSet
    let store:BattleArchiveStore
    private var cachedIdentity:String?
    init(data:DataSet,root:URL) {self.data = data;self.store = BattleArchiveStore(root:root)}
    func identity() throws -> String {
        if let cachedIdentity {return cachedIdentity}
        let value = try BattleReplayIdentity.data(at:data.root);cachedIdentity = value;return value
    }
    func begin(start:OriginalCampaignResume,progress:inout BattleArchiveProgress) throws {
        guard progress.recordingEnabled else {return}
        guard let battleStart = start.battleStart,let attempt = battleStart.resultLog?.attemptID else {throw EngineError.invalid("Replay has no first-turn attempt identity")}
        if progress.active?.attemptID == attempt {return}
        guard progress.completed.count < 64 else {throw EngineError.invalid("완료 기록 64개가 보관 중입니다. 기록 정리에서 옮긴 뒤 다음 전투를 기록할 수 있습니다.")}
        let source = try OriginalGameData(root:data.root)
        let clean = try BattleReplayStart.capture(start,source:source)
        let clone = try OriginalCampaignHost.resume(data:data,from:try clean.restore(source:source,attemptID:attempt))
        let id = UUID()
        let archive = BattleReplayArchive(dataDigest:try identity(),recordingID:id,attemptID:attempt,
            battleID:battleStart.battleID,title:source.battles.battles.first {$0.id == battleStart.battleID}?.name ?? battleStart.battleID,
            start:clean,initialDigest:try BattleReplayIdentity.state(clone))
        try store.write(archive)
        progress.active = .init(recordingID:id,attemptID:attempt,battleID:battleStart.battleID,cursor:0);progress.lastFailure = nil
    }
    /// Older cursors fork only when a new gameplay command is actually accepted.
    /// The campaign attempt remains identical; only the recording identity changes.
    func accepted(input:OriginalPlayInput,progress:inout BattleArchiveProgress) throws {
        guard progress.recordingEnabled,let cursor = progress.active else {return}
        guard BattleReplayArchive.supports(input.kind) else {throw EngineError.invalid("This input is not supported by battle recording")}
        try store.transaction {
        try input.validate();var archive = try store.read(cursor.recordingID)
        guard archive.attemptID == cursor.attemptID,archive.battleID == cursor.battleID,cursor.cursor <= archive.inputs.count else {
            throw EngineError.invalid("Saved recording cursor no longer matches the archive")
        }
        if cursor.cursor < archive.inputs.count,archive.inputs[cursor.cursor] == input {
            var next = cursor;next.cursor += 1;progress.active = next;return
        }
        if cursor.cursor < archive.inputs.count || archive.complete {
            archive.parentRecordingID = archive.recordingID;archive.forkCursor = cursor.cursor;archive.recordingID = UUID()
            archive.inputs = Array(archive.inputs.prefix(cursor.cursor));archive.checkpoints.removeAll {$0.cursor > cursor.cursor}
            archive.complete = false;archive.result = nil;archive.finalDigest = nil
        }
        guard archive.inputs.count < BattleReplayArchive.maximumInputs else {throw EngineError.invalid("Replay input limit reached")}
        archive.inputs.append(input);try store.write(archive)
        progress.active = .init(recordingID:archive.recordingID,attemptID:archive.attemptID,battleID:archive.battleID,cursor:archive.inputs.count)
        }
    }
    func checkpoint(host:OriginalCampaignHost,progress:inout BattleArchiveProgress) throws {
        guard let cursor = progress.active,let battle = host.battle,battle.resultLog.attemptID == cursor.attemptID else {return}
        try store.transaction {
        var archive = try store.read(cursor.recordingID)
        if let expected = archive.checkpoints.first(where:{$0.cursor == cursor.cursor}) {
            guard expected.digest == (try BattleReplayIdentity.state(host)) else {throw EngineError.invalid("이전 기록과 입력 \(cursor.cursor)의 상태가 달라 기록을 중단했습니다.")}
            return
        }
        guard archive.inputs.count == cursor.cursor,!archive.complete else {return}
        archive.checkpoints.append(.init(cursor:cursor.cursor,round:battle.turns.roundIndex,digest:try BattleReplayIdentity.state(host)))
        try store.write(archive)
        }
    }
    func finish(host:OriginalCampaignHost,progress:inout BattleArchiveProgress) throws {
        guard let cursor = progress.active,let battle = host.battle,battle.resultLog.attemptID == cursor.attemptID,battle.turns.result != 0 else {return}
        try store.transaction {
            var archive = try store.read(cursor.recordingID)
            let alreadyComplete = archive.complete
            guard archive.inputs.count == cursor.cursor else {throw EngineError.invalid("Replay completion cursor is stale")}
            let hash = try BattleReplayIdentity.state(host)
            if archive.complete {
                guard archive.result == Int(battle.turns.result),archive.finalDigest == hash else {throw EngineError.invalid("Replay completion differs from the existing recording")}
            } else {
                archive.checkpoints.removeAll {$0.cursor == cursor.cursor}
                archive.checkpoints.append(.init(cursor:cursor.cursor,round:battle.turns.roundIndex,digest:hash))
                archive.complete = true;archive.result = Int(battle.turns.result);archive.finalDigest = hash
            }
            let ref = BattleArchiveReference(recordingID:archive.recordingID,attemptID:archive.attemptID,battleID:archive.battleID,title:archive.title,
                result:Int(battle.turns.result),turns:battle.turns.roundIndex+1,inputCount:archive.inputs.count)
            var next = progress
            let verified = next.completed.first {$0.recordingID == ref.recordingID}?.verified ?? false
            next.completed.removeAll {$0.recordingID == ref.recordingID}
            guard next.completed.count < 64 else {throw EngineError.invalid("완료 기록이 가득 찼습니다. 기존 기록은 지우지 않았습니다. 기록 정리 후 다시 확인해 주세요.")}
            var value = ref;value.verified = verified;next.completed.append(value);next.active = nil;try next.validate()
            if !alreadyComplete {try store.write(archive)}
            progress = next
        }
    }
    /// References are changed only after the recoverable file move succeeds.
    /// Missing payloads keep a save-owned reference in the recovery list; they
    /// are never reconstructed from source data or another campaign's archive.
    func moveToTrash(_ id:UUID,progress:inout BattleArchiveProgress) throws {
        try store.transaction {
            guard id != progress.active?.recordingID else {throw EngineError.invalid("현재 기록 중인 전투는 정리할 수 없습니다.")}
            var next = progress
            let reference = next.completed.first {$0.recordingID == id}
            next.completed.removeAll {$0.recordingID == id}
            if let reference,!next.trashed.contains(where:{$0.recordingID == id}) {next.trashed.append(reference)}
            try next.validate()
            if FileManager.default.fileExists(atPath:store.url(id).path) {
                try store.moveToTrash(id,active:progress.active?.recordingID)
            } else if reference == nil {throw EngineError.invalid("정리할 기록 파일이 없습니다.")}
            progress = next
        }
    }
    func restore(_ entry:BattleArchiveTrashEntry,progress:inout BattleArchiveProgress) throws {
        try store.transaction {
            var next = progress
            if let reference = next.trashed.first(where:{$0.recordingID == entry.recordingID}) {
                guard next.completed.count < 64 else {throw EngineError.invalid("완료 목록을 먼저 정리해 주세요. 최대 64개를 사용할 수 있습니다.")}
                next.trashed.removeAll {$0.recordingID == entry.recordingID};next.completed.append(reference)
            }
            try next.validate();try store.restore(entry);progress = next
        }
    }
    /// A different saved cursor may already have restored the shared file.
    /// Reconcile only a reference this save itself retained in its recovery list.
    func restoreReference(_ id:UUID,progress:inout BattleArchiveProgress) throws {
        try store.transaction {
            guard let reference = progress.trashed.first(where:{$0.recordingID == id}) else {throw EngineError.invalid("현재 저장에서 보관한 참조가 없습니다.")}
            let archive = try store.read(id)
            guard archive.complete,archive.attemptID == reference.attemptID,archive.battleID == reference.battleID,
                  archive.result == reference.result,archive.inputs.count == reference.inputCount else {throw EngineError.invalid("복구된 파일과 이 저장의 전투 참조가 다릅니다.")}
            var next = progress;next.trashed.removeAll {$0.recordingID == id};next.completed.append(reference)
            try next.validate();progress = next
        }
    }
    func cleanupCandidates(_ progress:BattleArchiveProgress)->[UUID] {
        Array(progress.completed.filter {$0.recordingID != progress.active?.recordingID}.prefix(max(0,progress.completed.count-progress.retentionCount))).map(\.recordingID)
    }

    func failed(_ error:Error,progress:inout BattleArchiveProgress) {
        progress.lastFailure = String(String(describing:error).prefix(2048));progress.active = nil
    }
    func verifiedArchive(_ reference:BattleArchiveReference,cancellation:BattleArchiveCancellation? = nil,
                         progress:((BattleArchiveVerificationProgress)->Void)? = nil) throws -> BattleReplayArchive {
        try cancellation?.check()
        let archive = try store.read(reference.recordingID)
        guard archive.complete,archive.battleID == reference.battleID,archive.attemptID == reference.attemptID,
              archive.result == reference.result,archive.inputs.count == reference.inputCount else {throw EngineError.invalid("Replay is incomplete or differs from this saved campaign")}
        let currentIdentity = try BattleReplayIdentity.data(at:data.root,cancellation:{try cancellation?.check()},
            progress:{progress?(.init(phase:.identity,completed:$0,total:$1))})
        guard archive.dataDigest == currentIdentity else {throw EngineError.invalid("Replay requires its original local data version")}
        let replay = try BattleReplayDriver(data:data,archive:archive,expectedDataDigest:currentIdentity,cancellation:cancellation)
        progress?(.init(phase:.replay,completed:0,total:archive.inputs.count))
        while try replay.step() {progress?(.init(phase:.replay,completed:replay.cursor,total:archive.inputs.count))}
        try cancellation?.check()
        return archive
    }
}
