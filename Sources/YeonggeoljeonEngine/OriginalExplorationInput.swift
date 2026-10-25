// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum OriginalExplorationInputKind:String,Codable {case worldCity,townCell,townActor}
struct OriginalExplorationInputPlan:Codable {
    var kind:OriginalExplorationInputKind
    var packedMap:Int
    var chapter:Int
    var currentCity:Int
    var playerPerson:Int
    var route:[RouteNode]
    var selectedCity:Int?
    var selectedMarker:Int?
    var targetPerson:Int?
    var eventCity:Int?
}
struct OriginalExplorationFacing:Codable,Equatable {var person:Int;var nativeDirection:Int}
struct OriginalExplorationArrival:Codable {
    var event:OriginalCampaignEvent?
    var currentCity:Int
    var facings:[OriginalExplorationFacing] = []
    var afterInvocationFacings:[OriginalExplorationFacing] = []
    var unmatchedBuiltinBoundary:String?
}
enum OriginalWorldEntryMode {case script,nativeCityDefault}
struct OriginalWorldBootstrap {
    var commands:[Command]
    var rngAfter:OriginalRNG
    var placementPeriods:[Int]
    /// Source7A76 context stays separate from visible player0's city spawn.
    var retainedReturnContext:OriginalCampaignReturnContext?
}
struct OriginalExplorationPlacementEffects:Equatable {
    var standingPeriod:Int
    var autonomousPeriod:Int?
}
struct OriginalExplorationPlacements {
    var commands:[Command]
    var rngAfter:OriginalRNG
    var placementEffects:[OriginalExplorationPlacementEffects]
}

