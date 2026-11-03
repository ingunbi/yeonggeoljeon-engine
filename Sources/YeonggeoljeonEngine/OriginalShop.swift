// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Local shop facts exported by tools/prepare_shop.py from MAIN and BAKDATA.
struct OriginalShopCatalog:Codable {
    /// MAIN24BD6 spawns the merchant and starts its song in a palace map whose
    /// type DS:3838[index] equals `roomType` (indices 10 and 11).
    struct Merchant:Codable {
        var person:Int; var x:Int; var y:Int; var sourceFacing:Int; var music:Int
        var roomType:Int? = nil; var roomTypes:[Int]? = nil
        func hosts(palaceIndex index:Int) -> Bool {
            guard let key = roomType,let types = roomTypes,types.indices.contains(index) else { return false }
            return types[index] == key
        }
    }
    struct TownMusic:Codable { var normal:Int; var special:Int; var chapter:Int; var city:Int }
    struct Particles:Codable { var price:[String]; var receiver:[String]; var sale:[String] }
    struct Texts:Codable {
        var greeting,question,farewell,buyPrompt,priceTail,shortMoney,receiverFull,noItems,giveConfirm:String
        var buyAgain,sellPrompt,sellEmpty,sellItemPrompt,saleTail,sellAgain,confirm,thanks:String
        var giftFull,giftChoose,giftGaveUp,giftDiscarded,giftDeclined,giftGained:String
    }
    struct Top:Codable { var x:Int; var y:Int }
    struct List:Codable { var x:Int; var y:Int; var rows:Int }
    struct Description:Codable { var x:Int; var y:Int; var width:Int; var height:Int }
    struct Inventory:Codable {
        var x:Int; var y:Int; var width:Int; var height:Int
        var textColumn:Int; var firstRow:Int; var rowStep:Int
    }
    struct Windows:Codable { var top:Top; var list:List; var description:Description; var inventory:Inventory }
    var format:Int
    var stock:[[Int]]
    var prices:[Int]
    var merchant:Merchant
    var townMusic:TownMusic
    /// MAIN20F01: a default world entry starts this song.
    var worldMusic:Int? = nil
    var menu:[String]
    var texts:Texts
    var particles:Particles
    var windows:Windows
    var source:JSONValue?
    var limitations:[String]?

    static func load(from url:URL) throws -> OriginalShopCatalog {
        let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
        guard let size = attributes[.size] as? NSNumber,(1...1024*1024).contains(size.intValue) else {
            throw EngineError.invalid("Original shop catalog exceeds its supported input size")
        }
        let value = try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
        try value.validate();return value
    }
    func validate() throws {
        guard format == 1,prices.count == 64,menu.count == 2,prices.allSatisfy({(0...255).contains($0)}),
              stock.allSatisfy({$0.count <= 8 && $0.allSatisfy{(0..<64).contains($0)}}),
              [particles.price,particles.receiver,particles.sale].allSatisfy({$0.count == 64}),
              (1..<384).contains(merchant.person),(0..<8).contains(merchant.sourceFacing) else {
            throw EngineError.invalid("Original shop catalog does not match its examined source shape")
        }
    }
    /// MAIN36B47..36B61: the row is the player city plus the chapter's city base.
    func stock(cityBase:Int,city:Int) throws -> [Int] {
        guard stock.indices.contains(cityBase+city) else { throw EngineError.invalid("Original shop has no stock row for this city") }
        return stock[cityBase+city]
    }
    /// MAIN36C06 reads item+0E; the buying price is that byte times ten.
    func buyingPrice(_ item:Int) -> Int { prices[item]*10 }
    /// MAIN36981..36988: three quarters of the byte, then times ten.
    func sellingPrice(_ item:Int) -> Int { ((prices[item]*3)>>2)*10 }
}

