// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Entirely synthetic inputs: no original files, user saves or live UI state.
func managementHelpersSelfTests() throws {
    var checks = 0
    func check(_ condition:@autoclosure() throws -> Bool,_ message:String) throws {
        guard try condition() else {throw EngineError.invalid("Management helpers regression: \(message)")};checks += 1
    }
    func rejects(_ body:() throws -> Void)->Bool {do {try body();return false} catch {return true}}
    let combat = OriginalCombatTables(format:1,attackBase:Array(repeating:12,count:19),defenseBase:Array(repeating:13,count:19),
        troopBase:Array(repeating:10,count:19),troopGrowth:Array(repeating:10,count:19),physicalSubtypeByClass:Array(repeating:0,count:19),
        terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),
        items:(0..<64).map {id in .init(id:id,category:[4:0,5:5,6:4,7:4,8:0][id] ?? 15,
            value:[4:20,5:30,6:2,7:1,8:5][id] ?? 0,name:"도구 \(id)",description:"합성 도구 설명")})
    let cardinal = [OriginalAIOffset(dx:0,dy:-1),.init(dx:1,dy:0),.init(dx:0,dy:1),.init(dx:-1,dy:0)]
    let diagonal = [OriginalAIOffset(dx:-1,dy:-1),.init(dx:1,dy:-1),.init(dx:1,dy:1),.init(dx:-1,dy:1)]
    var levels = Array(repeating:Array(repeating:255,count:19),count:36);levels[0][0] = 5;levels[24][1] = 10
    let movement = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),classMovementBudgets:Array(repeating:4,count:19),
        attackRangeCodes:Array(repeating:0,count:19),movementCosts:Array(repeating:Array(repeating:1,count:256),count:4),
        cardinalOffsets:cardinal,diagonalOffsets:diagonal,extendedOffsets:cardinal,
        strategyLevelRequirements:levels,strategyMPCosts:Array(repeating:4,count:36),strategyCategories:Array(repeating:0,count:36))
    func person(_ id:Int,_ items:[Int] = []) -> OriginalPersonDefinition {
        OriginalPersonDefinition(id:id,name:"검증 장수 \(id)",classID:0,level:10,experience:9,rawTroops:700,defenseScalar:60,attackScalar:70,
            intellectScalar:50,personality:0,personalScalar:0,itemIDs:items+Array(repeating:255,count:max(0,8-items.count)),
            sourceFlags:0x80,sourceRole:0,sourceContext2:0,sourceContext3:0)
    }
    let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
    let decoder = JSONDecoder()
    var extras = CampaignExtras()
    try check(try decoder.decode(CampaignExtras.self,from:Data("{}".utf8)) == extras,"missing optional metadata decodes to empty defaults")
    try check(rejects {_ = try decoder.decode(CampaignExtras.self,from:Data("{\"format\":2}".utf8))},"unknown future extras format cannot be silently discarded")
    try extras.setFavorite(2,enabled:true);try extras.setFavorite(3,enabled:true)
    try extras.setItemProtection(personID:0,itemID:4,enabled:true)
    try check(extras.protects(personID:0,itemID:4,operation:.sell) && extras.protects(personID:0,itemID:4,operation:.discard),"type-level protection guards selling and discarding")
    try check(!extras.protects(personID:0,itemID:4,operation:.use) && !extras.protects(personID:0,itemID:4,operation:.script),"default use and forced source operations remain unblocked")
    try extras.setItemProtection(personID:0,itemID:4,enabled:true,protectUse:true)
    try extras.transferProtection(from:0,to:1,item:4)
    try check(extras.protects(personID:0,itemID:4,operation:.use) && extras.protects(personID:1,itemID:4,operation:.use),"successful transfers preserve sender protection and copy use protection to receiver")
    try check(!extras.protects(personID:1,itemID:4,operation:.script),"script consumption bypasses even opt-in use protection")
    let presetID = try extras.savePreset(name:"  정예  ",people:[0,2])
    try check(extras.partyPresets[0].name == "정예" && extras.partyPresets[0].people == [0,2],"presets retain requested order with a trimmed name")
    let extrasBefore = extras
    try check(rejects {_ = try extras.savePreset(name:"중복",people:[0,0])} && extras == extrasBefore,"invalid preset changes are atomic")
    try check(try decoder.decode(CampaignExtras.self,from:encoder.encode(extras)) == extras,"favorites, presets and protection survive round trips together")
    try extras.savePreset(name:"수정",people:[2,0],id:presetID)
    try check(extras.partyPresets.count == 1 && extras.partyPresets[0].people == [2,0],"renaming/updating a preset keeps its identity")
    extras.removePreset(presetID);try check(extras.partyPresets.isEmpty,"preset deletion removes only its own record")

    let giver = person(0,[4,4,8,6,7]),receiver = person(1,[5])
    let giverBytes = try encoder.encode(giver),receiverBytes = try encoder.encode(receiver)
    let transfer = try EquipmentComparison.transfer(giver:giver,receiver:receiver,item:4,combat:combat,movement:movement)
    try check(transfer.giver?.after.itemIDs == [255,4,8,6,7,255,255,255] && transfer.receiver.after.itemIDs == [5,4,255,255,255,255,255,255],"projection removes only the first duplicate and inserts into the first empty receiver slot")
    try check(transfer.giver?.before.attack == transfer.giver?.after.attack && transfer.receiver.before.attack < transfer.receiver.after.attack,"a remaining duplicate keeps the sender's maximum equipment bonus")
    let moveTransfer = try EquipmentComparison.transfer(giver:giver,receiver:receiver,item:6,combat:combat,movement:movement)
    try check(moveTransfer.giver?.before.movement == 6 && moveTransfer.giver?.after.movement == 5 && moveTransfer.receiver.after.movement == 6,"movement equipment uses the maximum bonus, not the sum")
    let bought = try EquipmentComparison.purchase(receiver:receiver,item:0x13,combat:combat,movement:movement)
    try check(bought.receiver.before.classID == bought.receiver.after.classID && bought.receiver.before.attack == bought.receiver.after.attack,"owning a promotion tool does not perform promotion")
    try check(rejects {_ = try EquipmentComparison.transfer(giver:giver,receiver:person(1,Array(repeating:5,count:8)),item:4,combat:combat,movement:movement)},"a full eight-slot receiver cannot produce a transfer preview")
    try check(rejects {_ = try EquipmentComparison.transfer(giver:giver,receiver:giver,item:4,combat:combat,movement:movement)},"same-officer transfer is rejected")
    let source = try OriginalPeople(catalog:OriginalPersonCatalog(format:1,people:(0..<384).map {$0 == 0 ? giver : $0 == 1 ? receiver : person($0)}),tables:combat)
    try check(try source.giveItem(from:0,to:1,item:4),"synthetic original transfer succeeds")
    let actualGiver = try OfficerComparison.snapshot(person:source.person(0),combat:combat,movement:movement)
    let actualReceiver = try OfficerComparison.snapshot(person:source.person(1),combat:combat,movement:movement)
    try check(actualGiver == transfer.giver?.after && actualReceiver == transfer.receiver.after,"both projected officers match the existing source transfer implementation")
    let entries = try InventoryOverview.entries(people:[giver,receiver],combat:combat,extras:extras)
    try check(entries.first?.count == 2 && entries.first?.sourceSlot == 0 && entries.first?.occupiedSlots == 5 && entries.first?.protected == true,"inventory groups duplicates while retaining their original first slot and ownership")
    let filtered = try InventoryOverview.entries(people:[giver,receiver],combat:combat,extras:extras,query:"장수 0",filter:.protected)
    try check(filtered.count == 1 && filtered[0].itemID == 4,"combined owner search and protection filter remain read-only")
    let noTables:OriginalMovementProfile = {
        var result = movement;result.strategyLevelRequirements = nil;result.strategyMPCosts = nil;result.strategyCategories = nil;return result
    }()
    try check(try OfficerComparison.snapshot(person:giver,combat:combat,movement:noTables).learnedAbilities == nil,"unavailable learning data is distinct from no learned abilities")
    var picked:[Int?] = [],buttons:[Int] = []
    let sheet = EquipmentComparison.sheet(transfer,onChoose:{picked.append($0)},onButton:{buttons.append($0)})
    sheet.onChoose(0);sheet.onChoose(nil);sheet.onButton?(1)
    try check(picked.count == 2 && picked[1] == nil && buttons == [1],"browsing/cancelling a comparison does not invoke the confirm callback")
    try check(try encoder.encode(giver) == giverBytes && encoder.encode(receiver) == receiverBytes,"all projections and display factories preserve source person values")

    let classNames = (0..<19).map {"병과 \($0)"},strategyNames = (0..<36).map {"책략 \($0)"}
    let compared = try OfficerComparison.snapshot(person:giver,combat:combat,movement:movement)
    for tab in OfficerComparison.Tab.allCases {
        let reference = OfficerComparison.sheet(left:compared,right:actualReceiver,classNames:classNames,strategyNames:strategyNames,tab:tab,terrainNames:["합성 평지"],onChoose:{_ in})
        try check(!reference.rows.isEmpty,"officer comparison tab \(tab.rawValue) has read-only content")
        if tab == .movement {
            let ranges = reference.rows.compactMap { $0.detail?.rangeComparison }.first
            try check(ranges?.left == compared.attackOffsets && ranges?.right == actualReceiver.attackOffsets,"comparison grids retain exact source attack offsets")
            try check(reference.rows.contains {$0.label.contains("합성 평지")},"movement comparison includes named terrain costs")
        }
    }
    let lowPerson = person(1),lowBytes = try encoder.encode(lowPerson)
    let lowPlan = try PromotionPlanning.build(person:lowPerson,item:0x13,combat:combat,movement:movement,
        classNames:classNames,strategyNames:strategyNames,terrainNames:["합성 평지"])
    try check(lowPlan.candidate.requiredLevel == 15 && lowPlan.candidate.conditions.contains {$0.contains("5레벨 남음")} && lowPlan.candidate.conditions.contains {$0.contains("소지하고 있지")},"planning shows both missing tool and unmet level without refusing a read")
    try check(try encoder.encode(lowPerson) == lowBytes && lowPlan.comparison.after.classID == 1,"planning projects another class without granting an item or changing the person")
    var eligible = person(1,[0x13,4,5,6]);eligible.level = 20
    let planned = try PromotionPlanning.build(person:eligible,item:0x13,combat:combat,movement:movement,
        classNames:classNames,strategyNames:strategyNames,terrainNames:["합성 평지"])
    let existing = try PromotionPreview.build(person:eligible,morale:100,item:0x13,combat:combat,movement:movement,
        classNames:classNames,strategyNames:strategyNames,terrainNames:["합성 평지"])
    try check(planned.comparison == existing,"an eligible growth plan matches the existing executable promotion preview")
    let planSheet = PromotionPlanning.sheet(lowPlan,onChoose:{_ in})
    try check(planSheet.buttons.isEmpty && planSheet.onButton == nil && planSheet.rows.first?.label == "전직 조건과 비교 기준","planning exposes no instant-promotion action and leads with its assumptions")
    try check(try PromotionPlanning.candidates(person:person(0)).filter {$0.requiredLevel == nil}.allSatisfy {$0.conditions.contains {$0.contains("주인공")}},"protagonist class-change restrictions are visible in planning")

    let selection = OriginalPartySelection(candidates:[0,1,2],selectedSlots:[0,1]+Array(repeating:65535,count:13),fixedCount:1,capacity:2,remaining:0,preparedRoster:OriginalRoster())
    let selectionBytes = try encoder.encode(selection)
    let rawPreset = CampaignExtras.PartyPreset(id:UUID(),name:"검증",people:[2,2,3,1,999])
    let plan = try PartyPreparation.applying(preset:rawPreset,to:selection)
    try check(plan.selection.selectedSlots.prefix(2) == [0,2] && plan.preservedFixedPeople == [0],"preset application preserves the forced prefix and picks the requested available officer")
    try check(plan.omitted.map(\.reason) == [.duplicate,.unavailable,.capacity,.invalid],"duplicate, unavailable, over-capacity and invalid requests have distinct reasons")
    try check(try encoder.encode(selection) == selectionBytes && encoder.encode(plan.selection.preparedRoster) == encoder.encode(selection.preparedRoster),"planning changes neither the original selection nor setup coordinates/flags")
    let small = try PartyPreparation.applying(preset:.init(id:UUID(),name:"소수",people:[]),to:selection)
    try check(small.selection.selectedSlots.prefix(2) == [0,65535],"unused capacity does not force extra officers into a preset")
    let report = try PartyPreparation.review(selection:selection,people:[person(0),person(1,Array(repeating:4,count:8)),person(2)],combat:combat,movement:movement,extras:extras)
    try check(report.issues.contains {$0.kind == .favoriteMissing && $0.personID == 2} && report.issues.contains {$0.kind == .favoriteUnavailable && $0.personID == 3},"unselected favorites and unavailable favorites are distinguished")
    try check(report.issues.contains {$0.kind == .fullInventory && $0.personID == 1} && report.issues.contains {$0.kind == .noTroopRecovery},"full inventory and absence of learned troop recovery are advisory findings")
    let moraleOnly = try PartyPreparation.review(selection:selection,people:[person(0,[0x1B]),person(1)],combat:combat,movement:movement)
    let troopItem = try PartyPreparation.review(selection:selection,people:[person(0,[0x1E]),person(1)],combat:combat,movement:movement)
    try check(moraleOnly.troopRecoveryPeople.isEmpty && troopItem.troopRecoveryPeople == [0],"morale-only items do not count as troop recovery")
    var learnedHealer = person(1);learnedHealer.classID = 1
    let skillReport = try PartyPreparation.review(selection:selection,people:[person(0),learnedHealer],combat:combat,movement:movement)
    try check(skillReport.troopRecoveryPeople == [1],"a troop recovery strategy counts only once its original learning level is reached")
    _ = PartyPreparation.sheet(report,onChoose:{_ in})
    try check(try encoder.encode(selection) == selectionBytes,"review and presentation never confirm or mutate the party")
    var cart = ShoppingCart()
    try cart.add(person:0,item:4,count:2);try cart.add(person:1,item:5,count:1)
    let cartReview = try cart.review(people:[giver,receiver],prices:[4:10,5:30],money:100)
    try check(cartReview.map(\.moneyAfter) == [80,50] && cartReview.map(\.slotsAfter) == [1,6],"multi-officer cart forecasts money and each receiver's remaining inventory")
    let firstLine = cart.lines[0].id
    try cart.recordCompleted(1,for:firstLine)
    try check(cart.lines[0].id == firstLine && cart.lines[0].count == 1,"partial cart completion retains only the unprocessed quantity with the same identity")
    try cart.recordCompleted(1,for:firstLine)
    try check(cart.lines.count == 1 && cart.lines[0].person == 1,"completed cart lines cannot replay when processing resumes")
    let cartBefore = cart
    try check(rejects {try cart.recordCompleted(2,for:cart.lines[0].id)} && cart == cartBefore,"invalid completion counts leave the draft unchanged")
    try cart.add(person:1,item:5,count:1)
    try check(cart.lines.count == 1 && cart.lines[0].count == 2,"repeated draft additions merge one recipient/item line instead of duplicating an execution identity")
    let invalidReview = try cart.review(people:[person(1,Array(repeating:4,count:8))],prices:[5:30],money:10)
    try check(invalidReview[0].issues.contains("소지품 빈칸 부족") && invalidReview[0].issues.contains("소지금 부족"),"cart revalidation reports both full inventory and insufficient money")
    let sourceA = String(repeating:"a",count:64),sourceB = String(repeating:"b",count:64)
    var sourceExtras = CampaignExtras()
    let boundID = try sourceExtras.savePreset(name:"현재 편성",people:[0,1],sourceIdentity:sourceA)
    try sourceExtras.savePreset(name:"이름 변경",people:[0,1],id:boundID)
    let boundPreset = sourceExtras.partyPresets[0]
    try check(boundPreset.sourceIdentity == sourceA && boundPreset.sourceIssue(for:sourceA) == nil,"preset rename preserves its exact immutable catalog identity")
    try check(boundPreset.sourceIssue(for:sourceB) != nil && boundPreset.sourceIssue(for:nil) != nil,"different or missing source cannot apply a preset to same-numbered officers")
    let legacyPreset = try decoder.decode(CampaignExtras.PartyPreset.self,from:Data("{\"id\":\"\(UUID().uuidString)\",\"name\":\"이전\",\"people\":[0]}".utf8))
    try check(legacyPreset.people == [0] && legacyPreset.sourceIssue(for:sourceA) != nil,"legacy preset stays readable but requires recreation before applying")
    var commands = OfficerCommandFavorites()
    try commands.set(person:0,actions:[.item(30)],sourceIdentity:sourceA)
    let preservedCommands = commands
    try check(rejects {try commands.set(person:0,actions:[.strategy(0)],sourceIdentity:sourceB)} && commands == preservedCommands,"source-mismatched favorite edits are atomic and retain old data")
    try check(rejects {try commands.set(person:0,actions:[])} && commands == preservedCommands,"omitting identity cannot bypass bound favorite protection")
    try check(try decoder.decode(OfficerCommandFavorites.self,from:encoder.encode(commands)) == commands,"favorite identity and ordered actions round trip together")
    try commands.reset(forSource:sourceB)
    try check(commands.officers.isEmpty && commands.sourceIssue(for:sourceB) == nil,"explicit favorite reset binds an empty list to the selected source")
    var boundCart = ShoppingCart()
    let shopA = ShoppingCart.Context(sourceIdentity:sourceA,chapter:0,city:1,prices:[4:10])
    try boundCart.add(person:0,item:4,count:3,context:shopA)
    let draft = boundCart
    var shopB = shopA;shopB.city = 2
    try check(rejects {try boundCart.add(person:0,item:4,count:1,context:shopB)} && boundCart == draft,"cart cannot cross to another city even with identical prices")
    shopB = shopA;shopB.prices[4] = 20
    try check(rejects {_ = try boundCart.review(people:[giver],prices:shopB.prices,money:100,context:shopB)} && boundCart == draft,"changed prices invalidate approval before any transaction")
    shopB = shopA;shopB.sourceIdentity = sourceB
    try check(rejects {try boundCart.requireContext(shopB)},"cart requires the exact source catalog")
    try boundCart.recordCompleted(1,for:boundCart.lines[0].id)
    let resumed = try boundCart.review(people:[giver],prices:shopA.prices,money:90,context:shopA)
    try check(resumed[0].line.count == 2 && resumed[0].moneyAfter == 70,"per-item cancellation retains only unprocessed quantity for a new approval")
    boundCart.clear();try boundCart.add(person:0,item:4,count:1,context:shopB)
    try check(boundCart.context == shopB && boundCart.lines.count == 1,"explicitly clearing draft allows a fresh source-bound cart")
    print("Management helpers self-tests passed: \(checks)")
}