/// Native input selects a source route; arrival is a second explicit boundary.
/// Runtime alone owns flood/route geometry and the retained movement clock.
/// Campaign VM alone owns current city, original flags and cache identities.
enum OriginalExplorationInput {
    /// Successful native place only. Scripted move has no placement draw.
    /// The source comparison is resolved actor personword == 0200 (player0).
    static func placementEffects(packedMap:Int,person:Int,rng:inout OriginalRNG)throws->OriginalExplorationPlacementEffects {
        let kind = packedMap>>12
        guard [0,1,2].contains(kind),(0..<384).contains(person) else {
            throw EngineError.invalid("Original exploration placement effects require a native settlement/world participant")
        }
        let standing = (try rng.next(bound:16)+2) & ~1
        let autonomous = kind != 1 && person != 0 ? try rng.next(bound:3)+1 : nil
        return OriginalExplorationPlacementEffects(standingPeriod:standing,autonomousPeriod:autonomous)
    }
    private static func city(_ id:Int,catalog:OriginalExplorationCatalog,state:OriginalCampaignState)throws->OriginalCity {
        guard let value = catalog.cities.first(where:{$0.chapter == state.chapter && $0.id == id}) else {
            throw EngineError.invalid("Original exploration city identity is unavailable")
        };return value
    }
    private static func requireInput(stage:Runtime,state:OriginalCampaignState,enabled:Bool,kinds:Set<Int>)throws->ActorState {
        guard enabled,stage.hostWaiting,state.pending == nil,kinds.contains(state.packedMap>>12),stage.mapID == state.packedMap,
              let player = stage.actors[0],!player.walking else {
            throw EngineError.invalid("Original exploration input is gated by its native stage/player boundary")
        };return player
    }
    /// MAIN20EF5 gates MAIN20B46 default spawn on native entry byte7==1.
    /// Script map entry has no default spawn; world has no cache replay call.
    static func worldBootstrap(catalog:OriginalExplorationCatalog,state:OriginalCampaignState,entry:OriginalWorldEntryMode,rng:OriginalRNG)throws->OriginalWorldBootstrap {
        guard state.packedMap>>12 == 1 else {throw EngineError.invalid("Original world bootstrap requires a world map")}
        if entry == .script {
            return OriginalWorldBootstrap(commands:[],rngAfter:rng,placementPeriods:[],retainedReturnContext:state.returnContext)
        }
        guard let current = state.currentCity,
              let directions = catalog.worldPlacementDirections,directions.count == 8,Set(directions) == Set(0..<8) else {
            throw EngineError.invalid("Original world bootstrap context/direction facts are absent")
        }
        let town = try city(current,catalog:catalog,state:state)
        guard town.worldPositionKnown,let x = town.worldX,let y = town.worldY else {
            throw EngineError.invalid("Original current city has no source world position")
        }
        let commands = [Command("place",person:0,x:x,y:y,sourcePlacementFacing:4)]
        var after = rng
        let effects = try placementEffects(packedMap:state.packedMap,person:0,rng:&after)
        return OriginalWorldBootstrap(commands:commands,rngAfter:after,placementPeriods:[effects.standingPeriod],retainedReturnContext:state.returnContext)
    }
    /// VM owns MAIN1C058 cache identity/dirty/omission/music semantics. Its
    /// parsed replay rows become native placements without a second selector.
    static func settlementCacheReplay(replay:OriginalSettlementCacheReplay,packedMap:Int,rng:OriginalRNG)throws->OriginalExplorationPlacements {
        guard [0,2].contains(packedMap>>12) else {throw EngineError.invalid("Original actor cache replay is settlement-only")}
        var commands:[Command] = []
        for actor in replay.actors {
                guard (1..<384).contains(actor.person),(0...255).contains(actor.x),(0...255).contains(actor.y),
                      (0..<8).contains(actor.sourceFacing) else {
                    throw EngineError.invalid("Original settlement cached actor has unsupported source placement fields")
                }
                commands.append(Command("place",person:actor.person,x:actor.x,y:actor.y,sourcePlacementFacing:actor.sourceFacing))
        }
        var after = rng,effects:[OriginalExplorationPlacementEffects] = []
        for command in commands {effects.append(try placementEffects(packedMap:packedMap,person:command.person!,rng:&after))}
        return OriginalExplorationPlacements(commands:commands,rngAfter:after,placementEffects:effects)
    }
    static func worldCity(catalog:OriginalExplorationCatalog,state:OriginalCampaignState,stage:Runtime,cityID:Int,enabled:Bool)throws->OriginalExplorationInputPlan {
        let player = try requireInput(stage:stage,state:state,enabled:enabled,kinds:[1])
        guard let current = state.currentCity,let flags = state.cityFlags,state.cityFlagsChapter == state.chapter,
              flags.indices.contains(cityID),flags[cityID]&3 == 3 else {
            throw EngineError.invalid("Original world city selection is unavailable under its native city flags")
        }
        let selected = try city(cityID,catalog:catalog,state:state)
        guard selected.worldPositionKnown,let x = selected.worldX,let y = selected.worldY else {
            throw EngineError.invalid("Original world city selection retains an unplaced source sentinel")
        }
        let route = try stage.sourceRoute(person:player.person,to:GridPoint(x:x*2,y:y*2))
        return OriginalExplorationInputPlan(kind:.worldCity,packedMap:state.packedMap,chapter:state.chapter,
            currentCity:current,playerPerson:player.person,route:route,selectedCity:cityID)
    }
    static func townCell(catalog:OriginalExplorationCatalog,state:OriginalCampaignState,stage:Runtime,point:GridPoint,enabled:Bool)throws->OriginalExplorationInputPlan {
        let player = try requireInput(stage:stage,state:state,enabled:enabled,kinds:[0,2])
        guard let map = stage.currentMap,let width = map.walkWidth,let height = map.walkHeight,let walk = map.walkBytes,
              let current = state.currentCity,let eventCity = state.gameCity,(0..<width).contains(point.x),(0..<height).contains(point.y),
              walk.count == width*height else {throw EngineError.invalid("Original settlement destination geometry is unavailable")}
        let marker = walk[point.y*width+point.x]
        guard marker&128 == 0 else {throw EngineError.invalid("Original town destination is blocked by source bit80")}
        return OriginalExplorationInputPlan(kind:.townCell,packedMap:state.packedMap,chapter:state.chapter,
            currentCity:current,playerPerson:player.person,route:try stage.sourceRoute(person:player.person,to:point),selectedMarker:marker,eventCity:eventCity)
    }
    /// MAIN25D9E/259FE: path to the target, discarding its final occupied-cell
    /// step. Replanning directly to that adjacent endpoint can change tie order.
    static func townActor(state:OriginalCampaignState,stage:Runtime,person:Int,enabled:Bool)throws->OriginalExplorationInputPlan {
        let player = try requireInput(stage:stage,state:state,enabled:enabled,kinds:[0,2])
        guard let current = state.currentCity,let target = stage.actors[person],target.person != player.person,!target.walking else {
            throw EngineError.invalid("Original town talk target is absent or not settled")
        }
        var route = try stage.sourceRoute(person:player.person,to:target.position)
        if route.count > 1 {route.removeLast()}
        return OriginalExplorationInputPlan(kind:.townActor,packedMap:state.packedMap,chapter:state.chapter,
            currentCity:current,playerPerson:player.person,route:route,targetPerson:person)
    }
    /// The host calls this only after Runtime settles the exact selected route.
    /// It applies returned state through VM APIs, then dispatches the event.
    static func arrive(_ plan:OriginalExplorationInputPlan,catalog:OriginalExplorationCatalog,state:OriginalCampaignState,stage:Runtime)throws->OriginalExplorationArrival {
        guard stage.hostWaiting,state.pending == nil,state.packedMap == plan.packedMap,state.chapter == plan.chapter,
              state.currentCity == plan.currentCity,let player = stage.actors[plan.playerPerson],!player.walking,
              let end = plan.route.last,player.position == end.position else {
            throw EngineError.invalid("Original exploration arrival is stale or its route has not completed")
        }
        switch plan.kind {
        case .worldCity:
            guard let selected = plan.selectedCity else {throw EngineError.invalid("Original world arrival has no selected city")}
            return OriginalExplorationArrival(event:.worldDestination(currentCity:selected),currentCity:selected)
        case .townCell:
            let point = player.position
            guard let eventCity = plan.eventCity,eventCity == state.gameCity,
                  let map = stage.currentMap,let width = map.walkWidth,let height = map.walkHeight,let walk = map.walkBytes,
                  (0..<width).contains(point.x),(0..<height).contains(point.y),walk.count == width*height else {
                throw EngineError.invalid("Original town arrival walk marker is unavailable")
            }
            let marker = walk[point.y*width+point.x]
            guard marker == plan.selectedMarker else {throw EngineError.invalid("Original town arrival marker changed while walking")}
            if marker == 127 {return OriginalExplorationArrival(event:nil,currentCity:plan.currentCity)}
            guard marker&128 == 0 else {throw EngineError.invalid("Original town arrival is blocked")}
            return OriginalExplorationArrival(event:.townDestination(marker:marker,currentCity:eventCity),currentCity:plan.currentCity,
                unmatchedBuiltinBoundary:marker != 126 ? "Original room/world destination fallback requires its native controller" : nil)
        case .townActor:
            guard let person = plan.targetPerson,let target = stage.actors[person],!target.walking,
                  let map = stage.currentMap,let even = map.neighborsEven,let odd = map.neighborsOdd else {
                throw EngineError.invalid("Original town talk arrival target/neighbor facts are unavailable")
            }
            var facings:[OriginalExplorationFacing] = []
            if target.position != player.position {
                guard let forward = (player.position.x&1 == 0 ? even : odd).first(where:{player.position.x+$0.dx == target.position.x && player.position.y+$0.dy == target.position.y}),
                      let reverse = (target.position.x&1 == 0 ? even : odd).first(where:{target.position.x+$0.dx == player.position.x && target.position.y+$0.dy == player.position.y}) else {
                    throw EngineError.invalid("Original talk target moved outside the source adjacent arrival gate")
                }
                facings = [.init(person:player.person,nativeDirection:forward.direction),.init(person:person,nativeDirection:reverse.direction)]
            }
            // Native person374 invokes a dedicated shop/controller before the
            // ordinary kind3 source event. Do not silently convert that branch.
            guard person != 374 else {throw EngineError.invalid("Original special town participant requires its native user-input controller")}
            return OriginalExplorationArrival(event:.townActor(person:person),currentCity:plan.currentCity,facings:facings,
                afterInvocationFacings:[.init(person:person,nativeDirection:target.facing)])
        }
    }
}
