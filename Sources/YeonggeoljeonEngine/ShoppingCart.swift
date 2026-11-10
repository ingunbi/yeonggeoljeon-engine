// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Session-only purchase draft. Completed quantities are removed immediately;
/// a cancelled or failed later line cannot replay them on the next attempt.
struct ShoppingCart:Equatable {
    struct Context:Equatable {
        var sourceIdentity:String;var chapter:Int;var city:Int;var prices:[Int:Int]
        func validate() throws {
            guard SourceCatalogIdentity.valid(sourceIdentity),chapter >= 0,city >= 0,
                  prices.count <= 64,prices.allSatisfy({(0..<64).contains($0.key) && (0...2550).contains($0.value)}) else {throw EngineError.invalid("장바구니의 상점 자료가 올바르지 않습니다.")}
        }
    }
    struct Line:Equatable,Identifiable {var id:UUID;var person:Int;var item:Int;var count:Int}
    struct Review:Equatable {var line:Line;var price:Int;var slotsAfter:Int;var moneyAfter:Int;var issues:[String]}
    private(set) var lines:[Line] = []
    private(set) var context:Context?
    func requireContext(_ current:Context?) throws {
        try current?.validate()
        guard lines.isEmpty || context == current else {throw EngineError.invalid("상점이나 가격이 변경되었습니다. 미처리 장바구니를 비우고 현재 상점에서 다시 확인해 주세요.")}
    }
    mutating func add(person:Int,item:Int,count:Int,context:Context? = nil) throws {
        try requireContext(context)
        guard (0..<384).contains(person),(0..<64).contains(item),(1...8).contains(count) else {throw EngineError.invalid("장바구니 수량과 장수를 확인해 주세요.")}
        var next = self
        if next.lines.isEmpty {next.context = context}
        if let index = next.lines.firstIndex(where:{$0.person == person && $0.item == item}) {
            guard next.lines[index].count+count <= 8 else {throw EngineError.invalid("한 장수의 같은 물품은 최대 8개까지 담을 수 있습니다.")}
            next.lines[index].count += count
        } else {
            guard next.lines.count < 20 else {throw EngineError.invalid("장바구니는 최대 20개 항목까지 담을 수 있습니다.")}
            next.lines.append(.init(id:UUID(),person:person,item:item,count:count))
        }
        self = next
    }
    mutating func remove(_ id:UUID) {lines.removeAll {$0.id == id}}
    mutating func clear() {lines = [];context = nil}
    mutating func recordCompleted(_ count:Int,for id:UUID) throws {
        guard let index = lines.firstIndex(where:{$0.id == id}),(0...lines[index].count).contains(count) else {throw EngineError.invalid("장바구니 완료 수량이 맞지 않습니다.")}
        lines[index].count -= count
        if lines[index].count == 0 {lines.remove(at:index)}
    }
    func review(people:[OriginalPersonDefinition],prices:[Int:Int],money:Int,context:Context? = nil) throws -> [Review] {
        try requireContext(context)
        if let context,context.prices != prices {throw EngineError.invalid("장바구니 가격을 다시 확인해 주세요.")}
        guard (0...10000).contains(money),Set(people.map(\.id)).count == people.count,
              prices.allSatisfy({(0..<64).contains($0.key) && (0...2550).contains($0.value)}) else {throw EngineError.invalid("장바구니의 현재 상점 자료가 올바르지 않습니다.")}
        var slots:[Int:Int] = [:],remaining = money,result:[Review] = []
        for person in people {try OfficerComparison.validatePerson(person);slots[person.id] = person.itemIDs.filter {$0 == 255}.count}
        for line in lines {
            var issues:[String] = []
            if slots[line.person] == nil {issues.append("현재 수령 불가")}
            if prices[line.item] == nil {issues.append("현재 상점에서 판매하지 않음")}
            let price = prices[line.item] ?? 0,free = (slots[line.person] ?? 0)-line.count
            remaining -= price*line.count;slots[line.person] = free
            if free < 0 {issues.append("소지품 빈칸 부족")}
            if remaining < 0 {issues.append("소지금 부족")}
            result.append(.init(line:line,price:price,slotsAfter:free,moneyAfter:remaining,issues:issues))
        }
        return result
    }
}
