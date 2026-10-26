// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// MAIN1E399..1E3A7 leaves the framework map loop once its mask contains
/// 04/08/20/40. main then selects the ending, the retry selector or exit.
enum OriginalFrameworkOutcome:String,Codable { case pending, restart, quit }

struct OriginalFrameworkReturn:Codable,Equatable {
    var mask:Int
    var producer:String
    var recordID:String?
    var sourceOffset:Int?
    var outcome:OriginalFrameworkOutcome = .pending
    /// main1E556..1E5DB: mask04 takes the ending branch first; only20/40
    /// reach the two-button selector at1E5DD.
    var asksRetry:Bool { mask & 4 == 0 && mask & 0x60 != 0 }

    /// main1E5DD..1E5FE: the selector returns one for Yes and zero for No.
    /// One returns exit code4; HERO.COM then executes MAIN again without
    /// OPEN. Zero shows MAIN1E3A8, waits for input and exits with code3.
    mutating func answer(_ result:Int) throws {
        guard outcome == .pending,asksRetry,[0,1].contains(result) else {
            throw EngineError.invalid("No original retry selector is pending")
        }
        outcome = result == 1 ? .restart : .quit
    }

    /// MAIN22250..22285/26491..264CA translate interpreter status7 into map
    /// flag20 and status8 into flag04. Other statuses do not leave the loop.
    static func mask(interpreterStatus:Int) -> Int? {
        switch interpreterStatus {
        case 7: return 0x20
        case 8: return 4
        default: return nil
        }
    }
}

/// MAIN1E31C..1E344 interprets the raw battle-loop result. One restores the
/// battle checkpoint (MAIN1E347..1E368), three and four add masks20/40, and
/// every other value calls CF5:C86C (MAIN201BC..2022E), which enters the map
/// held in script context+0A. Source09 and source11 both write that field.
enum OriginalBattleExit:Equatable {
    case restoreCheckpoint
    case framework(mask:Int)
    case enterMap(selectionIndex:Int)
    case unsupported(String)

    /// `selectionMaps` lists the restored producers of context+0A in source
    /// order. The latest one equal to the VM's context map owns provenance.
    static func decide(result:UInt8,contextMap:Int,selectionMaps:[Int]) -> OriginalBattleExit {
        switch result {
        case 0: return .unsupported("Original battle loop has not produced a raw result")
        case 1: return .restoreCheckpoint
        case 3: return .framework(mask:0x20)
        case 4: return .framework(mask:0x40)
        default:
            guard (0...0xFFFF).contains(contextMap),contextMap>>12 != 3 else {
                return .unsupported("Original battle exit would re-enter a battle map through C86C; battle re-entry is not restored")
            }
            guard let index = selectionMaps.lastIndex(of:contextMap) else {
                return .unsupported("Original battle exit has no restored producer for script context+0A")
            }
            return .enterMap(selectionIndex:index)
        }
    }
}
