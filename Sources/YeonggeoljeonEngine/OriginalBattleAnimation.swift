// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// CF5:3C5E over the map. Mode zero closes by itself, mode one waits for input.
enum OriginalBattleNotice:Equatable {
    case ambush(friendly:Bool)
    case strategyFailed(person:Int)
    case level(person:Int,level:Int)
    case learned(abilities:[Int])
    case strategyUsed(person:Int,ability:Int)
    case strategyCry(ability:Int)
    case confused(person:Int,again:Bool)
    case strategyMissed
    case moraleDown(person:Int)
    case healed(person:Int,kind:Int,raises:Bool)
    case stillConfused(person:Int)
    case recovered(person:Int)
    case turn(round:Int,weather:Int)
    case closingBonus(points:Int)
    case delayRetreat
    case troopsRecovered(person:Int,amount:Int)
    case troopsFull
    case moraleRecovered(amount:Int)
    case moraleFull
    var waitsForInput:Bool {
        switch self {
        case .learned,.closingBonus,.delayRetreat:return true
        default:return false
        }
    }
    /// MAIN1A919 and MAIN1A990.
    var sound:Int? {
        switch self {
        case .level,.learned:return 7
        default:return nil
        }
    }
}

/// What the screen shows around a battle action. Cues never touch game state:
/// the session decides the outcome and a view only decides when to show it.
enum OriginalBattleCue:Equatable {
    case walk(slot:Int,path:[GridPoint],sound:Int? = nil)
    case shot(from:GridPoint,to:GridPoint,stone:Bool)
    /// Half cells, so a clash can sit between two units (MAIN3213A).
    case effect(Int,halfX:Int,halfY:Int)
    /// The enlarged view, held after the context has committed its result.
    case combat(OriginalCombatSnapshot)
    case notice(OriginalBattleNotice)
    /// Takes the whole screen, so a view opens it before the next map step.
    var isPresentation:Bool {
        switch self {
        case .combat,.notice:return true
        case .walk,.shot,.effect:return false
        }
    }
}

extension OriginalBattleSession {
    /// MAIN2C847..2C87D: infantry 14, classes two and five 15, six to eight 16.
    func walkSound(_ slot:Int) throws -> Int? {
        guard let unit = units[slot] else { return nil }
        let classID = try people.person(unit.person).classID
        return (6...8).contains(classID) ? 16 : [2,5].contains(classID) ? 15 : 14
    }
    /// MAIN31FEB..3216D. Classes three to five shoot two arrows or stones; the
    /// others clash once at the midpoint. A set option high nibble doubles both.
    func attackCues(_ attacker:Int,target:Int) throws -> [OriginalBattleCue] {
        guard let from = units[attacker]?.position,let to = units[target]?.position,let unit = units[attacker] else { return [] }
        let classID = try people.person(unit.person).classID
        let passes = sourceOptionsWord&0xF0 == 0 ? 1 : 2
        if (3...5).contains(classID) {
            return Array(repeating:.shot(from:from,to:to,stone:classID == 5),count:passes*2)
        }
        return Array(repeating:.effect(8,halfX:from.x+to.x,halfY:from.y+to.y),count:passes)
    }
    /// MAIN1A902..1A9B0: one notice per level gained, then what it taught.
    /// The source compares only the first thirty strategy rows.
    func levelNotices(person:Int,experience:OriginalExperienceMutation) throws -> [OriginalBattleNotice] {
        guard experience.levelsGained > 0 else { return [] }
        let classID = try people.person(person).classID
        var notices:[OriginalBattleNotice] = []
        for level in (experience.level-experience.levelsGained+1)...experience.level {
            notices.append(.level(person:person,level:level))
            let learned = (0..<30).filter { movement.strategyLevelRequirements?[$0][classID] == level }
            if !learned.isEmpty { notices.append(.learned(abilities:learned)) }
        }
        return notices
    }
}