/// One step shown to the player: a timed line, a yes/no line or a list that
/// opens under the merchant's line.
struct OriginalShopPrompt:Equatable {
    enum Kind:Equatable { case say,ask,top,list }
    var kind:Kind
    var text:String
    var rows:[String] = []
    /// The item shown in the description window while the question is open.
    var item:Int? = nil
    /// The person whose eight slots are shown beside the question.
    var inventory:Int? = nil
}

/// The list a step works on. Questions and refusals keep the list they came from.
enum OriginalShopList:Hashable { case top,stock,customers,held(person:Int) }

/// MAIN2CB4:3602 (0x36B42), its buying loop 0x362DA and its selling loop
/// 0x367DC. Each case is one blocking call of the source routine; an answer
/// is the value that call returned.
struct OriginalShopOperation {
    enum Phase:Equatable {
        case greeting,top,farewell
        case buying,buyConfirm(item:Int),shortMoney
        case receiver(item:Int),receiverFull(item:Int),receiverConfirm(item:Int,person:Int),buyAgain
        case selling,sellEmpty,sellItems(person:Int),sellConfirm(person:Int,slot:Int),sellAgain
        case finished
    }
    let catalog:OriginalShopCatalog
    let stock:[Int]
    let itemName:(Int) -> String
    private(set) var phase = Phase.greeting
    var finished:Bool { phase == .finished }
    var list:OriginalShopList {
        switch phase {
        case .greeting,.top,.farewell,.finished:return .top
        case .buying,.buyConfirm,.shortMoney,.buyAgain:return .stock
        case .receiver,.receiverFull,.receiverConfirm,.selling,.sellEmpty,.sellAgain:return .customers
        case .sellItems(let person),.sellConfirm(let person,_):return .held(person:person)
        }
    }
    /// The item a receiver is being chosen for.
    var receiving:Int? {
        switch phase {
        case .receiver(let item),.receiverFull(let item),.receiverConfirm(let item,_):return item
        default:return nil
        }
    }

