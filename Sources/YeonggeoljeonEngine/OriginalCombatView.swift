// SPDX-License-Identifier: GPL-3.0-only
#if !os(Android)
import CoreGraphics
#else
import Foundation
#endif
import Foundation

/// The enlarged combat view (MAIN32318..3350B). It draws no random numbers and
/// writes no game state, so a scene can be built from the committed result.
struct OriginalCombatCatalog:Codable {
    struct Classes:Codable { var prep,run,swing,attack,total,shot:[Int] }
    struct Texts:Codable {
        var ambushFriendly,ambushEnemy,strategyFailed,levelUp,learned:String
        var strategyUsed,strategyCry,attackIntent,confuseIntent,moraleIntent,healIntent,moraleDown:String
        var healed,healVerb,raiseVerb,stillConfused,confused,moreConfused,strategyMissed,recovered:String
        var turn,closingBonus,delayRetreat,troopsFull,troopsUp,moraleFull,moraleUp:String
        var failed,noLoss,loss,moraleLoss,experience,counterFriendly,counterEnemy:String
        var level,attack,defense,troops,morale,exp,terrain,percent:String
        /// The duel panels' strength and experience rows (DS:4FBD, DS:4FDD).
        var strength,duelExperience:String
    }
    var format:Int
    var palette:[[Int]]
    var background:String
    var tiles:String
    var frameTiles:[Int]
    var backs:[String]
    var grounds:[String]
    var classes:Classes
    var classNames:[String]
    var slots:[[[Int]]]
    var terrainBack:[Int]
    var terrainGround:[Int]
    var strategySounds:[Int]
    var weathers:[String]
    var texts:Texts
    var source:JSONValue?
    var limitations:[String]?
    static func load(from url:URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
        guard value.format == 1,value.palette.count == 16,value.frameTiles.count == 181,value.backs.count == 5,value.grounds.count == 4,
              value.slots.count == 2,value.slots.allSatisfy({ $0.count == 5 && $0.allSatisfy { $0.count == 2 } }),
              value.terrainBack.count == 20,value.terrainGround.count == 20,value.classNames.count == 19,value.strategySounds.count >= 3,
              [value.classes.prep,value.classes.run,value.classes.swing,value.classes.attack,value.classes.total,value.classes.shot].allSatisfy({ $0.count == 19 }) else {
            throw EngineError.invalid("Original combat view catalog does not match its examined shape")
        }
        return value
    }
}

/// What a context knows before its scene opens. Values are from before the blow.
struct OriginalCombatSnapshot:Codable,Equatable {
    /// One physical, two strategy, three item.
    var kind:Int
    var subtype:Int
    var attackerSlot:Int
    var targetSlot:Int
    var attackerPerson:Int
    var targetPerson:Int
    var attackerClass:Int
    var targetClass:Int
    var attackerLevel:Int
    var targetLevel:Int
    var attackerTroops:Int
    var targetTroops:Int
    var attackerMaxTroops:Int
    var targetMaxTroops:Int
    var attackerMorale:Int
    var targetMorale:Int
    var attackValue:Int
    var defenseValue:Int
    var terrain:Int
    var terrainPercent:Int
    var damage:Int
    var moraleLoss:Int
    var experience:Int
    var experienceGain:Int
    var counter:Bool
}

/// One held picture of a scene.
struct OriginalCombatFrame {
    var layers:[Int16]
    var scroll:Int
    var ticks:Int
    var sounds:[Int] = []
    var stopsSound = false
    var waitsForSound = false
    var skippable = false
    var page:OriginalCombatPage? = nil
    var notice:String? = nil
}
/// The results window (MAIN31A06): text and gauges over the last picture.
struct OriginalCombatPage:Equatable {
    struct Line:Equatable { var y:Int;var text:String }
    struct Gauge:Equatable { var y:Int;var value:Int;var maximum:Int }
    var lines:[Line]
    var gauges:[Gauge]
    /// True for the experience pages; the others report the target's troops and morale.
    var experience = false
}

