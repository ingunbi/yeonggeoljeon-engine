// SPDX-License-Identifier: GPL-3.0-only
import AppKit

extension CampaignManagementUI {
    func showDialogueHistory(query:String = "",person:Int? = nil,chapter:Int? = nil,map:Int? = nil,record:String? = nil,
                             bookmarksOnly:Bool = false,selected:Int? = nil,onClose:@escaping()->Void) {
        let entries = host.extras.dialogueHistory.search(query:query,person:person,chapter:chapter,map:map,record:record,bookmarksOnly:bookmarksOnly)
        let selection = min(max(selected ?? entries.count-1,0),max(0,entries.count-1))
        let back = {self.showDialogueHistory(query:query,person:person,chapter:chapter,map:map,record:record,bookmarksOnly:bookmarksOnly,selected:selection,onClose:onClose)}
        let values:[CanvasSheet.Row] = entries.map {entry in
            .init(label:(entry.bookmarked ? "★ " : "")+(entry.speaker.isEmpty ? "해설" : entry.speaker),value:String(entry.text.prefix(18)),
                detail:.init(heading:entry.speaker.isEmpty ? "해설" : entry.speaker,body:entry.text,facts:[("장",entry.chapter == 0 ? "서장" : "제\(entry.chapter)장"),("표시 순서","\(entry.sequence+1)"),("북마크",entry.bookmarked ? "설정됨" : "없음")]))
        }
        rows(title:"대사 기록",line:entries.isEmpty ? "보관된 대사가 없거나 검색 조건에 맞는 항목이 없습니다. 이전 저장의 대사는 복원하지 않습니다." : "실제 표시한 대사만 검색합니다."+(query.isEmpty ? "" : " 검색: "+query),values:values,selected:selection,
            buttons:["검색","인물","장면",bookmarksOnly ? "전체 기록" : "★만","닫기"],onButton:{button in
                switch button {
                case 0:
                    let text = self.textInput(title:"대사 검색",message:"말한 인물이나 문장 일부를 입력하세요. 비우면 전체를 표시합니다.",value:query)
                    self.showDialogueHistory(query:text ?? query,person:person,chapter:chapter,map:map,record:record,bookmarksOnly:bookmarksOnly,onClose:onClose)
                case 1:
                    let ids = Array(Set(self.host.extras.dialogueHistory.entries.compactMap(\.person))).sorted()
                    let names = ids.map {id in self.host.extras.dialogueHistory.entries.first {$0.person == id}?.speaker ?? "인물 \(id)"}
                    self.rows(title:"대사 인물 필터",values:[.init(label:"모든 인물")]+names.map {.init(label:$0)}) {index in
                        guard let index else {back();return}
                        self.showDialogueHistory(query:query,person:index == 0 ? nil : ids[index-1],chapter:chapter,map:map,record:record,bookmarksOnly:bookmarksOnly,onClose:onClose)
                    }
                case 2:
                    var seen = Set<String>()
                    let scenes = self.host.extras.dialogueHistory.entries.filter {seen.insert("\($0.chapter):\($0.map):\($0.record ?? "")").inserted}
                    self.rows(title:"대사 장면 필터",values:[.init(label:"모든 장면")]+scenes.map {.init(label:$0.chapter == 0 ? "서장" : "제\($0.chapter)장",value:String($0.text.prefix(24)))}) {index in
                        guard let index else {back();return}
                        let entry = index == 0 ? nil : scenes[index-1]
                        self.showDialogueHistory(query:query,person:person,chapter:entry?.chapter,map:entry?.map,record:entry?.record,bookmarksOnly:bookmarksOnly,onClose:onClose)
                    }
                case 3:self.showDialogueHistory(query:query,person:person,chapter:chapter,map:map,record:record,bookmarksOnly:!bookmarksOnly,onClose:onClose)
                default:onClose()
                }
            }) {index in
                guard let index,entries.indices.contains(index) else {onClose();return}
                let entry = entries[index]
                let back = {self.showDialogueHistory(query:query,person:person,chapter:chapter,map:map,record:record,bookmarksOnly:bookmarksOnly,selected:index,onClose:onClose)}
                self.rows(title:entry.speaker.isEmpty ? "해설" : entry.speaker,values:[.init(label:"대사 전문",detail:.init(heading:entry.speaker,body:entry.text))],buttons:[entry.bookmarked ? "★ 해제" : "★ 보관","돌아가기"],onButton:{button in
                    guard button == 0 else {back();return}
                    do {try self.host.extras.dialogueHistory.setBookmark(entry.id,enabled:!entry.bookmarked);back()}
                    catch {self.failure(error,returning:back)}
                }) {_ in back()}
            }
    }
    func showObservedShops(query:String = "",selected:Int = 0,onClose:@escaping()->Void) {
        let sourceIdentity = try? host.currentShopSourceIdentity()
        let needle = query.trimmingCharacters(in:.whitespacesAndNewlines)
        // Plain loops and explicit types: older compilers time out on one long chain here.
        var records:[(ObservedShopStock.Visit,ObservedShopStock.Item)] = []
        for visit in host.extras.observedShops.visits.sorted(by:{ $0.sequence > $1.sequence }) {
            for item in visit.items {
                let text:String = visit.cityName+" "+item.name+" "+item.description
                if needle.isEmpty || text.range(of:needle,options:[.caseInsensitive,.diacriticInsensitive]) != nil { records.append((visit,item)) }
            }
        }
        var values:[CanvasSheet.Row] = []
        for (visit,item) in records {
            let match:String = visit.matchesSource(sourceIdentity) ? "현재 원본 자료와 일치합니다." : "자료가 다르거나 식별값이 없어 현재 도시로 연결하지 않습니다."
            let chapter:String = visit.chapter == 0 ? "서장" : "제\(visit.chapter)장"
            let facts:[(label:String,value:String)] = [("도시",visit.cityName),("장",chapter),("확인한 가격",String(item.price)),("관측 순서","\(visit.sequence+1)")]
            let detail = CanvasSheet.Detail(heading:item.name,body:item.description,list:["마지막 확인 정보이며 현재 재고·가격을 보장하지 않습니다.",match],facts:facts)
            values.append(CanvasSheet.Row(label:item.name,value:visit.cityName+" · \(item.price)",detail:detail))
        }
        rows(title:"방문 상점 판매품 기록",line:records.isEmpty ? "실제로 확인한 판매품 기록이 없거나 검색 결과가 없습니다." : "방문해서 본 판매 목록만 표시합니다.",values:values,selected:selected,buttons:["검색","닫기"],onButton:{button in
            guard button == 0 else {onClose();return}
            let text = self.textInput(title:"상점 기록 검색",message:"물품 이름·효과·도시를 입력하세요.",value:query)
            self.showObservedShops(query:text ?? query,onClose:onClose)
        }) {index in
            guard let index,records.indices.contains(index) else {onClose();return}
            let (visit,item) = records[index]
            let back = {self.showObservedShops(query:query,selected:index,onClose:onClose)}
            let state = self.host.vm.state
            let reachable = visit.matchesSource(sourceIdentity) && state.packedMap>>12 == 1 && state.chapter == visit.chapter &&
                self.host.exploration.destinations(chapter:state.chapter,flags:state.cityFlags ?? []).contains {$0.id == visit.city}
            self.rows(title:item.name,line:visit.cityName+" · 마지막 확인 가격 \(item.price)",values:[values[index]],buttons:reachable ? ["도시로 이동","돌아가기"] : ["돌아가기"],onButton:{button in
                guard reachable,button == 0 else {back();return}
                do {try self.host.travel(toCity:visit.city);onClose()}
                catch {self.failure(error,returning:back)}
            }) {_ in back()}
        }
    }
    func showInfoSearch(query:String = "",kind:GameInfoIndex.Kind? = nil,filter:GameInfoIndex.Filter = .all,selected:Int = 0,onClose:@escaping()->Void) {
        do {
            let commands = host.story.screens?.battle.commands
            let index = try GameInfoIndex.build(people:host.people.companions().map {try host.people.person($0)},combat:host.source.combat,movement:host.source.movement,
                strategyNames:commands?.strategyNames ?? [],terrainNames:commands?.terrain.names ?? [],observed:host.extras.observedShops,sourceIdentity:try host.currentShopSourceIdentity())
            let matches = GameInfoIndex.search(index,query:query,kind:kind,filter:filter)
            let values:[CanvasSheet.Row] = matches.map {entry in
                .init(label:entry.name,value:entry.kind.rawValue+" · "+(entry.current ? "보유·습득" : entry.future ? "향후 습득" : "관측"),
                    detail:.init(heading:entry.name,body:entry.body,list:entry.owners.map {self.name($0)},facts:[("공개 근거",entry.source),("효과",entry.tags.joined(separator:" · "))],strategy:entry.strategy))
            }
            rows(title:"장수·물품·책략 검색",line:query.isEmpty ? "현재 동료·소지품·습득표·방문 상점 범위입니다." : "검색: "+query,values:values,selected:selected,
                buttons:["검색",kind?.rawValue ?? "모든 종류",filter.rawValue,"닫기"],onButton:{button in
                    switch button {
                    case 0:
                        let text = self.textInput(title:"정보 검색",message:"이름이나 효과를 입력하세요. 예: 병력 회복, 범위 공격, 혼란 해제",value:query)
                        self.showInfoSearch(query:text ?? query,kind:kind,filter:filter,onClose:onClose)
                    case 1:
                        let kinds:[GameInfoIndex.Kind?] = [nil]+GameInfoIndex.Kind.allCases.map {Optional($0)}
                        let position = kinds.firstIndex(of:kind) ?? 0
                        self.showInfoSearch(query:query,kind:kinds[(position+1)%kinds.count],filter:filter,onClose:onClose)
                    case 2:
                        let filters = GameInfoIndex.Filter.allCases,position = filters.firstIndex(of:filter) ?? 0
                        self.showInfoSearch(query:query,kind:kind,filter:filters[(position+1)%filters.count],onClose:onClose)
                    default:onClose()
                    }
                }) {row in
                    guard let row,matches.indices.contains(row) else {onClose();return}
                    let entry = matches[row]
                    let back = {self.showInfoSearch(query:query,kind:kind,filter:filter,selected:row,onClose:onClose)}
                    if entry.kind == .person {self.showOfficerSummary(person:entry.id,onClose:back)}
                    else {self.rows(title:entry.name,values:[values[row]],buttons:["돌아가기"],onButton:{_ in back()}) {_ in back()}}
                }
        } catch {failure(error,returning:onClose)}
    }
    func showNearby(selected:Int = 0,onClose:@escaping()->Void) {
        do {
            guard let map = host.stage.currentMap else {throw EngineError.invalid("현재 지도가 없습니다.")}
            var names:[Int:String] = [:]
            for id in host.stage.actors.keys {
                if id >= OriginalCitizenCatalog.firstActor,host.citizens.people.indices.contains(id-OriginalCitizenCatalog.firstActor) {
                    names[id] = host.citizens.people[id-OriginalCitizenCatalog.firstActor].name
                } else {names[id] = name(id)}
            }
            let entries = try LocalDestinations.entries(packedMap:host.vm.state.packedMap,visible:host.stage.visible,map:map,actors:Array(host.stage.actors.values),names:names)
            rows(title:"주변 찾기",line:entries.isEmpty ? "현재 마을에 표시된 대상이 없습니다." : "현재 지도에 있는 인물과 입구입니다. 이동할 때 원래 경로 규칙을 따릅니다.",
                values:entries.map {.init(label:$0.name,value:"(\($0.point.x), \($0.point.y))"+($0.walking ? " · 이동 중" : ""))},selected:selected) {index in
                    guard let index,entries.indices.contains(index) else {onClose();return}
                    self.showNearbyTarget(entries[index],onClose:{self.showNearby(selected:index,onClose:onClose)},onMove:onClose)
                }
        } catch {failure(error,returning:onClose)}
    }
    private func showNearbyTarget(_ entry:LocalDestinations.Entry,onClose:@escaping()->Void,onMove:@escaping()->Void) {
        do {
            guard host.vm.state.packedMap == entry.packedMap,let map = host.stage.currentMap else {throw EngineError.invalid("지도가 바뀌었습니다. 대상을 다시 골라 주세요.")}
            let plan:OriginalExplorationInputPlan?
            if let person = entry.person {plan = try? OriginalExplorationInput.townActor(state:host.vm.state,stage:host.stage,person:person,enabled:host.explorationInputReady)}
            else {plan = try? OriginalExplorationInput.townCell(catalog:host.exploration,state:host.vm.state,stage:host.stage,point:entry.point,enabled:host.explorationInputReady)}
            let image = (try? Data(contentsOf:host.data.containedFile(map.image))).flatMap {NSBitmapImageRep(data:$0)?.cgImage}
            func mark(_ point:GridPoint,strong:Bool)->(point:CGPoint,strong:Bool) {
                (.init(x:CGFloat(point.x*16+16)/CGFloat(max(1,map.width)),y:CGFloat(point.y*16+8*(point.x&1)+8)/CGFloat(max(1,map.height))),strong)
            }
            let current = entry.person.flatMap {host.stage.actors[$0]?.position} ?? entry.point
            let marks = (plan?.route.map {mark($0.position,strong:false)} ?? [])+[mark(current,strong:true)]
            let detail = CanvasSheet.Detail(heading:entry.name,body:plan == nil ? "현재 원본 경로로 갈 수 없습니다. 이동 중인 인물은 멈춘 뒤 다시 확인하세요." : "경로를 확인한 뒤 이동하세요. 도착 후 대사와 선택지는 직접 처리합니다.",
                facts:[("위치","(\(current.x), \(current.y))"),("경로",plan.map {"\(max(0,$0.route.count-1))걸음"} ?? "이동 불가")],picture:image,marks:marks)
            rows(title:"주변 대상",values:[.init(label:entry.name,detail:detail)],buttons:plan == nil ? ["돌아가기"] : [entry.person == nil ? "이동" : "대화하러 가기","돌아가기"],onButton:{button in
                guard plan != nil,button == 0 else {onClose();return}
                do {
                    guard self.host.vm.state.packedMap == entry.packedMap else {throw EngineError.invalid("지도가 바뀌었습니다.")}
                    if let person = entry.person {try self.host.talk(to:person)} else {try self.host.walk(to:entry.point)}
                    onMove()
                } catch {self.failure(error,returning:onClose)}
            }) {_ in onClose()}
        } catch {failure(error,returning:onClose)}
    }
}
