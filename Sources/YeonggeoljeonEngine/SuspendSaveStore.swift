// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Engine-only, single-use continuation. It lives beside `slots`, never in
/// the original game directory or one of the ordinary native save slots.
/// Preparing a resumed host/view must succeed before the file is consumed.
struct SuspendSaveStore {
    static let maximumBytes = OriginalCampaignResume.maximumBytes + 64 * 1024
    private static let kind = "native-engine-suspend"
    let directory:URL
    var fileURL:URL { directory.appendingPathComponent("suspend.json") }

    struct Entry:Codable,Equatable {
        var id:UUID
        var title:String
        var date:Date
    }
    enum Failure:Error,LocalizedError {
        case missing,busy,unsupported,tooLarge,changed
        var errorDescription:String? {
            switch self {
            case .missing:return "There is no unused suspend save."
            case .busy:return "Another operation is using the suspend save."
            case .unsupported:return "The suspend save has an unsupported format."
            case .tooLarge:return "The suspend save exceeds its input bound."
            case .changed:return "The suspend save changed after it was selected."
            }
        }
    }
    private struct Header:Codable {
        // Revision two gates older builds before they can consume a save and
        // silently discard newer campaign extras. Revision-one files remain
        // readable here; their payload and one-use semantics are unchanged.
        var format = 2
        var kind = SuspendSaveStore.kind
        var entry:Entry
    }
    private struct Envelope<Payload:Codable>:Codable {
        var header:Header
        var snapshot:Payload
    }
    private struct Metadata:Decodable { var header:Header }

    /// An advisory file lock also serializes independent store instances and
    /// app processes. A nonblocking lock rejects duplicate callbacks instead
    /// of making the AppKit event loop wait on another process.
    private func locked<T>(_ operation:() throws -> T) throws -> T {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let lockURL = directory.appendingPathComponent(".suspend.lock")
        let descriptor = lockURL.withUnsafeFileSystemRepresentation { path in
            Darwin.open(path!,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW|O_EXLOCK|O_NONBLOCK,S_IRUSR|S_IWUSR)
        }
        guard descriptor >= 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw Failure.busy }
            throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))
        }
        defer { Darwin.close(descriptor) }
        return try operation()
    }
    private func readData() throws -> Data {
        guard FileManager.default.fileExists(atPath:fileURL.path) else { throw Failure.missing }
        let attributes = try FileManager.default.attributesOfItem(atPath:fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw Failure.unsupported }
        guard let size = attributes[.size] as? NSNumber,(1...Self.maximumBytes).contains(size.intValue) else {
            throw Failure.tooLarge
        }
        let data = try Data(contentsOf:fileURL)
        guard (1...Self.maximumBytes).contains(data.count) else { throw Failure.tooLarge }
        return data
    }
    private func validate(_ header:Header) throws {
        guard (1...2).contains(header.format),header.kind == Self.kind,header.entry.title.count <= 512,
              header.entry.date.timeIntervalSinceReferenceDate.isFinite else { throw Failure.unsupported }
    }

    func entry() throws -> Entry? {
        try locked {
            guard FileManager.default.fileExists(atPath:fileURL.path) else { return nil }
            let header = try JSONDecoder().decode(Metadata.self,from:readData()).header
            try validate(header)
            return header.entry
        }
    }
    /// The metadata and snapshot form one atomic write. A failed encode/write
    /// never replaces just one half of an existing continuation.
    @discardableResult
    func write<Payload:Codable>(_ snapshot:Payload,title:String,date:Date = Date()) throws -> Entry {
        let entry = Entry(id:UUID(),title:title,date:date)
        let header = Header(entry:entry)
        try validate(header)
        let data = try JSONEncoder().encode(Envelope(header:header,snapshot:snapshot))
        guard (1...Self.maximumBytes).contains(data.count) else { throw Failure.tooLarge }
        return try locked {
            try data.write(to:fileURL,options:.atomic)
            return entry
        }
    }
    /// `prepare` must construct and validate the entire resumed state without
    /// replacing the current window yet. If preparation or consumption fails,
    /// the caller keeps its current game and disposes of any prepared view.
    /// Only a successful return authorizes swapping that prepared state in.
    func resume<Payload:Codable,Result>(as type:Payload.Type,expectedID:UUID? = nil,
                                      prepare:(Payload) throws -> Result) throws -> Result {
        try locked {
            let data = try readData()
            // Reject a future envelope before decoding its possibly different
            // payload and before invoking any caller-owned reconstruction.
            try validate(JSONDecoder().decode(Metadata.self,from:data).header)
            let saved = try JSONDecoder().decode(Envelope<Payload>.self,from:data)
            if let expectedID = expectedID,expectedID != saved.header.entry.id { throw Failure.changed }
            let result = try prepare(saved.snapshot)
            // This is the sole point that consumes a save. No cleanup path
            // removes it, and no ordinary slot is read, renamed, or deleted.
            try FileManager.default.removeItem(at:fileURL)
            return result
        }
    }
}
