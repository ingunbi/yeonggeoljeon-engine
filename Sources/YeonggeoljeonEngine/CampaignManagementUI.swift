// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Native management flows. The overlay owns each current callback; the UI
/// helper borrows the overlay to avoid retaining the window through a cycle.
final class CampaignManagementUI {
    let host:OriginalCampaignHost
    unowned let overlay:CanvasOverlayView
    let portrait:(Int)->CGImage?
    let onError:(Error)->Void
    var purchaseCart = ShoppingCart()
    var cartExecuting = false
    var cartExecutionID:UUID?
    var cartApprovedContext:ShoppingCart.Context?
    init(host:OriginalCampaignHost,overlay:CanvasOverlayView,portrait:@escaping(Int)->CGImage?,onError:@escaping(Error)->Void) {
        self.host = host;self.overlay = overlay;self.portrait = portrait;self.onError = onError
    }
    func failure(_ error:Error,returning:@escaping()->Void) {
        onError(error)
        overlay.show(CanvasNotice(speaker:"진행할 수 없습니다",text:"현재 상태를 다시 확인해 주세요.\n\(error)",portrait:nil,onDismiss:returning))
    }
    func rows(title:String,line:String = "",values:[CanvasSheet.Row],selected:Int = 0,
                      buttons:[String] = [],onButton:((Int)->Void)? = nil,onChoose:@escaping(Int?)->Void) {
        overlay.show(CanvasSheet(portrait:nil,speaker:title,line:line,badge:("",""),rows:values,
            selected:min(max(selected,0),max(0,values.count-1)),mode:.list,buttons:buttons,
            hint:"↑↓ 항목 선택 · Tab 버튼 · Esc 돌아가기",fullCanvas:true,onButton:onButton,onChoose:onChoose))
    }
    func name(_ person:Int)->String {(try? host.people.person(person).name) ?? "장수 \(person)"}
    func itemName(_ item:Int)->String {host.source.combat.items.first {$0.id == item}?.name ?? "도구 \(item)"}
    func textInput(title:String,message:String,value:String)->String? {
        let alert = NSAlert();alert.messageText = title;alert.informativeText = message
        let field = NSTextField(string:value);field.frame = NSRect(x:0,y:0,width:320,height:24)
        alert.accessoryView = field;alert.addButton(withTitle:"확인");alert.addButton(withTitle:"취소")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else {return nil}
        return field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
    }
    func showInventory(filter:InventoryOverview.Filter = .all,query:String = "",selected:Int = 0,onClose:@escaping()->Void) {
        do {
            let people = try host.people.companions().map {try host.people.person($0)}
            let entries = try InventoryOverview.entries(people:people,combat:host.source.combat,extras:host.extras,query:query,filter:filter)
            var sheet = InventoryOverview.sheet(entries,filter:filter,selected:selected) {index in
                guard let index,entries.indices.contains(index) else {onClose();return}
                self.showInventoryActions(entries[index]) {self.showInventory(filter:filter,query:query,selected:index,onClose:onClose)}
            }
            if !query.isEmpty {sheet.line = "검색: "+query}
            sheet.buttons = ["분류: "+filter.title,"검색","닫기"]
            sheet.onButton = {button in
                switch button {
                case 0:
                    let options = InventoryOverview.Filter.allCases,index = options.firstIndex(of:filter) ?? 0
                    self.showInventory(filter:options[(index+1)%options.count],query:query,onClose:onClose)
                case 1:
                    let text = self.textInput(title:"소지품 검색",message:"장수 이름이나 물품 이름으로 찾습니다. 비우면 전체를 표시합니다.",value:query)
                    self.showInventory(filter:filter,query:text ?? query,onClose:onClose)
                default:onClose()
                }
            }
            overlay.show(sheet)
        } catch {failure(error,returning:onClose)}
    }
    private func showInventoryActions(_ entry:InventoryOverview.Entry,onClose:@escaping()->Void) {
        let locked = host.extras.protects(personID:entry.personID,itemID:entry.itemID,operation:.sell)
        let useLocked = host.extras.protects(personID:entry.personID,itemID:entry.itemID,operation:.use)
        rows(title:entry.itemName,line:entry.personName+" · 같은 물품 전체에 보호 적용",values:[
            .init(label:"다른 장수에게 전달",enabled:host.fieldMenuReady),
            .init(label:locked ? "매각·버리기 보호 해제" : "매각·버리기 보호 설정",checked:locked),
            .init(label:useLocked ? "사용 보호 해제" : "사용도 보호",checked:useLocked),
            .init(label:"뒤로")]) {index in
            guard let index else {onClose();return}
            do {
                switch index {
                case 0:self.showReceivers(giver:entry.personID,item:entry.itemID,onClose:onClose)
                case 1:
                    try self.host.extras.setItemProtection(personID:entry.personID,itemID:entry.itemID,enabled:!locked)
                    self.showInventoryActions(entry,onClose:onClose)
                case 2:
                    try self.host.extras.setItemProtection(personID:entry.personID,itemID:entry.itemID,enabled:true,protectUse:!useLocked)
                    self.showInventoryActions(entry,onClose:onClose)
                default:onClose()
                }
            } catch {self.failure(error,returning:onClose)}
        }
    }
    private func showReceivers(giver:Int,item:Int,onClose:@escaping()->Void) {
        do {
            let people = try host.people.companions().filter {$0 != giver}
            let values = try people.map {id -> CanvasSheet.Row in
                let person = try host.people.person(id),held = person.itemIDs.filter {$0 != 255}.count
                return .init(label:person.name,value:"\(held)/8칸",warns:held == 8,enabled:held < 8)
            }
            rows(title:"물품 받을 장수",line:name(giver)+" → "+itemName(item),values:values) {index in
                guard let index,people.indices.contains(index) else {onClose();return}
                self.showTransfer(giver:giver,receiver:people[index],item:item,onCancel:{self.showReceivers(giver:giver,item:item,onClose:onClose)},onSuccess:onClose)
            }
        } catch {failure(error,returning:onClose)}
    }
    func showTransfer(giver:Int,receiver:Int,item:Int,selected:Int = 0,onCancel:@escaping()->Void,onSuccess:@escaping()->Void) {
        do {
            let value = try EquipmentComparison.transfer(giver:host.people.person(giver),receiver:host.people.person(receiver),item:item,
                combat:host.source.combat,movement:host.source.movement)
            overlay.show(EquipmentComparison.sheet(value,selected:selected,onChoose:{row in
                guard let row else {onCancel();return}
                self.showTransfer(giver:giver,receiver:receiver,item:item,selected:row,onCancel:onCancel,onSuccess:onSuccess)
            },onButton:{button in
                guard button == 0 else {onCancel();return}
                do {
                    let fresh = try EquipmentComparison.transfer(giver:self.host.people.person(giver),receiver:self.host.people.person(receiver),item:item,
                        combat:self.host.source.combat,movement:self.host.source.movement)
                    guard fresh == value else {
                        self.overlay.show(CanvasNotice(speaker:"전력 변경",text:"상태가 바뀌어 비교를 다시 계산했습니다. 확인 후 전달해 주세요.",portrait:nil) {
                            self.showTransfer(giver:giver,receiver:receiver,item:item,onCancel:onCancel,onSuccess:onSuccess)
                        });return
                    }
                    guard try self.host.exchangeItem(from:giver,to:receiver,item:item) else {throw BattleError.illegalAction("받는 장수의 소지품이 가득 찼습니다.")}
                    onSuccess()
                } catch {self.failure(error,returning:onCancel)}
            }))
        } catch {failure(error,returning:onCancel)}
    }
    func showOfficerActions(person:Int,onStrategies:@escaping()->Void,onClose:@escaping()->Void) {
        let favorite = host.extras.favoritePeople.contains(person)
        rows(title:name(person),line:"장수 정보와 성장 계획",values:[.init(label:"책략 습득표"),.init(label:"전직·병종 변경 성장 계획"),
            .init(label:"다른 장수와 비교"),.init(label:favorite ? "주력 장수 해제" : "주력 장수 지정",checked:favorite)]) {index in
            guard let index else {onClose();return}
            let back = {self.showOfficerActions(person:person,onStrategies:onStrategies,onClose:onClose)}
            switch index {
            case 0:onStrategies()
            case 1:self.showGrowth(person:person,onClose:back)
            case 2:self.showComparison(first:person,onClose:back)
            default:
                do {try self.host.extras.setFavorite(person,enabled:!favorite);back()}
                catch {self.failure(error,returning:back)}
            }
        }
    }
    func showComparison(first:Int? = nil,second:Int? = nil,tab:OfficerComparison.Tab = .stats,selected:Int = 0,onClose:@escaping()->Void) {
        do {
            let ids = try host.people.companions().filter {person in
                host.battle.map {battle in battle.units.values.contains {!$0.enemy && $0.person == person}} ?? true
            }
            guard let first else {
                rows(title:"장수 비교",line:"기준 장수를 고르세요.",values:ids.map {.init(label:name($0))}) {index in
                    guard let index,ids.indices.contains(index) else {onClose();return}
                    self.showComparison(first:ids[index],tab:tab,onClose:onClose)
                };return
            }
            guard ids.contains(first) else {self.showComparison(tab:tab,onClose:onClose);return}
            guard let second else {
                let others = ids.filter {$0 != first}
                rows(title:"장수 비교",line:name(first)+"와 비교할 장수",values:others.map {.init(label:name($0))}) {index in
                    guard let index,others.indices.contains(index) else {onClose();return}
                    self.showComparison(first:first,second:others[index],tab:tab,onClose:onClose)
                };return
            }
            guard ids.contains(second),first != second else {self.showComparison(first:first,tab:tab,onClose:onClose);return}
            func morale(_ person:Int) -> Int {host.battle?.units.values.first(where:{$0.person == person && !$0.enemy}).map {Int($0.morale)} ?? 100}
            let left = try OfficerComparison.snapshot(person:host.people.person(first),morale:morale(first),combat:host.source.combat,movement:host.source.movement)
            let right = try OfficerComparison.snapshot(person:host.people.person(second),morale:morale(second),combat:host.source.combat,movement:host.source.movement)
            let commands = host.story.screens?.battle.commands
            var sheet = OfficerComparison.sheet(left:left,right:right,classNames:commands?.classNames ?? [],strategyNames:commands?.strategyNames ?? [],itemName:itemName,tab:tab,terrainNames:commands?.terrain.names ?? [],selected:selected) {row in
                guard let row else {self.showComparison(first:first,tab:tab,onClose:onClose);return}
                self.showComparison(first:first,second:second,tab:tab,selected:row,onClose:onClose)
            }
            sheet.buttons = ["보기: "+tab.rawValue,"좌우 교환","후보 변경","돌아가기"]
            sheet.onRowButton = {button,currentRow in
                if button == 0 {
                    let tabs = OfficerComparison.Tab.allCases,index = tabs.firstIndex(of:tab) ?? 0
                    self.showComparison(first:first,second:second,tab:tabs[(index+1)%tabs.count],onClose:onClose)
                }
                else if button == 1 {self.showComparison(first:second,second:first,tab:tab,selected:currentRow,onClose:onClose)}
                else if button == 2 {self.showComparison(first:first,tab:tab,onClose:onClose)}
                else {onClose()}
            }
            overlay.show(sheet)
        } catch {failure(error,returning:onClose)}
    }
    private func showGrowth(person:Int,item:Int? = nil,selected:Int = 0,onClose:@escaping()->Void) {
        do {
            let value = try host.people.person(person),candidates = try PromotionPlanning.candidates(person:value)
            guard let commands = host.story.screens?.battle.commands else {throw EngineError.invalid("전직 계획의 원본 표시 자료가 없습니다.")}
            guard let item else {
                let values:[CanvasSheet.Row] = candidates.map {candidate in
                    let target = commands.classNames.indices.contains(candidate.targetClass) ? commands.classNames[candidate.targetClass] : "병과 \(candidate.targetClass)"
                    return .init(label:target,value:itemName(candidate.itemID),detail:.init(heading:target,body:"필요 도구: "+itemName(candidate.itemID),list:candidate.conditions))
                }
                rows(title:value.name+" · 성장 계획",line:values.isEmpty ? "현재 병과에서 확인된 전직 후보가 없습니다." : "현재 레벨·장비로 전직 결과를 미리 비교합니다.",values:values) {index in
                    guard let index,candidates.indices.contains(index) else {onClose();return}
                    self.showGrowth(person:person,item:candidates[index].itemID,onClose:onClose)
                };return
            }
            let plan = try PromotionPlanning.build(person:value,item:item,combat:host.source.combat,movement:host.source.movement,
                classNames:commands.classNames,strategyNames:commands.strategyNames,terrainNames:commands.terrain.names)
            overlay.show(PromotionPlanning.sheet(plan,selected:selected) {row in
                guard let row else {self.showGrowth(person:person,onClose:onClose);return}
                self.showGrowth(person:person,item:item,selected:row,onClose:onClose)
            })
        } catch {failure(error,returning:onClose)}
    }
    func showPartyReview(selected:Int = 0,onClose:@escaping()->Void) {
        do {
            guard let selection = host.partySelection else {onClose();return}
            let ids = Set(selection.candidates).union(selection.selectedSlots.filter {$0 != 65535}).union(host.extras.favoritePeople)
            let report = try PartyPreparation.review(selection:selection,people:ids.sorted().map {try host.people.person($0)},
                combat:host.source.combat,movement:host.source.movement,extras:host.extras)
            overlay.show(PartyPreparation.sheet(report,selected:selected) {row in
                guard let row else {onClose();return}
                if report.issues.indices.contains(row),let person = report.issues[row].personID {
                    self.showOfficerSummary(person:person) {self.showPartyReview(selected:row,onClose:onClose)}
                    return
                }
                self.showPartyReview(selected:row,onClose:onClose)
            })
        } catch {failure(error,returning:onClose)}
    }
    func showOfficerSummary(person:Int,selected:Int = 0,onClose:@escaping()->Void) {
        do {
            let value = try host.people.person(person),snapshot = try OfficerComparison.snapshot(person:value,combat:host.source.combat,movement:host.source.movement)
            let detail = CanvasSheet.Detail(heading:value.name,body:"현재 레벨·장비 · 필드 사기 100 기준",
                list:value.itemIDs.filter {$0 != 255}.map(itemName),facts:[("레벨","\(value.level)"),("병력","\(value.rawTroops)/\(snapshot.maximumTroops)"),
                    ("공격력","\(snapshot.attack)"),("방어력","\(snapshot.defense)"),("이동력","\(snapshot.movement)"),("최대 책략치","\(snapshot.maximumMP)")],portrait:portrait(person))
            overlay.show(CanvasSheet(portrait:nil,speaker:value.name,line:"출전 준비 · 장수 정보",badge:("소지품","\(value.itemIDs.filter {$0 != 255}.count)/8"),
                rows:[.init(label:"현재 장수 정보",detail:detail)],selected:0,mode:.list,buttons:["성장 계획","돌아가기"],hint:"Tab 버튼 · Esc 준비 점검",fullCanvas:true,
                onButton:{button in
                    if button == 0 {self.showGrowth(person:person,onClose:{self.showOfficerSummary(person:person,onClose:onClose)})}
                    else {onClose()}
                },onChoose:{index in
                    guard index != nil else {onClose();return}
                    self.showOfficerSummary(person:person,onClose:onClose)
                }))
        } catch {failure(error,returning:onClose)}
    }
    func showFavorites(selected:Int = 0,onClose:@escaping()->Void) {
        do {
            let ids = try host.people.companions()
            rows(title:"주력 장수 지정",line:"준비 점검에서 누락 여부를 알려 드립니다. 출전을 강제하지 않습니다.",
                values:ids.map {.init(label:name($0),checked:host.extras.favoritePeople.contains($0))},selected:selected) {index in
                guard let index,ids.indices.contains(index) else {onClose();return}
                do {try self.host.extras.setFavorite(ids[index],enabled:!self.host.extras.favoritePeople.contains(ids[index]));self.showFavorites(selected:index,onClose:onClose)}
                catch {self.failure(error,returning:onClose)}
            }
        } catch {failure(error,returning:onClose)}
    }
    func showPresets(selected:Int = 0,onClose:@escaping()->Void) {
        let presets = host.extras.partyPresets
        rows(title:"출전 편성 프리셋",line:"강제 출전을 유지하며 선택만 바꿉니다.",
            values:presets.map {preset in
                let issue = preset.sourceIssue(for:host.currentAssistanceSourceIdentity)
                return .init(label:preset.name,value:issue == nil ? "\(preset.people.count)명" : "자료 확인 필요",warns:issue != nil,
                    detail:.init(heading:preset.name,body:issue ?? "",list:preset.people.map {issue == nil ? name($0) : "이전 장수 ID \($0)"}))
            },selected:selected,
            buttons:["현재 편성 저장","닫기"],onButton:{button in
                guard button == 0,let selection = self.host.partySelection else {onClose();return}
                guard let title = self.textInput(title:"편성 저장",message:"이름을 입력하세요. 최대 20개, 이름 64자까지 저장합니다.",value:"편성 \(presets.count+1)") else {self.showPresets(onClose:onClose);return}
                do {
                    guard let identity = self.host.currentAssistanceSourceIdentity else {throw EngineError.invalid("현재 원본 자료를 확인할 수 없습니다.")}
                    try self.host.extras.savePreset(name:title,people:Array(selection.selectedSlots.prefix(selection.capacity).filter {$0 != 65535}),sourceIdentity:identity)
                    self.showPresets(onClose:onClose)
                } catch {self.failure(error,returning:{self.showPresets(onClose:onClose)})}
            }) {index in
                guard let index,presets.indices.contains(index) else {onClose();return}
                self.showPreset(presets[index],onClose:{self.showPresets(selected:index,onClose:onClose)},onApplied:onClose)
            }
    }
    private func showPreset(_ preset:CampaignExtras.PartyPreset,onClose:@escaping()->Void,onApplied:@escaping()->Void) {
        do {
            guard let selection = host.partySelection else {onClose();return}
            if let issue = preset.sourceIssue(for:host.currentAssistanceSourceIdentity) {
                rows(title:preset.name,line:issue,values:preset.people.map {.init(label:"이전 장수 ID \($0)")},buttons:["삭제","돌아가기"],onButton:{button in
                    guard button == 0 else {onClose();return}
                    self.overlay.show(CanvasMenu(title:preset.name+"을 삭제할까요?",options:[.init(label:"삭제",destructive:true),.init(label:"취소")],horizontal:true,cancellable:true) {choice in
                        if choice == 0 {self.host.extras.removePreset(preset.id)}
                        onClose()
                    })
                }) {_ in onClose()}
                return
            }
            let plan = try PartyPreparation.applying(preset:preset,to:selection)
            let selected = plan.selection.selectedSlots.prefix(plan.selection.capacity).filter {$0 != 65535}
            let values:[CanvasSheet.Row] = [.init(label:"적용 후 편성",value:"\(selected.count)/\(selection.capacity)",detail:.init(heading:"적용 후 편성",list:selected.map(name))),
                .init(label:"강제 출전 유지",value:"\(plan.preservedFixedPeople.count)명",detail:.init(heading:"강제 출전 유지",list:plan.preservedFixedPeople.map(name))),
                .init(label:"제외 장수",value:"\(plan.omitted.count)명",warns:!plan.omitted.isEmpty,
                    detail:.init(heading:"제외 장수",list:plan.omitted.map {name($0.personID)+" · "+$0.reason.rawValue}))]
            rows(title:preset.name,line:"적용 후에도 출전 버튼으로 따로 확정합니다.",values:values,buttons:["적용","이름 변경","삭제","취소"],onButton:{button in
                do {
                    switch button {
                    case 0:try self.host.applyPartyPreset(preset);onApplied()
                    case 1:
                        if let title = self.textInput(title:"편성 이름 변경",message:"64자까지 입력할 수 있습니다.",value:preset.name) {
                            try self.host.extras.savePreset(name:title,people:preset.people,id:preset.id)
                        }
                        onClose()
                    case 2:
                        self.overlay.show(CanvasMenu(title:preset.name+"을 삭제할까요?",options:[.init(label:"삭제",destructive:true),.init(label:"취소")],horizontal:true,cancellable:true) {index in
                            if index == 0 {self.host.extras.removePreset(preset.id)}
                            onClose()
                        })
                    default:onClose()
                    }
                } catch {self.failure(error,returning:onClose)}
            }) {index in
                guard index != nil else {onClose();return}
                self.showPreset(preset,onClose:onClose,onApplied:onApplied)
            }
        } catch {failure(error,returning:onClose)}
    }
    func showShopPurchase(item:Int,person:Int,selected:Int = 0,onAnswer:@escaping(Bool)->Void) {
        do {
            let comparison = try EquipmentComparison.purchase(receiver:host.people.person(person),item:item,combat:host.source.combat,movement:host.source.movement)
            var sheet = EquipmentComparison.sheet(comparison,selected:selected,confirmTitle:"구입",onChoose:{row in
                guard let row else {onAnswer(false);return}
                self.showShopPurchase(item:item,person:person,selected:row,onAnswer:onAnswer)
            },onButton:{button in
                guard button == 0 else {onAnswer(false);return}
                do {
                    let fresh = try EquipmentComparison.purchase(receiver:self.host.people.person(person),item:item,combat:self.host.source.combat,movement:self.host.source.movement)
                    guard fresh == comparison else {
                        self.showShopPurchase(item:item,person:person,selected:selected,onAnswer:onAnswer);return
                    }
                    onAnswer(true)
                } catch {self.failure(error,returning:{onAnswer(false)})}
            })
            let price = host.shopCatalog.buyingPrice(item)
            sheet.line = name(person)+"에게 구입 · \(price) · 구입 후 \((host.money ?? 0)-price)"
            overlay.show(sheet)
        } catch {failure(error,returning:{onAnswer(false)})}
    }
    func showBulkShop(onClose:@escaping()->Void) {
        rows(title:"상점 일괄 거래",line:"선택한 물품을 한 개씩 확정합니다. 중단되면 완료된 거래만 남습니다.",
            values:[.init(label:"구입할 물품 고르기"),.init(label:"같은 물품 여러 개 판매"),.init(label:"장바구니 확인",value:"\(purchaseCart.lines.count)항목")]) {index in
                guard let index else {onClose();return}
                if index == 2 {self.showShoppingCart(onClose:onClose);return}
                self.showBulkPeople(buying:index == 0,onClose:{self.showBulkShop(onClose:onClose)},onFinished:onClose)
            }
    }
    func showBulkPeople(buying:Bool,onClose:@escaping()->Void,onFinished:@escaping()->Void) {
        do {
            let ids = try OriginalShopOperation.customers(host.people)
            let values = try ids.map {id -> CanvasSheet.Row in
                let count = try host.people.person(id).itemIDs.filter {$0 != 255}.count
                return .init(label:name(id),value:"\(count)/8칸",enabled:buying ? count < 8 : count > 0)
            }
            rows(title:buying ? "구입할 장수" : "판매할 장수",values:values) {index in
                guard let index,ids.indices.contains(index) else {onClose();return}
                self.showBulkItems(buying:buying,person:ids[index],onClose:{self.showBulkPeople(buying:buying,onClose:onClose,onFinished:onFinished)},onFinished:onFinished)
            }
        } catch {failure(error,returning:onClose)}
    }
    private func showBulkItems(buying:Bool,person:Int,onClose:@escaping()->Void,onFinished:@escaping()->Void) {
        do {
            guard let shop = host.shop else {onClose();return}
            let held = try host.people.person(person).itemIDs
            var seen = Set<Int>()
            let items = (buying ? shop.stock : held.filter {$0 != 255}).filter {seen.insert($0).inserted}
            if buying,!items.isEmpty {try host.observeCurrentShopStock()}
            let values:[CanvasSheet.Row] = items.map {item in
                let locked = !buying && host.extras.protects(personID:person,itemID:item,operation:.sell)
                let price = buying ? host.shopCatalog.buyingPrice(item) : host.shopCatalog.sellingPrice(item)
                return .init(label:itemName(item),value:locked ? "보호됨" : "\(price) / 개",enabled:!locked)
            }
            rows(title:buying ? "일괄 구입" : "일괄 판매",line:name(person),values:values) {index in
                guard let index,items.indices.contains(index) else {onClose();return}
                let item = items[index],maximum = buying ? held.filter {$0 == 255}.count : held.filter {$0 == item}.count
                guard let text = self.textInput(title:"거래 수량",message:"1~\(maximum)개를 입력하세요.",value:"1") else {
                    self.showBulkItems(buying:buying,person:person,onClose:onClose,onFinished:onFinished);return
                }
                guard let count = Int(text),(1...max(1,maximum)).contains(count),maximum > 0 else {
                    self.failure(EngineError.invalid("거래 수량은 1~\(maximum)개여야 합니다."),returning:{self.showBulkItems(buying:buying,person:person,onClose:onClose,onFinished:onFinished)});return
                }
                self.showBulkConfirmation(buying:buying,person:person,item:item,count:count,onClose:{self.showBulkItems(buying:buying,person:person,onClose:onClose,onFinished:onFinished)},onFinished:onFinished)
            }
        } catch {failure(error,returning:onClose)}
    }
    private func showBulkConfirmation(buying:Bool,person:Int,item:Int,count:Int,onClose:@escaping()->Void,onFinished:@escaping()->Void) {
        let price = buying ? host.shopCatalog.buyingPrice(item) : host.shopCatalog.sellingPrice(item)
        let money = host.money ?? 0,total = price*count,after = buying ? money-total : min(10000,money+total)
        let values:[CanvasSheet.Row] = [.init(label:"물품",value:itemName(item)),.init(label:"장수",value:name(person)),.init(label:"수량",value:"\(count)개"),
            .init(label:buying ? "총 구입가" : "총 판매가",value:String(total)),.init(label:"완료 시 소지금",value:after < 0 ? "전량 구매 불가" : String(after),warns:after < 0)]
        rows(title:buying ? "일괄 구입 확인" : "일괄 판매 확인",line:"확정 전에는 거래하지 않습니다. 취소해도 이미 확정한 다른 거래는 되돌리지 않습니다.",values:values,
            buttons:buying ? ["장바구니 추가","지금 구입","취소"] : ["거래 확정","취소"],onButton:{button in
                if buying,button == 0 {
                    do {
                        var candidate = self.purchaseCart;try candidate.add(person:person,item:item,count:count,context:self.currentCartContext())
                        let review = try self.reviewCart(candidate)
                        guard review.allSatisfy({$0.issues.isEmpty}) else {throw EngineError.invalid(review.flatMap(\.issues).joined(separator:" · "))}
                        self.purchaseCart = candidate;self.showShoppingCart(onClose:onFinished)
                    } catch {self.failure(error,returning:onClose)}
                    return
                }
                if buying,button != 1 {onClose();return}
                if !buying,button != 0 {onClose();return}
                let returning:()->Void = buying && !self.purchaseCart.lines.isEmpty ? {self.showShoppingCart(onClose:onFinished)} : onFinished
                do {
                    let result = try buying ? self.host.performShopPurchase(item:item,person:person,count:count) : self.host.performShopSale(person:person,item:item,count:count)
                    let message = "\(count)개 중 \(result.completed)개 거래했습니다."+(result.failure.map {"\n중단: "+$0} ?? "")
                    self.overlay.show(CanvasNotice(speaker:"일괄 거래 결과",text:message,portrait:nil,onDismiss:returning))
                } catch {self.failure(error,returning:returning)}
            }) {index in
                guard index != nil else {onClose();return}
                self.showBulkConfirmation(buying:buying,person:person,item:item,count:count,onClose:onClose,onFinished:onFinished)
            }
    }
}