/// Plays cues in order against source ticks. The driver adds 0x35 to a byte per
/// PIT interrupt (SBOPL2 0x255), so a tick is about 16.6 milliseconds.
struct OriginalBattleAnimator {
    static let tick = 256.0/53.0*4096.0/1193182.0
    /// MAIN2CBDD: pixels per draw for the option's low nibble.
    static let walkSteps = [1,2,4,8,16]
    /// MAIN2AC6A: each frame holds one 2502 interval of two, six ticks a unit.
    static let frameTicks = 12.0
    /// DS:3F7E, indexed by effect below eight.
    var effectSounds:[Int] = []
    private(set) var cues:[OriginalBattleCue] = []
    private var elapsed = 0.0
    private var speed = 0
    private var started = false
    private var noticeDismissed = false
    /// CF5:3C5E mode zero holds through CF5:25A6(2): sixteen units of six ticks.
    static let noticeSeconds = 96*tick
    var isIdle:Bool { cues.isEmpty }
    var notice:OriginalBattleNotice? {
        if case .notice(let value)? = cues.first { return value }
        return nil
    }
    /// Takes effect on the next advance, so a caller's completion still runs.
    mutating func dismissNotice() { if notice != nil { noticeDismissed = true } }
    mutating func play(_ new:[OriginalBattleCue],options:Int = 0) {
        cues += new;speed = min(options&15,Self.walkSteps.count-1)
    }
    /// One tick per two pixels at the slowest step. Faster steps skip the
    /// source wait and run as fast as the machine drew; here they halve it.
    var cellSeconds:Double { 16/Double(Self.walkSteps[speed])*Self.tick }
    private func duration(_ cue:OriginalBattleCue) -> Double {
        switch cue {
        case .walk(_,let path,_):return Double(max(0,path.count-1))*cellSeconds
        case .shot(let from,let to,_):return Double(max(abs(to.x-from.x),abs(to.y-from.y))*32)/4*Self.tick
        case .effect(let index,_,_):return (index == 8 ? 2 : 4)*Self.frameTicks*Self.tick
        case .combat:return 0
        case .notice(let value):return noticeDismissed ? elapsed : value.waitsForInput ? .infinity : Self.noticeSeconds
        }
    }
    private func sound(_ cue:OriginalBattleCue) -> Int? {
        switch cue {
        case .walk(_,_,let id):return id
        case .shot:return 19
        case .effect(let index,_,_):
            if index == 8 { return 41 }
            if index == 9 { return 37 }
            return index < effectSounds.count ? effectSounds[index] : nil
        case .combat:return nil
        case .notice(let value):return value.sound
        }
    }
    /// Returns the sounds that start in this interval.
    mutating func advance(_ seconds:Double) -> [Int] {
        var sounds:[Int] = [],left = seconds
        while let cue = cues.first {
            if !started { started = true;if let id = sound(cue) { sounds.append(id) } }
            let rest = duration(cue)-elapsed
            if left < rest { elapsed += left;break }
            left -= rest;elapsed = 0;started = false;noticeDismissed = false;cues.removeFirst()
        }
        return sounds
    }
    /// The current walker's place in cells and how far into its cell it is.
    var walker:(slot:Int,x:Double,y:Double,direction:Int,stepPixels:Int)? {
        guard case .walk(let slot,let path,_)? = cues.first,path.count > 1 else { return nil }
        let position = elapsed/cellSeconds,index = min(path.count-2,Int(position))
        let fraction = position-Double(index),from = path[index],to = path[index+1]
        let dx = to.x-from.x,dy = to.y-from.y
        return (slot,Double(from.x)+Double(dx)*fraction,Double(from.y)+Double(dy)*fraction,
                dy < 0 ? 0 : dx > 0 ? 1 : dy > 0 ? 2 : 3,min(32,Int(fraction*32)))
    }
    /// The frame in the effect catalog and its half-cell place. Effect nine
    /// reuses effect zero's art with its own sound (MAIN2ABEF).
    var effect:(frame:Int,halfX:Int,halfY:Int)? {
        guard case .effect(let index,let x,let y)? = cues.first else { return nil }
        let art = index == 9 ? 0 : index,shown = Int(elapsed/(Self.frameTicks*Self.tick))
        return (art*2+shown%2,x,y)
    }
    /// The shot's picture and its place in cells (MAIN3126B..31294).
    var shot:(frame:Int,x:Double,y:Double)? {
        guard case .shot(let from,let to,let stone)? = cues.first else { return nil }
        let total = duration(cues[0]),fraction = total > 0 ? min(1,elapsed/total) : 1
        let dx = to.x-from.x,dy = to.y-from.y
        let frame = stone ? 4 : abs(dx) > abs(dy) ? (dx > 0 ? 1 : 3) : (dy > 0 ? 2 : 0)
        return (frame,Double(from.x)+Double(dx)*fraction,Double(from.y)+Double(dy)*fraction)
    }
}
