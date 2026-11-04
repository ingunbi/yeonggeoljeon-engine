// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The player's options, from the object at DS:7A80: word +4 holds the battle
/// settings, byte +13 the field speed, and word +A the monitor and sound bits.
/// They stay per user, so replays and tests always run the source defaults
/// (the new-game word +4 is zero). The window's defaults differ in one place:
/// it follows enemy moves.
struct OriginalSettings:Codable,Equatable {
    /// 노웨이트 to 느리다: three ticks a step per level (MAIN24818).
    var speed = 2
    /// 1속 to 5속 (word +4 low nibble).
    var moveSpeed = 0
    /// 본다 or 안 본다 (high nibble). Zero asks for the enlarged combat view.
    var unitCombat = 0
    /// Bit 0x1000: the camera follows enemy moves (MAIN2C4D6). The source
    /// starts with it clear; the engine window starts with it set.
    var enemyMove = true
    /// Bit 8 of word +A: the grey palette.
    var monochrome = false
    /// Engine addition: one output level for the single chip.
    var volume:Float = 1
    /// 소 to 극대: tiles the world map moves a scroll step (player +11,
    /// MAIN22832; the new-game template holds 1).
    var scroll = 1
    static let scrollSteps = [1,2,4,8]
    /// Engine addition: a shown line closes by itself (see DialoguePace),
    /// at one of DialoguePace.speedLabels.
    var autoAdvance = false
    var autoSpeed = 1
    /// Engine addition: battle presentation (walks, effects, the enlarged
    /// combat view, notices) plays this many times as fast.
    var battlePace = 0
    static let battlePaceRates:[Double] = [1,1.5,2,3]
    var battleRate:Double { Self.battlePaceRates.indices.contains(battlePace) ? Self.battlePaceRates[battlePace] : 1 }

    /// Revision 1 turned enemy following on for settings stored before it,
    /// once; a later choice of 안 본다 is kept.
    static let currentRevision = 1
    var revision = Self.currentRevision

    private enum CodingKeys:String,CodingKey { case speed,moveSpeed,unitCombat,enemyMove,monochrome,volume,scroll,autoAdvance,autoSpeed,battlePace,revision }
    init() {}
    /// Settings stored by an older build keep their values; a missing key takes its default.
    init(from decoder:Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self),blank = OriginalSettings()
        speed = try values.decodeIfPresent(Int.self,forKey:.speed) ?? blank.speed
        moveSpeed = try values.decodeIfPresent(Int.self,forKey:.moveSpeed) ?? blank.moveSpeed
        unitCombat = try values.decodeIfPresent(Int.self,forKey:.unitCombat) ?? blank.unitCombat
        enemyMove = try values.decodeIfPresent(Bool.self,forKey:.enemyMove) ?? blank.enemyMove
        if (try values.decodeIfPresent(Int.self,forKey:.revision) ?? 0) < 1 { enemyMove = true }
        monochrome = try values.decodeIfPresent(Bool.self,forKey:.monochrome) ?? blank.monochrome
        volume = try values.decodeIfPresent(Float.self,forKey:.volume) ?? blank.volume
        scroll = try values.decodeIfPresent(Int.self,forKey:.scroll).flatMap { Self.scrollSteps.contains($0) ? $0 : nil } ?? blank.scroll
        autoAdvance = try values.decodeIfPresent(Bool.self,forKey:.autoAdvance) ?? blank.autoAdvance
        autoSpeed = try values.decodeIfPresent(Int.self,forKey:.autoSpeed).flatMap { DialoguePace.speedLabels.indices.contains($0) ? $0 : nil } ?? blank.autoSpeed
        battlePace = try values.decodeIfPresent(Int.self,forKey:.battlePace).flatMap { Self.battlePaceRates.indices.contains($0) ? $0 : nil } ?? blank.battlePace
    }

    private static let key = "originalSettings"
    static var current:OriginalSettings {
        get {
            UserDefaults.standard.data(forKey:key).flatMap { try? JSONDecoder().decode(Self.self,from:$0) } ?? OriginalSettings()
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data,forKey:key)
            NotificationCenter.default.post(name:changed,object:nil)
        }
    }
    static let changed = Notification.Name("OriginalSettingsChanged")
    var battleWord:Int { moveSpeed|unitCombat<<4|(enemyMove ? 0x1000 : 0) }
    /// Field time runs at the source's step over the chosen one. 노웨이트
    /// has no wait at all, so it takes a short frame of the window's own.
    var timeScale:Double { speed == 0 ? 6 : 2/Double(speed) }
}