/// Printf subset of the source's result strings: %s, %u with a width, %%.
extension OriginalCombatCatalog {
    func text(_ notice:OriginalBattleNotice,person:(Int)->String,strategy:(Int)->String,kind:(Int)->String = { _ in "" }) -> String {
        switch notice {
        case .strategyUsed(let id,let ability):return originalFormat(texts.strategyUsed,[person(id),strategy(ability)])
        case .strategyCry(let ability):return originalFormat(texts.strategyCry,[strategy(ability)])
        case .confused(let id,let again):return originalFormat(again ? texts.moreConfused : texts.confused,[person(id)])
        case .strategyMissed:return texts.strategyMissed
        case .moraleDown(let id):return originalFormat(texts.moraleDown,[person(id)])
        case .healed(let id,let value,let raises):
            return originalFormat(texts.healed,[person(id),kind(value),raises ? texts.raiseVerb : texts.healVerb])
        case .stillConfused(let id):return originalFormat(texts.stillConfused,[person(id)])
        case .recovered(let id):return originalFormat(texts.recovered,[person(id)])
        case .turn(let round,let weather):
            return originalFormat(texts.turn,[String(round),weathers.indices.contains(weather) ? weathers[weather] : ""])
        case .closingBonus(let points):return originalFormat(texts.closingBonus,[String(points)])
        case .delayRetreat:return texts.delayRetreat
        case .troopsRecovered(let id,let amount):return originalFormat(texts.troopsUp,[person(id),String(amount)])
        case .troopsFull:return texts.troopsFull
        case .moraleRecovered(let amount):return originalFormat(texts.moraleUp,[String(amount)])
        case .moraleFull:return texts.moraleFull
        case .ambush(let friendly):return friendly ? texts.ambushFriendly : texts.ambushEnemy
        case .counter(let friendly):return friendly ? texts.counterFriendly : texts.counterEnemy
        case .phase(let enemy):return enemy ? "적군 순서" : ""
        case .strategyFailed(let id):return originalFormat(texts.strategyFailed,[person(id)])
        case .level(let id,let level):return originalFormat(texts.levelUp,[person(id),String(level)])
        case .learned(let abilities):return originalFormat(texts.learned,[abilities.map(strategy).joined()])
        }
    }
}

func originalFormat(_ pattern:String,_ values:[String]) -> String {
    var result = "",next = values.makeIterator()
    var scanner = pattern.makeIterator()
    while let character = scanner.next() {
        guard character == "%" else { result.append(character);continue }
        var width = ""
        while let code = scanner.next() {
            if code.isNumber { width.append(code);continue }
            if code == "%" { result.append("%");break }
            let value = next.next() ?? ""
            result += String(repeating:" ",count:max(0,(Int(width) ?? 0)-value.count))+value
            break
        }
    }
    return result
}

struct OriginalCombatScene {
    static let columns = 26,rows = 13
    let snapshot:OriginalCombatSnapshot
    /// Bank tile to catalog tile; negative is mirrored (~tile).
    private(set) var bank = [Int32](repeating:Int32.min,count:0x160+27)
    let backMember:Int,groundMember:Int
    private(set) var frames:[OriginalCombatFrame] = []

    private var layers = [Int16](repeating:-1,count:4*rows*columns)
    private var x:[[Int]] = [[],[],[]],y:[[Int]] = [[],[],[]]
    private var pose = [0,0]
    private var phase = 0
    private var scroll = 0
    private var classOf = [0,0]
    private var troops = [0,0]
    private let attacker:Int,target:Int,catalog:OriginalCombatCatalog
    private var pendingSounds:[Int] = []
    private var family:Int { snapshot.subtype>>4 }
    private var overlayFamily:Int { snapshot.subtype>>4 }

