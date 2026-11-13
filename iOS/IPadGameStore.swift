// SPDX-License-Identifier: GPL-3.0-only
#if !os(Android)
import SwiftUI
import CoreGraphics
#endif
import Foundation

struct IPadAction:Identifiable {
    var id:String
    var title:String
    var subtitle:String = ""
    var enabled:Bool = true
    var perform:()->Void
}
/// What the battle screen shows about the unit being looked at.
struct IPadUnitInfo {
    var slot:Int
    var name:String
    var className:String
    var level:Int
    var troops:Int
    var maxTroops:Int
    var morale:Int
    var mp:Int
    var maxMP:Int
    var terrain:String
    var enemy:Bool
    var confused:Bool
    var portrait:CGImage?
}
/// One side of the enlarged combat view: who fights and the numbers before the blow.
struct IPadCombatSide {
    var name:String
    var classLevel:String
    var valueLabel:String
    var value:Int
    var troops:Int
    var maximum:Int
    var morale:Int
    var extraLabel:String
    var extraText:String
    var portrait:CGImage?
}
struct IPadCombatState {
    var image:CGImage?
    var left:IPadCombatSide
    var right:IPadCombatSide
    var lines:[String]
    var gauges:[(value:Int,maximum:Int)]
    var notice:String?
}
struct IPadPanel {
    enum Style {case panel,dialogue}
    var title:String
    var body:String
    var actions:[IPadAction]
    var style:Style = .panel
    /// A spoken line: the card sits over the picture and a tap anywhere advances it.
    var portrait:CGImage? = nil
}

/// Touch input owns no alternative combat rules. Every accepted command goes
/// through the same host/flow used by the desktop game and deterministic driver.
@MainActor final class IPadGameStore:ObservableObject {
    private(set) var data:DataSet?
    private(set) var host:OriginalCampaignHost?
    private(set) var flow:OriginalBattleFlow?
    @Published var selectedSlot:Int?
    @Published private(set) var highlighted:Set<GridPoint> = []
    /// The desktop's reading aids: where the enemy can strike, and what a unit could hit from a cell it has not moved to yet.
    @Published private(set) var threatOn = false
    @Published private(set) var previewCells:Set<GridPoint> = []
    /// The cells of the enemies the pending attack can hit; `highlighted` also holds the rest of the range.
    private var attackTargets:Set<GridPoint> = []
    @Published private(set) var fieldImage:CGImage?
    /// True while the image is the cropped map window, so touches can act on it.
    private(set) var fieldIsMap = false
    private var portraits:[String:CGImage] = [:]
    @Published private(set) var header = "영걸전"
    @Published private(set) var status = ""
    @Published private(set) var revision = 0
    @Published var error:String?

    /// An error as a player reads it: engine reasons are mostly Korean already, so drop the English
    /// prefix; the few untranslated ones get a plain sentence.
    static func message(_ error:Error) -> String {
        var text = String(describing:error)
        for prefix in ["Illegal battle action: ","Invalid: "] where text.hasPrefix(prefix) {text = String(text.dropFirst(prefix.count))}
        if text.contains("outside the manual friendly input gate") {return "이 부대는 지금 직접 조작할 수 없습니다."}
        if text.contains("world city selection is unavailable") {return "지금은 그곳을 고를 수 없습니다. 인물·목적지 목록에서 고르세요."}
        return text
    }
    @Published var menu:IPadPanel?
    /// Lines close on their own while skipping; it stops at the first choice or other decision.
    @Published var skipping = false
    /// Simulation steps per timer callback: 1, 2 or 4. Only the pace changes, never a step's rules.
    @Published private(set) var speedFactor = 1
    /// The map's action timeline: walks, shots, strikes and damage numbers play here.
    private(set) var animator = OriginalBattleAnimator()
    private var afterCues:(()->Void)?
    private var combatArt:OriginalCombatArt?
    /// The enlarged scene that holds the battle while it plays.
    @Published private(set) var combatPlayer:OriginalCombatPlayer?
    private var combatRest:[OriginalBattleCue] = []
    private var combatImage:(key:Int,image:CGImage)?
    private var hasPresentedCombat = false
    private var lineSeen:(text:String,since:TimeInterval)?
    private var skipPhase = 0
    private var renderer:Renderer?
    private var audio:OriginalAudio?
    private var timer:Timer?
    private var active = true
    private var suspendedRequest = false
    /// A suspend-save that keeps playing instead of returning to the title (a tablet's quick save).
    private var suspendContinues = false
    private var transientNoticeUntil:Double?
    private var queuedNotice:IPadPanel?
    private var pendingBattleStart:(snapshot:OriginalCampaignResume,title:String)?
    private var capturedBattle:ObjectIdentifier?
    private var lastAutoKey:String?
    private var nextAutoAttempt = 0.0
    private var nextBattleSaveAttempt = 0.0
    private var saveNotice:String?
    private var archive:BattleArchiveCoordinator?
    private var archiveRevision = 0
    private var checkpointRevision = -1
    private var combatCatalog:OriginalCombatCatalog?
    private var targetMode:TargetMode?
    private let saveRoot:URL
    private enum TargetMode {case move,attack,strategy(Int),item(Int),give(Int)}
    var isBattle:Bool {host?.stage.palette == 3 && host?.battle != nil && host?.ending == nil}
    var session:OriginalBattleSession? {isBattle ? host?.battle : nil}
    var canAct:Bool {active && animator.isIdle && afterCues == nil && combatPlayer == nil && error == nil && menu == nil && prompt == nil && host?.battleInputReady == true && flow?.acceptsManualInput == true && !suspendedRequest}

