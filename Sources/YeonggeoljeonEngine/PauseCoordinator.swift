// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Only this value combines pause ownership. A confirmed exit may finish its
/// current action in the background; it never dismisses a player choice.
struct PauseCoordinator {
    enum Reason:Hashable { case inactiveApp,minimizedWindow,userPause,savePrompt }
    private(set) var reasons:Set<Reason> = []
    var finishingSave = false
    mutating func set(_ reason:Reason,_ enabled:Bool) {
        if enabled { reasons.insert(reason) } else { reasons.remove(reason) }
    }
    var paused:Bool {
        let effective = finishingSave ? reasons.subtracting([.inactiveApp,.minimizedWindow,.userPause]) : reasons
        return !effective.isEmpty
    }
}

func pauseCoordinatorSelfTests() throws {
    func check(_ test:Bool,_ message:String) throws { if !test { throw EngineError.invalid(message) } }
    var value = PauseCoordinator()
    value.set(.inactiveApp,true);value.set(.minimizedWindow,true)
    value.set(.inactiveApp,false)
    try check(value.paused,"minimized still owns pause")
    value.set(.userPause,true);value.set(.minimizedWindow,false)
    try check(value.paused,"manual pause survives activation")
    value.finishingSave = true
    try check(!value.paused,"confirmed suspension may reach its safe boundary")
    value.set(.savePrompt,true)
    try check(value.paused,"save prompt stays interactive with underlying simulation paused")
    value.set(.savePrompt,false);value.finishingSave = false
    try check(value.paused,"cancelled save restores manual pause")
    value.set(.userPause,false)
    try check(!value.paused,"last owner releases once")
    let decoded = try JSONDecoder().decode(OriginalSettings.self,from:Data("{}".utf8))
    try check(decoded.pauseInBackground,"older settings default to background pause")
    print("PASS pause coordinator: 7 checks")
}
