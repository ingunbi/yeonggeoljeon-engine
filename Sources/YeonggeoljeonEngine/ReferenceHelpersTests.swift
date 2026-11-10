// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func referenceHelpersSelfTests() throws {
    var checks = 0
    func check(_ condition:@autoclosure() throws -> Bool,_ message:String) throws {
        guard try condition() else {throw EngineError.invalid("Reference helpers regression: \(message)")};checks += 1
    }
    func rejects(_ action:() throws -> Void)->Bool {do {try action();return false} catch {return true}}
    let encoder = JSONEncoder(),decoder = JSONDecoder()
    var history = DialogueHistory()
    let first = try history.present(person:1,speaker:"검증 장수",text:"성으로 돌아갑시다.",chapter:0,map:0,record:"synthetic",signature:"first")
    let repeatedDraw = try history.present(person:1,speaker:"검증 장수",text:"성으로 돌아갑시다.",chapter:0,map:0,record:"synthetic",signature:"first")
    try check(first == repeatedDraw && history.entries.count == 1,"redrawing a still-active presentation does not append history")
    var restored = try decoder.decode(DialogueHistory.self,from:encoder.encode(history))
    let resumed = try restored.present(person:1,speaker:"검증 장수",text:"성으로 돌아갑시다.",chapter:0,map:0,record:"synthetic",signature:"first")
    try check(resumed == first && restored.entries.count == 1,"resuming the same displayed line keeps its stable history identity")
    history.finishPresentation()
    let repeatedEvent = try history.present(person:1,speaker:"검증 장수",text:"성으로 돌아갑시다.",chapter:0,map:0,record:"synthetic",signature:"first")
    try check(first != repeatedEvent && history.entries.count == 2,"a second occurrence of identical dialogue is a separate event")
    try history.setBookmark(first,enabled:true)
    for number in 0..<310 {
        history.finishPresentation()
        try history.present(person:nil,speaker:"",text:"합성 대사 \(number)",chapter:1,map:2,record:nil,signature:"row-\(number)")
    }
    try check(history.entries.count == 301 && history.entries.first?.id == first,"a bookmarked old line survives the recent-300 retention boundary")
    try check(history.search(query:"돌아",person:1,bookmarksOnly:true).map(\.id) == [first],"history filtering only finds retained observed lines")
    try check(history.search(chapter:0,map:2).isEmpty,"chapter and map filters do not cross scene boundaries")
    try history.setBookmark(first,enabled:false)
    try check(history.entries.count == 300 && !history.entries.contains {$0.id == first},"unbookmarking an aged entry releases its extra retention slot")
    var full = DialogueHistory()
    for number in 0..<200 {
        full.finishPresentation()
        let id = try full.present(person:1024,speaker:"검증 주민",text:"보관 \(number)",chapter:0,map:0,record:nil,signature:"bookmark-\(number)")
        try full.setBookmark(id,enabled:true)
    }
    full.finishPresentation()
    let extra = try full.present(person:nil,speaker:"",text:"마지막",chapter:0,map:0,record:nil,signature:"extra")
    let before = full
    try check(rejects {try full.setBookmark(extra,enabled:true)} && full == before,"the 201st bookmark is rejected without deleting or changing existing bookmarks")
    try check(try decoder.decode(DialogueHistory.self,from:Data("{}".utf8)).entries.isEmpty,"older snapshots start with no reconstructed dialogue")
    try check(try decoder.decode(DialogueHistory.self,from:encoder.encode(history)) == history,"retained dialogue and bookmarks round-trip as one snapshot value")

    var observations = ObservedShopStock()
    let a = ObservedShopStock.Item(id:2,name:"관측 물품",description:"확인한 효과",price:100)
    try observations.observe(chapter:0,city:1,cityName:"검증 도시",items:[a])
    let oldObservation = observations
    try observations.observe(chapter:0,city:1,cityName:"검증 도시",items:[a])
    try check(observations.nextSequence == 1,"redrawing unchanged stock does not duplicate observations")
    try observations.observe(chapter:0,city:1,cityName:"검증 도시",items:[.init(id:2,name:a.name,description:a.description,price:200)])
    try check(observations.visits.count == 1 && observations.visits[0].items[0].price == 200 && oldObservation.visits[0].items[0].price == 100,"a new observation updates current records while old snapshots retain their actual old price")
    try check(try decoder.decode(ObservedShopStock.self,from:encoder.encode(oldObservation)) == oldObservation,"restoring old observations never imports later shop facts")

    let combat = OriginalCombatTables(format:1,attackBase:Array(repeating:12,count:19),defenseBase:Array(repeating:13,count:19),troopBase:Array(repeating:10,count:19),
        troopGrowth:Array(repeating:10,count:19),physicalSubtypeByClass:Array(repeating:0,count:19),terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),
        items:(0..<64).map {.init(id:$0,category:15,value:0,name:"합성 물품 \($0)")})
    let person = OriginalPersonDefinition(id:0,name:"공개 장수",classID:0,level:10,experience:0,rawTroops:500,defenseScalar:60,attackScalar:70,intellectScalar:50,
        personality:0,personalScalar:0,itemIDs:[0x1B]+Array(repeating:255,count:7),sourceFlags:0x80,sourceRole:0,sourceContext2:0,sourceContext3:0)
    let cardinal = [OriginalAIOffset(dx:0,dy:-1),.init(dx:1,dy:0),.init(dx:0,dy:1),.init(dx:-1,dy:0)]
    let diagonal = [OriginalAIOffset(dx:-1,dy:-1),.init(dx:1,dy:-1),.init(dx:1,dy:1),.init(dx:-1,dy:1)]
    var levels = Array(repeating:Array(repeating:255,count:19),count:36);levels[21][0] = 5;levels[24][0] = 20
    let movement = OriginalMovementProfile(format:1,classMovementTypes:Array(repeating:0,count:19),classMovementBudgets:Array(repeating:4,count:19),attackRangeCodes:Array(repeating:0,count:19),
        movementCosts:Array(repeating:Array(repeating:1,count:256),count:4),cardinalOffsets:cardinal,diagonalOffsets:diagonal,extendedOffsets:cardinal,
        strategyLevelRequirements:levels,strategyMPCosts:Array(repeating:4,count:36),strategyCategories:Array(repeating:0,count:36))
    let index = try GameInfoIndex.build(people:[person],combat:combat,movement:movement,strategyNames:(0..<36).map {"합성 책략 \($0)"},terrainNames:[],observed:observations)
    try check(index.filter {$0.kind == .person}.map(\.id) == [0],"search only indexes caller-provided public officers")
    try check(Set(index.filter {$0.kind == .item}.map(\.id)) == Set([2,0x1B]),"search item IDs come only from held inventory or observed stock")
    try check(Set(index.filter {$0.kind == .strategy}.map(\.id)) == Set([21,24]),"unlearnable abilities do not leak through full source tables")
    try check(GameInfoIndex.search(index,query:"혼란 회복",kind:.strategy,filter:.owned).map(\.id) == [21],"explicit effect tags find learned morale/confusion recovery")
    try check(GameInfoIndex.search(index,query:"병력 회복",filter:.future).map(\.id) == [24],"future learning remains separate from currently learned abilities")
    let noObservation = try GameInfoIndex.build(people:[person],combat:combat,movement:movement,strategyNames:(0..<36).map {"합성 책략 \($0)"},terrainNames:[],observed:ObservedShopStock())
    try check(!noObservation.contains {$0.kind == .item && $0.id == 2},"rebuilding after an older snapshot drops future shop visibility")

    let map = MapResource(image:"synthetic-map.png",width:64,height:32,walkWidth:4,walkHeight:2,walkBytes:[127,5,5,124,128,125,126,127])
    let actors = [ActorState(person:0,position:.init(x:0,y:0),facing:0,phase:0,registration:0,walking:false),
        ActorState(person:2,position:.init(x:2,y:0),facing:0,phase:0,registration:1,walking:false)]
    let nearby = try LocalDestinations.entries(packedMap:0,visible:true,map:map,actors:actors,names:[2:"실제 배치 장수"])
    try check(nearby.filter {$0.person != nil}.map(\.person) == [2],"nearby actors come from actual placements and exclude the player")
    try check(nearby.filter {$0.marker == 5}.map(\.point) == [.init(x:1,y:0),.init(x:2,y:0)],"shared entrance markers preserve separate explicit cells")
    try check(!nearby.contains {$0.marker == 126 || $0.marker == 127 || $0.marker == 128},"plain terrain, blocked terrain and unsupported markers are not invented facilities")
    try check(try LocalDestinations.entries(packedMap:0,visible:false,map:map,actors:actors,names:[:]).isEmpty && LocalDestinations.entries(packedMap:0x1000,visible:true,map:map,actors:actors,names:[:]).isEmpty,"hidden maps and world maps do not expose town destinations")
    let identity = try SourceCatalogIdentity.digest(["b":2,"a":1]),same = try SourceCatalogIdentity.digest(["a":1,"b":2])
    try check(identity == same && SourceCatalogIdentity.valid(identity),"source identity is independent of dictionary insertion order")
    try check(!oldObservation.visits[0].matchesSource(identity),"legacy observations have no current-source navigation permission")
    var identified = ObservedShopStock()
    try identified.observe(chapter:0,city:1,cityName:"검증 도시",items:[a],sourceIdentity:identity)
    try check(identified.visits[0].matchesSource(identity) && !identified.visits[0].matchesSource(String(repeating:"f",count:64)),"shop links require exact current source identity")
    try check(try decoder.decode(ObservedShopStock.self,from:encoder.encode(identified)) == identified,"observation source identity round-trips with campaign facts")
    let historical = try GameInfoIndex.build(people:[person],combat:combat,movement:movement,strategyNames:(0..<36).map {"합성 책략 \($0)"},terrainNames:[],observed:identified,sourceIdentity:String(repeating:"f",count:64))
    try check(historical.first {$0.kind == .item && $0.id == 2}?.name == a.name && historical.first {$0.kind == .item && $0.id == 2}?.tags.isEmpty == true,"mismatched observed items retain recorded text without deriving current catalog effects")
    print("Reference helpers self-tests passed: \(checks)")
}
