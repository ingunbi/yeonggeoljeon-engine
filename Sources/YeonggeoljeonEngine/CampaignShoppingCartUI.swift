// SPDX-License-Identifier: GPL-3.0-only
import AppKit

extension CampaignManagementUI {
    func currentCartContext() throws -> ShoppingCart.Context {
        guard let shop = host.shop,let city = host.vm.state.currentCity else {throw EngineError.invalid("방문 중인 상점이 없습니다.")}
        var prices:[Int:Int] = [:]
        for item in shop.stock {prices[item] = host.shopCatalog.buyingPrice(item)}
        let context = ShoppingCart.Context(sourceIdentity:try host.currentShopSourceIdentity(),chapter:host.vm.state.chapter,city:city,prices:prices)
        try context.validate();return context
    }
    func reviewCart(_ cart:ShoppingCart) throws -> [ShoppingCart.Review] {
        guard let shop = host.shop,let money = host.money else {throw EngineError.invalid("방문 중인 상점이 없습니다.")}
        var prices:[Int:Int] = [:]
        for item in shop.stock {prices[item] = host.shopCatalog.buyingPrice(item)}
        return try cart.review(people:OriginalShopOperation.customers(host.people).map {try host.people.person($0)},prices:prices,money:money,context:currentCartContext())
    }
    func showShoppingCart(onClose:@escaping()->Void) {
        do {
            let review = try reviewCart(purchaseCart)
            let total = review.reduce(0) {$0+$1.price*$1.line.count}
            let values:[CanvasSheet.Row] = review.map {row in
                .init(label:itemName(row.line.item),value:name(row.line.person)+" · \(row.line.count)개",warns:!row.issues.isEmpty,
                    detail:.init(heading:itemName(row.line.item),body:row.issues.isEmpty ? "현재 조건에서 구입할 수 있습니다." : row.issues.joined(separator:" · "),
                        facts:[("받을 장수",name(row.line.person)),("수량","\(row.line.count)개"),("구입가","\(row.price*row.line.count)"),
                            ("장수의 남을 빈칸",String(max(0,row.slotsAfter))),("순서대로 구입 후 소지금",row.moneyAfter < 0 ? "부족" : String(row.moneyAfter))]))
            }
            rows(title:"구매 장바구니",line:"\(review.count)항목 · 총 \(total) · 닫으면 미처리 초안은 사라집니다.",values:values,
                buttons:["물품 추가","전체 구입","닫기"],onButton:{button in
                    switch button {
                    case 0:self.showBulkPeople(buying:true,onClose:{self.showShoppingCart(onClose:onClose)},onFinished:onClose)
                    case 1:
                        guard !self.cartExecuting,!review.isEmpty else {self.showShoppingCart(onClose:onClose);return}
                        do {
                            let refreshed = try self.reviewCart(self.purchaseCart)
                            guard refreshed.allSatisfy({$0.issues.isEmpty}) else {throw EngineError.invalid(refreshed.flatMap(\.issues).joined(separator:" · "))}
                            self.cartApprovedContext = try self.currentCartContext()
                            self.cartExecuting = true;let id = UUID();self.cartExecutionID = id
                            self.executeCartStep(id:id,receipts:[],onClose:onClose)
                        } catch {self.failure(error,returning:{self.showShoppingCart(onClose:onClose)})}
                    default:onClose()
                    }
                }) {index in
                    guard let index,review.indices.contains(index) else {onClose();return}
                    let line = review[index].line
                    self.overlay.show(CanvasMenu(title:self.itemName(line.item)+" · "+self.name(line.person),options:[.init(label:"장바구니에서 빼기"),.init(label:"취소")],horizontal:true,cancellable:true) {choice in
                        if choice == 0 {self.purchaseCart.remove(line.id)}
                        self.showShoppingCart(onClose:onClose)
                    })
                }
        } catch {
            overlay.show(CanvasMenu(title:"장바구니 확인 필요",options:[.init(label:"미처리 장바구니 비우기"),.init(label:"돌아가기")],cancellable:true,footer:error.localizedDescription) {choice in
                if choice == 0 {self.purchaseCart.clear();self.showShoppingCart(onClose:onClose)} else {onClose()}
            })
        }
    }
    private func cartResult(_ receipts:[String],message:String,onClose:@escaping()->Void) {
        cartExecuting = false;cartExecutionID = nil;cartApprovedContext = nil
        rows(title:"장바구니 처리 결과",line:message,values:receipts.map {.init(label:$0)},buttons:["미처리 항목 보기","닫기"],onButton:{button in
            if button == 0 {self.showShoppingCart(onClose:onClose)} else {onClose()}
        }) {_ in self.showShoppingCart(onClose:onClose)}
    }
    private func executeCartStep(id:UUID,receipts:[String],onClose:@escaping()->Void) {
        guard cartExecuting,cartExecutionID == id else {return}
        if overlay.isSuspended {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [weak self] in self?.executeCartStep(id:id,receipts:receipts,onClose:onClose) }
            return
        }
        guard let line = purchaseCart.lines.first else {cartResult(receipts,message:"모든 구입이 완료됐습니다.",onClose:onClose);return}
        do {
            let current = try currentCartContext()
            guard current == cartApprovedContext else {throw EngineError.invalid("확정 후 상점이나 가격이 바뀌어 멈췄습니다. 남은 거래를 다시 확인해 주세요.")}
            try purchaseCart.requireContext(current)
            // One source transaction per run-loop turn gives cancellation a
            // boundary even inside a multi-quantity line.
            let result = try host.performShopPurchase(item:line.item,person:line.person,count:1)
            try purchaseCart.recordCompleted(result.completed,for:line.id)
            let next = receipts+[name(line.person)+" · "+itemName(line.item)+" · \(result.completed)개 완료"]
            if let failure = result.failure {
                cartResult(next,message:"중단: "+failure+" · 완료 거래는 유지하고 미처리 수량만 남겼습니다.",onClose:onClose);return
            }
            guard result.completed == 1 else {cartResult(next,message:"거래를 처리하지 못해 멈췄습니다.",onClose:onClose);return}
            rows(title:"장바구니 구입 중",line:"\(purchaseCart.lines.count)항목 남음 · 완료한 거래는 되돌리지 않습니다.",values:next.map {.init(label:$0)},
                buttons:["남은 거래 취소"],onButton:{_ in self.cartResult(next,message:"남은 거래를 취소했습니다. 완료 거래는 유지됩니다.",onClose:onClose)}) {_ in
                    self.cartResult(next,message:"남은 거래를 취소했습니다. 완료 거래는 유지됩니다.",onClose:onClose)
                }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [weak self] in self?.executeCartStep(id:id,receipts:next,onClose:onClose) }
        } catch {cartResult(receipts,message:"중단: \(error) · 미처리 수량만 남겼습니다.",onClose:onClose)}
    }
}