/// Engine additions for reading pace. The source waits for a key on every
/// line; auto advance and skip only decide when the window sends that key,
/// so neither changes game state.
final class DialoguePace {
    static let shared = DialoguePace()
    static let changed = Notification.Name("DialoguePaceChanged")
    static let speedLabels = ["느리게","보통","빠르게"]
    /// A fully shown line closes by itself after a reading pause. Kept with
    /// the player's settings, which a menu may also change directly.
    var auto = false { didSet { if auto != oldValue { persist() } } }
    var speed = 1 { didSet { if speed != oldValue { persist() } } }
    private var loading = false
    private var observer:NSObjectProtocol?
    private init() {
        reload()
        observer = NotificationCenter.default.addObserver(forName:OriginalSettings.changed,object:nil,queue:.main) { [weak self] _ in self?.reload() }
    }
    private func reload() {
        let value = OriginalSettings.current
        loading = true;auto = value.autoAdvance;speed = value.autoSpeed;loading = false
    }
    private func persist() {
        if !loading { var value = OriginalSettings.current;value.autoAdvance = auto;value.autoSpeed = speed;OriginalSettings.current = value }
        post()
    }
    /// Lines close at once and time runs fast until the player has
    /// something to decide; the window turns it off there.
    var skipping = false { didSet { if skipping != oldValue { post() } } }
    private func post() { NotificationCenter.default.post(name:Self.changed,object:nil) }
    /// How long auto mode leaves a fully shown line up: a base and a little
    /// per character, within bounds, for 느리게, 보통 and 빠르게.
    private static let reading:[(base:Double,perCharacter:Double,least:Double,most:Double)] = [(0.8,0.04,1.2,5),(0.4,0.02,0.8,2.5),(0.15,0.01,0.4,1.5)]
    static func readingSeconds(_ text:String,speed:Int = 1) -> Double {
        let pace = reading[min(max(0,speed),reading.count-1)]
        return min(pace.most,max(pace.least,pace.base+Double(text.count)*pace.perCharacter))
    }
}

/// Five native slots, as the original has five MSAVE files. They hold
/// `OriginalCampaignResume` JSON; original slots are never read or written.
struct OriginalSaveSlots {
    static let count = 5
    struct Entry:Codable,Equatable { var title:String;var date:Date }
    let directory:URL
    /// Engine slots beside the five: the autosave and the quick slot.
    enum Named:String,CaseIterable { case auto,quick }
    private func file(_ name:String) -> URL { directory.appendingPathComponent("\(name).json") }
    private func label(_ name:String) -> URL { directory.appendingPathComponent("\(name).label.json") }
    private func entry(_ name:String) -> Entry? {
        guard FileManager.default.fileExists(atPath:file(name).path),let data = try? Data(contentsOf:label(name)) else { return nil }
        return try? JSONDecoder().decode(Entry.self,from:data)
    }
    private func write<Snapshot:Encodable>(_ snapshot:Snapshot,title:String,name:String,date:Date) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try JSONEncoder().encode(snapshot).write(to:file(name),options:.atomic)
        try JSONEncoder().encode(Entry(title:title,date:date)).write(to:label(name),options:.atomic)
    }
    func entries() -> [Entry?] { (0..<Self.count).map { entry("slot-\($0)") } }
    func write<Snapshot:Encodable>(_ snapshot:Snapshot,title:String,slot:Int,date:Date = Date()) throws {
        guard (0..<Self.count).contains(slot) else { throw EngineError.invalid("Save slot is outside the five slots") }
        try write(snapshot,title:title,name:"slot-\(slot)",date:date)
    }
    func read(slot:Int) throws -> OriginalCampaignResume { try OriginalCampaignResume.read(from:file("slot-\(slot)")) }
    func entry(_ name:Named) -> Entry? { entry(name.rawValue) }
    func write<Snapshot:Encodable>(_ snapshot:Snapshot,title:String,named name:Named,date:Date = Date()) throws {
        try write(snapshot,title:title,name:name.rawValue,date:date)
    }
    func read(_ name:Named) throws -> OriginalCampaignResume { try OriginalCampaignResume.read(from:file(name.rawValue)) }
}
