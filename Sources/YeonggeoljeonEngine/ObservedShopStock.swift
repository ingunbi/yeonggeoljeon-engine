// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct ObservedShopStock:Codable,Equatable {
    struct Item:Codable,Equatable {var id:Int;var name:String;var description:String;var price:Int}
    struct Visit:Codable,Equatable {
        var chapter:Int;var city:Int;var cityName:String;var sequence:Int;var items:[Item]
        var sourceIdentity:String? = nil
        func matchesSource(_ identity:String?) -> Bool {sourceIdentity != nil && identity != nil && sourceIdentity == identity}
    }
    private(set) var visits:[Visit] = []
    private(set) var nextSequence = 0
    private enum CodingKeys:String,CodingKey {case visits,nextSequence}
    init() {}
    init(from decoder:Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        visits = try c.decodeIfPresent([Visit].self,forKey:.visits) ?? []
        nextSequence = try c.decodeIfPresent(Int.self,forKey:.nextSequence) ?? 0
        try validate()
    }
    mutating func observe(chapter:Int,city:Int,cityName:String,items:[Item],sourceIdentity:String? = nil) throws {
        if let previous = visits.first(where:{$0.chapter == chapter && $0.city == city}),previous.items == items,previous.sourceIdentity == sourceIdentity {return}
        guard nextSequence < Int.max else {throw EngineError.invalid("Shop observation sequence limit reached")}
        var next = self
        next.visits.removeAll {$0.chapter == chapter && $0.city == city}
        next.visits.append(.init(chapter:chapter,city:city,cityName:cityName,sequence:nextSequence,items:items,sourceIdentity:sourceIdentity));next.nextSequence += 1
        if next.visits.count > 512 {next.visits.removeFirst()}
        while next.textBytes > 1_000_000,next.visits.count > 1 {next.visits.removeFirst()}
        try next.validate();self = next
    }
    private var textBytes:Int {visits.reduce(0) {$0+$1.cityName.utf8.count+$1.items.reduce(0) {$0+$1.name.utf8.count+$1.description.utf8.count}}}
    func validate() throws {
        guard nextSequence >= 0,visits.count <= 512,textBytes <= 1_000_000,Set(visits.map {"\($0.chapter):\($0.city)"}).count == visits.count,
              Set(visits.map(\.sequence)).count == visits.count,
              visits.allSatisfy({(0...255).contains($0.chapter) && (0...255).contains($0.city) && $0.cityName.count <= 256 &&
                (0..<nextSequence).contains($0.sequence) && ($0.sourceIdentity == nil || SourceCatalogIdentity.valid($0.sourceIdentity!)) && $0.items.count <= 8 &&
                $0.items.allSatisfy({(0..<64).contains($0.id) && (0...2550).contains($0.price) && $0.name.count <= 256 && $0.description.utf8.count <= 8192})}) else {
            throw EngineError.invalid("Observed shop stock is invalid")
        }
    }
}

extension OriginalCampaignHost {
    /// Source identity is independent of the user's installation directory.
    /// Include names, prices, stock and world/city mappings, not game progress.
    func currentShopSourceIdentity() throws -> String {
        struct Facts:Encodable {var combat:OriginalCombatTables;var shop:OriginalShopCatalog;var exploration:OriginalExplorationCatalog}
        return try SourceCatalogIdentity.digest(Facts(combat:source.combat,shop:shopCatalog,exploration:exploration))
    }
    /// Invoke only after preparing the visible current stock list. Opening a
    /// city or a merchant greeting alone is not an observation.
    func observeCurrentShopStock() throws {
        guard let shop,let city = vm.state.currentCity else {throw EngineError.invalid("No current shop stock is visible")}
        let name = exploration.cities.first {$0.chapter == vm.state.chapter && $0.id == city}?.name ?? "도시 \(city)"
        let items = try shop.stock.map {id -> ObservedShopStock.Item in
            guard let item = source.combat.items.first(where:{$0.id == id}) else {throw EngineError.invalid("Observed shop item has no source record")}
            return .init(id:id,name:item.name ?? "도구 \(id)",description:item.description ?? "",price:shopCatalog.buyingPrice(id))
        }
        try extras.observedShops.observe(chapter:vm.state.chapter,city:city,cityName:name,items:items,sourceIdentity:currentShopSourceIdentity())
    }
}