    init(catalog:OriginalCombatCatalog,snapshot:OriginalCombatSnapshot) throws {
        guard (0..<20).contains(snapshot.terrain),(0..<19).contains(snapshot.attackerClass),(0..<19).contains(snapshot.targetClass) else {
            throw EngineError.invalid("Original combat view has no background for this terrain or class")
        }
        self.catalog = catalog;self.snapshot = snapshot
        attacker = snapshot.attackerSlot < 15 ? 0 : 1;target = 1-attacker
        backMember = catalog.terrainBack[snapshot.terrain];groundMember = catalog.terrainGround[snapshot.terrain]-5
        classOf[attacker] = snapshot.attackerClass;classOf[target] = snapshot.targetClass
        troops[attacker] = snapshot.attackerTroops;troops[target] = snapshot.targetTroops
        loadArt();placeUnits();script()
    }
    private func frameStart(_ member:Int) -> Int { catalog.frameTiles[..<member].reduce(0,+) }
    private mutating func put(_ frame:Int,member:Int,count:Int,flipped:Bool,base:Int) {
        let side = count == 16 ? 4 : 3,start = frameStart(member)
        guard catalog.frameTiles[member] == count else { return }
        for tile in 0..<count {
            let column = tile%side,slot = flipped ? tile-column+(side-1-column) : tile
            let at = base+frame*count+slot
            guard bank.indices.contains(at) else { continue }
            bank[at] = flipped ? ~Int32(start+tile) : Int32(start+tile)
        }
    }
    /// MAIN325B2: the attacker loads its attack frames, the target three.
    private mutating func loadArt() {
        let classes = catalog.classes
        let bases = (0..<19).map { classes.total[..<$0].reduce(0,+) }
        for side in 0..<2 {
            let kind = classOf[side],base = bases[kind]
            let count = side == attacker ? classes.attack[kind] : classOf[target] == 5 ? 6 : 3
            for frame in 0..<count {
                let member:Int
                if side == attacker { member = base+frame }
                else if kind == 5 { member = frame < 2 ? base+frame : base+frame+4 }
                else { member = frame < 1 ? base : base+classes.attack[kind]+frame-1 }
                put(frame,member:member,count:16,flipped:side == 1,base:11*side*16)
            }
        }
        if snapshot.kind == 1 {
            let shot = classes.shot[classOf[attacker]]
            guard shot != 255 else { return }
            for frame in 0..<(shot >= 6 ? 3 : 2) { put(frame,member:0xA9+shot+frame,count:9,flipped:attacker == 1,base:0x160) }
        } else {
            for frame in 0..<(family == 2 ? 3 : 6) { put(frame,member:0x9A+family*6+frame,count:16,flipped:attacker == 1,base:(11*target+4)*16) }
        }
    }
    /// MAIN32473..32561: the target starts forty cells away, the overlay on the attacker.
    private mutating func placeUnits() {
        for side in 0..<2 {
            x[side] = catalog.slots[side].map { $0[0]+(side == target ? (target == 1 ? 40 : -40) : 0) }
            y[side] = catalog.slots[side].map { $0[1] }
        }
        x[2] = x[attacker];y[2] = y[attacker]
        for index in 0..<5 {
            if snapshot.kind == 1 {
                if [13,18].contains(classOf[attacker]) { y[2][index] += 1 }
            } else {
                y[2][index] += 1
                if index > 2 { x[2][index] += attacker == 0 ? -2 : 2 }
            }
        }
        scroll = attacker == 0 ? 0 : 40
    }
    /// MAIN2A294's layer rule: the sprite's top row is layer three, its bottom row zero.
    private mutating func stamp(_ base:Int?,x left:Int,y top:Int,size:Int) {
        for row in 0..<size {
            for column in 0..<size {
                let cellX = left+column,cellY = top+row
                guard (0..<Self.columns).contains(cellX),(0..<Self.rows).contains(cellY) else { continue }
                let at = (3-row)*Self.rows*Self.columns+cellY*Self.columns+cellX
                layers[at] = base.map { Int16($0+row*size+column) } ?? -1
            }
        }
    }
    private func count(_ side:Int) -> Int {
        if side == 2 { return snapshot.kind == 1 ? min(5,troops[attacker]/600+1) : min(5,(snapshot.subtype&15)*2+1) }
        return min(5,troops[side]/600+1)
    }
    /// MAIN32926. A nil pose erases, which the source only does to sides and shots.
    private mutating func draw(_ side:Int,_ value:Int?) {
        func frame(_ owner:Int,_ pose:Int) -> Int { (11*owner+pose)*16 }
        if side == 2 {
            for index in 0..<count(2) {
                let left = x[2][index],top = y[2][index]
                if snapshot.kind == 1 { stamp(value.map { 0x160+9*$0 },x:left,y:top,size:3) }
                else if family == 2 { stamp(value.map { frame(target,$0+4) },x:left,y:top,size:4) }
                else {
                    stamp(value.map { frame(target,2*$0+4) },x:left,y:top,size:4)
                    stamp(value.map { frame(target,2*$0+5) },x:left+(attacker == 0 ? 4 : -4),y:top,size:4)
                }
            }
            return
        }
        if classOf[side] == 5 {
            let lead = side == 0 ? 3 : -3
            for index in 0..<count(side) {
                stamp(value.map { frame(side,2*$0+1) },x:x[side][index],y:y[side][index],size:4)
                stamp(value.map { frame(side,2*$0) },x:x[side][index]-lead,y:y[side][index]-1,size:4)
            }
        } else {
            for index in 0..<count(side) { stamp(value.map { frame(side,$0) },x:x[side][index],y:y[side][index],size:4) }
        }
        if let value = value { pose[side] = value }
    }
    private mutating func render(ticks:Int,scroll view:Int? = nil,skippable:Bool = false,stopsSound:Bool = false,waitsForSound:Bool = false) {
        frames.append(OriginalCombatFrame(layers:layers,scroll:view ?? scroll,ticks:ticks,sounds:pendingSounds,stopsSound:stopsSound,
            waitsForSound:waitsForSound,skippable:skippable))
        pendingSounds = []
    }
    private mutating func script() {
        begin()
        if snapshot.kind == 1 {
            prep();run()
            let kind = classOf[attacker]
            if catalog.classes.swing[kind] == 255 || catalog.classes.shot[kind] != 255 { pan() } else { swing() }
        } else { pan() }
        hit();results()
    }
    /// MAIN32572: a second of stillness, cut short by a mouse button.
    private mutating func begin() {
        if snapshot.counter {
            let friendly = snapshot.attackerSlot < 15
            frames.append(OriginalCombatFrame(layers:[],scroll:scroll,ticks:96,skippable:true,
                notice:friendly ? catalog.texts.counterFriendly : catalog.texts.counterEnemy))
        }
        draw(0,0);draw(1,0);render(ticks:60,skippable:true)
    }
    private mutating func prep() {
        let kind = classOf[attacker],classes = catalog.classes,first = classes.prep[kind]
        guard first != 255 else { return }
        draw(attacker,first);render(ticks:12)
        draw(attacker,first+1);render(ticks:6)
        if kind == 5 { pendingSounds.append(22) }
        guard classes.shot[kind] != 255,kind != 5 else { return }
        if [3,4].contains(kind) { pendingSounds.append(19) } else if kind == 13 { pendingSounds.append(25) }
        draw(attacker,first+2)
        if [13,18].contains(kind) { draw(2,0) }
        render(ticks:1,waitsForSound:true)
    }
    private mutating func run() {
        let kind = classOf[attacker],first = catalog.classes.run[kind]
        guard first != 255,![12,18].contains(kind) else { return }
        pendingSounds.append([6,7,8,16].contains(kind) ? 17 : 18)
        for step in 0...40 {
            draw(attacker,first+phase+(step%4 == 3 ? 1 : 0))
            draw(target,nil)
            if step > 0 { for index in 0..<5 { x[target][index] += attacker == 0 ? -1 : 1 } }
            draw(target,0)
            scroll = attacker == 0 ? step : 40-step
            render(ticks:1,stopsSound:step == 40)
            phase ^= 1
        }
    }
    private mutating func swing() {
        let first = catalog.classes.swing[classOf[attacker]]
        draw(attacker,0);render(ticks:0)
        draw(attacker,first);render(ticks:12)
        draw(attacker,first+1);render(ticks:12)
    }
    private mutating func pan() {
        let kind = classOf[attacker]
        if snapshot.kind == 1 {
            if let id = [13:24,12:26,18:15][kind] { pendingSounds.append(id) }
        } else if catalog.strategySounds.indices.contains(family) { pendingSounds.append(catalog.strategySounds[family]) }
        for step in stride(from:0,through:40,by:2) {
            draw(attacker,nil);draw(target,nil)
            if step > 0 { for side in 0..<2 { for index in 0..<5 { x[side][index] += attacker == 0 ? -2 : 2 } } }
            if snapshot.kind != 1 { draw(2,(step%6)>>1) }
            else if kind == 12 { draw(2,(step&2)>>1) }
            else if [13,18].contains(kind) { draw(2,(step%6)>>1) }
            else if [3,4,5].contains(kind),step%4 == 0 {
                draw(2,nil)
                let quarter = step/4
                if (1...4).contains(quarter) {
                    for index in 0..<5 { y[2][index] -= 1 }
                    draw(2,0)
                } else if (5...8).contains(quarter) {
                    for index in 0..<5 { y[2][index] += 1 }
                    draw(2,1)
                }
            }
            draw(attacker,pose[attacker]);draw(target,pose[target])
            // MAIN333E1: this scroll is not stored, so the hit snaps back to +7B.
            render(ticks:1,scroll:attacker == 0 ? step : 40-step)
            phase ^= 1
        }
    }
    /// MAIN3341C: one cell of shove per hundred troops; a kill is thirteen.
    private mutating func hit() {
        let attackerClass = classOf[attacker]
        let shove = snapshot.damage == snapshot.targetTroops ? 13 : (snapshot.damage/100)&255
        pendingSounds.append([3,4].contains(attackerClass) ? 21 : attackerClass == 5 ? 23 : 20)
        for step in 0..<shove {
            draw(target,nil)
            for index in 0..<5 { x[target][index] += attacker == 0 ? 1 : -1 }
            draw(target,classOf[target] == 5 && snapshot.kind == 2 ? 1 : step <= shove/2 ? 1 : 2)
            render(ticks:1)
        }
    }
    private mutating func page(_ lines:[OriginalCombatPage.Line],_ gauges:[OriginalCombatPage.Gauge],experience:Bool = false) {
        frames.append(OriginalCombatFrame(layers:layers,scroll:scroll,ticks:60,sounds:pendingSounds,skippable:true,
            page:OriginalCombatPage(lines:lines,gauges:gauges,experience:experience)))
        pendingSounds = []
    }
    /// MAIN31A06: names and numbers come from the view's owner through `names`.
    private mutating func results() { resultsPending = true }
    private(set) var resultsPending = false
    mutating func addResults(attackerName:String,targetName:String) {
        guard resultsPending else { return }
        resultsPending = false
        let texts = catalog.texts,s = snapshot
        let troopsGauge = OriginalCombatPage.Gauge(y:144,value:s.targetTroops,maximum:s.targetMaxTroops)
        if s.damage > 0 {
            let loss = OriginalCombatPage.Line(y:120,text:originalFormat(texts.loss,[targetName,String(s.damage)]))
            let morale = OriginalCombatPage.Line(y:168,text:originalFormat(texts.moraleLoss,[String(s.moraleLoss)]))
            page([loss,morale],[troopsGauge,.init(y:192,value:s.targetMorale,maximum:100)])
            page([loss,morale],[.init(y:144,value:s.targetTroops-s.damage,maximum:s.targetMaxTroops),
                                .init(y:192,value:max(0,s.targetMorale-s.moraleLoss),maximum:100)])
        } else {
            let line = s.kind == 2 ? originalFormat(texts.failed,[attackerName]) : originalFormat(texts.noLoss,[targetName])
            page([.init(y:120,text:line)],[troopsGauge])
        }
        guard s.attackerSlot < 15 else {
            if var last = frames.last { last.sounds = [];frames.append(last) }
            return
        }
        let gained = OriginalCombatPage.Line(y:128,text:originalFormat(texts.experience,[attackerName,String(s.experienceGain)]))
        page([gained],[.init(y:164,value:s.experience,maximum:100)],experience:true)
        page([gained],[.init(y:164,value:s.experience+s.experienceGain,maximum:100)],experience:true)
    }
}

