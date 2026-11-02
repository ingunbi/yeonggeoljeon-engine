// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One rider as the duel grid holds it: the cell it was stamped at, the frame,
/// and the load mode that last filled that frame of its bank.
struct OriginalDuelPose:Equatable { var x:Int; var frame:Int; var mode:Int }
/// What the duel window shows after a render (2CB4:0C16).
struct OriginalDuelPicture:Equatable { var poses:[OriginalDuelPose?]; var camera:Int }
/// One hold of the duel scene. Its sounds start as it shows; a waiting step
/// then holds until the effect ends (CF5:631A).
struct OriginalDuelStep:Equatable {
    var picture:OriginalDuelPicture
    var ticks:Int
    var stopsSound = false
    var sounds:[Int] = []
    var waitsForSound = false
}
/// Facts the panels read once at setup (2CB4:0C3C, 1CB6:F752 sides 2 and 3).
struct OriginalDuelPanel:Equatable {
    var person:Int; var level:Int; var classID:Int; var strength:Int; var troops:Int; var maxTroops:Int; var experience:Int
}

/// The duel window between and during script opcodes 10, 33, 34 and 35
/// (2CB4:125E..1824). The battle session owns positions, frames and the RNG;
/// this replays the same steps so the window can show them. It is never saved.
struct OriginalDuelStage:Equatable {
    let people:[Int]
    /// The terrain under participant 1 at setup picks the background (0x34877).
    let terrain:Int
    let panels:[OriginalDuelPanel]
    private(set) var x = [7,13]
    private(set) var frames = [0,0]
    /// Bank 0 holds participant 0's frames, bank 1 participant 1's. A load
    /// replaces only some frames, so each frame keeps the mode that loaded it.
    private(set) var banks = [Array(repeating:0,count:10),Array(repeating:1,count:10)]
    private(set) var camera = 0
    private(set) var shown = OriginalDuelPicture(poses:[nil,nil],camera:0)
    private var grid:[OriginalDuelPose?] = [nil,nil]
    private var steps:[OriginalDuelStep] = []
    private var pendingSounds:[Int] = []
    private var pendingStop = false
    private var pendingWait = false
    /// DS:5082, the sound each motion code starts before its frames.
    private static let motionSounds:[Int?] = [40,41,23,nil,nil,13,38,39]
    init(people:[Int],terrain:Int,panels:[OriginalDuelPanel]) { self.people = people;self.terrain = terrain;self.panels = panels }

    /// The run pose of step `i`: frames 1, 2, 3, 1, ...
    private static func run(_ step:Int) -> Int { step%3+1 }
    /// 0CD6: a stamp records the frame; FF erases and records nothing.
    private mutating func stamp(_ side:Int,_ frame:Int) {
        grid[side] = OriginalDuelPose(x:x[side],frame:frame,mode:banks[side][frame]);frames[side] = frame
    }
    private mutating func erase(_ side:Int) { grid[side] = nil }
    /// 0C16, the only present. A camera argument scrolls the background first.
    private mutating func render(_ view:Int? = nil) {
        if let view = view { camera = view }
        shown = OriginalDuelPicture(poses:grid,camera:camera)
    }
    /// CF5:6280. Starting one effect ends the one before it.
    private mutating func start(_ sound:Int) { pendingSounds.append(sound) }
    /// CF5:629E. A sound started since the last hold never sounds.
    private mutating func stop() { pendingSounds = [];pendingStop = true }
    /// A countdown started before the drawing, then CF5:24C4: the newest
    /// render shows for at least `ticks`.
    private mutating func hold(_ ticks:Int,_ body:(inout Self) -> Void = { _ in }) {
        body(&self)
        append(ticks)
    }
    private mutating func append(_ ticks:Int) {
        steps.append(OriginalDuelStep(picture:shown,ticks:ticks,stopsSound:pendingStop,sounds:pendingSounds,waitsForSound:pendingWait))
        pendingStop = false;pendingSounds = [];pendingWait = false
    }
    /// A sound that holds the scene until it ends, outside any countdown.
    private mutating func waitFor(_ sound:Int?) {
        if let sound = sound { start(sound) }
        pendingWait = true;append(0)
    }
    /// A render with no hold of its own, shown until the next step.
    private mutating func present() {
        if !pendingStop,pendingSounds.isEmpty,steps.last?.picture == shown { return }
        append(0)
    }
    private mutating func take() -> [OriginalDuelStep] {
        present()
        defer { steps = [] }
        return steps
    }