    /// MAIN365B7..365D9: joined people of the player force, in person order.
    static func customers(_ people:OriginalPeople) throws -> [Int] {
        try (0..<384).filter {
            let flags = try people.person($0).sourceFlags
            return flags&31 == 0 && flags&0x80 != 0
        }
    }
    private func heldSlots(_ person:Int,_ people:OriginalPeople) throws -> [Int] {
        try people.person(person).itemIDs.indices.filter { try people.person(person).itemIDs[$0] != 255 }
    }
    private func customerRows(_ people:OriginalPeople) throws -> [String] {
        try Self.customers(people).map { try people.person($0).name }
    }
    private func offer(_ item:Int,_ word:[String],_ tail:String,price:Int) -> String {
        "\(itemName(item))\(word[item])\(price)\(tail)\(catalog.texts.confirm)"
    }
    func prompt(people:OriginalPeople) throws -> OriginalShopPrompt {
        let texts = catalog.texts
        switch phase {
        case .greeting:return .init(kind:.say,text:texts.greeting)
        case .top:return .init(kind:.top,text:texts.question,rows:catalog.menu)
        case .farewell:return .init(kind:.say,text:texts.farewell)
        case .buying:return .init(kind:.list,text:texts.buyPrompt,rows:stock.map(itemName))
        case .buyConfirm(let item):
            return .init(kind:.ask,text:offer(item,catalog.particles.price,texts.priceTail,price:catalog.buyingPrice(item)),item:item)
        case .shortMoney:return .init(kind:.say,text:texts.shortMoney)
        case .receiver(let item):
            return .init(kind:.list,text:itemName(item)+catalog.particles.receiver[item],rows:try customerRows(people))
        case .receiverFull:return .init(kind:.ask,text:texts.receiverFull)
        case .receiverConfirm(_,let person):
            return .init(kind:.ask,text:try people.person(person).name+texts.giveConfirm,inventory:person)
        case .buyAgain:return .init(kind:.ask,text:texts.thanks+texts.buyAgain)
        case .selling:return .init(kind:.list,text:texts.sellPrompt,rows:try customerRows(people))
        case .sellEmpty:return .init(kind:.say,text:texts.sellEmpty)
        case .sellItems(let person):
            let held = try people.person(person).itemIDs
            return .init(kind:.list,text:texts.sellItemPrompt,rows:try heldSlots(person,people).map{itemName(held[$0])})
        case .sellConfirm(let person,let slot):
            let item = try people.person(person).itemIDs[slot]
            return .init(kind:.ask,text:offer(item,catalog.particles.sale,texts.saleTail,price:catalog.sellingPrice(item)),item:item)
        case .sellAgain:return .init(kind:.ask,text:texts.thanks+texts.sellAgain)
        case .finished:throw EngineError.invalid("Original shop has ended")
        }
    }
    private func row(_ value:Int?,in count:Int) throws -> Int? {
        guard let value = value else { return nil }
        guard (0..<count).contains(value) else { throw EngineError.invalid("Original shop list has no such row") }
        return value
    }
    private func yes(_ value:Int?) throws -> Bool {
        guard let value = value,[0,1].contains(value) else { throw EngineError.invalid("Original shop question needs a yes or no answer") }
        return value == 1
    }
    /// A list answer is a row or nil for cancel, a question answer is 1 or 0.
    /// A timed line takes any answer. Money follows the source writes.
    mutating func answer(_ value:Int?,people:OriginalPeople,money:inout Int) throws {
        switch phase {
        case .greeting:phase = .top
        case .top:
            guard let chosen = try row(value,in:catalog.menu.count) else { phase = .farewell;return }
            phase = chosen == 0 ? .buying : .selling
        case .farewell:phase = .finished
        case .buying:
            guard let chosen = try row(value,in:stock.count) else { phase = .top;return }
            phase = .buyConfirm(item:stock[chosen])
        case .buyConfirm(let item):
            guard try yes(value) else { phase = .buying;return }
            // MAIN364BD compares before the receiver is chosen.
            phase = money < catalog.buyingPrice(item) ? .shortMoney : .receiver(item:item)
        case .shortMoney:phase = .buying
        case .receiver(let item):
            let people2 = try Self.customers(people)
            guard let chosen = try row(value,in:people2.count) else { phase = .buying;return }
            let person = people2[chosen]
            phase = try people.person(person).itemIDs.contains(255) ? .receiverConfirm(item:item,person:person) : .receiverFull(item:item)
        case .receiverFull(let item):phase = try yes(value) ? .receiver(item:item) : .buying
        case .receiverConfirm(let item,let person):
            guard try yes(value) else { phase = .receiver(item:item);return }
            guard let slot = try people.person(person).itemIDs.firstIndex(of:255) else { throw EngineError.invalid("Original shop receiver lost its empty slot") }
            try people.setItem(person:person,slot:slot,item:item)
            money -= catalog.buyingPrice(item)
            phase = .buyAgain
        case .buyAgain:phase = try yes(value) ? .buying : .top
        case .selling:
            let people2 = try Self.customers(people)
            guard let chosen = try row(value,in:people2.count) else { phase = .top;return }
            let person = people2[chosen]
            phase = try heldSlots(person,people).isEmpty ? .sellEmpty : .sellItems(person:person)
        case .sellEmpty:phase = .selling
        case .sellItems(let person):
            let slots = try heldSlots(person,people)
            guard let chosen = try row(value,in:slots.count) else { phase = .top;return }
            phase = .sellConfirm(person:person,slot:slots[chosen])
        case .sellConfirm(let person,let slot):
            guard try yes(value) else { phase = .sellItems(person:person);return }
            // CF5:224C caps the money word at 10000 (0x15B9F..0x15BA8).
            money = min(10000,money+catalog.sellingPrice(try people.person(person).itemIDs[slot]))
            try people.setItem(person:person,slot:slot,item:255)
            phase = .sellAgain
        case .sellAgain:phase = try yes(value) ? .selling : .top
        case .finished:throw EngineError.invalid("Original shop has ended")
        }
    }
}