/// Indexed art as loaded, and the one compositor (MAIN2A294).
final class OriginalCombatArt {
    let catalog:OriginalCombatCatalog
    private let background:[UInt8],tiles:[UInt8],backs:[[UInt8]],grounds:[[UInt8]]
    private let colors:[UInt32]
    init(catalog:OriginalCombatCatalog) throws {
        self.catalog = catalog
        func bytes(_ text:String) throws -> [UInt8] {
            guard let data = Data(base64Encoded:text) else { throw EngineError.invalid("Original combat view data is not base64") }
            return [UInt8](data)
        }
        background = try bytes(catalog.background);tiles = try bytes(catalog.tiles)
        backs = try catalog.backs.map(bytes);grounds = try catalog.grounds.map(bytes)
        guard background.count == 224*256,tiles.count == catalog.frameTiles.reduce(0,+)*256,
              backs.allSatisfy({ $0.count == 230 }),grounds.allSatisfy({ $0.count == 528 }) else {
            throw EngineError.invalid("Original combat view art has the wrong size")
        }
        colors = catalog.palette.map { UInt32($0[0])|UInt32($0[1])<<8|UInt32($0[2])<<16|0xFF00_0000 }
    }
    func picture(_ frame:OriginalCombatFrame,scene:OriginalCombatScene) -> CGImage? {
        compose(back:backs[scene.backMember],ground:grounds[scene.groundMember],scroll:frame.scroll,layers:frame.layers,bank:scene.bank)
    }
    /// The duel's background (0x3488F..0x348E6): the same members by terrain,
    /// with no layers. The source reads past a row from camera 41 on; this clamps.
    func backdrop(terrain:Int,scroll:Int) -> CGImage? {
        guard catalog.terrainBack.indices.contains(terrain),backs.indices.contains(catalog.terrainBack[terrain]),
              grounds.indices.contains(catalog.terrainGround[terrain]-5) else { return nil }
        return compose(back:backs[catalog.terrainBack[terrain]],ground:grounds[catalog.terrainGround[terrain]-5],scroll:min(max(0,scroll),40),layers:[],bank:[])
    }
    private func compose(back:[UInt8],ground:[UInt8],scroll:Int,layers:[Int16],bank:[Int32]) -> CGImage? {
        let width = OriginalCombatScene.columns*16,height = OriginalCombatScene.rows*16
        var pixels = [UInt32](repeating:0xFF00_0000,count:width*height)
        pixels.withUnsafeMutableBufferPointer { out in
            for row in 0..<OriginalCombatScene.rows {
                for column in 0..<OriginalCombatScene.columns {
                    let tile = row < 5 ? Int(back[row*46+scroll/3+column]) : Int(ground[(row-5)*66+scroll+column])
                    let origin = row*16*width+column*16
                    for line in 0..<16 { for dot in 0..<16 { out[origin+line*width+dot] = colors[Int(background[tile*256+line*16+dot])&15] } }
                    guard layers.count == 4*OriginalCombatScene.rows*OriginalCombatScene.columns else { continue }
                    for layer in 0..<4 {
                        let id = Int(layers[layer*OriginalCombatScene.rows*OriginalCombatScene.columns+row*OriginalCombatScene.columns+column])
                        guard id >= 0,id < bank.count,bank[id] != Int32.min else { continue }
                        let mirrored = bank[id] < 0,source = Int(mirrored ? ~bank[id] : bank[id])*256
                        for line in 0..<16 {
                            for dot in 0..<16 {
                                let value = tiles[source+line*16+(mirrored ? 15-dot : dot)]
                                if value != 0 { out[origin+line*width+dot] = colors[Int(value)&15] }
                            }
                        }
                    }
                }
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data:data) else { return nil }
        return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)
    }
}

