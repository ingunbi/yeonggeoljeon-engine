// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if !os(Android)
import CryptoKit
#else
import Foundation
#endif

/// Canonical source-bound identity for a read-only reference. It is never a
/// replacement for original file hashes or a claim of original runtime parity.
enum SourceCatalogIdentity {
    static func digest<T:Encodable>(_ value:T) throws -> String {
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data:try encoder.encode(value)).map {String(format:"%02x",$0)}.joined()
    }
    static func valid(_ value:String)->Bool {value.count == 64 && value.utf8.allSatisfy {($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)}}
}
