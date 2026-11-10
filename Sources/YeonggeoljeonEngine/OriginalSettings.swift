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
    /// Engine-only presentation choice. The legacy unitCombat nibble remains
    /// untouched because physicalPrelude consumes source RNG according to it.
    var combatPresentationMode:CombatPresentationPolicy.Mode = .all
    var showDuelPresentation = true
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
    var showResumeBrief = true
    var pauseInBackground = true
    var controls = AppControlPreferences()
    var tutorials = TutorialGuidance.Preferences()
    var eventHintLevel = ReviewedEventHints.Level.off
    var eventHintCatalogPath:String? = nil
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

    private enum CodingKeys:String,CodingKey { case speed,moveSpeed,unitCombat,enemyMove,monochrome,volume,scroll,autoAdvance,autoSpeed,battlePace,revision,pauseInBackground,showResumeBrief,combatPresentationMode,showDuelPresentation,controls,tutorials,eventHintLevel,eventHintCatalogPath }
    init() {}
    /// Settings stored by an older build keep their values; a missing key takes its default.
    init(from decoder:Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self),blank = OriginalSettings()
        speed = try values.decodeIfPresent(Int.self,forKey:.speed) ?? blank.speed
        moveSpeed = try values.decodeIfPresent(Int.self,forKey:.moveSpeed) ?? blank.moveSpeed
        unitCombat = try values.decodeIfPresent(Int.self,forKey:.unitCombat) ?? blank.unitCombat
        let storedMode = try values.decodeIfPresent(String.self,forKey:.combatPresentationMode)
        combatPresentationMode = storedMode.flatMap(CombatPresentationPolicy.Mode.init(rawValue:)) ?? (unitCombat == 0 ? .all : .none)
        showDuelPresentation = try values.decodeIfPresent(Bool.self,forKey:.showDuelPresentation) ?? blank.showDuelPresentation
        enemyMove = try values.decodeIfPresent(Bool.self,forKey:.enemyMove) ?? blank.enemyMove
        if (try values.decodeIfPresent(Int.self,forKey:.revision) ?? 0) < 1 { enemyMove = true }
        monochrome = try values.decodeIfPresent(Bool.self,forKey:.monochrome) ?? blank.monochrome
        volume = try values.decodeIfPresent(Float.self,forKey:.volume) ?? blank.volume
        scroll = try values.decodeIfPresent(Int.self,forKey:.scroll).flatMap { Self.scrollSteps.contains($0) ? $0 : nil } ?? blank.scroll
        showResumeBrief = try values.decodeIfPresent(Bool.self,forKey:.showResumeBrief) ?? blank.showResumeBrief
        pauseInBackground = try values.decodeIfPresent(Bool.self,forKey:.pauseInBackground) ?? blank.pauseInBackground
        controls = (try? values.decodeIfPresent(AppControlPreferences.self,forKey:.controls)) ?? blank.controls
        tutorials = (try? values.decodeIfPresent(TutorialGuidance.Preferences.self,forKey:.tutorials)) ?? blank.tutorials
        eventHintLevel = (try? values.decodeIfPresent(ReviewedEventHints.Level.self,forKey:.eventHintLevel)) ?? .off
        eventHintCatalogPath = (try? values.decodeIfPresent(String.self,forKey:.eventHintCatalogPath)).flatMap { $0.hasPrefix("/") && $0.count <= 4096 ? $0 : nil }
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
            AppControlRuntime.update(newValue.controls)
            NotificationCenter.default.post(name:changed,object:nil)
        }
    }
    static let changed = Notification.Name("OriginalSettingsChanged")
    var battleWord:Int { moveSpeed|unitCombat<<4|(enemyMove ? 0x1000 : 0) }
    /// Field time runs at the source's step over the chosen one. 노웨이트
    /// has no wait at all, so it takes a short frame of the window's own.
    var timeScale:Double { speed == 0 ? 6 : 2/Double(speed) }
}

/// Modern labels explain which presentation changes. Stored source choices
/// and all timing rules stay unchanged (MAIN2CBDD, 27DC4, 2C4D6).
enum BattleSettingPresentation {
    static func label(_ action:String,original:String) -> String {
        switch action {
        case "battle-pace":return "전투 재생 배속"
        case "move-speed":return "지도 이동 속도"
        case "unit-combat":return "확대 전투 연출"
        case "enemy-move":return "적 이동 따라가기"
        default:return original
        }
    }
    static func help(_ action:String) -> String {
        switch action {
        case "battle-pace":return "전투 연출 전체의 재생 배속입니다.\n이동·공격·책략·일기토에 함께 적용됩니다."
        case "move-speed":return "지도 위 걷기 속도입니다(1 느림 → 5 빠름).\n재생 배속도 함께 적용됩니다. 이동력은 그대로입니다."
        case "unit-combat":return "확대 화면만 선택합니다. 생략한 결과는 지도에 표시합니다.\n중요 교전: 주력 장수·확정 격파·아군 병력 25% 이하."
        case "duel-presentation":return "일기토 확대 연출을 표시합니다.\n생략해도 대사와 전투 결과는 그대로 진행됩니다."
        case "enemy-move":return "적이 이동할 때 화면이 해당 부대를 따라갑니다.\n끄면 화면 밖 적의 이동 연출은 생략합니다."
        case "auto":return "대사를 읽을 시간을 둔 뒤 자동으로 넘깁니다.\n선택지가 나오면 입력을 기다립니다."
        default:return ""
        }
    }
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
        // A view can already be observing before the first shared access.
        // Publishing here would let it re-enter shared's once-only initializer.
        reload(notifying:false)
        observer = NotificationCenter.default.addObserver(forName:OriginalSettings.changed,object:nil,queue:.main) { [weak self] _ in self?.reload() }
    }
    private func reload(notifying:Bool = true) {
        let value = OriginalSettings.current
        let changed = auto != value.autoAdvance || speed != value.autoSpeed
        loading = true;auto = value.autoAdvance;speed = value.autoSpeed;loading = false
        // Observers see the complete pair, never an intermediate setting.
        if notifying && changed { post() }
    }
    private func persist() {
        guard !loading else { return }
        var value = OriginalSettings.current;value.autoAdvance = auto;value.autoSpeed = speed;OriginalSettings.current = value
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
