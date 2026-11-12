// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#endif

/// Replace operations are injectable for synthetic failure and lock tests.
/// Reads always use the actual bounded file reader; callers cannot bypass
/// the resume kind/version checks through this seam.
struct NativeSaveFileOperations {
    var writeAtomically:(Data,URL) throws -> Void = { data,url in try data.write(to:url,options:.atomic) }
}

/// Native ordinary slots only. There is deliberately no suspend key.
/// New files live below native-v1 so older builds cannot overwrite their
/// metadata or payload. Legacy pairs are read without changing either file.
struct OriginalSaveSlots {
    static let count = 5
    static let maximumBytes = OriginalCampaignResume.maximumBytes + 64 * 1024
    private static let kind = "native-engine-slot"
    private static let practiceKind = "native-engine-practice-slot"
    struct Entry:Codable,Equatable { var title:String;var date:Date }
    enum Named:String,CaseIterable { case auto,quick,battleStart = "battle-start" }
    enum SlotKey:Equatable { case numbered(Int),named(Named) }
    enum Status:Equatable { case empty,ready,metadataDamaged,dataDamaged,unsupported }
    struct Inspection {
        var key:SlotKey
        var status:Status
        var entry:Entry?
        var backupEntry:Entry?
        var legacyEntry:Entry?
        var canLoad:Bool
        var message:String
        var primaryURL:URL?
        var isLegacy:Bool
        var canRestoreBackup:Bool { backupEntry != nil }
        var canRestoreLegacy:Bool { !isLegacy && legacyEntry != nil }
    }
    struct RecoveryResult { var entry:Entry;var preservedDirectory:URL? }
    enum Failure:Error,LocalizedError,Equatable {
        case invalidSlot,busy,missing,unsupported,invalidMetadata,invalidPayload,noBackup,noLegacy,unsafeDestination,destinationExists
        var errorDescription:String? {
            switch self {
            case .invalidSlot:return "일반 저장 슬롯 번호가 올바르지 않습니다."
            case .busy:return "다른 저장 작업이 진행 중입니다. 잠시 후 다시 시도하세요."
            case .missing:return "이 슬롯에 저장된 게임이 없습니다."
            case .unsupported:return "지원하지 않는 저장 버전 또는 형식입니다. 파일은 그대로 보존됩니다."
            case .invalidMetadata:return "저장 제목 또는 날짜 정보가 손상되었습니다."
            case .invalidPayload:return "저장된 진행 데이터를 읽을 수 없습니다. 파일은 그대로 보존됩니다."
            case .noBackup:return "복구할 수 있는 마지막 정상 저장이 없습니다."
            case .noLegacy:return "복구할 수 있는 이전 형식 저장이 없습니다."
            case .unsafeDestination:return "백업은 일반 저장과 중단 저장 파일 밖의 새 파일에 내보내세요."
            case .destinationExists:return "같은 이름의 파일이 있습니다. 다른 백업 파일 이름을 선택하세요."
            }
        }
    }
    private struct Envelope:Codable {
        var format = 1
        var kind = OriginalSaveSlots.kind
        var entry:Entry
        var payload:OriginalCampaignResume
    }
    private struct Header:Decodable { var format:Int;var kind:String }
    private struct Metadata:Decodable { var entry:Entry }
    private struct Payload:Decodable { var payload:OriginalCampaignResume }
    private struct Candidate {
        var status:Status
        var entry:Entry?
        var payload:OriginalCampaignResume?
        var url:URL?
        var legacy = false
        var message:String
    }
    let directory:URL
    let practiceMode:Bool
    private let operations:NativeSaveFileOperations
    init(directory:URL,operations:NativeSaveFileOperations = NativeSaveFileOperations(),practiceMode:Bool = false) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.operations = operations;self.practiceMode = practiceMode
    }
    var storageDirectory:URL { directory.appendingPathComponent(practiceMode ? "practice-v1" : "native-v1",isDirectory:true) }
    private func name(_ key:SlotKey) throws -> String {
        switch key {
        case .numbered(let slot):
            guard (0..<Self.count).contains(slot) else { throw Failure.invalidSlot }
            return "slot-\(slot)"
        case .named(let name):return name.rawValue
        }
    }
    func fileURL(for key:SlotKey) throws -> URL { storageDirectory.appendingPathComponent("\(try name(key)).json") }
    func backupURL(for key:SlotKey) throws -> URL { storageDirectory.appendingPathComponent("backups/\(try name(key)).json") }
    private func legacyFile(_ key:SlotKey) throws -> URL { directory.appendingPathComponent("\(try name(key)).json") }
    private func legacyLabel(_ key:SlotKey) throws -> URL { directory.appendingPathComponent("\(try name(key)).label.json") }

    /// Inspection is read-only, including when the directory does not exist.
    /// In particular it does not create a lock file or migrate a legacy pair.
    func inspect(_ key:SlotKey) throws -> Inspection {
        let current = try candidate(key),backup = Self.envelopeCandidate(at:try backupURL(for:key),practiceMode:practiceMode)
        let legacy = try legacyCandidate(key)
        return Inspection(key:key,status:current.status,entry:current.entry,
            backupEntry:backup.payload == nil ? nil : backup.entry,
            legacyEntry:legacy.payload == nil ? nil : legacy.entry,
            canLoad:current.payload != nil,message:current.message,primaryURL:current.url,isLegacy:current.legacy)
    }
    func inspections() throws -> [Inspection] { try (0..<Self.count).map { try inspect(.numbered($0)) } }
    func entries() -> [Entry?] { (0..<Self.count).map { (try? inspect(.numbered($0)))?.entry } }
    func entry(_ name:Named) -> Entry? { (try? inspect(.named(name)))?.entry }
    func read(slot:Int) throws -> OriginalCampaignResume { try read(.numbered(slot)) }
    func read(_ name:Named) throws -> OriginalCampaignResume { try read(.named(name)) }
    private func read(_ key:SlotKey) throws -> OriginalCampaignResume {
        let value = try candidate(key)
        guard let payload = value.payload else { throw Self.failure(value.status) }
        return payload
    }
    static func readFile(from url:URL,practiceMode:Bool = false) throws -> OriginalCampaignResume {
        let data = try boundedData(url,maximum:maximumBytes)
        let header = try JSONDecoder().decode(Header.self,from:data)
        if header.kind == (practiceMode ? practiceKind : kind) {
            guard header.format == 1 else { throw Failure.unsupported }
            return try validate(JSONDecoder().decode(Payload.self,from:data).payload,practiceMode:practiceMode)
        }
        guard data.count <= OriginalCampaignResume.maximumBytes,
              header.kind == (practiceMode ? "native-engine-practice" : "native-engine-resume"),header.format == 1 else { throw Failure.unsupported }
        return try validate(JSONDecoder().decode(OriginalCampaignResume.self,from:data),practiceMode:practiceMode)
    }

    func write<Snapshot:Encodable>(_ snapshot:Snapshot,title:String,slot:Int,date:Date = Date()) throws {
        try write(snapshot,title:title,key:.numbered(slot),date:date)
    }
    func write<Snapshot:Encodable>(_ snapshot:Snapshot,title:String,named name:Named,date:Date = Date()) throws {
        try write(snapshot,title:title,key:.named(name),date:date)
    }
    private func write<Snapshot:Encodable>(_ snapshot:Snapshot,title:String,key:SlotKey,date:Date) throws {
        _ = try name(key)
        let raw = try JSONEncoder().encode(snapshot)
        guard (1...OriginalCampaignResume.maximumBytes).contains(raw.count) else { throw Failure.invalidPayload }
        let payload = try Self.validate(JSONDecoder().decode(OriginalCampaignResume.self,from:raw),practiceMode:practiceMode)
        let bytes = try Self.encode(payload,entry:Entry(title:title,date:date),practiceMode:practiceMode)
        try locked {
            let old = try candidate(key)
            guard old.status != .unsupported else { throw Failure.unsupported }
            if old.status != .empty && old.status != .ready { _ = try preserveCurrent(key) }
            // Commit the previous complete state first. If any staging/write
            // fails, the current file has not changed and remains loadable.
            if let payload = old.payload,let entry = old.entry {
                try writeBackup(Self.encode(payload,entry:entry,practiceMode:practiceMode),key:key)
            }
            try writeManaged(bytes,to:fileURL(for:key))
        }
    }
    /// Refresh the single last-good copy from a structurally readable slot.
    /// This is never called for a suspended continuation.
    @discardableResult func backup(_ key:SlotKey) throws -> Entry {
        try locked {
            let value = try candidate(key)
            guard let payload = value.payload,let entry = value.entry else { throw Self.failure(value.status) }
            try writeBackup(Self.encode(payload,entry:entry,practiceMode:practiceMode),key:key)
            return entry
        }
    }
    /// An explicit recovery keeps the displaced current bytes in a unique
    /// local folder. It does not silently fall back while loading a bad slot.
    @discardableResult func restoreBackup(_ key:SlotKey) throws -> RecoveryResult {
        try locked {
            let saved = Self.envelopeCandidate(at:try backupURL(for:key),practiceMode:practiceMode)
            guard let payload = saved.payload,let entry = saved.entry else { throw Failure.noBackup }
            return try restore(payload,entry:entry,key:key)
        }
    }
    @discardableResult func restoreLegacy(_ key:SlotKey) throws -> RecoveryResult {
        try locked {
            let saved = try legacyCandidate(key)
            guard let payload = saved.payload,let entry = saved.entry else { throw Failure.noLegacy }
            return try restore(payload,entry:entry,key:key)
        }
    }
    private func restore(_ payload:OriginalCampaignResume,entry:Entry,key:SlotKey) throws -> RecoveryResult {
        // Unsupported future formats must not be overwritten even by a
        // recovery from an older copy. The user can export that copy instead.
        guard try candidate(key).status != .unsupported else { throw Failure.unsupported }
        let bytes = try Self.encode(payload,entry:entry,practiceMode:practiceMode)
        let preserved = try preserveCurrent(key)
        try writeManaged(bytes,to:fileURL(for:key))
        return RecoveryResult(entry:entry,preservedDirectory:preserved)
    }
    /// Export a complete, ordinary snapshot. A new name is required; neither
    /// existing saves nor a consumed suspend file can be recreated in place.
    @discardableResult func exportBackup(_ key:SlotKey,to destination:URL) throws -> Entry {
        try locked {
            let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
            let target = destination.standardizedFileURL.resolvingSymlinksInPath().path
            guard destination.isFileURL,target != root,!target.hasPrefix(root+"/"),destination.lastPathComponent.lowercased() != "suspend.json" else {
                throw Failure.unsafeDestination
            }
            let value = try candidate(key)
            guard let payload = value.payload,let entry = value.entry else { throw Self.failure(value.status) }
            let bytes = try Self.encode(payload,entry:entry,practiceMode:practiceMode)
            let parent = destination.deletingLastPathComponent()
            let temporary = parent.appendingPathComponent(".native-save-export-"+UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:temporary) }
            try operations.writeAtomically(bytes,temporary)
            // Hard linking a same-directory staged file is atomic and refuses
            // an existing destination, including a concurrently created file.
            let result = temporary.withUnsafeFileSystemRepresentation { source in
                destination.withUnsafeFileSystemRepresentation { target in Darwin.link(source!,target!) }
            }
            guard result == 0 else {
                if errno == EEXIST { throw Failure.destinationExists }
                throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))
            }
            return entry
        }
    }

    private func candidate(_ key:SlotKey) throws -> Candidate {
        let current = try fileURL(for:key)
        if Self.exists(current) { return Self.envelopeCandidate(at:current,practiceMode:practiceMode) }
        return try legacyCandidate(key)
    }
    private func legacyCandidate(_ key:SlotKey) throws -> Candidate {
        if practiceMode { return Candidate(status:.empty,entry:nil,payload:nil,url:nil,message:"비어 있음") }
        let url = try legacyFile(key),label = try legacyLabel(key)
        guard Self.exists(url) || Self.exists(label) else {
            return Candidate(status:.empty,entry:nil,payload:nil,url:nil,legacy:true,message:"비어 있음")
        }
        var entry:Entry?
        if let bytes = try? Self.boundedData(label,maximum:64*1024),
           let metadata = try? JSONDecoder().decode(Entry.self,from:bytes),Self.valid(metadata) { entry = metadata }
        let missingMetadata = entry == nil
        do {
            let payload = try Self.readFile(from:url)
            if entry == nil { entry = Self.fallbackEntry(at:url) }
            return Candidate(status:missingMetadata ? .metadataDamaged : .ready,entry:entry,payload:payload,url:url,legacy:true,
                message:missingMetadata ? "제목 정보 없음 · 진행은 불러올 수 있습니다." : "이전 형식 저장")
        } catch {
            return Candidate(status:Self.isUnsupported(error) ? .unsupported : .dataDamaged,entry:entry,payload:nil,url:url,legacy:true,
                             message:Self.isUnsupported(error) ? "지원하지 않는 저장 형식" : "진행 데이터를 읽을 수 없음 · 파일 보존됨")
        }
    }
    private static func envelopeCandidate(at url:URL,practiceMode:Bool = false) -> Candidate {
        guard exists(url) else { return Candidate(status:.empty,entry:nil,payload:nil,url:nil,message:"비어 있음") }
        var entry:Entry?
        do {
            let bytes = try boundedData(url,maximum:maximumBytes)
            let header = try JSONDecoder().decode(Header.self,from:bytes)
            guard header.format == 1,header.kind == (practiceMode ? practiceKind : kind) else { throw Failure.unsupported }
            if let metadata = try? JSONDecoder().decode(Metadata.self,from:bytes),valid(metadata.entry) { entry = metadata.entry }
            let payload = try validate(JSONDecoder().decode(Payload.self,from:bytes).payload,practiceMode:practiceMode)
            let metadataMissing = entry == nil
            return Candidate(status:metadataMissing ? .metadataDamaged : .ready,entry:entry ?? fallbackEntry(at:url),payload:payload,url:url,
                             message:metadataMissing ? "제목 정보 손상 · 진행은 불러올 수 있습니다." : "정상")
        } catch {
            return Candidate(status:isUnsupported(error) ? .unsupported : .dataDamaged,entry:entry,payload:nil,url:url,
                             message:isUnsupported(error) ? "지원하지 않는 저장 버전 · 파일 보존됨" : "진행 데이터를 읽을 수 없음 · 파일 보존됨")
        }
    }
    private static func validate(_ payload:OriginalCampaignResume,practiceMode:Bool = false) throws -> OriginalCampaignResume {
        guard payload.format == 1,payload.kind == (practiceMode ? "native-engine-practice" : "native-engine-resume"),payload.checkpoint.format == 1 else { throw Failure.unsupported }
        // Ordinary backups must never turn a one-use continuation into a
        // reusable general save. The suspend store owns that payload.
        guard payload.suspension == nil else { throw Failure.unsupported }
        return payload
    }
    private static func valid(_ entry:Entry) -> Bool { entry.title.count <= 512 && entry.date.timeIntervalSinceReferenceDate.isFinite }
    private static func encode(_ payload:OriginalCampaignResume,entry:Entry,practiceMode:Bool = false) throws -> Data {
        guard valid(entry) else { throw Failure.invalidMetadata }
        let bytes = try JSONEncoder().encode(Envelope(kind:practiceMode ? practiceKind : kind,entry:entry,payload:try validate(payload,practiceMode:practiceMode)))
        guard (1...maximumBytes).contains(bytes.count) else { throw Failure.invalidPayload }
        return bytes
    }
    private static func boundedData(_ url:URL,maximum:Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,(1...maximum).contains(size.intValue) else { throw Failure.invalidPayload }
        let data = try Data(contentsOf:url)
        guard (1...maximum).contains(data.count) else { throw Failure.invalidPayload }
        return data
    }
    private static func exists(_ url:URL) -> Bool {
        var attributes = stat()
        let result = url.withUnsafeFileSystemRepresentation { Darwin.lstat($0!,&attributes) }
        // An inaccessible modern path is not evidence that it is absent.
        // Keep it selected so its error is reported, rather than falling
        // through to older progress in the legacy pair.
        return result == 0 || (errno != ENOENT && errno != ENOTDIR)
    }
    private static func fallbackEntry(at url:URL) -> Entry {
        let attributes = try? FileManager.default.attributesOfItem(atPath:url.path)
        return Entry(title:"제목 정보 없음",date:attributes?[.modificationDate] as? Date ?? Date(timeIntervalSince1970:0))
    }
    private static func failure(_ status:Status) -> Failure {
        switch status { case .empty:return .missing;case .unsupported:return .unsupported;case .metadataDamaged:return .invalidMetadata;default:return .invalidPayload }
    }
    private static func isUnsupported(_ error:Error) -> Bool { if case Failure.unsupported = error { return true };return false }
    private func writeManaged(_ data:Data,to url:URL) throws {
        try ensureManagedDirectory(url.deletingLastPathComponent())
        try operations.writeAtomically(data,url)
    }
    private func writeBackup(_ data:Data,key:SlotKey) throws {
        let url = try backupURL(for:key),old = Self.envelopeCandidate(at:url,practiceMode:practiceMode)
        guard old.status != .unsupported else { throw Failure.unsupported }
        if old.status != .empty && old.status != .ready {
            _ = try preserve([url],name:"\(try name(key))-backup")
        }
        try writeManaged(data,to:url)
    }
    private func ensureManagedDirectory(_ folder:URL) throws {
        // Canonicalize the caller's root once in init. Standardizing each
        // existing/non-existing child independently can rewrite /private/tmp
        // differently. Keep managed components intact so symlinks are refused.
        let root = directory.path,path = folder.path
        guard path.hasPrefix(root+"/") else { throw Failure.unsafeDestination }
        var current = directory
        for component in path.dropFirst(root.count+1).split(separator:"/") {
            current.appendPathComponent(String(component),isDirectory:true)
            if !Self.exists(current) { try FileManager.default.createDirectory(at:current,withIntermediateDirectories:false) }
            let attributes = try FileManager.default.attributesOfItem(atPath:current.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw Failure.unsafeDestination }
        }
    }
    private func preserveCurrent(_ key:SlotKey) throws -> URL? {
        let modern = try fileURL(for:key)
        let sources = Self.exists(modern) ? [modern] : [try legacyFile(key),try legacyLabel(key)].filter(Self.exists)
        return try preserve(sources,name:name(key))
    }
    private func preserve(_ sources:[URL],name:String) throws -> URL? {
        guard !sources.isEmpty else { return nil }
        let folder = storageDirectory.appendingPathComponent("preserved/\(name)-\(UUID().uuidString)",isDirectory:true)
        try ensureManagedDirectory(folder)
        for source in sources {
            // copyItem retains the actual corrupt bytes, even an oversized
            // file, without decoding or allocating it as a snapshot.
            try FileManager.default.copyItem(at:source,to:folder.appendingPathComponent(source.lastPathComponent))
        }
        return folder
    }
    private func locked<T>(_ operation:() throws -> T) throws -> T {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let url = directory.appendingPathComponent(".native-slots.lock")
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            Darwin.open(path!,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW|O_EXLOCK|O_NONBLOCK,S_IRUSR|S_IWUSR)
        }
        guard descriptor >= 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw Failure.busy }
            throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))
        }
        defer { Darwin.close(descriptor) }
        return try operation()
    }
}