/// Plays one scene against source ticks. A mouse button ends a skippable hold.
struct OriginalCombatPlayer {
    let scene:OriginalCombatScene
    private(set) var index = 0
    private var elapsed = 0.0
    private var started = false
    init(scene:OriginalCombatScene) { self.scene = scene }
    /// Frames shown in this interval carry these actions.
    enum Action:Equatable { case sound(Int),stopSound }
    var finished:Bool { index >= scene.frames.count }
    var frame:OriginalCombatFrame? { finished ? nil : scene.frames[index] }
    /// The newest frame with a picture, for pages drawn over it.
    var picture:OriginalCombatFrame? {
        var at = min(index,scene.frames.count-1)
        while at >= 0 { if !scene.frames[at].layers.isEmpty { return scene.frames[at] };at -= 1 }
        return nil
    }
    mutating func advance(_ seconds:Double,soundBusy:Bool) -> [Action] {
        var actions:[Action] = [],left = seconds/OriginalBattleAnimator.tick
        while let current = frame {
            if !started {
                started = true
                actions += current.sounds.map(Action.sound)
            }
            let rest = Double(current.ticks)-elapsed
            if left < rest { elapsed += left;break }
            if current.waitsForSound,soundBusy || !actions.isEmpty { break }
            left -= rest;next(&actions)
        }
        return actions
    }
    private mutating func next(_ actions:inout [Action]) {
        if frame?.stopsSound == true { actions.append(.stopSound) }
        index += 1;elapsed = 0;started = false
    }
    /// MAIN24D2 ends the hold while a mouse button is down.
    mutating func skip() { if frame?.skippable == true { elapsed = Double(frame?.ticks ?? 0) } }
    /// The view can be cut short with no effect on results.
    mutating func finish() { index = scene.frames.count }
}
