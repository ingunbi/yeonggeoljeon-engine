// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Synthetic checks for the shop routine (MAIN36244..36BF6).
func originalShopSelfTests() throws {
    var checks = 0
    func check(_ value:@autoclosure() throws -> Bool,_ reason:String) throws {
        guard try value() else {throw BattleError.invalid("Original shop regression: \(reason)")};checks += 1
    }
    func denied(_ body:() throws -> Void) -> Bool { do { try body();return false } catch { return true } }
    var prices = Array(repeating:0,count:64)
    prices[10] = 30;prices[11] = 5;prices[12] = 255
    let texts = OriginalShopCatalog.Texts(greeting:"hello",question:"what",farewell:"bye",buyPrompt:"buy?",priceTail:" gold\n",shortMoney:"short",
        receiverFull:"full",noItems:"none",giveConfirm:" takes it",buyAgain:" buy more",sellPrompt:"whose",sellEmpty:"empty",
        sellItemPrompt:"which",saleTail:" paid",sellAgain:" sell more",confirm:"ok?",thanks:"thanks",
        giftFull:"%s full",giftChoose:"choose",giftGaveUp:"%s gone",giftDiscarded:"%s out",giftDeclined:"%s no",giftGained:"%s got")
    let catalog = OriginalShopCatalog(format:1,stock:[[],[10,11],[12]],prices:prices,
        merchant:.init(person:374,x:15,y:11,sourceFacing:4,music:15),townMusic:.init(normal:5,special:1,chapter:3,city:11),menu:["buy","sell"],texts:texts,
        particles:.init(price:Array(repeating:" at ",count:64),receiver:Array(repeating:" for",count:64),sale:Array(repeating:" at ",count:64)),
        windows:.init(top:.init(x:232,y:128),list:.init(x:416,y:96,rows:8),description:.init(x:112,y:160,width:320,height:128),
            inventory:.init(x:216,y:160,width:112,height:144,textColumn:28,firstRow:168,rowStep:16)),source:nil,limitations:nil)
    try catalog.validate()
    try check(try catalog.stock(cityBase:1,city:0) == [10,11],"the row is base plus city")
    try check(denied { _ = try catalog.stock(cityBase:2,city:5) },"a row outside the table stops")
    try check(catalog.buyingPrice(10) == 300 && catalog.sellingPrice(10) == 220,"prices follow the source arithmetic")
    try check(catalog.buyingPrice(12) == 2550 && catalog.sellingPrice(12) == 1910,"a full byte keeps its sixteen-bit product")
    var broken = catalog;broken.prices = [1]
    try check(denied { try broken.validate() },"a short price table is refused")

    func people() throws -> OriginalPeople {
        let tables = OriginalCombatTables(format:1,attackBase:Array(repeating:1,count:19),defenseBase:Array(repeating:1,count:19),
            troopBase:Array(repeating:10,count:19),troopGrowth:Array(repeating:10,count:19),physicalSubtypeByClass:Array(repeating:0,count:19),
            terrainDefensePercent:Array(repeating:0,count:256),strategyEnvironmentLookup:Array(repeating:0,count:256),
            items:(0..<64).map{OriginalItemEffect(id:$0,category:15,value:0)})
        // Person 0 and 1 are joined players; 2 is not joined; 3 is another force.
        let rows = (0..<384).map { id -> OriginalPersonDefinition in
            let held = id == 0 ? [255,11,255,255,255,255,255,255] : id == 1 ? Array(repeating:10,count:8) : Array(repeating:255,count:8)
            let flags = id <= 1 ? 0x80 : id == 3 ? 0x81 : 0
            return OriginalPersonDefinition(id:id,name:"p\(id)",classID:0,level:1,experience:0,rawTroops:0,defenseScalar:0,attackScalar:0,
                intellectScalar:0,personality:1,personalScalar:0,itemIDs:held,sourceFlags:flags,sourceRole:1,sourceContext2:0,sourceContext3:0,source:nil)
        }
        return try OriginalPeople(catalog:OriginalPersonCatalog(format:1,people:rows),tables:tables)
    }
    func session(_ stock:[Int] = [10,11]) -> OriginalShopOperation {
        OriginalShopOperation(catalog:catalog,stock:stock,itemName:{"i\($0)"})
    }
    let cast = try people()
    try check(try OriginalShopOperation.customers(cast) == [0,1],"only joined people of the player force are listed")

    // The field lists follow the first person's force, joined people only.
    try check(try cast.companions() == [0,1],"companions share person zero's force and joined bit")
    try check(try cast.giveItem(from:1,to:0,item:10) && (try cast.person(0).itemIDs) == [10,11,255,255,255,255,255,255],"an exchange fills the first empty slot")
    try check((try cast.person(1).itemIDs[0]) == 255,"and clears the giver's first match")
    try cast.setItem(person:1,slot:0,item:10);try cast.setItem(person:0,slot:0,item:255)
    let full = try people()
    for slot in 0..<8 { try full.setItem(person:0,slot:slot,item:11) }
    try check(try !full.giveItem(from:1,to:0,item:10) && (try full.person(1).itemIDs[0]) == 10,"a full receiver changes nothing")

    // Entering and leaving.
    var shop = session(),money = 1000
    try check(try shop.prompt(people:cast) == .init(kind:.say,text:"hello"),"the greeting comes first")
    try shop.answer(0,people:cast,money:&money)
    try check(try shop.prompt(people:cast) == .init(kind:.top,text:"what",rows:["buy","sell"]),"the top menu asks")
    try check(denied { try shop.answer(2,people:cast,money:&money) },"a missing row stops")
    try shop.answer(nil,people:cast,money:&money)
    try check(shop.phase == .farewell,"cancel at the top says goodbye")
    try shop.answer(0,people:cast,money:&money)
    try check(shop.finished && denied { _ = try shop.prompt(people:cast) },"the routine ends after the farewell")

    // Every step keeps the list it came from, so a question can leave it on screen.
    var lists = session(),funds = 1000
    try check(lists.list == .top,"the greeting belongs to the top list")
    try lists.answer(0,people:cast,money:&funds);try lists.answer(0,people:cast,money:&funds)
    try check(lists.list == .stock && lists.receiving == nil,"buying works on the stock")
    try lists.answer(0,people:cast,money:&funds)
    try check(lists.list == .stock,"the offer keeps the stock")
    try lists.answer(1,people:cast,money:&funds)
    try check(lists.list == .customers && lists.receiving == 10,"the receiver list knows its item")
    try lists.answer(1,people:cast,money:&funds)
    try check(lists.phase == .receiverFull(item:10) && lists.list == .customers && lists.receiving == 10,"a full receiver keeps the list")
    var selling = session(),purse = 100
    try selling.answer(0,people:cast,money:&purse);try selling.answer(1,people:cast,money:&purse)
    try check(selling.list == .customers && selling.receiving == nil,"selling starts on the people")
    try selling.answer(1,people:cast,money:&purse)
    try check(selling.list == .held(person:1),"the held list names its owner")
    try selling.answer(0,people:cast,money:&purse)
    try check(selling.list == .held(person:1),"the sale offer keeps the held list")

    // A purchase: confirm, receiver, slot, money, then the next question.
    shop = session();try shop.answer(0,people:cast,money:&money);try shop.answer(0,people:cast,money:&money)
    try check(try shop.prompt(people:cast) == .init(kind:.list,text:"buy?",rows:["i10","i11"]),"the stock is listed by name")
    try shop.answer(0,people:cast,money:&money)
    try check(try shop.prompt(people:cast) == .init(kind:.ask,text:"i10 at 300 gold\nok?",item:10),"the offer shows the price and the item window")
    try check(denied { try shop.answer(nil,people:cast,money:&money) },"a question has no cancel")
    try shop.answer(0,people:cast,money:&money)
    try check(shop.phase == .buying && money == 1000,"no returns to the stock")
    try shop.answer(0,people:cast,money:&money);try shop.answer(1,people:cast,money:&money)
    try check(try shop.prompt(people:cast) == .init(kind:.list,text:"i10 for",rows:["p0","p1"]),"the receiver list follows")
    try shop.answer(nil,people:cast,money:&money)
    try check(shop.phase == .buying,"cancel leaves the receiver list")
    try shop.answer(0,people:cast,money:&money);try shop.answer(1,people:cast,money:&money)
    try shop.answer(0,people:cast,money:&money)
    try check(try shop.prompt(people:cast) == .init(kind:.ask,text:"p0 takes it",inventory:0),"the receiver is confirmed beside its slots")
    try shop.answer(0,people:cast,money:&money)
    try check(shop.phase == .receiver(item:10) && money == 1000,"no returns to the receiver list and writes nothing")
    try shop.answer(0,people:cast,money:&money);try shop.answer(1,people:cast,money:&money)
    try check(money == 700 && (try cast.person(0).itemIDs[0]) == 10,"yes fills the first empty slot and takes the price")
    try check(try shop.prompt(people:cast) == .init(kind:.ask,text:"thanks buy more"),"the next question joins its two source parts")
    try shop.answer(0,people:cast,money:&money)
    try check(shop.phase == .top,"no returns to the top menu")

    // Not enough money, then a full receiver.
    money = 299
    shop = session();try shop.answer(0,people:cast,money:&money);try shop.answer(0,people:cast,money:&money)
    try shop.answer(0,people:cast,money:&money);try shop.answer(1,people:cast,money:&money)
    try check(try shop.prompt(people:cast) == .init(kind:.say,text:"short"),"short money refuses before the receiver")
    try shop.answer(0,people:cast,money:&money)
    try check(shop.phase == .buying && money == 299,"the refusal returns to the stock")
    money = 300
    try shop.answer(0,people:cast,money:&money);try shop.answer(1,people:cast,money:&money)
    try check(shop.phase == .receiver(item:10),"the exact price is enough")
    try shop.answer(1,people:cast,money:&money)
    try check(try shop.prompt(people:cast) == .init(kind:.ask,text:"full"),"a full receiver asks for another")
    try shop.answer(1,people:cast,money:&money)
    try check(shop.phase == .receiver(item:10),"yes returns to the receiver list")
    try shop.answer(1,people:cast,money:&money);try shop.answer(0,people:cast,money:&money)
    try check(shop.phase == .buying,"no returns to the stock")

    // An empty shop still opens its list.
    shop = session([]);try shop.answer(0,people:cast,money:&money);try shop.answer(0,people:cast,money:&money)
    try check(try shop.prompt(people:cast).rows.isEmpty,"an empty row lists nothing")
    try shop.answer(nil,people:cast,money:&money)
    try check(shop.phase == .top,"its cancel returns to the top")

    // Selling.
    let seller = try people()
    money = 9900
    shop = session();try shop.answer(0,people:seller,money:&money);try shop.answer(1,people:seller,money:&money)
    try check(try shop.prompt(people:seller) == .init(kind:.list,text:"whose",rows:["p0","p1"]),"selling starts with the owner")
    try shop.answer(nil,people:seller,money:&money)
    try check(shop.phase == .top,"cancel leaves the owner list")
    try shop.answer(1,people:seller,money:&money);try shop.answer(0,people:seller,money:&money)
    try check(try shop.prompt(people:seller) == .init(kind:.list,text:"which",rows:["i11"]),"only held items are listed")
    try shop.answer(0,people:seller,money:&money)
    try check(try shop.prompt(people:seller) == .init(kind:.ask,text:"i11 at 30 paidok?",item:11),"the sale offers three quarters")
    try shop.answer(0,people:seller,money:&money)
    try check(shop.phase == .sellItems(person:0),"no returns to the item list")
    try shop.answer(0,people:seller,money:&money);try shop.answer(1,people:seller,money:&money)
    try check(money == 9930 && (try seller.person(0).itemIDs[1]) == 255,"yes pays and clears the slot")
    try check(try shop.prompt(people:seller) == .init(kind:.ask,text:"thanks sell more"),"the next sale is offered")
    try shop.answer(1,people:seller,money:&money)
    try check(shop.phase == .selling,"yes returns to the owner list")
    try shop.answer(0,people:seller,money:&money)
    try check(try shop.prompt(people:seller) == .init(kind:.say,text:"empty"),"an owner without items is refused")
    try shop.answer(0,people:seller,money:&money)
    try check(shop.phase == .selling,"the refusal returns to the owner list")
    money = 9950
    try shop.answer(1,people:seller,money:&money);try shop.answer(nil,people:seller,money:&money)
    try check(shop.phase == .top,"cancel at the item list leaves selling")
    try shop.answer(1,people:seller,money:&money);try shop.answer(1,people:seller,money:&money)
    try shop.answer(0,people:seller,money:&money);try shop.answer(1,people:seller,money:&money)
    try check(money == 10000,"sale money stops at the source cap")
    try shop.answer(0,people:seller,money:&money)
    try check(shop.phase == .top,"no returns to the top menu")

    // Citizens: the table row, even plain cells, and the source's draw order.
    let citizens = OriginalCitizenCatalog(format:1,people:(0..<256).map{.init(name:"c\($0)",sprite:$0%2)},
        groups:[.init(cityCount:1,cities:["0":[.init(key:125,ids:[3,4]),.init(key:8,ids:[5])]],lines:["3":"hello"])],source:nil,limitations:nil)
    var walk = Array(repeating:255,count:31*20)
    for y in stride(from:0,to:20,by:2) { for x in stride(from:0,to:31,by:2) { walk[y*31+x] = 127 } }
    var rng = OriginalRNG(state:7),twin = OriginalRNG(state:7)
    let placed = try citizens.placements(group:0,city:0,key:125,width:31,walk:walk,rng:&rng)
    try check(placed.map(\.person) == [1027,1028],"citizens keep their table order above the people ids")
    try check(placed.allSatisfy{($0.x ?? 1)&1 == 0 && ($0.y ?? 1)&1 == 0 && walk[($0.y ?? 0)*31+($0.x ?? 0)] == 127},"they stand on even plain cells")
    let x = try twin.next(bound:0x1F),y = try twin.next(bound:0x13)
    try check(placed[0].x == x+x&1 && placed[0].y == y+y&1,"the first draws choose the cell")
    var empty = OriginalRNG(state:7)
    try check(try citizens.placements(group:0,city:1,key:125,width:31,walk:walk,rng:&empty).isEmpty && empty == OriginalRNG(state:7),"a city without a row draws nothing")
    try check(citizens.say(group:0,citizen:3)?.text == "hello" && citizens.say(group:0,citizen:3)?.speaker == "c3","a citizen speaks its line under its own name")
    try check(citizens.say(group:0,citizen:4) == nil,"a citizen without a line stays silent")
    let sheets = citizens.actors(sprites:["a.png","b.png"])
    try check(sheets["1025"]?.image == "b.png" && sheets.count == 256,"each citizen takes its sprite sheet")
    // Citizens idle, then walk, and stay within three cells of home.
    var wander = OriginalCitizenWander(home:GridPoint(x:10,y:10))
    var draws:[Int] = [],script = [1,3,7]
    let next:(Int) -> Int = { bound in draws.append(bound);return script.removeFirst() }
    try check(!wander.tick(draw:next) && wander.standing && draws == [2] && wander.counter == 0,"a new citizen first stands for a short draw")
    try check(wander.tick(draw:next) && draws == [2,4,16] && wander.direction == 3 && wander.counter == 8,"then it picks a direction and an odd walk")
    try check(wander.allows(GridPoint(x:13,y:7)) && !wander.allows(GridPoint(x:14,y:10)),"home bounds the walk")
    wander.blocked()
    try check(wander.counter == 0,"a blocked step ends the walk")
    print("Original shop self-tests passed: \(checks)")
}