    /// 125E after its loads: each rider runs in place alone while the ground
    /// scrolls under it, then both ride in from the edges. At least 188 ticks.
    mutating func setup() -> [OriginalDuelStep] {
        x = [7,13];frames = [0,0];grid = [nil,nil]
        banks = [Array(repeating:0,count:10),Array(repeating:1,count:10)]
        for side in 0..<2 {
            start(17)
            hold(24) { $0.stamp(side,0);$0.render(side == 0 ? 0 : 40) }
            for step in 0...10 { hold(4) { $0.stamp(side,Self.run(step));$0.render(side == 0 ? step : 40-step) } }
            erase(side);stop()
        }
        render(0);present()
        x = [-6,26];adjust(10)
        hold(12) { $0.stamp(0,0);$0.stamp(1,0);$0.render() }
        return take()
    }
    /// 115E: both run toward each other, or apart when bit seven is set.
    private mutating func adjust(_ encoded:Int) {
        let apart = encoded&0x80 != 0
        start(17)
        for step in 0..<(encoded&0x7F) {
            hold(4) {
                $0.erase(0);$0.erase(1)
                $0.x[0] += apart ? -1 : 1;$0.x[1] += apart ? 1 : -1
                $0.stamp(0,Self.run(step));$0.stamp(1,Self.run(step));$0.render()
                if $0.x[1]-$0.x[0] == 4 { $0.start(38) }                         // 0x3472F
                if $0.x[0] == $0.x[1] { $0.start(40);$0.pendingWait = true }     // 0x34741
            }
            if x[0] == x[1] { start(17) }
        }
        stamp(0,0);stamp(1,0);render();stop();present()
    }
    /// 0FFC: one rider runs at the other. Without `extra` it stops four cells
    /// short; with it the rider runs `span+extra+1` steps, through and on.
    private mutating func approach(_ side:Int,extra:Int?) {
        let other = side^1,direction = side == 0 ? 1 : -1
        let target = side == 0 ? x[1]-4 : x[0]+4,span = abs(x[1]-x[0])
        // The source walks a rider that is past its mark away from it until the
        // word wraps; the session jumps to the mark, and so does this.
        if extra == nil,(target-x[side])*direction < 0 { x[side] = target }
        start(17)
        var step = 0
        while true {
            if extra == nil,x[side] == target { break }
            hold(4) {
                $0.erase(side);$0.erase(other);$0.x[side] += direction
                $0.stamp(side,Self.run(step));$0.stamp(other,$0.frames[other]);$0.render()
            }
            step += 1
            if x[0] == x[1] { waitFor(40);start(17) }                                  // 0x3460A
            if let extra = extra,step > extra+span { break }
        }
        erase(0);erase(1);stamp(side,0);stamp(other,frames[other]);render();stop();present()
    }
    /// 1736: five rounds of poses and blows. It draws what the session drew,
    /// from the same RNG state, so `rng` ends where the session's did.
    mutating func clash(rng:inout OriginalRNG) throws -> [OriginalDuelStep] {
        adjust(4)
        for _ in 0..<5 {
            erase(0);erase(1)
            let a = (try rng.next(bound:3)+2)*2,b = (try rng.next(bound:3)+2)*2
            for pose in 0..<2 {
                var blow:Int?
                if a != 8 || b != 8 { blow = try rng.next(bound:2) == 0 ? 40 : 41 }
                hold(4) {
                    $0.stamp(0,a == 8 ? 0 : a+pose);$0.stamp(1,b == 8 ? 0 : b+pose);$0.render()
                    if let blow = blow { $0.start(blow) }
                }
            }
            hold(12)
        }
        adjust(0x84)
        return take()
    }
    /// 14D0. `person` must be a participant the session found a unit for.
    mutating func motion(person:Int,code:Int) throws -> [OriginalDuelStep] {
        let side = person == people[0] ? 0 : 1
        switch code {
        case 0,1,6,7:
            approach(side,extra:nil)
            frameSteps(side,code:code,frames:code == 0 || code == 6 ? [4,5] : [6,7])
        case 2:frameSteps(side,code:2,frames:[8,9])
        case 3:
            // Death art always loads into bank 1, whichever rider the script named.
            for frame in 0..<5 { banks[1][frame] = 2 }
            frameSteps(side,code:3,frames:Array(0..<5))
        case 4:
            // 0x34A91: participant 1 flees and is left erased.
            for frame in 0..<3 { banks[1][frame] = 3 }
            start(17)
            for step in 0...13 {
                hold(4) { $0.stamp(1,step%3);$0.render() }
                erase(1);x[1] += 1
            }
            stop();render();present()
        case 5:
            start(13)
            hold(6) { $0.stamp(side,0);$0.render() }
        case 8:adjust(10)
        case 9:
            // 0x34B4D: the sprites move first, so the camera ends one short.
            let target = max(0,x[side]-10)
            var view = camera
            let direction = view > target ? -1 : 1
            while view != target {
                let shown = view
                hold(1) {
                    $0.erase(0);$0.erase(1);$0.x[0] -= direction;$0.x[1] -= direction
                    $0.stamp(0,$0.frames[0]);$0.stamp(1,$0.frames[1]);$0.render(shown)
                }
                view += direction
            }
        case 10:approach(side,extra:8)
        default:throw BattleError.unsupported("Original duel motion code has no examined steps")
        }
        render();present()                                                          // 0x34C66
        return take()
    }
    /// 0x34BF9..0x34C61: the code's sound, six ticks a frame, then a wait for the sound.
    private mutating func frameSteps(_ side:Int,code:Int,frames shown:[Int]) {
        if let sound = Self.motionSounds[code] { start(sound) }
        for frame in shown { hold(6) { $0.stamp(side,frame);$0.render() } }
        waitFor(code == 3 ? 21 : nil)
    }
}

/// Plays duel steps against source ticks, as the combat view's player does.
struct OriginalDuelPlayer {
    let steps:[OriginalDuelStep]
    private(set) var index = 0
    private var elapsed = 0.0
    private var started = false
    init(steps:[OriginalDuelStep]) { self.steps = steps }
    enum Action:Equatable { case sound(Int),stopSound }
    var finished:Bool { index >= steps.count }
    var picture:OriginalDuelPicture? { finished ? steps.last?.picture : steps[index].picture }
    mutating func advance(_ seconds:Double,soundBusy:Bool) -> [Action] {
        var actions:[Action] = [],left = seconds/OriginalBattleAnimator.tick
        while !finished {
            let current = steps[index]
            if !started {
                started = true
                if current.stopsSound { actions.append(.stopSound) }
                actions += current.sounds.map(Action.sound)
            }
            let rest = Double(current.ticks)-elapsed
            if left < rest { elapsed += left;break }
            // A sound started in this call may not report itself yet.
            if current.waitsForSound,soundBusy || actions.contains(where:{ if case .sound = $0 { return true };return false }) {
                elapsed = Double(current.ticks);break
            }
            left -= max(0,rest);index += 1;elapsed = 0;started = false
        }
        return actions
    }
}