    /// Explicit roots and disabled timers let local verification inspect the
    /// real controller without touching a device's or a Mac user's saves.
    init(dataRoot:URL? = nil,saveRoot:URL? = nil,startsTimer:Bool = true,enablesAudio:Bool = true) {
        self.saveRoot = saveRoot ?? FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("YeonggeoljeonSaves",isDirectory:true)
        do {
            guard let root = dataRoot ?? Bundle.main.url(forResource:"GameData",withExtension:nil) else {throw EngineError.invalid("앱에 게임 자료가 없습니다.")}
            let data = try DataSet(root:root)
            self.data = data;renderer = try Renderer(data)
            combatCatalog = try? OriginalCombatCatalog.load(from:root.appendingPathComponent("combat-view.json"))
            combatArt = combatCatalog.flatMap {try? OriginalCombatArt(catalog:$0)}
            if enablesAudio,let music = try? OriginalMusicCatalog.load(from:root.appendingPathComponent("music.json")) {audio = OriginalAudio(catalog:music)}
            audio?.volume = OriginalSettings.current.volume
            try prepareTitle()
        } catch {self.error = Self.message(error);status = "게임을 열지 못했습니다."}
        if startsTimer {
            timer = Timer.scheduledTimer(withTimeInterval:1.0/30,repeats:true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
        }
    }
    deinit {timer?.invalidate()}
    var dialogueAuto:Bool {
        get {DialoguePace.shared.auto}
        set {DialoguePace.shared.auto = newValue;revision += 1}
    }
    func cycleSpeed() {speedFactor = speedFactor == 1 ? 2 : (speedFactor == 2 ? 4 : 1)}
    func toggleSkip() {skipping.toggle();if skipping {dialogueAuto = false}}
    func advanceDialogue() {prompt?.actions.first?.perform()}
    /// A battle notice (level up, phase change, a failed strategy) over the map.
    var cueBanner:(text:String,waits:Bool)? {
        guard let notice = animator.notice else {return nil}
        let text = noticeText(notice)
        return text.isEmpty ? nil : (text,notice.waitsForInput)
    }
    func dismissCueNotice() {if animator.notice != nil {animator.dismissNotice()}}
    private func play(_ cues:[OriginalBattleCue],then done:(()->Void)? = nil) {
        guard !cues.isEmpty else {done?();return}
        animator.play(cues,options:1);afterCues = done;revision += 1
    }
    private func playHeldCues(_ flow:OriginalBattleFlow) -> Bool {
        let cues = flow.takeCues()
        guard !cues.isEmpty else {return false}
        startCues(cues);return true
    }
    /// Walks, shots and numbers play on the map; a combat cue opens the enlarged scene
    /// (or shrinks to a number, by the player's setting) and the cues after it wait.
    private func startCues(_ cues:[OriginalBattleCue]) {
        var found:(index:Int,snapshot:OriginalCombatSnapshot)?
        for (index,cue) in cues.enumerated() {if case .combat(let snapshot) = cue {found = (index,snapshot);break}}
        guard let found else {play(cues);return}
        let before = Array(cues[..<found.index]),rest = Array(cues[(found.index+1)...])
        let begin:()->Void = {[weak self] in self?.beginCombat(found.snapshot,rest:rest)}
        if before.isEmpty {begin()} else {play(before,then:begin)}
    }
    private func beginCombat(_ snapshot:OriginalCombatSnapshot,rest:[OriginalBattleCue]) {
        let policy = CombatPresentationPolicy(mode:OriginalSettings.current.combatPresentationMode,importantPersonIDs:[],showsDuels:false)
        if policy.showsCombat(snapshot,hasPresentedCombat:hasPresentedCombat),let art = combatArt,
           var scene = try? OriginalCombatScene(catalog:art.catalog,snapshot:snapshot) {
            scene.addResults(attackerName:personName(snapshot.attackerPerson),targetName:personName(snapshot.targetPerson))
            combatPlayer = OriginalCombatPlayer(scene:scene);combatRest = rest;hasPresentedCombat = true;combatImage = nil;revision += 1
        } else {startCues(policy.abbreviatedCues(for:snapshot)+rest)}
    }
    func skipCombatHold() {combatPlayer?.skip()}
    func endCombat() {combatPlayer?.finish()}
    /// The enlarged scene as the screen reads it: picture, both sides, the result window.
    var combatState:IPadCombatState? {
        guard let player = combatPlayer,let art = combatArt else {return nil}
        if let shown = player.picture {
            let key = shown.layers.hashValue^shown.scroll
            if combatImage?.key != key,let image = art.picture(shown,scene:player.scene) {combatImage = (key,image)}
        }
        let snapshot = player.scene.snapshot,texts = art.catalog.texts,friendly = snapshot.attackerSlot < 15
        let palette = host?.stage.palette ?? 0
        func side(_ person:Int,_ classID:Int,_ level:Int,_ label:String,_ value:Int,_ troops:Int,_ maximum:Int,_ morale:Int,_ extra:(String,String)) -> IPadCombatSide {
            let className = art.catalog.classNames.indices.contains(classID) ? art.catalog.classNames[classID] : ""
            return IPadCombatSide(name:personName(person),classLevel:originalFormat(texts.level,[String(level),className]),valueLabel:label,value:value,
                troops:troops,maximum:maximum,morale:morale,extraLabel:extra.0,extraText:extra.1,portrait:portraitImage(person:person,palette:palette))
        }
        let terrain = (texts.terrain,"\(snapshot.terrainPercent)%")
        let attacker = side(snapshot.attackerPerson,snapshot.attackerClass,snapshot.attackerLevel,texts.attack,snapshot.attackValue,
                            snapshot.attackerTroops,snapshot.attackerMaxTroops,snapshot.attackerMorale,friendly ? (texts.exp,String(snapshot.experience)) : ("",""))
        let target = side(snapshot.targetPerson,snapshot.targetClass,snapshot.targetLevel,texts.defense,snapshot.defenseValue,
                          snapshot.targetTroops,snapshot.targetMaxTroops,snapshot.targetMorale,terrain)
        var left = friendly ? attacker : target,right = friendly ? target : attacker
        if friendly {left.extraLabel = texts.exp;left.extraText = String(snapshot.experience)} else {right.extraLabel = "";right.extraText = ""}
        let frame = player.frame
        // The cards show the numbers the result window is on: the snapshot holds the figures from before the exchange.
        if let page = frame?.page {
            func apply(_ target:inout IPadCombatSide,_ attacker:inout IPadCombatSide) {
                if page.experience {
                    target.troops = max(0,snapshot.targetTroops-snapshot.damage);target.morale = max(0,snapshot.targetMorale-snapshot.moraleLoss)
                    if friendly,let value = page.gauges.first?.value {attacker.extraText = String(value)}
                } else if let value = page.gauges.first?.value {
                    target.troops = value
                    if page.gauges.count > 1 {target.morale = page.gauges[1].value}
                }
            }
            if friendly {apply(&right,&left)} else {apply(&left,&right)}
        }
        return IPadCombatState(image:combatImage?.image,left:left,right:right,lines:frame?.page?.lines.map(\.text) ?? [],
                               gauges:frame?.page?.gauges.map {($0.value,$0.maximum)} ?? [],notice:frame?.notice)
    }
    /// Auto and skip only decide when the tap that closes a line is sent.
    private func paceDialogue() -> Bool {
        guard let current = prompt else {lineSeen = nil;return false}
        guard current.style == .dialogue else {skipping = false;lineSeen = nil;return false}
        if skipping {
            skipPhase = (skipPhase+1)%3
            if skipPhase == 0 {current.actions.first?.perform()}
            return true
        }
        guard DialoguePace.shared.auto else {lineSeen = nil;return true}
        let now = ProcessInfo.processInfo.systemUptime,key = current.title+current.body
        if lineSeen?.text != key {lineSeen = (key,now);return true}
        if let seen = lineSeen,now-seen.since >= DialoguePace.readingSeconds(current.body,speed:DialoguePace.shared.speed) {
            lineSeen = nil;current.actions.first?.perform()
        }
        return true
    }
    #if os(Android)
    /// The Android host pulls mono samples on its own audio thread.
    func pullAudio(_ out:UnsafeMutablePointer<Float>,count:Int) {audio?.pull(out,count:count)}
    #endif
    func setActive(_ value:Bool) {active = value;audio?.setPaused(!value);revision += 1}
    /// Before a game has started the title buttons are the menu's floor, so a closed panel returns to them.
    func closeMenu() {menu = host?.hasStarted == false ? titlePanel() : nil;refresh()}
    private func action(_ id:String,_ title:String,_ subtitle:String = "",enabled:Bool = true,_ body:@escaping()->Void)->IPadAction {
        .init(id:id,title:title,subtitle:subtitle,enabled:enabled,perform:body)
    }
    private func run(_ body:() throws -> Void) {
        guard active else {return}
        do {try body();try synchronizeBattle();refresh()}
        catch {self.error = Self.message(error);refresh()}
    }
    private func install(_ next:OriginalCampaignHost) {
        host = next;next.announcesItems = true
        // Results and dialogue are retained. The first touch release uses map
        // presentation; it does not change the source animation option/RNG word.
        next.presentsDuels = false
        flow = nil;capturedBattle = nil;pendingBattleStart = nil;lastAutoKey = nil;saveNotice = nil
        selectedSlot = nil;targetMode = nil;highlighted = [];queuedNotice = nil
        archive = data.map {BattleArchiveCoordinator(data:$0,root:saveRoot.appendingPathComponent("battle-archives",isDirectory:true))}
        archiveRevision = 0;checkpointRevision = -1
    }
    private func prepareTitle() throws {
        guard let data else {throw EngineError.invalid("게임 자료를 열지 못했습니다.")}
        let next = try OriginalCampaignHost(data:data,rng:OriginalRNG(state:1))
        install(next);suspendedRequest = false;menu = titlePanel();refresh()
    }
    private func titlePanel()->IPadPanel {
        .init(title:"영걸전",body:"iPad 독립 실행 · 저장은 이 앱에 보관됩니다.",actions:[
            action("new","새 게임") {[weak self] in self?.newGame()},
            action("load","불러오기") {[weak self] in self?.showLoad()},
            action("resume","중단 이어하기","성공하면 중단 저장 1칸을 소모합니다.") {[weak self] in self?.askResume()}])
    }
    func newGame() {
        run {
            guard let data else {throw EngineError.invalid("게임 자료가 없습니다.")}
            let next = try OriginalCampaignHost(data:data,rng:OriginalRNG(state:1))
            try next.acknowledge();install(next);menu = nil;suspendedRequest = false
        }
    }
    /// One fixed simulation quantum per callback. Background time is never
    /// accumulated or caught up after scene activation.
    /// The original flips every waiting unit between two frames (research: battle idle phase).
    private(set) var idlePhase:UInt8 = 0
    private var idleClock = 0.0
    /// The enlarged combat scene plays on the source's 60 Hz tick, so a front end steps it twice as often as the rest.
    /// A unit walking across the map plays at that rate too, so a move reads as smooth as the screen allows.
    var combatLive:Bool {(combatPlayer != nil || !animator.isIdle) && menu == nil && prompt == nil && error == nil}
    func tickCombat() {
        guard active,combatLive else {return}
        if combatPlayer != nil {advanceCombat(Double(speedFactor)/60);return}
        for sound in animator.advance(Double(speedFactor)/60) {audio?.playEffect(sound)}
        if animator.isIdle,let done = afterCues {afterCues = nil;done()}
        revision += 1
    }
    private func advanceCombat(_ seconds:Double) {
        guard var player = combatPlayer else {return}
        for action in player.advance(seconds,soundBusy:false) {if case .sound(let id) = action {audio?.playEffect(id)}}
        if player.finished {
            combatPlayer = nil;combatImage = nil
            let rest = combatRest;combatRest = [];startCues(rest)
        } else {combatPlayer = player}
        revision += 1
    }
    func tick() {
        guard active,error == nil,let host else {return}
        if let until = transientNoticeUntil,ProcessInfo.processInfo.systemUptime >= until {transientNoticeUntil = nil;saveNotice = nil;refresh()}
        if isBattle {
            idleClock += 1.0/30
            if idleClock >= 24*OriginalBattleAnimator.tick {idleClock = 0;idlePhase ^= 1;revision += 1}
        }
        do {
            if try completeSuspendIfReady() {return}
            if menu == nil,paceDialogue() {return}
            guard menu == nil,prompt == nil else {return}
            if combatPlayer != nil {advanceCombat(Double(speedFactor)/30);return}
            if !animator.isIdle {
                for sound in animator.advance(Double(speedFactor)/30) {audio?.playEffect(sound)}
                if animator.isIdle,let done = afterCues {afterCues = nil;done()}
                revision += 1;return
            }
            watchEnemyTurn()
            if try autoEndTurnIfDone() {return}
            // The source marches an army across the world map at 0.3 s a cell, three
            // times slower than a town walk; on a touch screen that reads as sluggish,
            // so the march runs at the town pace. Battles and towns keep the source pace.
            let marching = host.vm.state.packedMap>>12 == 1 && host.stage.batch != nil && host.stage.dialogue == nil
            let steps = speedFactor*(marching ? 3 : 1)
            for step in 0..<steps {
                try host.advance(microseconds:33_333)
                try synchronizeBattle()
                if step+1 < steps,prompt != nil {break}
            }
            if pendingBattleStart != nil {saveBattleStart()}
            if let notice = host.takeClosingNotice() {
                queuedNotice = .init(title:"전투 결과",body:noticeText(notice),actions:[action("next","확인") {[weak self] in self?.queuedNotice = nil;self?.refresh()}])
            }
            if host.fieldMenuReady {tryAutomaticSave()}
            if host.frameworkReturn?.outcome == .restart {try prepareTitle()}
            audio?.select(host.vm.state.music)
            for sound in host.takeSounds() {audio?.playEffect(sound)}
            refresh()
        } catch {self.error = Self.message(error);refresh()}
    }
    private func synchronizeBattle() throws {
        guard let host,isBattle,let battle = host.battle else {flow = nil;selectedSlot = nil;highlighted = [];return}
        if flow?.session !== battle {
            let value = OriginalBattleFlow(session:battle)
            value.onHook = {[weak host] in try host?.beginTurnHook($0) ?? false}
            value.onRetirement = {[weak host] in try host?.beginRetirement($0) ?? false}
            value.onAcceptedInput = {[weak self] in self?.accepted($0)}
            // Holding source continuations does not require a desktop view.
            // The map refreshes after committed results; dialogue still blocks.
            value.presentsNativeActions = true;value.emitsCombatPresentationCues = true;flow = value
            selectedSlot = battle.pendingMovementSlots.first
        }
        guard let flow,host.battleInputReady else {return}
        if !animator.isIdle || afterCues != nil || combatPlayer != nil {return}
        if battle.turns.stage == .unstarted {
            if capturedBattle != ObjectIdentifier(battle),var snapshot = try host.battleStartSnapshot() {
                capturedBattle = ObjectIdentifier(battle)
                if host.extras.battleArchives.recordingEnabled {
                    do {try archive?.begin(start:snapshot,progress:&host.extras.battleArchives)}
                    catch {archive?.failed(error,progress:&host.extras.battleArchives)}
                }
                snapshot.extras = host.extras
                pendingBattleStart = (snapshot,battle.definition.name ?? "전투 시작")
                saveBattleStart()
            }
            try flow.start()
        } else if flow.suspended {
            if playHeldCues(flow) {return}
            try flow.resumeSourceFlow()
            _ = playHeldCues(flow)
        }
        if flow.canLeaveBattle {
            if host.extras.battleArchives.active != nil {
                do {try archive?.finish(host:host,progress:&host.extras.battleArchives)}
                catch {archive?.failed(error,progress:&host.extras.battleArchives)}
            }
            try host.finishBattleLoop();selectedSlot = nil;targetMode = nil;highlighted = []
        } else if flow.acceptsManualInput,archiveRevision != checkpointRevision {
            do {try archive?.checkpoint(host:host,progress:&host.extras.battleArchives);checkpointRevision = archiveRevision}
            catch {archive?.failed(error,progress:&host.extras.battleArchives);checkpointRevision = archiveRevision}
        }
    }
    private func accepted(_ input:OriginalPlayInput) {
        guard let host else {return};archiveRevision += 1
        do {try archive?.accepted(input:input,progress:&host.extras.battleArchives)}
        catch {archive?.failed(error,progress:&host.extras.battleArchives)}
    }
    private func refresh() {
        guard let host else {revision += 1;return}
        header = isBattle ? host.battle?.definition.name ?? "전투" : "영걸전"
        if suspendedRequest {status = suspendContinues ? "중단 저장 대기 중 · 현재 명령을 마치면 저장합니다." : "중단 저장 대기 중 · 현재 명령을 마치면 저장하고 타이틀로 이동합니다."}
        else if let battle = session {
            status = "\(battle.turns.roundIndex+1)턴 · "+(flow?.acceptsManualInput == true ? "부대를 선택하세요." : "부대의 행동을 진행하고 있습니다.")
            // Say why a selected friendly unit gives no commands, instead of showing dead buttons.
            if flow?.acceptsManualInput == true,let slot = selectedSlot,let unit = battle.units[slot],let why = OriginalBattleCommand.denial(unit) {
                let name = personName(unit.person)
                switch why {
                case "cannotControl":status = "\(name) · 자동으로 움직이는 부대라 직접 명령할 수 없습니다."
                case "confused":status = "\(name) · 혼란 상태라 명령할 수 없습니다."
                case "finished":status = "\(name) · 이미 행동을 마쳤습니다."
                default:break
                }
            }
        }
        else {status = host.playerStatus ?? host.notice ?? (host.explorationInputReady ? "목적지나 인물을 선택하세요." : "")}
        if let saveNotice {status += " · "+saveNotice}
        if !isBattle {
            do {
                let frame = try host.ending.map {try renderer?.renderEnding($0).image} ?? renderer?.render(host.stage,screen:host.fieldScreenState(),dialogue:false).image
                // The map window alone: touches map straight onto its pixels.
                if host.hasStarted,host.ending == nil,host.fieldScreenState() != nil,let frame {
                    let v = host.stage.viewport
                    fieldImage = frame.cropping(to:CGRect(x:v[0],y:v[1],width:v[2],height:v[3])) ?? frame
                    fieldIsMap = true
                } else {fieldImage = frame;fieldIsMap = false}
            }
            catch {self.error = Self.message(error)}
        }
        if let selectedSlot,session?.units[selectedSlot]?.status != 2 {self.selectedSlot = nil;targetMode = nil;highlighted = []}
        revision += 1
    }
    var prompt:IPadPanel? {
        guard let host else {return nil}
        if let queuedNotice {return queuedNotice}
        if let failure = host.failure {return .init(title:"현재 지원되지 않는 진행",body:failure.reason,actions:[action("load","불러오기") {[weak self] in self?.showLoad()}])}
        if let returned = host.frameworkReturn,returned.outcome == .pending,returned.asksRetry {
            return .init(title:"다시 시작",body:host.retryPromptText ?? "다시 시작하시겠습니까?",actions:[
                action("yes","예") {[weak self] in self?.run {try host.answerRetryPrompt(1)}},
                action("no","아니요") {[weak self] in self?.run {try host.answerRetryPrompt(0)}}])
        }
        if host.frameworkReturn?.outcome == .quit {return .init(title:"게임 종료",body:"타이틀로 돌아갑니다.",actions:[action("title","타이틀로") {[weak self] in self?.run {try self?.prepareTitle()}}])}
        if host.saveRequest != nil {
            return .init(title:"저장",body:"지금까지의 진행을 저장할까요?",actions:[
                action("save","저장") {[weak self] in self?.showSave()},
                action("skip","저장하지 않고 계속") {[weak self] in self?.run {try host.completeSaveRequest();self?.accepted(.init(kind:.saveSkip))}}])
        }
        if let choice = host.choice {
            let labels = choice.kind == "choice-skip" ? ["아니요","예"] : choice.options
            return .init(title:"선택",body:choice.prompt,actions:labels.enumerated().map {index,title in
                action("choice-\(index)",title) {[weak self] in self?.run {try host.choose(index);self?.accepted(.init(kind:.choice,index:index))}}
            })
        }
        if let party = host.partySelection {
            let chosen = Set(party.selectedSlots.prefix(party.capacity)),fixed = Set(party.selectedSlots.prefix(party.fixedCount))
            var rows = party.candidates.compactMap {id -> IPadAction? in
                guard let person = try? host.people.person(id) else {return nil}
                return action("party-\(id)",(chosen.contains(id) ? "✓ " : "")+person.name,"Lv.\(person.level)",enabled:!fixed.contains(id)) {[weak self] in self?.run {try host.toggleParty(person:id)}}
            }
            rows.append(action("deploy","출전","남은 선택 \(party.remaining)") {[weak self] in self?.run {try host.confirmParty()}})
            return .init(title:"출전 부대 선택",body:"최대 \(party.capacity)명 · 고정 장수는 바꿀 수 없습니다.",actions:rows)
        }
        if let shop = host.shopPrompt {
            let rows:[IPadAction]
            switch shop.kind {
            case .say:rows = [action("shop-next","확인") {[weak self] in self?.run {try host.answerShop(nil)}}]
            case .ask:rows = [action("yes","예") {[weak self] in self?.run {try host.answerShop(1)}},action("no","아니요") {[weak self] in self?.run {try host.answerShop(0)}}]
            case .top,.list:
                rows = shop.rows.enumerated().map {index,title in action("shop-\(index)",title) {[weak self] in self?.run {try host.answerShop(index)}}}
                    + [action("back","돌아가기") {[weak self] in self?.run {try host.answerShop(nil)}}]
            }
            return .init(title:"상점 · 소지금 \(host.money ?? 0)",body:shop.text,actions:rows)
        }
        if let entry = host.cityEntry {return .init(title:"도시 입장",body:entry.question,actions:[
            action("yes","예") {[weak self] in self?.run {try host.answerCityEntry(true)}},action("no","아니요") {[weak self] in self?.run {try host.answerCityEntry(false)}}])}
        if let text = host.retirementText {return .init(title:"전투",body:text,actions:[action("retirement","확인") {[weak self] in self?.run {try host.acknowledgeRetirement()}}])}
        if let offer = host.itemOffer {
            let items = (try? host.people.person(offer.person).itemIDs) ?? []
            var rows = items.enumerated().map {index,item in action("discard-\(index)",itemName(item)+" 대신 받기",enabled:!host.extras.protects(personID:offer.person,itemID:item,operation:.discard)) {[weak self] in self?.run {try host.answerItemOffer(slot:index);self?.accepted(.init(kind:.itemOffer,slot:index))}}}
            rows.append(action("decline","받지 않기") {[weak self] in self?.run {try host.answerItemOffer(slot:nil,declined:true);self?.accepted(.init(kind:.itemOffer))}})
            return .init(title:"소지품이 가득 찼습니다",body:itemName(offer.item)+"을 받으려면 버릴 물품을 선택하세요.",actions:rows)
        }
        if let message = host.itemMessage {
            let item:Int,pattern:String,texts = host.shopCatalog.texts
            switch message {case .gained(let id):item = id;pattern = texts.giftGained;case .declined(let id):item = id;pattern = texts.giftDeclined;case .gaveUp(let id):item = id;pattern = texts.giftGaveUp;case .discarded(let id):item = id;pattern = texts.giftDiscarded}
            return .init(title:"소지품",body:originalFormat(pattern,[itemName(item)]),actions:[action("item-next","확인") {[weak self] in self?.run {try host.acknowledgeItemMessage()}}])
        }
        if let dialogue = host.stage.dialogue {
            return .init(title:dialogue.speaker,body:dialogue.text,actions:[action("dialogue","다음") {[weak self] in self?.run {try host.acknowledge()}}],
                         style:.dialogue,portrait:portraitImage(person:dialogue.person,palette:host.stage.palette))
        }
        if let ending = host.ending,case .unsupported(let frontier) = ending.output {return .init(title:"엔딩 재생 경계",body:frontier.reason,actions:[action("title","타이틀로") {[weak self] in self?.run {try self?.prepareTitle()}}])}
        if host.interpreterReturn != nil {return .init(title:"캠페인 반환",body:host.status,actions:[action("menu","메뉴") {[weak self] in self?.showMenu()}])}
        return nil
    }
    var actions:[IPadAction] {
        guard let host else {return []}
        if !host.hasStarted {return [action("title","타이틀 메뉴") {[weak self] in self?.menu = self?.titlePanel()}]}
        // The header holds the menu; this row carries only what the scene can do now.
        var result:[IPadAction] = []
        if isBattle {
            if let slot = selectedSlot,let unit = session?.units[slot],!unit.enemy {
                // A unit the source plays itself (an ally AI unit, an acted unit) can only be looked at.
                let canAct = self.canAct && (try? session?.requireManualUnit(slot)) != nil
                result += [action("move","이동",enabled:canAct && unit.scriptFlags&0x40 == 0) {[weak self] in self?.beginMove(slot)},
                    action("attack","공격",enabled:canAct) {[weak self] in self?.beginAttack(slot)},
                    action("strategies","책략",enabled:canAct) {[weak self] in self?.showStrategies(slot)},
                    action("items","도구",enabled:canAct) {[weak self] in self?.showItems(slot)},
                    action("wait","대기",enabled:canAct) {[weak self] in self?.run {try self?.flow?.manualWait(slot);self?.clearSelection()}},
                    action("cancel","취소",enabled:canAct) {[weak self] in self?.cancelSelection()}]
            } else {
                result.append(action("next","다음 부대",enabled:canAct && !(session.map(actionableUnits)?.isEmpty ?? true)) {[weak self] in self?.nextUnit()})
                if let slot = selectedSlot,let unit = session?.units[slot],unit.enemy,unit.status == 2 {
                    result.append(action("coop","협공 계산",enabled:canAct) {[weak self] in self?.showCooperation(slot)})
                }
            }
            if annotationMarking {result.append(action("memo-cancel","메모 취소") {[weak self] in self?.cancelMarking()})}
            result.append(action("threat",threatOn ? "위험도 끄기" : "위험도") {[weak self] in self?.toggleThreat()})
            result.append(action("turn","턴 종료",enabled:canAct) {[weak self] in self?.confirmEndTurn()})
        } else if host.explorationInputReady {result.append(action("destinations","인물·목적지") {[weak self] in self?.showDestinations()})}
        return result
    }
    func portraitImage(person:Int?,palette:Int) -> CGImage? {
        guard let person,let data,let value = data.resources.portraits?[String(person)],let path = Renderer.portraitPath(value,palette:palette) else {return nil}
        if let cached = portraits[path] {return cached}
        #if !os(Android)
        guard let url = try? data.containedFile(path),let image = UIImage(contentsOfFile:url.path)?.cgImage else {return nil}
        #else
        guard let url = try? data.containedFile(path),let bytes = try? Data(contentsOf:url),let image = PNGReader.decode(bytes) else {return nil}
        #endif
        portraits[path] = image;return image
    }
    /// A touch on the town, palace or world map, as a point in the map window
    /// (0...1 in both axes). It does what a click does on the desktop: talk
    /// to a person, walk to a cell or door, or march to a city.
    func fieldTapped(_ unit:CGPoint) {
        guard let host,fieldIsMap,prompt == nil,menu == nil,host.explorationInputReady else {return}
        let v = host.stage.viewport,camera = host.stage.camera
        let screen = CGPoint(x:CGFloat(v[0])+unit.x*CGFloat(v[2]),y:CGFloat(v[1])+unit.y*CGFloat(v[3]))
        run {
            if host.vm.state.packedMap>>12 == 1 {
                let chapter = host.vm.state.chapter
                if let city = host.exploration.cities.first(where:{ city in
                    guard city.chapter == chapter,city.worldPositionKnown,let cx = city.worldX,let cy = city.worldY else {return false}
                    // A finger is wider than a 32-pixel icon: the touch target is 48 pixels.
                    return CGRect(x:CGFloat(v[0]+cx*32-camera[0])-8,y:CGFloat(v[1]+cy*32-camera[1])-8,width:48,height:48).contains(screen)
                }) {try host.travel(toCity:city.id)}
                return
            }
            let actor = host.stage.actors.values.sorted{$0.registration > $1.registration}.first {actor in
                actor.person != 0 && CGRect(x:CGFloat(v[0]+16*actor.position.x-camera[0])-6,y:CGFloat(v[1]+16*actor.position.y+8*(actor.position.x&1)-24-camera[1])-6,width:44,height:52).contains(screen)
            }
            if let actor {try host.talk(to:actor.person);return}
            guard let map = host.stage.currentMap,let width = map.walkWidth,let height = map.walkHeight,let walk = map.walkBytes else {return}
            let local = CGPoint(x:screen.x-CGFloat(v[0])+CGFloat(camera[0]),y:screen.y-CGFloat(v[1])+CGFloat(camera[1]))
            if let cell = OriginalTownPointer.target(at:local,walk:walk,width:width,height:height) {try host.walk(to:cell)}
        }
    }
    /// Dragging the world map moves its view a tile at a time (the desktop
    /// scroll steps), so a larger map can be explored by touch.
    func scrollField(tilesX:Int,tilesY:Int) {
        guard let host,fieldIsMap,prompt == nil,menu == nil,host.explorationInputReady,host.vm.state.packedMap>>12 == 1 else {return}
        if host.scrollWorld(dx:tilesX,dy:tilesY,step:1) {refresh()}
    }
    func cellTapped(_ point:GridPoint) {
        guard canAct,let battle = session else {return}
        if !previewCells.isEmpty {previewCells = []}
        if let mode = annotationMode {placeAnnotation(point,mode);return}
        run {
            let target = battle.units.values.first {$0.status == 2 && $0.position == point && (!$0.enemy || $0.scriptFlags&0x20 != 0)}
            if let slot = selectedSlot,let mode = targetMode {
                switch mode {
                case .move:
                    if highlighted.contains(point) {
                        let path = try battle.move(slot,to:point);accepted(.init(kind:.battleMove,slot:slot,x:point.x,y:point.y));targetMode = nil;highlighted = []
                        play([.walk(slot:slot,path:path,sound:try? battle.walkSound(slot))])
                        return
                    }
                    if target == nil,let reason = try? BattleAssistance.movement(in:battle,slot:slot,to:point).reason {
                        saveNotice = reason.text;transientNoticeUntil = ProcessInfo.processInfo.systemUptime+5;refresh()
                    }
                case .attack:if let target,attackTargets.contains(point) {confirmAttack(slot,target.slot);return}
                case .strategy(let ability):if let target,highlighted.contains(point) {confirmStrategy(slot,ability,target.slot);return}
                case .item(let item):if let target,highlighted.contains(point) {confirmItem(slot,item,target.slot);return}
                case .give(let item):if let target,!target.enemy,highlighted.contains(point) {confirmGive(slot,item,target.slot);return}
                }
                // Not a target of the current command: a touch on another unit picks that unit instead of being dropped.
                guard let target,target.slot != slot else {return}
                try selectUnit(target,battle)
                return
            }
            guard let target else {clearSelection();return}
            try selectUnit(target,battle)
        }
    }
    /// Picks a unit and, if it can still move, shows its reach. A unit that has already
    /// moved keeps the turn's command until it acts or cancels, so another touch returns to it.
    private func selectUnit(_ target:OriginalLiveUnit,_ battle:OriginalBattleSession) throws {
        if !target.enemy,let pending = battle.pendingMovementSlots.first(where:{$0 != target.slot}) {
            selectedSlot = pending;targetMode = nil;highlighted = []
            saveNotice = "이동한 부대의 명령을 먼저 마치거나 취소하세요";transientNoticeUntil = ProcessInfo.processInfo.systemUptime+4
            return
        }
        selectedSlot = target.slot;highlighted = [];targetMode = nil
        if target.enemy || OriginalBattleCommand.denial(target) != nil {return}
        if target.scriptFlags&0x40 != 0 {return}
        highlighted = Set(try battle.reachable(target.slot));targetMode = .move
    }
    private func clearSelection() {selectedSlot = nil;targetMode = nil;highlighted = [];previewCells = []}
    private func cancelSelection() {
        run {
            if let slot = selectedSlot,let battle = session,battle.pendingMovementSlots.contains(slot) {
                try battle.cancelMove(slot);accepted(.init(kind:.battleCancelMove,slot:slot))
            }
            clearSelection()
        }
    }
    private func nextUnit() {
        guard canAct,let battle = session else {return}
        if let pending = battle.pendingMovementSlots.first {
            selectedSlot = pending;targetMode = nil;highlighted = []
            saveNotice = "이동한 부대의 명령을 먼저 마치거나 취소하세요";transientNoticeUntil = ProcessInfo.processInfo.systemUptime+4
            refresh();return
        }
        let slots = battle.units.values.filter {$0.status == 2 && OriginalBattleCommand.denial($0) == nil}.map(\.slot).sorted()
        guard !slots.isEmpty else {return}
        let index = selectedSlot.flatMap {slots.firstIndex(of:$0)}.map {($0+1)%slots.count} ?? 0
        selectedSlot = slots[index];beginMove(slots[index])
    }
    private func beginMove(_ slot:Int) {run {guard let battle = session else {return};_ = try battle.requireManualUnit(slot);selectedSlot = slot;targetMode = .move;highlighted = Set(try battle.reachable(slot))}}
    private func beginAttack(_ slot:Int) {
        run {
            guard let battle = session else {return};_ = try battle.requireManualUnit(slot)
            let targets = battle.units.values.filter {$0.status == 2 && $0.enemy && $0.scriptFlags&0x20 != 0 && (try? OriginalAttackOperation.begin(in:battle,attackerSlot:slot,targetSlot:$0.slot)) != nil}
            // The whole striking range is shown, so the player sees where a target would have to stand; only enemies in it can be picked.
            let range = battle.units[slot].flatMap {try? BattleProjection(battle).preview(slot,at:$0.position).attackCells} ?? []
            attackTargets = Set(targets.map(\.position))
            targetMode = .attack;highlighted = range.union(attackTargets)
            // A plain hint, not an error window: nothing is wrong, there is just nobody to hit from here.
            if targets.isEmpty {
                saveNotice = "공격 사거리 안에 적이 없습니다. 먼저 이동하세요.";transientNoticeUntil = ProcessInfo.processInfo.systemUptime+4
            }
        }
    }
    /// The desktop's growth helper: what this command would earn, whether it would raise a level, and what comes next.
    private func growthLines(_ slot:Int,target:Int?,ability:Int?) -> [String] {
        guard let battle = session else {return []}
        let names = host?.story.screens?.battle.commands.strategyNames ?? []
        guard let forecast = try? BattleProjection(battle).growth(slot,target:target,ability:ability,names:names) else {return []}
        let current = (try? battle.people.person(battle.units[slot]?.person ?? 0).level) ?? 0
        var lines:[String] = []
        for branch in forecast.branches {
            let grew = branch.level > current ? " · 레벨 \(current) → \(branch.level) 상승" : ""
            lines.append("\(branch.condition): 경험치 +\(branch.total)"+grew)
            if let next = branch.nextStrategies.first {
                lines.append("다음 책략: "+branch.nextStrategies.map(\.name).joined(separator:"·")+" (Lv.\(next.requiredLevel))")
            }
        }
        return lines
    }
    private func confirmAttack(_ slot:Int,_ target:Int) {
        guard let battle = session else {return}
        let forecast = try? battle.attackForecast(slot,target:target)
        var lines = [personName(battle.units[target]?.person)+" 공격"+(forecast.map {" · 예상 피해 \($0.damage)"} ?? "")]
        // The factors behind the number, from the engine's own physical result: attack, the defense after class and terrain, what is left.
        if let result = try? BattleProjection(battle).physical(slot,target:target) {
            lines.append("공격력 \(result.attack) · 방어력 \(result.defense)"+(result.adjustedDefense != result.defense ? " → 지형·병과 보정 후 \(result.adjustedDefense)" : ""))
            lines.append("피해 \(result.damage) → 남은 병력 \(result.remainingTroops) · 사기 -\(result.moraleLoss)")
        }
        if let forecast {
            if forecast.defeats {lines.append("격파할 수 있습니다.")}
            else if forecast.counterPercent > 0 {lines.append("반격 가능성 \(forecast.counterPercent)%")}
        }
        lines += growthLines(slot,target:target,ability:nil)
        confirm("공격",lines.joined(separator:"\n")) {[weak self] in
            self?.run {
                guard let self,let flow = self.flow else {return}
                let cues = try flow.beginManualAttack(slot,target:target)
                self.clearSelection()
                self.play(cues) {[weak self] in self?.run {_ = try self?.flow?.finishManualOperation()}}
            }
        }
    }
    private func unitName(_ slot:Int) -> String {
        guard let battle = session,let unit = battle.units[slot] else {return "부대"}
        return personName(unit.person)
    }
    /// The desktop's cooperation calculator: which of our units can bring this enemy down, and in what order.
    func showCooperation(_ target:Int) {
        run {
            guard let battle = session else {return}
            let search = try BattleProjection(battle).cooperation(target:target)
            var rows:[IPadAction] = [],seen = Set<String>()
            for candidate in search.candidates {
                let names = candidate.steps.map {unitName($0.actor)+($0.action == .attack ? "" : "(책략)")}.joined(separator:" → ")
                // The same units in the same order only differ by where they stand; the first, best-ranked one is enough.
                guard seen.insert(names).inserted else {continue}
                if rows.count >= 6 {break}
                let label = candidate.guaranteed ? "확정 격파" : candidate.defeats ? "격파 가능" : "격파 불가"
                let left = candidate.remaining.lowerBound == candidate.remaining.upperBound ? "\(candidate.remaining.lowerBound)" : "\(candidate.remaining.lowerBound)~\(candidate.remaining.upperBound)"
                let counter = candidate.counterLoss.upperBound > 0 ? " · 반격 손실 \(candidate.counterLoss.lowerBound)~\(candidate.counterLoss.upperBound)" : ""
                let moves = candidate.steps.map {$0.movementCost > 0 ? "\(unitName($0.actor)) 이동 \($0.movementCost)칸" : nil}.compactMap {$0}.joined(separator:", ")
                rows.append(action("coop-\(rows.count)",names,"\(label) · 남은 병력 \(left)\(counter)"+(moves.isEmpty ? "" : " · "+moves)) {})
            }
            let body = search.candidates.isEmpty ? "지금 이 적에게 닿을 수 있는 아군이 없습니다." :
                "\(unitName(target))에게 이번 턴 닿는 아군의 공격·책략 조합입니다. 결과는 난수에 따른 범위이며, 실제 명령은 직접 내립니다."+(search.limited ? "\n후보가 많아 일부만 비교했습니다." : "")
            menu = .init(title:"협공 계산",body:body,actions:rows+[backAction()])
        }
    }
    private func showStrategies(_ slot:Int) {
        run {
            guard let battle = session,let unit = battle.units[slot],let levels = battle.movement.strategyLevelRequirements,let costs = battle.movement.strategyMPCosts else {throw EngineError.invalid("책략 자료가 없습니다.")}
            let person = try battle.people.person(unit.person)
            let rain = battle.combat.strategyEnvironmentLookup[Int(battle.turns.weatherIndex)] == 2
            let rows = OriginalBattleCommand.strategyRows(classID:person.classID,level:person.level,mp:unit.mp,rain:rain,levels:levels,costs:costs)
            menu = .init(title:person.name+" · 책략",body:rows.isEmpty ? "MP \(unit.mp) · 아직 쓸 수 있는 책략이 없습니다. 습득표에서 배우는 레벨을 확인하세요." : "MP \(unit.mp) · 책략을 선택한 뒤 지도에서 대상을 선택하세요.",actions:rows.map {row in
                let why = BattleAssistance.strategyReasons(ability:row.ability,cost:row.cost,mp:unit.mp,rain:rain).map(\.text).joined(separator:" · ")
                return action("strategy-\(row.ability)",strategyName(row.ability),"MP \(row.cost)"+(why.isEmpty ? "" : " · "+why),enabled:row.enabled) {[weak self] in self?.selectStrategy(slot,row.ability)}}+[action("learn","책략 습득표") {[weak self] in self?.showLearning(slot)},backAction()])
        }
    }
    /// An area strategy first shows where it would hit the most, as the desktop's placement advice does; the choice stays the player's.
    private func selectStrategy(_ slot:Int,_ ability:Int,advised:Bool = false) {
        if !advised,BattleProjection.isAreaStrategy(ability),let battle = session,
           let search = try? BattleProjection(battle).areaAdvice(slot,ability:ability),!search.candidates.isEmpty {
            showStrategyAdvice(slot,ability,search,battle);return
        }
        run {
            guard let battle = session else {return}
            let board = try battle.board()
            guard let actor = board.actors.first(where:{$0.runtimeSlot == slot}) else {return}
            let targets = try OriginalAI.strategyTargetSlots(profile:battle.movement,board:board,actor:actor,abilityID:ability)
            let legal = try targets.filter {try OriginalStrategyOperation.begin(in:battle,casterSlot:slot,abilityID:ability,target:ability < 30 ? $0 : nil).execution == nil}
            guard !legal.isEmpty else {throw BattleError.illegalAction("현재 책략을 사용할 수 있는 대상이 없습니다.")}
            menu = nil;targetMode = .strategy(ability);highlighted = Set(legal.compactMap {battle.units[$0]?.position})
            if ability >= 30 {confirmStrategy(slot,ability,nil)}
        }
    }
    private func showStrategyAdvice(_ slot:Int,_ ability:Int,_ search:BattleProjection.AreaSearch,_ battle:OriginalBattleSession) {
        let here = battle.units[slot]?.position
        var rows:[IPadAction] = []
        for candidate in search.candidates.prefix(5) {
            let place = candidate.origin == here ? "제자리" : "(\(candidate.origin.x),\(candidate.origin.y))로 이동 \(candidate.movementCost)칸"
            let around = candidate.center.map {unitName($0)+" 중심"} ?? "범위 내 전체"
            let range = candidate.troops.lowerBound == candidate.troops.upperBound ? "\(candidate.troops.lowerBound)" : "\(candidate.troops.lowerBound)~\(candidate.troops.upperBound)"
            let note = candidate.limitation == nil ? "" : " · 일부는 확정할 수 없음"
            rows.append(action("advice-\(rows.count)","\(place) · \(around)","효과 대상 \(candidate.usefulTargets)명 · 병력 변화 \(range)"+note) {[weak self] in
                guard let self else {return}
                var cells:Set<GridPoint> = [candidate.origin]
                for target in candidate.targets {if let at = battle.units[target]?.position {cells.insert(at)}}
                self.menu = nil;self.previewCells = cells
                self.saveNotice = candidate.origin == here ? "주황 칸이 이 위치의 효과 범위입니다. 중심 대상을 눌러 시전하세요." : "(\(candidate.origin.x),\(candidate.origin.y))로 이동한 뒤 시전하는 것을 추천합니다. 주황 칸이 효과 범위입니다."
                self.transientNoticeUntil = ProcessInfo.processInfo.systemUptime+10
                self.selectStrategy(slot,ability,advised:true)
            })
        }
        rows.append(action("advice-skip","추천 없이 직접 고르기") {[weak self] in self?.selectStrategy(slot,ability,advised:true)})
        menu = .init(title:strategyName(ability)+" · 추천 위치",body:"맞는 대상이 많은 순서입니다. 결과는 난수에 따른 범위이며 시전은 직접 확정합니다."+(search.limited ? "\n후보가 많아 일부만 비교했습니다." : ""),
                     actions:rows+[navAction {[weak self] in self?.showStrategies(slot)}])
    }
    private func confirmStrategy(_ slot:Int,_ ability:Int,_ target:Int?) {
        let details = session.flatMap {try? StrategyGuideDetails.describe(abilityID:ability,profile:$0.movement)}
        let recipient = target.map {" → "+personName(session?.units[$0]?.person)} ?? " · 범위 내 대상 전체"
        let description = details.map {"\n"+$0.effect+"\n사거리: "+$0.range+"\n적용 범위: "+$0.area} ?? ""
        let growth = growthLines(slot,target:target,ability:ability)
        let body = strategyName(ability)+recipient+description+(growth.isEmpty ? "" : "\n"+growth.joined(separator:"\n"))
        confirm("책략 사용",body) {[weak self] in self?.run {_ = try self?.flow?.manualStrategy(slot,abilityID:ability,target:target);self?.clearSelection()}}
    }
    private func showItems(_ slot:Int) {
        run {
            guard let battle = session,let unit = battle.units[slot] else {return}
            let items = try battle.people.person(unit.person).itemIDs.filter {$0 != 255}
            menu = .init(title:"소지품",body:items.isEmpty ? "가지고 있는 물품이 없습니다." : "사용할 물품을 선택하세요.",actions:items.enumerated().map {offset,item in
                action("item-\(offset)",itemName(item),host?.source.combat.items.first {$0.id == item}?.description ?? "") {[weak self] in self?.showItemActions(slot,item)}
            }+[backAction()])
        }
    }
    private func showItemActions(_ slot:Int,_ item:Int) {
        menu = .init(title:itemName(item),body:host?.source.combat.items.first {$0.id == item}?.description ?? "",actions:[
            action("use","사용") {[weak self] in self?.selectItem(slot,item)},
            action("give","전달") {[weak self] in self?.beginGive(slot,item)},backAction()])
    }
    private func giveTargets(_ slot:Int)throws->[OriginalLiveUnit] {
        guard let battle = session else {return []}
        let unit = try battle.requireManualUnit(slot)
        let cells = Set(try OriginalAI.rangeCells(profile:battle.movement,board:battle.board(),point:unit.position,raw:1))
        return try battle.units.values.filter {unit in
            guard unit.status == 2,!unit.enemy,unit.slot != slot,cells.contains(unit.position) else {return false}
            return try battle.people.person(unit.person).itemIDs.contains(255)
        }.sorted {$0.slot < $1.slot}
    }
    private func beginGive(_ slot:Int,_ item:Int) {
        run {
            let targets = try giveTargets(slot)
            guard !targets.isEmpty else {throw BattleError.illegalAction("전달 범위에 소지품 여유가 있는 아군이 없습니다.")}
            menu = nil;targetMode = .give(item);highlighted = Set(targets.map(\.position))
        }
    }
    private func selectItem(_ slot:Int,_ item:Int) {
        run {
            guard let battle = session,let unit = battle.units[slot],let host else {return}
            guard !host.extras.protects(personID:unit.person,itemID:item,operation:.use) else {throw BattleError.illegalAction("사용 보호된 물품입니다.")}
            let use = OriginalItemUse.of(item)
            if use.rangeCode == nil {
                if let rejection = try OriginalItemOperation.begin(in:battle,userSlot:slot,item:item).execution?.rejection {throw BattleError.illegalAction(rejection)}
                confirmItem(slot,item,nil);return
            }
            let targets = try OriginalItemOperation.targetSlots(in:battle,userSlot:slot,use:use).filter {try OriginalItemOperation.begin(in:battle,userSlot:slot,item:item,target:$0).execution == nil}
            guard !targets.isEmpty else {throw BattleError.illegalAction("현재 도구를 사용할 수 있는 대상이 없습니다.")}
            menu = nil;targetMode = .item(item);highlighted = Set(targets.compactMap {battle.units[$0]?.position})
        }
    }
    private func confirmItem(_ slot:Int,_ item:Int,_ target:Int?) {
        confirm("도구 사용",itemName(item)+(target.map {" → "+personName(session?.units[$0]?.person)} ?? "")+"\n사용이 완료되면 1개를 소모합니다.") {[weak self] in self?.run {
            if let value = try self?.flow?.manualItem(slot,item:item,target:target),!value.completed {throw BattleError.illegalAction(value.rejection ?? "도구를 사용할 수 없습니다.")}
            self?.clearSelection()
        }}
    }
    private func confirmGive(_ slot:Int,_ item:Int,_ target:Int) {
        confirm("물품 전달",itemName(item)+" → "+personName(session?.units[target]?.person)) {[weak self] in self?.run {
            guard try self?.giveTargets(slot).contains(where:{$0.slot == target}) == true else {throw BattleError.illegalAction("전달할 수 있는 아군이 아닙니다.")}
            guard try self?.flow?.manualGive(slot,to:target,item:item) == true else {throw BattleError.illegalAction("받는 장수의 소지품이 가득 찼습니다.")};self?.clearSelection()
        }}
    }
    /// Friendly units that can still be commanded this turn.
    private func actionableUnits(_ battle:OriginalBattleSession) -> [OriginalLiveUnit] {
        battle.units.values.filter {$0.status == 2 && OriginalBattleCommand.denial($0) == nil}
    }
    private var autoEndClock = 0.0
    /// Once the player has acted and no friendly unit can act any more, the turn ends by itself
    /// after a short beat (so the last result stays readable). Nothing happens if nobody has acted yet.
    private func autoEndTurnIfDone() throws -> Bool {
        guard isBattle,canAct,let battle = session,let flow else {autoEndClock = 0;return false}
        let mine = battle.units.values.filter {$0.status == 2 && !$0.enemy}
        guard mine.contains(where:{$0.scriptFlags&0x80 != 0}),actionableUnits(battle).isEmpty,battle.pendingMovementSlots.isEmpty else {
            autoEndClock = 0;return false
        }
        if autoEndClock == 0 {saveNotice = "모든 부대가 행동을 마쳤습니다. 턴을 종료합니다.";transientNoticeUntil = ProcessInfo.processInfo.systemUptime+4;refresh()}
        autoEndClock += 1.0/30
        guard autoEndClock >= 0.9 else {return false}
        autoEndClock = 0
        beginEnemyTurnWatch();try flow.finishManual();clearSelection();try synchronizeBattle();refresh()
        return true
    }
    // MARK: Enemy turn summary, battle history (the desktop's records, as menus)
    private var enemyTurnBefore:EnemyTurnSnapshot?
    private var enemyPhaseSeen = false
    private(set) var enemyTurnChanges:[EnemyTurnSnapshot.Change] = []
    private func beginEnemyTurnWatch() {
        guard let battle = session else {return}
        enemyTurnBefore = EnemyTurnSnapshot(battle);enemyPhaseSeen = false
    }
    /// Once the enemy phase has run and control is back, compare what was public before and after.
    private func watchEnemyTurn() {
        guard let before = enemyTurnBefore,let battle = session,let flow else {return}
        if !flow.acceptsManualInput {enemyPhaseSeen = true;return}
        guard enemyPhaseSeen,animator.isIdle,combatPlayer == nil else {return}
        let changes = before.changes(to:EnemyTurnSnapshot(battle))
        enemyTurnBefore = nil;enemyTurnChanges = changes
        if !changes.isEmpty {
            saveNotice = "적 턴에 \(changes.count)부대의 변화가 있었습니다. 메뉴 → 적 턴 요약에서 볼 수 있습니다."
            transientNoticeUntil = ProcessInfo.processInfo.systemUptime+6;refresh()
        }
    }
    private func showEnemyTurn() {
        let rows = enemyTurnChanges.map {change in action("change-\(change.person)",change.name,change.detail) {}}
        menu = .init(title:"적 턴 요약",body:rows.isEmpty ? "확인된 변화가 없습니다." : "적 턴 전후에 공개된 부대의 변화입니다. 중간 공격 순서는 전투 결과 기록에서 볼 수 있습니다.",
                     actions:rows+[navAction {[weak self] in self?.showMenu()}])
    }
    private func showHistory() {
        guard let host else {return}
        let summaries = Array(host.extras.journal.summaries.reversed())
        let rows = summaries.enumerated().map {index,summary in
            action("summary-\(index)",summary.name,"\(summary.label) · \(summary.turns)턴 · 아군 피해 \(summary.totals.damageByPlayer)") {[weak self] in self?.showSummary(summary)}
        }
        menu = .init(title:"누적 전적",body:summaries.isEmpty ? "기록된 전투가 없습니다." : "저장한 진행에 속한 확정 결과입니다. 최근 \(summaries.count)전투.",
                     actions:rows+[navAction {[weak self] in self?.showMenu()}])
    }
    private func showSummary(_ summary:BattleSummary) {
        let totals = summary.totals
        var lines = [summary.label+(summary.endingReason.map {" · "+$0} ?? ""),"소요 턴 \(summary.turns)",
                     "아군 피해 \(totals.damageByPlayer) · 적군 피해 \(totals.damageByEnemy) · 아군 회복 \(totals.recoveredByPlayer)",
                     "경험치 행동 \(totals.actionExperience.values.reduce(0,+)) · 승리 \(totals.victoryExperience.values.reduce(0,+))"]
        if !totals.retiredPeople.isEmpty {
            lines.append("퇴각: "+totals.retiredPeople.map {(try? host?.people.person($0).name) ?? "인물 \($0)"}.joined(separator:", "))
        }
        let money = (totals.sourceRewards?.moneyChange ?? 0)+(totals.afterBattleRewards?.moneyChange ?? 0)
        if money != 0 {lines.append("금 \(money > 0 ? "+" : "")\(money)")}
        if !totals.complete {lines.append("이전 저장의 기록이 없어 일부 행동은 집계되지 않았습니다.")}
        menu = .init(title:summary.name,body:lines.joined(separator:"\n"),actions:[navAction {[weak self] in self?.showHistory()}])
    }
    // MARK: Battle map notes (the desktop's pins, lines, arrows and short notes)
    enum AnnotationMode {case pin,line,arrow,note(String)}
    private var annotationMode:AnnotationMode?
    private var annotationStart:GridPoint?
    @Published private(set) var annotationsVisible = true
    var annotationMarking:Bool {annotationMode != nil}
    /// What the map draws: only this attempt's notes, and only while they are shown.
    var annotationEntries:[BattleAnnotations.Entry] {
        guard annotationsVisible,let battle = session,let notes = host?.extras.annotations,notes.matches(battle) else {return []}
        return notes.entries
    }
    private func editAnnotations(_ body:(inout BattleAnnotations) throws -> Void) throws {
        guard let host,let battle = session else {return}
        var notes = host.extras.annotations
        if notes == nil || notes?.matches(battle) != true {
            notes = BattleAnnotations(battleID:battle.definition.id,attemptID:battle.resultLog.attemptID,width:battle.width,height:battle.height)
        }
        try body(&notes!)
        host.extras.annotations = notes;revision += 1
    }
    private func beginMarking(_ mode:AnnotationMode,_ hint:String) {
        annotationMode = mode;annotationStart = nil;menu = nil
        saveNotice = hint;transientNoticeUntil = ProcessInfo.processInfo.systemUptime+8;revision += 1;refresh()
    }
    func cancelMarking() {annotationMode = nil;annotationStart = nil;saveNotice = nil;revision += 1;refresh()}
    private func placeAnnotation(_ point:GridPoint,_ mode:AnnotationMode) {
        run {
            func entry(_ kind:BattleAnnotations.Kind,end:GridPoint? = nil,text:String = "",style:BattleAnnotations.Style = .gold) -> BattleAnnotations.Entry {
                .init(id:UUID(),kind:kind,start:point,end:end,text:text,style:style)
            }
            switch mode {
            case .pin:
                try editAnnotations {try $0.upsert(entry(.pin))};annotationMode = nil
            case .note(let text):
                try editAnnotations {try $0.upsert(entry(.note,text:text,style:.blue))};annotationMode = nil
            case .line,.arrow:
                guard let start = annotationStart else {
                    annotationStart = point;saveNotice = "끝 칸을 누르세요.";transientNoticeUntil = ProcessInfo.processInfo.systemUptime+8;refresh();return
                }
                let isArrow:Bool = {if case .arrow = mode {return true};return false}()
                try editAnnotations {try $0.upsert(.init(id:UUID(),kind:isArrow ? .arrow : .line,start:start,end:point,text:"",style:isArrow ? .pink : .gold))}
                annotationMode = nil;annotationStart = nil
            }
            saveNotice = "표시를 남겼습니다.";transientNoticeUntil = ProcessInfo.processInfo.systemUptime+3;refresh()
        }
    }
    func showAnnotations() {
        let count = annotationEntries.count
        menu = .init(title:"작전 메모",body:"지도에 핀·방어선·화살표·짧은 메모를 남깁니다. 게임 진행에는 영향이 없고 저장에 함께 보관됩니다.",actions:[
            action("pin","핀 놓기","칸 하나를 눌러 표시") {[weak self] in self?.beginMarking(.pin,"핀을 놓을 칸을 누르세요.")},
            action("line","방어선 긋기","시작 칸과 끝 칸을 차례로") {[weak self] in self?.beginMarking(.line,"방어선의 시작 칸을 누르세요.")},
            action("arrow","화살표 긋기","시작 칸에서 끝 칸으로") {[weak self] in self?.beginMarking(.arrow,"화살표의 시작 칸을 누르세요.")},
            action("note","짧은 메모","문구를 고른 뒤 칸을 눌러 붙임") {[weak self] in self?.showNotePhrases()},
            action("list","메모 목록","\(count)개 · 눌러서 지우기") {[weak self] in self?.showAnnotationList()},
            action("visible",annotationsVisible ? "메모 숨기기" : "메모 보이기") {[weak self] in self?.annotationsVisible.toggle();self?.revision += 1;self?.showAnnotations()},
            action("clear-notes","이 전투의 메모 모두 지우기",enabled:count > 0) {[weak self] in
                self?.confirm("메모 지우기","이 전투에 남긴 메모를 모두 지웁니다.") {self?.run {try self?.editAnnotations {$0.clear()};self?.showAnnotations()}}
            },
            backAction()])
    }
    private func showNotePhrases() {
        let phrases = ["집결","주의","공격 예정","후퇴","회복 필요","보호","함정?","대기"]
        menu = .init(title:"짧은 메모",body:"붙일 문구를 고르세요.",actions:phrases.map {phrase in
            action("phrase-\(phrase)",phrase) {[weak self] in self?.beginMarking(.note(phrase),"'\(phrase)'을 붙일 칸을 누르세요.")}
        }+[navAction {[weak self] in self?.showAnnotations()}])
    }
    private func showAnnotationList() {
        let entries = annotationEntries
        let rows = entries.enumerated().map {index,entry -> IPadAction in
            let place = entry.end.map {"(\(entry.start.x),\(entry.start.y)) → (\($0.x),\($0.y))"} ?? "(\(entry.start.x),\(entry.start.y))"
            return action("note-\(index)",entry.kind.label+(entry.text.isEmpty ? "" : " · "+entry.text),place+" · 눌러서 지우기") {[weak self] in
                self?.run {try self?.editAnnotations {$0.remove(entry.id)};self?.showAnnotationList()}
            }
        }
        menu = .init(title:"메모 목록",body:entries.isEmpty ? "남긴 메모가 없습니다." : "눌러서 지웁니다.",actions:rows+[navAction {[weak self] in self?.showAnnotations()}])
    }
    // MARK: Victory conditions with progress
    private func objectiveSubtitle(_ battle:OriginalBattleSession) -> String {
        let limit = battle.header.turnLimit
        let turn = battle.turns.roundIndex+1
        return limit > 0 ? "\(turn)/\(limit)턴" : "\(turn)턴"
    }
    /// The public objective, the turn limit and, where reviewed source data links it, whether its completion event has happened.
    func showObjective() {
        guard let host,let battle = session else {return}
        let text = host.vm.state.objectiveText ?? ""
        let limit = battle.header.turnLimit,turn = battle.turns.roundIndex+1
        var lines = [text.isEmpty ? "현재 목표 정보가 없습니다." : text]
        if limit > 0 {lines.append("제한 턴 \(limit) · 지금 \(turn)턴 · 남은 턴 \(max(0,limit-turn))")}
        let foes = battle.units.values.filter {$0.enemy && $0.status == 2 && $0.scriptFlags&0x20 != 0}.count
        lines.append("보이는 적 부대 \(foes)")
        let conditions = host.reviewedObjectiveProgress(publicText:text)
        let entries = BattleObjectiveTracker.entries(session:battle,publicText:text,conditions:conditions)
        var rows:[IPadAction] = []
        for entry in entries {
            let state = entry.state.rawValue
            if let target = entry.target {
                rows.append(action("objective-target","목표 위치 표시",state+" · (\(target.x),\(target.y))") {[weak self] in
                    self?.menu = nil;self?.previewCells = [target]
                    self?.saveNotice = "주황 칸이 목표 대상의 위치입니다.";self?.transientNoticeUntil = ProcessInfo.processInfo.systemUptime+8
                    self?.revision += 1;self?.refresh()
                })
            }
            lines.append("진행: "+state+(entry.sourceReference.isEmpty || entry.state != .unavailable ? "" : "\n"+entry.sourceReference))
        }
        menu = .init(title:"승리조건",body:lines.joined(separator:"\n"),actions:rows+[backAction()])
    }
    // MARK: Dialogue record and unit list
    private var rosterOptions = BattleRosterOptions()
    private var bookmarksOnly = false
    /// Lines already shown, newest first; a long press on a row's detail can bookmark one.
    func showDialogueRecord() {
        guard let host else {return}
        let entries = Array(host.extras.dialogueHistory.search(bookmarksOnly:bookmarksOnly).suffix(40).reversed())
        var rows:[IPadAction] = [action("bookmark-filter",bookmarksOnly ? "북마크만 보는 중" : "전체 보는 중",bookmarksOnly ? "눌러서 전체 보기" : "눌러서 북마크만 보기") {[weak self] in self?.bookmarksOnly.toggle();self?.showDialogueRecord()}]
        rows += entries.enumerated().map {index,entry in
            action("line-\(index)",(entry.bookmarked ? "★ " : "")+entry.speaker,String(entry.text.replacingOccurrences(of:"\n",with:" ").prefix(60))) {[weak self] in self?.showDialogueLine(entry)}
        }
        menu = .init(title:"대사 기록",body:entries.isEmpty ? (bookmarksOnly ? "북마크한 대사가 없습니다." : "아직 본 대사가 없습니다.") : "이미 본 대사입니다. 최근 \(entries.count)건.",
                     actions:rows+[navAction {[weak self] in self?.showMenu()}])
    }
    private func showDialogueLine(_ entry:DialogueHistory.Entry) {
        guard let host else {return}
        let marked = host.extras.dialogueHistory.entries.first {$0.id == entry.id}?.bookmarked ?? entry.bookmarked
        menu = .init(title:entry.speaker,body:entry.text,actions:[
            action("bookmark",marked ? "북마크 해제" : "북마크") {[weak self] in
                self?.run {
                    guard let self,let host = self.host else {return}
                    try host.extras.dialogueHistory.setBookmark(entry.id,enabled:!marked)
                    if let updated = host.extras.dialogueHistory.entries.first(where:{$0.id == entry.id}) {self.showDialogueLine(updated)}
                }
            },
            navAction {[weak self] in self?.showDialogueRecord()}])
    }
    /// Our units at a glance, with the desktop's filters; a tap selects the unit on the map.
    func showRoster() {
        guard let battle = session else {return}
        run {
            let slots = battle.units.values.filter {!$0.enemy && $0.status == 2}.map(\.slot).sorted()
            let ordered = try BattleAssistance.rosterRows(in:battle,slots:slots,options:rosterOptions)
            let filters = BattleRosterOptions.Filter.allCases
            var rows:[IPadAction] = [action("roster-filter","보기: "+rosterOptions.summary,"눌러서 다음 조건으로") {[weak self] in
                guard let self else {return}
                let current = filters.first {self.rosterOptions.filters.contains($0)}
                let next = current.flatMap {filters.firstIndex(of:$0)}.map {$0+1} ?? 0
                self.rosterOptions.filters = next < filters.count ? [filters[next]] : []
                self.showRoster()
            }]
            for slot in ordered {
                guard let unit = battle.units[slot],let person = try? battle.people.person(unit.person) else {continue}
                let maximum = (try? OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:battle.combat)) ?? person.rawTroops
                let state = unit.scriptFlags&0x80 != 0 ? " · 행동 완료" : unit.scriptFlags&2 != 0 ? " · 혼란" : ""
                rows.append(action("roster-\(slot)",person.name,"Lv.\(person.level) · 병력 \(person.rawTroops)/\(maximum) · 사기 \(unit.morale)"+state) {[weak self] in
                    self?.menu = nil;self?.run {try self?.selectUnit(unit,battle)}
                })
            }
            menu = .init(title:"부대 목록",body:ordered.isEmpty ? "조건에 맞는 부대가 없습니다." : "아군 \(ordered.count)부대. 누르면 그 부대를 선택합니다.",actions:rows+[navAction {[weak self] in self?.showMenu()}])
        }
    }
    private func showJourney() {
        guard let host else {return}
        let entries = Array(host.extras.journal.journey.suffix(40).reversed())
        let rows = entries.enumerated().map {index,entry in action("journey-\(index)",entry.kind,entry.text) {}}
        menu = .init(title:"여정",body:entries.isEmpty ? "이 저장 이전의 여정은 없습니다." : "실제 방문과 확정한 선택만 표시합니다. 최근 \(entries.count)건.",
                     actions:rows+[navAction {[weak self] in self?.showMenu()}])
    }
    private var threatCache:(key:[Int],counts:[GridPoint:Int])?
    /// Cells the visible enemy units can reach with a blow or a strategy, with how many of them can.
    var threatCounts:[GridPoint:Int] {
        guard threatOn,let battle = session else {return [:]}
        let key = battle.units.values.sorted {$0.slot < $1.slot}.flatMap {[$0.slot,$0.position.x,$0.position.y,$0.status,Int($0.scriptFlags)]}
        if let cached = threatCache,cached.key == key {return cached.counts}
        var counts:[GridPoint:Int] = [:]
        if let map = try? BattleProjection(battle).threats() {for point in map.cells {counts[point] = map.sources(point).count}}
        threatCache = (key,counts);return counts
    }
    func toggleThreat() {
        threatOn.toggle();revision += 1
        saveNotice = threatOn ? "빨간 칸은 적이 공격할 수 있는 곳입니다. 진할수록 많은 적이 닿습니다." : nil
        transientNoticeUntil = threatOn ? ProcessInfo.processInfo.systemUptime+5 : nil;refresh()
    }
    /// A long press on a reachable cell: what the unit would cost to move there and could strike from it. Nothing moves.
    func previewCell(_ point:GridPoint) {
        guard canAct,let battle = session,let slot = selectedSlot,case .move? = targetMode,highlighted.contains(point) else {return}
        run {
            let detail = try BattleAssistance.movement(in:battle,slot:slot,to:point)
            let view = try BattleProjection(battle).preview(slot,at:point)
            previewCells = view.attackCells
            let commands = host?.story.screens?.battle.commands
            let terrains = commands?.terrain.names ?? []
            var parts:[String] = []
            if let cost = detail.totalCost {parts.append("이동 \(cost)/\(detail.budget)")}
            if let id = detail.terrain,terrains.indices.contains(id) {parts.append(terrains[id])}
            let names = view.attackTargets.compactMap {battle.units[$0].flatMap {try? battle.people.person($0.person).name}}
            parts.append(names.isEmpty ? "여기서 칠 수 있는 적 없음" : "여기서 공격 가능: "+names.joined(separator:", "))
            let strategies = view.strategies.values.filter {!$0.isEmpty}.count
            if strategies > 0 {parts.append("책략 \(strategies)종 사용 가능")}
            saveNotice = parts.joined(separator:" · ");transientNoticeUntil = ProcessInfo.processInfo.systemUptime+8;revision += 1;refresh()
        }
    }
    private var footprintCache:(key:[Int],cells:Set<GridPoint>)?
    /// Cells a floating command strip should stay off: the highlighted ones while a move or target is being picked,
    /// otherwise (for example right after a move) where the selected unit could strike.
    var stripClearCells:Set<GridPoint> {
        guard let battle = session,let slot = selectedSlot,let at = battle.units[slot]?.position else {return highlighted}
        let key = [slot,at.x,at.y]+battle.units.values.sorted {$0.slot < $1.slot}.flatMap {[$0.slot,$0.position.x,$0.position.y,$0.status]}
        if let cached = footprintCache,cached.key == key {return cached.cells.union(highlighted)}
        let cells = (try? BattleProjection(battle).preview(slot,at:at).attackCells) ?? []
        footprintCache = (key,cells)
        // Both together, so the strip does not jump when a move turns into a target pick.
        return cells.union(highlighted)
    }
    private func confirmEndTurn() {
        guard canAct else {return}
        confirm("턴 종료","아직 행동하지 않은 부대가 있어도 적의 턴으로 넘어갑니다.") {[weak self] in self?.run {self?.beginEnemyTurnWatch();try self?.flow?.finishManual();self?.clearSelection()}}
    }
    private func confirm(_ title:String,_ body:String,_ accepted:@escaping()->Void) {
        menu = .init(title:title,body:body,actions:[action("confirm","확인") {[weak self] in self?.menu = nil;accepted()},backAction()])
    }
    private func backAction()->IPadAction {action("back","돌아가기") {[weak self] in self?.closeMenu()}}
    private func personName(_ id:Int?)->String {guard let id else {return ""};return (try? host?.people.person(id).name) ?? "인물 \(id)"}
    private func itemName(_ id:Int)->String {host?.source.combat.items.first {$0.id == id}?.name ?? "도구 \(id)"}
    private func strategyName(_ id:Int)->String {let names = host?.story.screens?.battle.commands.strategyNames ?? [];return names.indices.contains(id) ? names[id] : "책략 \(id)"}
    private func noticeText(_ value:OriginalBattleNotice)->String {combatCatalog?.text(value,person:{self.personName($0)},strategy:{self.strategyName($0)}) ?? "전투 보상과 성장 결과가 반영되었습니다."}
    /// The selected unit, or the enemy last tapped, as the info card reads it.
    var unitInfo:IPadUnitInfo? {
        guard let battle = session,let slot = selectedSlot,let unit = battle.units[slot],unit.status == 2,
              !unit.enemy || unit.scriptFlags&0x20 != 0,let person = try? battle.people.person(unit.person) else {return nil}
        let commands = host?.story.screens?.battle.commands
        let classes = commands?.classNames ?? [],terrains = commands?.terrain.names ?? []
        let maxTroops = (try? OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:battle.combat)) ?? person.rawTroops
        var maxMP = Int(unit.mp)
        if let stats = try? battle.people.stats(unit.person,morale:100),let value = try? OriginalCombat.maxMP(stats:stats) {maxMP = Int(value)}
        let terrainID = Int(battle.terrain[unit.position.y*battle.width+unit.position.x])
        let className = classes.indices.contains(person.classID) ? classes[person.classID] : "병과 \(person.classID)"
        let terrain = terrains.indices.contains(terrainID) ? terrains[terrainID] : "지형 \(terrainID)"
        return IPadUnitInfo(slot:slot,name:person.name,className:className,level:person.level,troops:person.rawTroops,maxTroops:max(1,maxTroops),
            morale:unit.morale,mp:Int(unit.mp),maxMP:max(1,maxMP),terrain:terrain,enemy:unit.enemy,confused:unit.scriptFlags&2 != 0,
            portrait:portraitImage(person:unit.person,palette:host?.stage.palette ?? 0))
    }
    func showSelectedUnit() {if let slot = selectedSlot {showUnit(slot)}}
    private func showUnit(_ slot:Int) {
        guard let battle = session,let unit = battle.units[slot],let person = try? battle.people.person(unit.person) else {return}
        let conditions = (try? BattleAssistance.conditions(in:battle,slot:slot)) ?? []
        menu = .init(title:person.name,body:"Lv.\(person.level) · 병력 \(person.rawTroops) · 사기 \(unit.morale) · MP \(unit.mp)",actions:[
            action("conditions","상태 설명",conditions.map(\.title).joined(separator:" · ")) {[weak self] in self?.showConditions(slot)},
            action("learning","책략 습득표") {[weak self] in self?.showLearning(slot)},backAction()])
    }
    private func showConditions(_ slot:Int) {
        guard let battle = session,let unit = battle.units[slot] else {return}
        let conditions = (try? BattleAssistance.conditions(in:battle,slot:slot)) ?? []
        let text = conditions.map {condition in
            ([condition.title,condition.body]+condition.facts.map {"· \($0.label): \($0.value)"}).joined(separator:"\n")
        }.joined(separator:"\n\n")
        menu = .init(title:personName(unit.person)+" · 상태",body:text.isEmpty ? "확인할 상태가 없습니다." : text,actions:[navAction {[weak self] in self?.showUnit(slot)}])
    }
    private func showLearning(_ slot:Int) {
        run {
            guard let battle = session,let unit = battle.units[slot],let levels = battle.movement.strategyLevelRequirements,let costs = battle.movement.strategyMPCosts else {return}
            let person = try battle.people.person(unit.person),names = host?.story.screens?.battle.commands.strategyNames ?? []
            let rows = try StrategyLearningGuide.entries(classID:person.classID,level:person.level,levels:levels,costs:costs,names:names)
            menu = .init(title:person.name+" · 책략 습득표",body:"현재 병과 기준 · Lv.\(person.level)",actions:rows.map {row in action("learn-\(row.abilityID)",row.name,"Lv.\(row.requiredLevel) · MP \(row.mpCost)"+(row.learned ? " · 습득" : " · 예정")) {[weak self] in self?.showStrategyDetail(row.abilityID)}}+[backAction()])
        }
    }
    private func showStrategyDetail(_ id:Int) {
        run {guard let battle = session else {return};let value = try StrategyGuideDetails.describe(abilityID:id,profile:battle.movement)
            menu = .init(title:strategyName(id),body:value.effect+"\n대상: "+value.target+"\n사거리: "+value.range+"\n적용 범위: "+value.area+"\n"+value.conditions.joined(separator:"\n"),actions:[backAction()])}
    }
    func showDestinations() {
        run {
            guard let host,host.explorationInputReady else {return}
            let actions:[IPadAction]
            if host.vm.state.packedMap>>12 == 1 {
                guard let flags = host.vm.state.cityFlags,host.vm.state.cityFlagsChapter == host.vm.state.chapter else {throw EngineError.invalid("현재 이동 가능한 도시 정보가 없습니다.")}
                actions = host.exploration.destinations(chapter:host.vm.state.chapter,flags:flags).map {city in
                    action("city-\(city.id)",city.name) {[weak self] in self?.run {try host.travel(toCity:city.id);self?.menu = nil}}
                }
            } else {
                guard let map = host.stage.currentMap else {throw EngineError.invalid("현재 지도 자료가 없습니다.")}
                let names = Dictionary(uniqueKeysWithValues:host.stage.actors.values.map {($0.person,personName($0.person))})
                let entries = try LocalDestinations.entries(packedMap:host.vm.state.packedMap,visible:host.stage.visible,map:map,actors:Array(host.stage.actors.values),names:names)
                actions = entries.enumerated().map {index,entry in action("destination-\(index)",entry.name,"(\(entry.point.x), \(entry.point.y))") {[weak self] in self?.run {
                    if let person = entry.person {try host.talk(to:person)} else {try host.walk(to:entry.point)}
                    self?.menu = nil
                }}}
            }
            menu = .init(title:"인물·목적지",body:"현재 지도에 공개된 목적지입니다. 이동은 원본 경로 규칙을 따릅니다.",actions:actions+[backAction()])
        }
    }
    func showMenu() {
        guard let host else {return}
        if !host.hasStarted {menu = titlePanel();return}
        let canSave = host.fieldMenuReady || host.saveRequest != nil
        var rows = [action("load","불러오기") {[weak self] in self?.showLoad()},
            action("save","일반 저장",canSave ? "슬롯 5칸 · 여러 번 불러올 수 있습니다" : session != nil ? "전투 중에는 아래 '중단 저장하고 계속'을 쓰세요" : "대사나 연출이 끝난 뒤 저장할 수 있습니다",enabled:canSave) {[weak self] in self?.showSave()},
            action("quick-suspend","중단 저장하고 계속","별도 1칸 · 전투 중에도 가능 · 이어하기 성공 시 소모") {[weak self] in self?.askSuspend(continues:true)},
            action("suspend","중단 저장 후 타이틀로","별도 1칸 · 이어하기 성공 시 소모") {[weak self] in self?.askSuspend()},
            action("resume","중단 이어하기") {[weak self] in self?.askResume()}]
        if suspendedRequest {rows.append(action("cancel-suspend","중단 저장 요청 취소") {[weak self] in self?.suspendedRequest = false;self?.suspendContinues = false;self?.closeMenu()})}
        if let battle = session {
            rows.append(action("objective","승리조건",objectiveSubtitle(battle)) {[weak self] in self?.showObjective()})
            rows.append(action("records","전투 결과 기록","현재 전투 \(battle.resultLog.entries.count)건") {[weak self] in self?.showResults()})
            rows.append(action("memo","작전 메모","핀 · 방어선 · 화살표 · 짧은 메모") {[weak self] in self?.showAnnotations()})
            rows.append(action("roster","부대 목록","병력·상태 한눈에 · 눌러서 선택") {[weak self] in self?.showRoster()})
            if !enemyTurnChanges.isEmpty {rows.append(action("enemy-turn","적 턴 요약","지난 적 턴의 변화 \(enemyTurnChanges.count)건") {[weak self] in self?.showEnemyTurn()})}
            if let slot = selectedSlot {rows.append(action("officer","선택 장수 정보") {[weak self] in self?.showUnit(slot)})}
        }
        rows.append(action("dialogue","대사 기록","이미 본 대사 · 북마크") {[weak self] in self?.showDialogueRecord()})
        rows.append(action("history","누적 전적","끝낸 전투의 결과·경험치·퇴각") {[weak self] in self?.showHistory()})
        rows.append(action("journey","여정","방문한 곳과 확정한 선택") {[weak self] in self?.showJourney()})
        rows.append(action("manage","장수·물품","장수 정보 · 소지품 · 전달 · 보호") {[weak self] in self?.showManagement()})
        rows.append(action("settings","설정","소리 · 대사 속도 · 진행 속도") {[weak self] in self?.showSettings()})
        if let battle = session,flow?.acceptsManualInput == true,flow?.retreatAllowed == true,let texts = host.framework?.battleMenu {
            _ = battle
            rows.append(action("retreat","총퇴각","전투 시작 시점으로 돌아갑니다") {[weak self] in
                self?.confirm("총퇴각",texts.retreat.confirm.text) {self?.run {try self?.flow?.requestRetreat();self?.clearSelection();self?.menu = nil}}
            })
        }
        rows.append(action("title","타이틀로") {[weak self] in self?.confirm("타이틀로","저장하지 않은 진행은 사라집니다.") {self?.run {try self?.prepareTitle()}}})
        rows.append(backAction());menu = .init(title:"게임 메뉴",body:"일반 저장 · 전투 시작 저장 · 중단 저장",actions:rows)
    }
    // MARK: Officers and belongings (the desktop's management screens, as menus)
    private func navAction(_ title:String = "돌아가기",_ to:@escaping()->Void) -> IPadAction {action("back",title) {to()}}
    func showManagement() {
        menu = .init(title:"장수·물품",body:"함께하는 장수의 능력과 소지품을 보고, 물품을 전달하거나 보호합니다.",actions:[
            action("officers","장수 정보","능력 · 소지품 · 책략") {[weak self] in self?.showOfficers()},
            action("inventory","소지품 모아 보기","장수별 물품 · 전달 · 보호") {[weak self] in self?.showInventory()},
            navAction {[weak self] in self?.showMenu()}])
    }
    private func showOfficers() {
        run {
            guard let host else {return}
            let rows = try host.people.companions().map {id -> IPadAction in
                let person = try host.people.person(id)
                return action("officer-\(id)",person.name,"Lv.\(person.level) · 병력 \(person.rawTroops) · 소지품 \(person.itemIDs.filter {$0 != 255}.count)/8") {[weak self] in self?.showOfficer(id)}
            }
            menu = .init(title:"장수 정보",body:"현재 함께하는 장수 \(rows.count)명",actions:rows+[navAction {[weak self] in self?.showManagement()}])
        }
    }
    private func showOfficer(_ id:Int) {
        run {
            guard let host else {return}
            let person = try host.people.person(id)
            let snapshot = try OfficerComparison.snapshot(person:person,combat:host.source.combat,movement:host.source.movement)
            let classes = host.story.screens?.battle.commands.classNames ?? []
            let className = classes.indices.contains(person.classID) ? classes[person.classID] : "병과 \(person.classID)"
            let body = "\(className) Lv.\(person.level) · 병력 \(person.rawTroops)/\(snapshot.maximumTroops)\n공격력 \(snapshot.attack) · 방어력 \(snapshot.defense) · 이동력 \(snapshot.movement) · 최대 책략치 \(snapshot.maximumMP)\n현재 장비와 사기 100 기준입니다."
            var rows:[IPadAction] = person.itemIDs.filter {$0 != 255}.map {item in
                action("item-\(id)-\(item)",itemName(item),"눌러서 전달·보호") {[weak self] in self?.showItemOptions(giver:id,item:item,back:{self?.showOfficer(id)})}
            }
            if let levels = host.source.movement.strategyLevelRequirements,let costs = host.source.movement.strategyMPCosts {
                let names = classes.isEmpty ? [] : (host.story.screens?.battle.commands.strategyNames ?? [])
                let guide = try StrategyLearningGuide.entries(classID:person.classID,level:person.level,levels:levels,costs:costs,names:names)
                if !guide.isEmpty {
                    rows.append(action("learning","책략 습득표","\(guide.filter(\.learned).count)/\(guide.count) 습득") {[weak self] in
                        guard let self else {return}
                        let learn:[IPadAction] = guide.map {row in
                            self.action("learn-\(row.abilityID)",row.name,"Lv.\(row.requiredLevel) · MP \(row.mpCost)"+(row.learned ? " · 습득" : " · 예정")) {[weak self] in self?.showStrategyDetail(row.abilityID)}
                        }
                        self.menu = .init(title:person.name+" · 책략 습득표",body:"현재 병과 기준 · Lv.\(person.level)",actions:learn+[self.navAction {[weak self] in self?.showOfficer(id)}])
                    })
                }
            }
            let plans = (try? PromotionPlanning.candidates(person:person)) ?? []
            if !plans.isEmpty {
                rows.append(action("promotion","전직 미리보기","\(plans.count)가지 · 도구가 없어도 볼 수 있습니다") {[weak self] in self?.showPromotionList(id)})
            }
            menu = .init(title:person.name,body:body,actions:rows+[navAction {[weak self] in self?.showOfficers()}])
        }
    }
    /// The desktop's promotion planner: what a class change or promotion would do, without using the tool or an action.
    private func showPromotionList(_ id:Int) {
        run {
            guard let host else {return}
            let person = try host.people.person(id)
            let classes = host.story.screens?.battle.commands.classNames ?? []
            let rows = try PromotionPlanning.candidates(person:person).map {candidate -> IPadAction in
                let target = classes.indices.contains(candidate.targetClass) ? classes[candidate.targetClass] : "병과 \(candidate.targetClass)"
                let have = person.itemIDs.contains(candidate.itemID) ? "소지" : "미소지"
                let need = candidate.requiredLevel.map {person.level >= $0 ? "Lv.\($0) 충족" : "Lv.\($0) 필요"} ?? "레벨 제한 없음"
                return action("promo-\(candidate.itemID)",itemName(candidate.itemID)+" → "+target,"\(have) · \(need)") {[weak self] in self?.showPromotion(id,candidate)}
            }
            menu = .init(title:person.name+" · 전직",body:"병과가 바뀌면 어떻게 달라지는지 미리 봅니다. 아무것도 소모하지 않습니다.",actions:rows+[navAction {[weak self] in self?.showOfficer(id)}])
        }
    }
    private func showPromotion(_ id:Int,_ candidate:PromotionPlanning.Candidate) {
        run {
            guard let host else {return}
            let person = try host.people.person(id)
            let battle = host.story.screens?.battle.commands
            let plan = try PromotionPlanning.build(person:person,item:candidate.itemID,combat:host.source.combat,movement:host.source.movement,
                classNames:battle?.classNames ?? [],strategyNames:battle?.strategyNames ?? [],terrainNames:battle?.terrain.names ?? [])
            let c = plan.comparison
            func delta(_ label:String,_ old:Int,_ new:Int) -> String {"\(label) \(old) → \(new)"+(new == old ? "" : new > old ? " (+\(new-old))" : " (\(new-old))")}
            var lines = ["\(c.beforeClass) → \(c.afterClass) · Lv.\(c.level)",
                delta("공격력",c.before.attack,c.after.attack),delta("방어력",c.before.defense,c.after.defense),
                delta("최대 병력",c.before.maximumTroops,c.after.maximumTroops),delta("최대 책략치",c.before.maximumMP,c.after.maximumMP),
                delta("이동력",c.before.movement,c.after.movement),
                "공격 범위 "+PromotionPreview.rangeText(c.before.attackOffsets).replacingOccurrences(of:"\n",with:" ")+" → "+PromotionPreview.rangeText(c.after.attackOffsets).replacingOccurrences(of:"\n",with:" ")]
            if !c.terrainChanges.isEmpty {
                lines.append("지형 이동 비용: "+c.terrainChanges.map {"\($0.name) \($0.before == 255 ? "불가" : "\($0.before)") → \($0.after == 255 ? "불가" : "\($0.after)")"}.joined(separator:" · "))
            }
            if !c.strategyChanges.isEmpty {
                // Gained, lost and shifted strategies on their own lines: one long paragraph is unreadable.
                func level(_ n:Int?)->String {n.map {"Lv.\($0)"} ?? "없음"}
                let gained = c.strategyChanges.filter {$0.beforeLevel == nil && $0.afterLevel != nil}
                let lost = c.strategyChanges.filter {$0.beforeLevel != nil && $0.afterLevel == nil}
                let moved = c.strategyChanges.filter {$0.beforeLevel != nil && $0.afterLevel != nil}
                if !gained.isEmpty {lines.append("새로 배우는 책략 \(gained.count)개: "+gained.prefix(8).map {"\($0.name)(\(level($0.afterLevel)))"}.joined(separator:" ")+(gained.count > 8 ? " 외 \(gained.count-8)개" : ""))}
                if !lost.isEmpty {lines.append("잃는 책략: "+lost.map {"\($0.name)(\(level($0.beforeLevel)))"}.joined(separator:" "))}
                if !moved.isEmpty {lines.append("배우는 레벨이 바뀌는 책략: "+moved.map {"\($0.name) \(level($0.beforeLevel)) → \(level($0.afterLevel))"}.joined(separator:" · "))}
            }
            lines += plan.candidate.conditions
            menu = .init(title:c.itemName+" 전직 미리보기",body:lines.joined(separator:"\n"),actions:[navAction {[weak self] in self?.showPromotionList(id)}])
        }
    }
    private func showInventory() {
        run {
            guard let host else {return}
            let people = try host.people.companions().map {try host.people.person($0)}
            let entries = try InventoryOverview.entries(people:people,combat:host.source.combat,extras:host.extras)
            let rows = entries.map {entry in
                action("stock-\(entry.personID)-\(entry.itemID)",entry.itemName,"\(entry.personName) · \(entry.count)개"+(entry.protected ? " · 보호" : "")) {[weak self] in
                    self?.showItemOptions(giver:entry.personID,item:entry.itemID,back:{self?.showInventory()})
                }
            }
            menu = .init(title:"소지품 모아 보기",body:entries.isEmpty ? "소지품이 없습니다." : "장수별 소지품입니다. 고르면 전달이나 보호를 정할 수 있습니다.",actions:rows+[navAction {[weak self] in self?.showManagement()}])
        }
    }
    private func showItemOptions(giver:Int,item:Int,back:@escaping()->Void) {
        guard let host else {return}
        let sellLocked = host.extras.protects(personID:giver,itemID:item,operation:.sell)
        let useLocked = host.extras.protects(personID:giver,itemID:item,operation:.use)
        let description = host.source.combat.items.first {$0.id == item}?.description ?? ""
        func toggle(sell:Bool) {
            run {
                try host.extras.setItemProtection(personID:giver,itemID:item,enabled:sell ? !sellLocked : true,protectUse:sell ? useLocked : !useLocked)
                showItemOptions(giver:giver,item:item,back:back)
            }
        }
        menu = .init(title:itemName(item),body:personName(giver)+"의 물품"+(description.isEmpty ? "" : "\n"+description),actions:[
            action("give","다른 장수에게 전달",host.fieldMenuReady ? "" : "필드에서만 전달할 수 있습니다",enabled:host.fieldMenuReady) {[weak self] in self?.showReceivers(giver:giver,item:item,back:back)},
            action("protect-sell",sellLocked ? "매각·버리기 보호 해제" : "매각·버리기 보호 설정",sellLocked ? "지금 보호 중" : "같은 물품 전체에 적용") {toggle(sell:true)},
            action("protect-use",useLocked ? "사용 보호 해제" : "사용도 보호",useLocked ? "지금 보호 중" : "보호를 켠 뒤에만 설정할 수 있습니다",enabled:sellLocked || useLocked) {toggle(sell:false)},
            navAction {back()}])
    }
    private func showReceivers(giver:Int,item:Int,back:@escaping()->Void) {
        run {
            guard let host else {return}
            let rows = try host.people.companions().filter {$0 != giver}.map {id -> IPadAction in
                let person = try host.people.person(id),held = person.itemIDs.filter {$0 != 255}.count
                return action("to-\(id)",person.name,"\(held)/8칸"+(held == 8 ? " · 가득 참" : ""),enabled:held < 8) {[weak self] in self?.showTransferPreview(giver:giver,receiver:id,item:item,back:back)}
            }
            menu = .init(title:"물품 받을 장수",body:personName(giver)+" → "+itemName(item),actions:rows+[navAction {[weak self] in self?.showItemOptions(giver:giver,item:item,back:back)}])
        }
    }
    private func showTransferPreview(giver:Int,receiver:Int,item:Int,back:@escaping()->Void) {
        run {
            guard let host else {return}
            let value = try EquipmentComparison.transfer(giver:host.people.person(giver),receiver:host.people.person(receiver),item:item,combat:host.source.combat,movement:host.source.movement)
            func line(_ role:String,_ change:EquipmentComparison.Change) -> String {
                let a = change.before,b = change.after
                return "\(role) \(a.name): 공격력 \(a.attack)→\(b.attack) · 방어력 \(a.defense)→\(b.defense) · 이동력 \(a.movement)→\(b.movement) · 소지품 \(a.itemIDs.filter {$0 != 255}.count)→\(b.itemIDs.filter {$0 != 255}.count)"
            }
            let body = [value.giver.map {line("주는 장수",$0)},line("받는 장수",value.receiver)].compactMap {$0}.joined(separator:"\n")
            menu = .init(title:itemName(item)+" 전달",body:body+"\n같은 종류의 장비 보너스는 최댓값만 적용됩니다.",actions:[
                action("confirm","전달") {[weak self] in
                    self?.run {
                        let fresh = try EquipmentComparison.transfer(giver:host.people.person(giver),receiver:host.people.person(receiver),item:item,combat:host.source.combat,movement:host.source.movement)
                        guard fresh == value else {self?.showTransferPreview(giver:giver,receiver:receiver,item:item,back:back);return}
                        guard try host.exchangeItem(from:giver,to:receiver,item:item) else {throw BattleError.illegalAction("받는 장수의 소지품이 가득 찼습니다.")}
                        back()
                    }
                },
                navAction("취소") {[weak self] in self?.showReceivers(giver:giver,item:item,back:back)}])
        }
    }
    /// Options that take effect at once and stay on this device.
    func showSettings() {
        let pace = DialoguePace.shared
        let volume = OriginalSettings.current.volume
        let volumeLabel = "\(Int((volume*100).rounded()))%"
        menu = .init(title:"설정",body:"고르면 바로 적용되고 이 기기에 저장됩니다. 확대 전투 연출은 전부·중요 교전·입장 후 첫 교전·생략 중에서 고릅니다.",actions:[
            action("setting-music","배경음악",OriginalAudio.musicEnabled ? "켬" : "끔") {[weak self] in
                OriginalAudio.musicEnabled.toggle();self?.audio?.select(self?.host?.vm.state.music);self?.showSettings()},
            action("setting-effects","효과음",OriginalAudio.effectsEnabled ? "켬" : "끔") {[weak self] in
                OriginalAudio.effectsEnabled.toggle();self?.showSettings()},
            action("setting-volume","소리 크기",volumeLabel) {[weak self] in
                let steps:[Float] = [0.25,0.5,0.75,1],next = steps.first {$0 > volume+0.01} ?? steps[0]
                var settings = OriginalSettings.current;settings.volume = next;OriginalSettings.current = settings
                self?.audio?.volume = next;self?.showSettings()},
            action("setting-auto","대사 자동 넘김 속도",DialoguePace.speedLabels[min(max(0,pace.speed),2)]) {[weak self] in
                pace.speed = (pace.speed+1)%3;self?.showSettings()},
            action("setting-combat","확대 전투 연출",OriginalSettings.current.combatPresentationMode.label) {[weak self] in
                let modes = CombatPresentationPolicy.Mode.allCases
                var settings = OriginalSettings.current
                let next = ((modes.firstIndex(of:settings.combatPresentationMode) ?? 0)+1)%modes.count
                settings.combatPresentationMode = modes[next];OriginalSettings.current = settings;self?.showSettings()},
            action("setting-speed","진행 속도","\(speedFactor)× · 위쪽 버튼으로도 바꿉니다") {[weak self] in
                self?.cycleSpeed();self?.showSettings()},
            backAction()])
    }
    private func showResults() {
        guard let battle = session else {return}
        let lines = battle.resultLog.entries.map {entry in
            let who = personName(entry.actorPerson),target = personName(entry.targetPerson),verb:String
            switch entry.action {case .attack(let counter):verb = counter ? "반격" : "공격";case .strategy(let id):verb = strategyName(id);case .item(let id):verb = itemName(id);case .retirement:verb = "퇴각"}
            return "\(entry.round+1)턴 · \(who) \(verb) \(target)"+(entry.result.damage.map {" · 피해 \($0)"} ?? "")+(entry.result.troopsRecovered.map {" · 회복 \($0)"} ?? "")
        }
        menu = .init(title:"전투 결과 기록",body:lines.isEmpty ? "기록된 행동이 없습니다." : lines.joined(separator:"\n"),actions:[backAction()])
    }
    private func slots()->OriginalSaveSlots {OriginalSaveSlots(directory:saveRoot)}
    private func showSave() {
        run {
            guard let host else {return}
            let snapshot = try host.resumeSnapshot()
            let inspections = try slots().inspections()
            menu = .init(title:"일반 저장",body:"슬롯을 선택하세요. 기존 저장은 마지막 정상 백업으로 보관됩니다.",actions:inspections.enumerated().map {index,entry in
                action("slot-\(index)","슬롯 \(index+1)",entry.entry?.title ?? "비어 있음") {[weak self] in
                    guard let self else {return}
                    let write:()->Void = { [weak self] in self?.run {
                        guard let self else {return};try self.slots().write(snapshot,title:self.header,slot:index)
                        if host.saveRequest != nil {try host.completeSaveRequest();self.accepted(.init(kind:.saveNative))}
                        self.menu = nil
                    }}
                    if entry.status != .empty {self.confirm("저장 덮어쓰기","슬롯 \(index+1)의 진행을 지금 상태로 바꿀까요?",write)} else {write()}
                }
            }+[backAction()])
        }
    }
    private func showLoad() {
        run {
            let store = slots();var rows:[IPadAction] = []
            for index in 0..<OriginalSaveSlots.count {
                let entry = try store.inspect(.numbered(index))
                rows.append(action("load-\(index)","슬롯 \(index+1)",entry.entry?.title ?? entry.message,enabled:entry.canLoad) {[weak self] in self?.askLoad {try store.read(slot:index)}})
                if entry.canRestoreBackup {rows.append(action("recover-\(index)","슬롯 \(index+1) 마지막 정상 백업 복구",entry.backupEntry?.title ?? "") {[weak self] in self?.confirm("백업 복구","현재 파일을 보존한 뒤 마지막 정상 저장으로 복구합니다.") {self?.run {_ = try store.restoreBackup(.numbered(index));self?.showLoad()}}})}
            }
            for name in [OriginalSaveSlots.Named.auto,.battleStart,.quick] {
                let entry = try store.inspect(.named(name)),label = name == .auto ? "자동 저장" : name == .battleStart ? "전투 시작" : "이전 빠른 저장"
                if entry.status != .empty {rows.append(action("named-\(name.rawValue)",label,entry.entry?.title ?? entry.message,enabled:entry.canLoad) {[weak self] in self?.askLoad {try store.read(name)}})}
            }
            rows.append(action("suspend-load","중단 이어하기") {[weak self] in self?.askResume()});rows.append(backAction())
            menu = .init(title:"불러오기",body:"일반 저장과 전투 시작 저장은 반복해서 불러올 수 있습니다. 중단 저장은 1회만 이어합니다.",actions:rows)
        }
    }
    private func askLoad(_ read:@escaping() throws -> OriginalCampaignResume) {
        let load:()->Void = {[weak self] in self?.run {guard let self,let data = self.data else {return};let next = try OriginalCampaignHost.resume(data:data,from:read());self.install(next);self.menu = nil;self.suspendedRequest = false}}
        if host?.hasStarted == true {confirm("불러오기","현재 저장하지 않은 진행을 대신합니다.",load)} else {load()}
    }
    func importSave(_ url:URL) {
        let accessed = url.startAccessingSecurityScopedResource();defer {if accessed {url.stopAccessingSecurityScopedResource()}}
        do {
            let snapshot = try OriginalSaveSlots.readFile(from:url)
            askLoad {snapshot}
        } catch {self.error = "일반 저장 파일을 불러오지 못했습니다. 현재 진행과 파일은 그대로입니다.\n\(error)"}
    }
    private func askSuspend(continues:Bool = false) {
        run {
            let entry = try SuspendSaveStore(directory:saveRoot).entry()
            let tail = continues ? "안전한 지점에서 현재 진행을 저장하고 계속 이어서 합니다. 이어하기 성공 시 소모됩니다." : "안전한 지점에서 현재 진행을 저장하고 타이틀로 이동합니다. 이어하기 성공 시 소모됩니다."
            confirm("중단 저장",(entry == nil ? "" : "기존 중단 저장 1칸을 덮어씁니다.\n")+tail) {[weak self] in
                self?.suspendedRequest = true;self?.suspendContinues = continues;self?.menu = nil;self?.run {_ = try self?.completeSuspendIfReady()}
            }
        }
    }
    @discardableResult private func completeSuspendIfReady() throws -> Bool {
        guard suspendedRequest,let host,let data,let snapshot = try host.suspendSnapshot(battleFlow:flow) else {return false}
        if suspendContinues {
            suspendedRequest = false;suspendContinues = false
            try SuspendSaveStore(directory:saveRoot).write(snapshot,title:header)
            saveNotice = "중단 저장 완료";transientNoticeUntil = ProcessInfo.processInfo.systemUptime+4;refresh();return false
        }
        do {
            let next = try OriginalCampaignHost(data:data,rng:OriginalRNG(state:1))
            try SuspendSaveStore(directory:saveRoot).write(snapshot,title:header)
            install(next);suspendedRequest = false;menu = titlePanel();refresh();return true
        } catch {suspendedRequest = false;suspendContinues = false;throw error}
    }
    private func askResume() {
        run {
            let store = SuspendSaveStore(directory:saveRoot)
            guard let entry = try store.entry() else {throw EngineError.invalid("이어할 중단 저장이 없습니다.")}
            confirm("중단 이어하기",entry.title+"\n이어하기에 성공하면 이 중단 저장은 소모됩니다. 현재 진행을 대신합니다.") {[weak self] in self?.run {
                guard let self,let data = self.data else {return}
                let next = try store.resume(as:OriginalCampaignResume.self,expectedID:entry.id) {snapshot in
                    guard snapshot.kind == "native-engine-resume",snapshot.suspension != nil else {throw EngineError.invalid("지원하지 않는 중단 저장입니다.")}
                    return try OriginalCampaignHost.resume(data:data,from:snapshot)
                }
                self.install(next);self.menu = nil;self.suspendedRequest = false
            }}
        }
    }
    private func tryAutomaticSave() {
        guard let host else {return}
        let key = "\(host.vm.state.chapter):\(host.vm.state.member):\(host.vm.state.block):\(host.vm.state.groupBase):\(host.vm.state.packedMap)"
        guard key != lastAutoKey,ProcessInfo.processInfo.systemUptime >= nextAutoAttempt else {return}
        do {try slots().write(host.resumeSnapshot(),title:header,named:.auto);lastAutoKey = key;saveNotice = nil}
        catch {nextAutoAttempt = ProcessInfo.processInfo.systemUptime+15;saveNotice = "자동 저장 실패: \(error.localizedDescription)"}
    }
    private func saveBattleStart() {
        guard let pending = pendingBattleStart,ProcessInfo.processInfo.systemUptime >= nextBattleSaveAttempt else {return}
        do {try slots().write(pending.snapshot,title:pending.title,named:.battleStart);pendingBattleStart = nil;saveNotice = nil}
        catch {nextBattleSaveAttempt = ProcessInfo.processInfo.systemUptime+15;saveNotice = "전투 시작 저장 실패: \(error.localizedDescription)"}
    }
}
