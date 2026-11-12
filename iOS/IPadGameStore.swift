// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import Foundation
import CoreGraphics

struct IPadAction:Identifiable {
    var id:String
    var title:String
    var subtitle:String = ""
    var enabled:Bool = true
    var perform:()->Void
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
        if text.contains("world city selection is unavailable") {return "지금은 그곳을 고를 수 없습니다. 인물·목적지 목록에서 고르세요."}
        return text
    }
    @Published var menu:IPadPanel?
    private var renderer:Renderer?
    private var audio:OriginalAudio?
    private var timer:Timer?
    private var active = true
    private var suspendedRequest = false
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
    var canAct:Bool {active && error == nil && menu == nil && prompt == nil && host?.battleInputReady == true && flow?.acceptsManualInput == true && !suspendedRequest}

    /// Explicit roots and disabled timers let local verification inspect the
    /// real controller without touching a device's or a Mac user's saves.
    init(dataRoot:URL? = nil,saveRoot:URL? = nil,startsTimer:Bool = true,enablesAudio:Bool = true) {
        self.saveRoot = saveRoot ?? FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("YeonggeoljeonSaves",isDirectory:true)
        do {
            guard let root = dataRoot ?? Bundle.main.url(forResource:"GameData",withExtension:nil) else {throw EngineError.invalid("앱에 게임 자료가 없습니다.")}
            let data = try DataSet(root:root)
            self.data = data;renderer = try Renderer(data)
            combatCatalog = try? OriginalCombatCatalog.load(from:root.appendingPathComponent("combat-view.json"))
            if enablesAudio,let music = try? OriginalMusicCatalog.load(from:root.appendingPathComponent("music.json")) {audio = OriginalAudio(catalog:music)}
            try prepareTitle()
        } catch {self.error = Self.message(error);status = "게임을 열지 못했습니다."}
        if startsTimer {
            timer = Timer.scheduledTimer(withTimeInterval:1.0/30,repeats:true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
        }
    }
    deinit {timer?.invalidate()}
    func setActive(_ value:Bool) {active = value;audio?.setPaused(!value);revision += 1}
    func closeMenu() {menu = nil;refresh()}
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
    func tick() {
        guard active,error == nil,let host else {return}
        do {
            if try completeSuspendIfReady() {return}
            guard menu == nil,prompt == nil else {return}
            try host.advance(microseconds:33_333)
            try synchronizeBattle()
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
            value.presentsNativeActions = false;flow = value
            selectedSlot = battle.pendingMovementSlots.first
        }
        guard let flow,host.battleInputReady else {return}
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
        } else if flow.suspended {try flow.resumeSourceFlow()}
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
        if suspendedRequest {status = "중단 저장 대기 중 · 현재 명령을 마치면 저장하고 타이틀로 이동합니다."}
        else if let battle = session {status = "\(battle.turns.roundIndex+1)턴 · "+(flow?.acceptsManualInput == true ? "부대를 선택하세요." : "부대의 행동을 진행하고 있습니다.")}
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
                result += [action("move","이동",enabled:canAct && unit.scriptFlags&0x40 == 0) {[weak self] in self?.beginMove(slot)},
                    action("attack","공격",enabled:canAct) {[weak self] in self?.beginAttack(slot)},
                    action("strategies","책략",enabled:canAct) {[weak self] in self?.showStrategies(slot)},
                    action("items","도구",enabled:canAct) {[weak self] in self?.showItems(slot)},
                    action("wait","대기",enabled:canAct) {[weak self] in self?.run {try self?.flow?.manualWait(slot);self?.clearSelection()}},
                    action("cancel","취소",enabled:canAct) {[weak self] in self?.cancelSelection()}]
            } else {
                result.append(action("next","다음 부대",enabled:canAct) {[weak self] in self?.nextUnit()})
            }
            result.append(action("turn","턴 종료",enabled:canAct) {[weak self] in self?.confirmEndTurn()})
        } else if host.explorationInputReady {result.append(action("destinations","인물·목적지") {[weak self] in self?.showDestinations()})}
        return result
    }
    func portraitImage(person:Int?,palette:Int) -> CGImage? {
        guard let person,let data,let value = data.resources.portraits?[String(person)],let path = Renderer.portraitPath(value,palette:palette) else {return nil}
        if let cached = portraits[path] {return cached}
        guard let url = try? data.containedFile(path),let image = UIImage(contentsOfFile:url.path)?.cgImage else {return nil}
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
        run {
            let target = battle.units.values.first {$0.status == 2 && $0.position == point && (!$0.enemy || $0.scriptFlags&0x20 != 0)}
            if let slot = selectedSlot,let mode = targetMode {
                switch mode {
                case .move:
                    guard highlighted.contains(point) else {return}
                    _ = try battle.move(slot,to:point);accepted(.init(kind:.battleMove,slot:slot,x:point.x,y:point.y));targetMode = nil;highlighted = []
                case .attack:if let target,highlighted.contains(point) {confirmAttack(slot,target.slot)}
                case .strategy(let ability):if let target,highlighted.contains(point) {confirmStrategy(slot,ability,target.slot)}
                case .item(let item):if let target,highlighted.contains(point) {confirmItem(slot,item,target.slot)}
                case .give(let item):if let target,!target.enemy,highlighted.contains(point) {confirmGive(slot,item,target.slot)}
                }
                return
            }
            guard let target else {clearSelection();return}
            selectedSlot = target.slot;highlighted = []
            if target.enemy || OriginalBattleCommand.denial(target) != nil {showUnit(target.slot);return}
            if target.scriptFlags&0x40 != 0 {targetMode = nil;return}
            highlighted = Set(try battle.reachable(target.slot));targetMode = .move
        }
    }
    private func clearSelection() {selectedSlot = nil;targetMode = nil;highlighted = []}
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
            guard !targets.isEmpty else {throw BattleError.illegalAction("공격 사거리 안에 적이 없습니다.")}
            targetMode = .attack;highlighted = Set(targets.map(\.position))
        }
    }
    private func confirmAttack(_ slot:Int,_ target:Int) {
        guard let battle = session else {return}
        let forecast = try? battle.attackForecast(slot,target:target)
        confirm("공격",personName(battle.units[target]?.person)+" 공격"+(forecast.map {" · 예상 피해 \($0.damage)"} ?? "")) {[weak self] in
            self?.run {_ = try self?.flow?.manualAttack(slot,target:target);self?.clearSelection()}
        }
    }
    private func showStrategies(_ slot:Int) {
        run {
            guard let battle = session,let unit = battle.units[slot],let levels = battle.movement.strategyLevelRequirements,let costs = battle.movement.strategyMPCosts else {throw EngineError.invalid("책략 자료가 없습니다.")}
            let person = try battle.people.person(unit.person)
            let rain = battle.combat.strategyEnvironmentLookup[Int(battle.turns.weatherIndex)] == 2
            let rows = OriginalBattleCommand.strategyRows(classID:person.classID,level:person.level,mp:unit.mp,rain:rain,levels:levels,costs:costs)
            menu = .init(title:person.name+" · 책략",body:"MP \(unit.mp) · 책략을 선택한 뒤 지도에서 대상을 선택하세요.",actions:rows.map {row in action("strategy-\(row.ability)",strategyName(row.ability),"MP \(row.cost)",enabled:row.enabled) {[weak self] in self?.selectStrategy(slot,row.ability)}}+[action("learn","책략 습득표") {[weak self] in self?.showLearning(slot)},backAction()])
        }
    }
    private func selectStrategy(_ slot:Int,_ ability:Int) {
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
    private func confirmStrategy(_ slot:Int,_ ability:Int,_ target:Int?) {
        let details = session.flatMap {try? StrategyGuideDetails.describe(abilityID:ability,profile:$0.movement)}
        let recipient = target.map {" → "+personName(session?.units[$0]?.person)} ?? " · 범위 내 대상 전체"
        let description = details.map {"\n"+$0.effect+"\n사거리: "+$0.range+"\n적용 범위: "+$0.area} ?? ""
        let body = strategyName(ability)+recipient+description
        confirm("책략 사용",body) {[weak self] in self?.run {_ = try self?.flow?.manualStrategy(slot,abilityID:ability,target:target);self?.clearSelection()}}
    }
    private func showItems(_ slot:Int) {
        run {
            guard let battle = session,let unit = battle.units[slot] else {return}
            let items = try battle.people.person(unit.person).itemIDs.filter {$0 != 255}
            menu = .init(title:"소지품",body:"사용할 물품을 선택하세요.",actions:items.enumerated().map {offset,item in
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
    private func confirmEndTurn() {
        guard canAct else {return}
        confirm("턴 종료","아직 행동하지 않은 부대가 있어도 적의 턴으로 넘어갑니다.") {[weak self] in self?.run {try self?.flow?.finishManual();self?.clearSelection()}}
    }
    private func confirm(_ title:String,_ body:String,_ accepted:@escaping()->Void) {
        menu = .init(title:title,body:body,actions:[action("confirm","확인") {[weak self] in self?.menu = nil;accepted()},backAction()])
    }
    private func backAction()->IPadAction {action("back","돌아가기") {[weak self] in self?.closeMenu()}}
    private func personName(_ id:Int?)->String {guard let id else {return ""};return (try? host?.people.person(id).name) ?? "인물 \(id)"}
    private func itemName(_ id:Int)->String {host?.source.combat.items.first {$0.id == id}?.name ?? "도구 \(id)"}
    private func strategyName(_ id:Int)->String {let names = host?.story.screens?.battle.commands.strategyNames ?? [];return names.indices.contains(id) ? names[id] : "책략 \(id)"}
    private func noticeText(_ value:OriginalBattleNotice)->String {combatCatalog?.text(value,person:{self.personName($0)},strategy:{self.strategyName($0)}) ?? "전투 보상과 성장 결과가 반영되었습니다."}
    private func showUnit(_ slot:Int) {
        guard let battle = session,let unit = battle.units[slot],let person = try? battle.people.person(unit.person) else {return}
        menu = .init(title:person.name,body:"Lv.\(person.level) · 병력 \(person.rawTroops) · 사기 \(unit.morale) · MP \(unit.mp)",actions:[action("learning","책략 습득표") {[weak self] in self?.showLearning(slot)},backAction()])
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
        var rows = [action("load","불러오기") {[weak self] in self?.showLoad()},action("save","일반 저장",enabled:host.fieldMenuReady || host.saveRequest != nil) {[weak self] in self?.showSave()},
            action("suspend","중단 저장 후 타이틀로","별도 1칸 · 이어하기 성공 시 소모") {[weak self] in self?.askSuspend()},
            action("resume","중단 이어하기") {[weak self] in self?.askResume()}]
        if suspendedRequest {rows.append(action("cancel-suspend","중단 저장 요청 취소") {[weak self] in self?.suspendedRequest = false;self?.closeMenu()})}
        if let battle = session {
            rows.append(action("objective","승리조건") {[weak self] in self?.menu = .init(title:"승리조건",body:host.vm.state.objectiveText ?? "현재 목표 정보가 없습니다.",actions:[self?.backAction()].compactMap {$0})})
            rows.append(action("records","전투 결과 기록","현재 전투 \(battle.resultLog.entries.count)건") {[weak self] in self?.showResults()})
            if let slot = selectedSlot {rows.append(action("officer","선택 장수 정보") {[weak self] in self?.showUnit(slot)})}
        }
        rows.append(action("title","타이틀로") {[weak self] in self?.confirm("타이틀로","저장하지 않은 진행은 사라집니다.") {self?.run {try self?.prepareTitle()}}})
        rows.append(backAction());menu = .init(title:"게임 메뉴",body:"일반 저장 · 전투 시작 저장 · 중단 저장",actions:rows)
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
    private func askSuspend() {
        run {
            let entry = try SuspendSaveStore(directory:saveRoot).entry()
            confirm("중단 저장",(entry == nil ? "" : "기존 중단 저장 1칸을 덮어씁니다.\n")+"안전한 지점에서 현재 진행을 저장하고 타이틀로 이동합니다. 이어하기 성공 시 소모됩니다.") {[weak self] in
                self?.suspendedRequest = true;self?.menu = nil;self?.run {_ = try self?.completeSuspendIfReady()}
            }
        }
    }
    @discardableResult private func completeSuspendIfReady() throws -> Bool {
        guard suspendedRequest,let host,let data,let snapshot = try host.suspendSnapshot(battleFlow:flow) else {return false}
        do {
            let next = try OriginalCampaignHost(data:data,rng:OriginalRNG(state:1))
            try SuspendSaveStore(directory:saveRoot).write(snapshot,title:header)
            install(next);suspendedRequest = false;menu = titlePanel();refresh();return true
        } catch {suspendedRequest = false;throw error}
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
