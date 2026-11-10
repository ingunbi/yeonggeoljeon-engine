// SPDX-License-Identifier: GPL-3.0-only
import AppKit

private enum BattleArchivePreparation {case replay(BattleReplayDriver),practice(PracticeHostContext)}
/// Accessed exclusively on the main queue. A cancelled or replaced request can
/// never install a late result into a different menu or a closed game window.
private enum PendingBattleArchiveChecks {static var jobs:[ObjectIdentifier:BattleArchiveCancellation] = [:]}
private final class BattleArchivePresentationTarget {
    weak var overlay:CanvasOverlayView?
    weak var window:NSWindow?
    init(overlay:CanvasOverlayView,window:NSWindow) {self.overlay = overlay;self.window = window}
}

extension CampaignManagementUI {
    func showBattleArchives(coordinator:BattleArchiveCoordinator,practice:Bool = false,
                           onPractice:@escaping(PracticeHostContext)->Void,onClose:@escaping()->Void) {
        let references = host.extras.battleArchives.completed.reversed().filter {!practice || $0.result == 2}
        let progress = host.extras.battleArchives
        let back = {self.showBattleArchives(coordinator:coordinator,practice:practice,onPractice:onPractice,onClose:onClose)}
        let entries:[CanvasSheet.Row] = references.map {value in
            .init(label:value.title,value:"\(value.turns)턴 · "+(value.result == 2 ? "승리" : "종료"),
                detail:.init(heading:value.title,body:practice ? "당시 시작 상태를 별도 호스트에 복원합니다. 본편 경험치·물품·금·저장에 반영되지 않습니다." : "실제 수락한 명령을 처음부터 별도 호스트에서 다시 실행합니다.",
                    facts:[("입력 수","\(value.inputCount)"),("검증",value.verified ? "게임 상태·난수 일치 확인" : "열기 전에 게임 상태·난수 검사"),("저장","본편과 별도 경로")]))
        }
        let empty = "처음부터 기록하고 끝낸 전투가 없습니다. 예전 전투는 시작 기록이 없으므로 임의로 복원하지 않습니다."
        var line = references.isEmpty ? empty : "호환 자료와 최종 상태가 일치해야 열립니다. 원작 실행 결과와의 일치 검증은 별도입니다."
        if let failure = progress.lastFailure {line += "\n최근 기록 중단: "+failure}
        let buttons = practice ? ["다시 보기 목록","닫기"] : [progress.recordingEnabled ? "기록 끄기" : "다음 전투부터 기록","연습 전투","기록 정리","닫기"]
        rows(title:practice ? "클리어 전투 연습" : "전투 다시 보기",line:line,values:entries,buttons:buttons,onButton:{index in
            if practice {
                if index == 0 {self.showBattleArchives(coordinator:coordinator,onPractice:onPractice,onClose:onClose)} else {onClose()}
            } else {
                switch index {
                case 0:
                    self.host.extras.battleArchives.recordingEnabled.toggle()
                    if !self.host.extras.battleArchives.recordingEnabled {self.host.extras.battleArchives.active = nil}
                    back()
                case 1:self.showBattleArchives(coordinator:coordinator,practice:true,onPractice:onPractice,onClose:onClose)
                case 2:self.showArchiveCleanup(coordinator:coordinator,onClose:back)
                default:onClose()
                }
            }
        }) {index in
            guard let index,references.indices.contains(index) else {onClose();return}
            let reference = references[index]
            self.prepareBattleArchive(reference,coordinator:coordinator,practice:practice,onCancel:back) {result in
                do {
                    switch result {
                    case .practice(let context):
                        self.markReplayVerified(reference.recordingID)
                        let fighters = (context.host.battle?.units.values.filter {!$0.enemy && $0.status == 2}.sorted {$0.slot < $1.slot}) ?? []
                        let values:[CanvasSheet.Row] = fighters.map {unit in
                            let person = try? context.host.people.person(unit.person)
                            return .init(label:person?.name ?? "장수",value:"Lv.\(person?.level ?? 0)",detail:.init(heading:person?.name ?? "장수",body:"당시 전투 시작 상태",list:(person?.itemIDs.filter {$0 != 255}.map(self.itemName)) ?? [],facts:[("병력","\(person?.rawTroops ?? 0)"),("MP","\(unit.mp)"),("물품 수","\(person?.itemIDs.filter {$0 != 255}.count ?? 0)")]))
                        }
                        self.rows(title:"연습 · "+reference.title,line:"본편에 반영되지 않음 · 연습 저장은 별도입니다.",values:values,buttons:["연습 시작","취소"],onButton:{button in
                            if button == 0 {onClose();onPractice(context)} else {back()}
                        }) {_ in back()}
                    case .replay(let driver):
                        self.markReplayVerified(reference.recordingID)
                        let player = try BattleReplayWindow(driver:driver)
                        player.open();back()
                    }
                } catch {self.failure(error,returning:back)}
            }
        }
    }
    /// The list never uses names from unreferenced files: an older campaign
    /// save may share the directory with a later campaign's recordings.
    private func showArchiveCleanup(coordinator:BattleArchiveCoordinator,onClose:@escaping()->Void) {
        let back = {self.showArchiveCleanup(coordinator:coordinator,onClose:onClose)}
        do {
            let progress = host.extras.battleArchives,files = try coordinator.store.inventory()
            let sizes = Dictionary(uniqueKeysWithValues:files.map {($0.recordingID,$0.byteCount)})
            let known = Set(progress.completed.map(\.recordingID))
            let ids = progress.completed.reversed().map(\.recordingID)+files.filter {!known.contains($0.recordingID)}.map(\.recordingID)
            let values:[CanvasSheet.Row] = ids.map {id in
                let reference = progress.completed.first {$0.recordingID == id},active = progress.active?.recordingID == id
                let state = active ? "기록 중 · 정리 불가" : sizes[id] == nil ? "파일 없음 · 참조만 보관" : reference == nil ? "현재 저장에 미등록" : "완료 기록"
                let label = reference?.title ?? ("미등록 기록 · "+String(id.uuidString.prefix(8)))
                let facts:[(String,String)] = [("기록 ID",String(id.uuidString.prefix(8))),("용량",Self.archiveSize(sizes[id] ?? 0)),("상태",state)]
                let detail = CanvasSheet.Detail(heading:reference?.title ?? "현재 저장에 등록되지 않은 기록",body:"정리하면 복구 보관함으로 옮깁니다. 본편 전적·진행·저장은 바뀌지 않습니다.",
                    list:["분기 기록은 공통 입력과 시작 상태를 독립 보관하므로 원본 분기를 옮겨도 다른 분기는 유지됩니다.","기록 파일이 없는 항목은 목록 참조만 보관합니다. 사라진 파일을 새로 만들지는 않습니다."],facts:facts)
                return CanvasSheet.Row(label:label,value:state,detail:detail,enabled:!active)
            }
            let used = files.reduce(0) {$0+$1.byteCount}
            rows(title:"전투 기록 정리",line:"사용 \(Self.archiveSize(used)) / 256 MB · 완료 \(progress.completed.count)/64개\n자동 삭제하지 않습니다. 정리는 아래 확인 버튼을 눌렀을 때만 실행합니다.",values:values,
                buttons:["남길 수 \(progress.retentionCount)개","정리 미리보기","복구 보관함","돌아가기"],onButton:{button in
                    switch button {
                    case 0:
                        let choices = [10,20,40,64],index = choices.firstIndex(of:self.host.extras.battleArchives.retentionCount) ?? 3
                        self.host.extras.battleArchives.retentionCount = choices[(index+1)%choices.count];back()
                    case 1:self.confirmArchiveCleanup(coordinator:coordinator,ids:coordinator.cleanupCandidates(self.host.extras.battleArchives),onClose:back)
                    case 2:self.showArchiveTrash(coordinator:coordinator,onClose:back)
                    default:onClose()
                    }
                }) {index in
                    guard let index,ids.indices.contains(index) else {onClose();return}
                    self.confirmArchiveCleanup(coordinator:coordinator,ids:[ids[index]],onClose:back)
                }
        } catch {failure(error,returning:onClose)}
    }
    private static func archiveSize(_ count:Int)->String {
        count >= 1024*1024 ? String(format:"%.1f MB",Double(count)/(1024*1024)) : "\((count+1023)/1024) KB"
    }
    private func confirmArchiveCleanup(coordinator:BattleArchiveCoordinator,ids:[UUID],onClose:@escaping()->Void) {
        let references = host.extras.battleArchives.completed
        let values:[CanvasSheet.Row] = ids.map {id in
            .init(label:references.first {$0.recordingID == id}?.title ?? "미등록 기록 · "+String(id.uuidString.prefix(8)))
        }
        rows(title:"복구 보관함으로 이동",line:ids.isEmpty ? "현재 설정에서 정리할 기록이 없습니다." : "선택한 \(ids.count)개를 목록에서 보관합니다. 복구할 수 있으며 디스크에서 영구 삭제하지 않습니다. 본편의 클리어 기록은 유지됩니다.",values:values,
            buttons:ids.isEmpty ? ["돌아가기"] : ["보관함으로 이동","취소"],onButton:{button in
                guard !ids.isEmpty,button == 0 else {onClose();return}
                do {
                    for id in ids {try coordinator.moveToTrash(id,progress:&self.host.extras.battleArchives)}
                    onClose()
                } catch {self.failure(error,returning:onClose)}
            }) {_ in onClose()}
    }
    private func showArchiveTrash(coordinator:BattleArchiveCoordinator,onClose:@escaping()->Void) {
        let back = {self.showArchiveTrash(coordinator:coordinator,onClose:onClose)}
        do {
            let entries = try coordinator.store.trashEntries(),progress = host.extras.battleArchives
            let known = progress.completed+progress.trashed
            var values:[CanvasSheet.Row] = entries.map {entry in
                let reference = known.first {$0.recordingID == entry.recordingID}
                return .init(label:reference?.title ?? "현재 저장에 미등록 · "+String(entry.recordingID.uuidString.prefix(8)),value:Self.archiveSize(entry.byteCount),
                    detail:.init(heading:reference?.title ?? "미등록 기록",body:reference == nil ? "파일만 원래 위치로 복구합니다. 현재 저장에서 경험하지 않은 전투의 다시 보기·연습을 해금하지 않습니다." : "파일 해시를 확인한 뒤 현재 저장의 다시 보기·연습 목록으로 복구합니다.",
                        facts:[("보관일",DateFormatter.localizedString(from:entry.movedAt,dateStyle:.short,timeStyle:.short)),("용량",Self.archiveSize(entry.byteCount))]))
            }
            let noPayload = progress.trashed.filter {reference in !entries.contains {$0.recordingID == reference.recordingID}}
            let restored = noPayload.filter {FileManager.default.fileExists(atPath:coordinator.store.url($0.recordingID).path)}
            values += restored.map {.init(label:$0.title,value:"파일 있음 · 목록 복원",detail:.init(heading:$0.title,body:"다른 저장에서 파일을 이미 복구했습니다. 이 저장이 보관한 전투 참조를 확인하고 목록만 복원합니다."))}
            let missing = noPayload.count-restored.count
            rows(title:"기록 복구 보관함",line:"보관 중 \(entries.count)개 · \(Self.archiveSize(entries.reduce(0) {$0+$1.byteCount})) · 영구 삭제 기능은 없습니다."+(missing > 0 ? "\n파일이 없는 보관 참조 \(missing)개는 복구할 수 없습니다." : ""),values:values,buttons:["돌아가기"],onButton:{_ in onClose()}) {index in
                guard let index,values.indices.contains(index) else {onClose();return}
                self.rows(title:"기록 복구",values:[values[index]],buttons:["복구","취소"],onButton:{button in
                    guard button == 0 else {back();return}
                    do {
                        if entries.indices.contains(index) {try coordinator.restore(entries[index],progress:&self.host.extras.battleArchives)}
                        else {try coordinator.restoreReference(restored[index-entries.count].recordingID,progress:&self.host.extras.battleArchives)}
                        back()
                    } catch {self.failure(error,returning:back)}
                }) {_ in back()}
            }
        } catch {failure(error,returning:onClose)}
    }
    /// Only immutable values leave the main queue. The worker owns its own
    /// coordinator/host; no live campaign or AppKit object is used by it.
    private func prepareBattleArchive(_ reference:BattleArchiveReference,coordinator:BattleArchiveCoordinator,practice:Bool,
                                      onCancel:@escaping()->Void,onReady:@escaping(BattleArchivePreparation)->Void) {
        let data = coordinator.data,root = coordinator.store.root
        prepareBattleWork(onCancel:onCancel,onReady:onReady) {token,report in
            let worker = BattleArchiveCoordinator(data:data,root:root)
            if practice {
                return .practice(try PracticeHostContext.open(reference,coordinator:worker,cancellation:token,progress:report))
            }
            let archive = try worker.verifiedArchive(reference,cancellation:token,progress:report)
            let driver = try BattleReplayDriver(data:data,archive:archive,expectedDataDigest:archive.dataDigest,cancellation:token)
            try token.check();driver.finishBackgroundPreparation();return .replay(driver)
        }
    }
    func preparePracticeRetry(_ context:PracticeHostContext,onCancel:@escaping()->Void,onReady:@escaping(PracticeHostContext)->Void) {
        // Copy immutable values on main; the current practice host is not
        // referenced or mutated by the worker.
        let data = context.host.data,archive = context.archive,root = context.saveRoot,scenario = context.scenario
        prepareBattleWork(onCancel:onCancel,onReady:{prepared in
            if case .practice(let value) = prepared {onReady(value)}
        }) {token,report in
            .practice(try PracticeHostContext.restarting(data:data,archive:archive,saveRoot:root,scenario:scenario,cancellation:token,progress:report))
        }
    }
    private func prepareBattleWork(onCancel:@escaping()->Void,onReady:@escaping(BattleArchivePreparation)->Void,
                                  operation:@escaping(BattleArchiveCancellation,@escaping(BattleArchiveVerificationProgress)->Void)throws->BattleArchivePreparation) {
        guard let window = overlay.window else {return}
        let target = BattleArchivePresentationTarget(overlay:overlay,window:window)
        let key = ObjectIdentifier(overlay),token = BattleArchiveCancellation()
        PendingBattleArchiveChecks.jobs[key]?.cancel();PendingBattleArchiveChecks.jobs[key] = token
        let title = "전투 기록 확인 중"
        func isCurrent() -> Bool {
            guard PendingBattleArchiveChecks.jobs[key] === token,!token.isCancelled else {return false}
            guard let surface = target.overlay,let window = target.window,surface.window === window,window.isVisible,!surface.isHidden else {
                PendingBattleArchiveChecks.jobs.removeValue(forKey:key);token.cancel();return false
            }
            return true
        }
        func showProgress(_ message:String) {
            guard isCurrent(),let surface = target.overlay else {return}
            surface.show(CanvasMenu(title:title,options:[.init(label:"취소")],cancellable:true,footer:message) {_ in
                guard PendingBattleArchiveChecks.jobs[key] === token else {return}
                PendingBattleArchiveChecks.jobs.removeValue(forKey:key);token.cancel();onCancel()
            })
        }
        showProgress("기록을 준비하고 있습니다. 확인하는 동안 취소할 수 있습니다.")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            var lastProgress = Date.distantPast
            let report:(BattleArchiveVerificationProgress)->Void = {value in
                let now = Date()
                guard value.completed == value.total || now.timeIntervalSince(lastProgress) >= 0.15 else {return}
                lastProgress = now
                let label = value.phase == .identity ? "게임 자료 확인" : "전투 기록 확인"
                let message = "\(label) · \(value.completed) / \(value.total)\n확인하는 동안 취소할 수 있습니다."
                DispatchQueue.main.async {if isCurrent(),target.overlay?.selector?.title == title {showProgress(message)}}
            }
            let result:Result<BattleArchivePreparation,Error>
            do {result = .success(try operation(token,report))}
            catch {result = .failure(error)}
            DispatchQueue.main.async { [weak self] in
                guard let self,isCurrent(),target.overlay?.selector?.title == title else {
                    if PendingBattleArchiveChecks.jobs[key] === token {PendingBattleArchiveChecks.jobs.removeValue(forKey:key)}
                    token.cancel();return
                }
                PendingBattleArchiveChecks.jobs.removeValue(forKey:key)
                switch result {
                case .success(let prepared):onReady(prepared)
                case .failure(let error):self.failure(error,returning:onCancel)
                }
            }
        }
    }
    private func markReplayVerified(_ id:UUID) {
        if let index = host.extras.battleArchives.completed.firstIndex(where:{$0.recordingID == id}) {
            host.extras.battleArchives.completed[index].verified = true
        }
    }
}

/// Owns itself while its separate read-only replay window is open. The board's
/// mouse/key events are intercepted; playback buttons are the sole input owner.
final class BattleReplayWindow:NSObject,NSWindowDelegate {
    private static var openPlayers:[UUID:BattleReplayWindow] = [:]
    private let identity = UUID()
    private var driver:BattleReplayDriver
    private var seekCancellation:BattleArchiveCancellation?
    private let window:NSWindow
    private let body = NSView()
    private let controls = NSView()
    private let status = NSTextField(labelWithString:"")
    private let play = NSButton(title:"재생",target:nil,action:nil)
    private let previous = NSButton(title:"이전 턴",target:nil,action:nil)
    private let next = NSButton(title:"다음 턴",target:nil,action:nil)
    private let speed = NSPopUpButton()
    private let details = NSButton(title:"부대·확정 기록",target:nil,action:nil)
    private let shield = ReplayInputShield()
    private var board:OriginalBattleView?
    private var timer:Timer?
    private var playing = false
    private var elapsed:TimeInterval = 0
    init(driver:BattleReplayDriver) throws {
        self.driver = driver
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:800),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init()
        window.title = "다시 보기 · "+driver.archive.title+" · 읽기 전용"
        window.isReleasedWhenClosed = false;window.delegate = self;window.contentMinSize = NSSize(width:640,height:480)
        window.contentView = body;body.wantsLayer = true;body.layer?.backgroundColor = NSColor.black.cgColor
        controls.wantsLayer = true;controls.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        body.addSubview(controls)
        for item in [play,previous,next,details] {item.target = self;controls.addSubview(item)}
        play.action = #selector(togglePlay);previous.action = #selector(previousTurn);next.action = #selector(nextTurn);details.action = #selector(showDetails)
        speed.addItems(withTitles:["1배","2배","4배"]);controls.addSubview(speed);controls.addSubview(status)
        status.lineBreakMode = .byTruncatingTail;status.font = .systemFont(ofSize:13)
        try refreshBoard();layout()
        timer = Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) {[weak self] _ in self?.tick()}
    }
    func open() {Self.openPlayers[identity] = self;window.center();window.makeKeyAndOrderFront(nil)}
    func windowWillClose(_ notification:Notification) {seekCancellation?.cancel();seekCancellation = nil;timer?.invalidate();timer = nil;Self.openPlayers.removeValue(forKey:identity)}
    func windowDidResize(_ notification:Notification) {layout()}
    private func layout() {
        let bounds = body.bounds;controls.frame = NSRect(x:0,y:0,width:bounds.width,height:80)
        board?.frame = NSRect(x:0,y:80,width:bounds.width,height:max(1,bounds.height-80));shield.frame = board?.frame ?? .zero
        play.frame = NSRect(x:12,y:40,width:70,height:28);previous.frame = NSRect(x:90,y:40,width:90,height:28)
        next.frame = NSRect(x:188,y:40,width:90,height:28);speed.frame = NSRect(x:286,y:40,width:90,height:28)
        details.frame = NSRect(x:388,y:40,width:160,height:28);status.frame = NSRect(x:14,y:10,width:bounds.width-28,height:22)
    }
    private func refreshBoard() throws {
        guard let session = driver.host.battle else {throw EngineError.invalid("Replay battle is unavailable")}
        if board?.session !== session {
            board?.removeFromSuperview();shield.removeFromSuperview()
            let value = try OriginalBattleView(session:session,background:battleBackground(session.definition,root:driver.data.root),
                sprites:OriginalBattleSpriteRenderer(root:driver.data.root),style:OriginalBattleStyle.load(definition:session.definition,root:driver.data.root,story:driver.host.story))
            value.inputReady = {false};value.animatesActions = false
            board = value;body.addSubview(value,positioned:.below,relativeTo:controls);body.addSubview(shield,positioned:.above,relativeTo:value)
        }
        status.stringValue = "\(session.turns.roundIndex+1)턴 · 입력 \(driver.cursor)/\(driver.archive.inputs.count) · "+(driver.finished ? "최종 상태·난수 일치" : "읽기 전용")
        layout();board?.needsDisplay = true
    }
    private func fail(_ error:Error) {playing = false;play.title = "재생";status.stringValue = "재생 중지: \(error)"}
    @objc private func togglePlay() {
        if let pending = seekCancellation {
            pending.cancel();seekCancellation = nil;setSeeking(false);status.stringValue = "턴 이동을 취소했습니다. 현재 화면은 유지됩니다.";return
        }
        if driver.finished {seek(0,playAfter:true);return}
        playing.toggle();play.title = playing ? "일시정지" : "재생"
    }
    private func tick() {
        guard playing,seekCancellation == nil,window.isVisible,!window.isMiniaturized,NSApp.isActive else {return}
        elapsed += 0.1
        let multiplier = [1.0,2.0,4.0][min(max(speed.indexOfSelectedItem,0),2)]
        guard elapsed >= 0.5/multiplier else {return};elapsed = 0
        do {
            _ = try driver.step();try refreshBoard()
            if driver.finished {playing = false;play.title = "다시 재생"}
        } catch {fail(error)}
    }
    private func setSeeking(_ pending:Bool) {
        previous.isEnabled = !pending;next.isEnabled = !pending;speed.isEnabled = !pending;details.isEnabled = !pending
        play.title = pending ? "취소" : "재생"
    }
    private func seek(_ value:Int,playAfter:Bool = false) {
        guard seekCancellation == nil,(0...driver.archive.inputs.count).contains(value) else {return}
        playing = false;setSeeking(true)
        let token = BattleArchiveCancellation();seekCancellation = token
        status.stringValue = "선택한 턴을 확인하고 있습니다. 취소할 수 있습니다."
        let data = driver.data,archive = driver.archive
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result:Result<BattleReplayDriver,Error>
            do {
                let prepared = try BattleReplayDriver(data:data,archive:archive,expectedDataDigest:archive.dataDigest,cancellation:token)
                while prepared.cursor < value {_ = try prepared.step()}
                try token.check();prepared.finishBackgroundPreparation();result = .success(prepared)
            } catch {result = .failure(error)}
            DispatchQueue.main.async { [weak self] in
                guard let self,self.seekCancellation === token,!token.isCancelled,self.window.isVisible else {return}
                self.seekCancellation = nil;self.setSeeking(false)
                switch result {
                case .success(let prepared):
                    self.driver = prepared;self.playing = playAfter;self.play.title = playAfter ? "일시정지" : "재생"
                    do {try self.refreshBoard()} catch {self.fail(error)}
                case .failure(let error):self.fail(error)
                }
            }
        }
    }
    @objc private func previousTurn() {seek(driver.turnStops.last {$0 < driver.cursor} ?? 0)}
    @objc private func nextTurn() {seek(driver.turnStops.first {$0 > driver.cursor} ?? driver.archive.inputs.count)}
    @objc private func showDetails() {
        guard let session = driver.host.battle else {return}
        playing = false;play.title = "재생"
        let visible = session.units.values.filter {$0.status == 2 && (!$0.enemy || $0.scriptFlags&0x20 != 0)}.sorted {$0.slot < $1.slot}
        let lines = visible.map {unit -> String in
            let person = try? session.people.person(unit.person)
            return "\(person?.name ?? "장수") · Lv.\(person?.level ?? 0) · 병력 \(person?.rawTroops ?? 0) · MP \(unit.mp)"
        }
        let alert = NSAlert();alert.messageText = "현재 부대 · 확정 행동"
        let publicPeople = Set(visible.map(\.person)).union(session.units.values.filter {!$0.enemy}.map(\.person))
        func publicName(_ id:Int?,fallback:String)->String {
            guard let id else {return fallback}
            return publicPeople.contains(id) ? ((try? session.people.person(id).name) ?? fallback) : "미확인 부대"
        }
        let log = session.resultLog.entries.suffix(8).map {entry in "\(entry.round)턴 · \(publicName(entry.actorPerson,fallback:"전투")) → \(publicName(entry.targetPerson,fallback:"대상"))"}
        alert.informativeText = (lines+["", "최근 확정 행동"]+log).joined(separator:"\n");alert.addButton(withTitle:"닫기");alert.runModal()
    }
}
private final class ReplayInputShield:NSView {
    override var acceptsFirstResponder:Bool {true}
    override func mouseDown(with event:NSEvent) {window?.makeFirstResponder(self)}
    override func rightMouseDown(with event:NSEvent) {}
    override func keyDown(with event:NSEvent) {}
    override func scrollWheel(with event:NSEvent) {}
}
