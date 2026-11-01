// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Coordinates of MAIN's battle screen, in the 640×400 source canvas. The story
/// producer reads them from checked MAIN writers; `source` lets the native view
/// run on synthetic data, and catalog validation rejects any other values.
struct OriginalBattleLayout:Codable,Equatable {
    struct TextBox:Codable,Equatable { var column:Int; var width:Int; var y:Int }
    struct UnitList:Codable,Equatable {
        var rect:[Int]; var rowHeight:Int; var rows:Int; var nameColumn:Int; var statusColumn:Int
        var textY:Int; var gauge:[Int]; var track:[Int]; var hover:[Int]
    }
    struct Minimap:Codable,Equatable { var panel:[Int]; var base:[Int]; var span:[Int]; var cellPixels:Int }
    /// The victory conditions window (MAIN27876..27A3A).
    struct Conditions:Codable,Equatable {
        var window:[Int]; var textBox:[Int]; var turnBox:[Int]; var button:[Int]
        var titleColumn:Int; var headingColumn:Int; var headerY:Int
        var textColumn:Int; var textY:Int; var lineStep:Int; var lineWidth:Int; var lineEnd:Int
        var turnColumn:Int; var turnY:Int
    }
    var viewport:[Int]; var cell:Int; var functionButton:[Int]
    var title:TextBox; var force:TextBox; var sideButtons:[[Int]]
    /// The terrain window, relative to its own corner (MAIN2A5F4..2A8C6).
    struct Terrain:Codable,Equatable {
        var size:[Int]; var tile:[Int]; var textX:Int; var headingY:Int; var percentY:Int; var nameY:Int; var percentWidth:Int
    }
    var list:UnitList; var minimap:Minimap; var conditions:Conditions; var terrain:Terrain; var followMargin:Int

    static let source = Self(viewport:[16,32,416,352],cell:32,functionButton:[16,8,64,16],
        title:TextBox(column:28,width:22,y:8),force:TextBox(column:56,width:10,y:40),
        sideButtons:[[528,32,32,32],[560,32,32,32]],
        list:UnitList(rect:[448,72,160,200],rowHeight:20,rows:10,nameColumn:57,statusColumn:65,textY:74,
                      gauge:[512,77,88,10],track:[608,72,16,200],hover:[454,148]),
        minimap:Minimap(panel:[448,272,176,112],base:[456,280],span:[40,24],cellPixels:4),
        conditions:Conditions(window:[64,96,320,192],textBox:[72,136,304,96],turnBox:[72,232,240,48],button:[320,246,48,20],
                              titleColumn:10,headingColumn:38,headerY:112,textColumn:12,textY:152,lineStep:32,lineWidth:34,lineEnd:216,
                              turnColumn:11,turnY:248),
        terrain:Terrain(size:[128,80],tile:[8,16,32,32],textX:48,headingY:16,percentY:36,nameY:56,percentWidth:64),followMargin:6)
    /// The engine's own arrangement of the same parts: a slim top bar, fifteen
    /// by twelve cells, and a sidebar. Only the map window's size differs in play.
    func modern() -> Self {
        var value = self
        value.viewport = [0,16,480,384];value.functionButton = [0,0,56,16]
        value.sideButtons = [[488,32,72,20],[560,32,72,20]]
        value.list = UnitList(rect:[484,58,152,200],rowHeight:20,rows:10,nameColumn:61,statusColumn:69,textY:60,
                              gauge:[490,74,140,3],track:[633,58,3,200],hover:[484,152])
        value.minimap = Minimap(panel:[484,264,152,128],base:[500,292],span:[40,24],cellPixels:3)
        return value
    }
    static func rect(_ value:[Int]) -> CGRect { CGRect(x:value[0],y:value[1],width:value[2],height:value[3]) }
    var viewportRect:CGRect { Self.rect(viewport) }
    var columns:Int { viewport[2]/cell }
    var rows:Int { viewport[3]/cell }
    /// MAIN2898C..289C5 centres the map in eight-pixel steps inside the panel.
    func minimapOrigin(width:Int,height:Int) -> CGPoint {
        CGPoint(x:minimap.base[0]+(minimap.span[0]-width)*minimap.cellPixels/2/8*8,
                y:minimap.base[1]+(minimap.span[1]-height)*minimap.cellPixels/2/8*8)
    }
}

struct OriginalBattleTexts:Codable,Equatable {
    var forces:[String]; var forceSuffix:String; var retired:String; var source:JSONValue?
}
struct OriginalBattlePart:Codable,Equatable { var image:String; var width:Int; var height:Int; var source:JSONValue? }
struct OriginalBattleParts:Codable,Equatable {
    var function:OriginalBattlePart
    /// Indexed by side (friendly, enemy), then by lit state (MAIN287B0..28805).
    var side:[[OriginalBattlePart]]
    var gauge:[String:OriginalBattlePart]
    var ok:OriginalBattlePart
}

struct OriginalBattleConditionTexts:Codable,Equatable {
    var titleFormat:String; var currentTurn:String; var turnLimit:String
    var playerPhase:String; var heading:String; var chapterLabels:[String]; var source:JSONValue?
}

struct OriginalBattleTerrainTexts:Codable,Equatable {
    var names:[String]; var defense:String; var none:String; var percent:String; var recovery:String; var source:JSONValue?
}

/// Labels and refusals of the unit command routine (MAIN2D9D4..2DE42).
struct OriginalBattleCommands:Codable,Equatable {
    var labels:[String]; var ambush:[String]; var itemActions:[String]
    var strategyNames:[String]; var messages:[String:String]
    var itemMessages:[String:String]; var kindLabels:[String]; var familyLabels:[String]
    var classNames:[String]; var terrainRefusals:[String]
    var conditions:OriginalBattleConditionTexts; var terrain:OriginalBattleTerrainTexts; var source:JSONValue?
    static let messageKeys:Set<String> = ["outOfMoveRange","notOurs","cannotControl","confused","finished","noStrategy",
        "releaseAmbush","noItems","gave","inventoryFull","discarded","noAllyInRange","noEnemyInRange","enemyUnit",
        "cannotAttackAlly","outOfItemRange","outOfAttackRange"]
    static let itemMessageKeys:Set<String> = ["rainFire","attackWith","usedItem","confuseEnemy","alreadyConfused","recoverKind",
        "recoveryLine","bombAttack","bombThrow","unusable","noRecovery","classPrompt","classDone","classTerrain","sameFamily",
        "sameClass","playerClass","promotePrompt","promoteDone","lowLevel","wrongClass","areaPrompt","areaDone","noAllyNearby",
        "becameConfused","lostWill","raised","friendlySide","enemySide"]
    var isValid:Bool {
        labels.count == 4 && ambush.count == 2 && itemActions.count == 4 && strategyNames.count == 36 &&
            Set(messages.keys) == Self.messageKeys && (labels+ambush+itemActions+strategyNames).allSatisfy({ !$0.isEmpty }) &&
            messages.values.allSatisfy({ !$0.isEmpty }) && Set(itemMessages.keys) == Self.itemMessageKeys &&
            itemMessages.values.allSatisfy({ !$0.isEmpty }) && kindLabels.count == 4 && familyLabels.count == 3 &&
            classNames.count == 19 && terrainRefusals.count == 3 && conditions.chapterLabels.count == 5 &&
            ![conditions.titleFormat,conditions.currentTurn,conditions.turnLimit,conditions.playerPhase,conditions.heading].contains("") &&
            terrain.names.count == 20 && terrain.names.allSatisfy({ !$0.isEmpty }) &&
            ![terrain.defense,terrain.none,terrain.percent,terrain.recovery].contains("")
    }
}

/// Map scroll in half cells, as DS:E1BC+8/+0A. Both axes stay even, so the
/// view always aligns to whole cells. Original scrolling steps two half cells
/// per frame; the native view jumps to the target.
struct OriginalBattleCamera:Equatable {
    let width:Int; let height:Int
    let columns:Int; let rows:Int
    private(set) var x = 0
    private(set) var y = 0
    init(width:Int,height:Int,layout:OriginalBattleLayout = .source) {
        self.width = width;self.height = height;columns = layout.columns;rows = layout.rows
    }
    private var limitX:Int { max(0,width*2-columns*2) }
    private var limitY:Int { max(0,height*2-rows*2) }
    private mutating func set(_ newX:Int,_ newY:Int) {
        x = min(max(0,newX),limitX) & ~1;y = min(max(0,newY),limitY) & ~1
    }
    /// MAIN2927E..2936A with its centre flag; arguments are half cells.
    mutating func center(halfX:Int,halfY:Int) { set(halfX-columns,halfY-rows) }
    mutating func center(on cell:GridPoint) { center(halfX:cell.x*2,halfY:cell.y*2) }
    mutating func move(columns dx:Int,rows dy:Int) { set(x+dx*2,y+dy*2) }
    /// MAIN2997E..29ADA: stay put while the cell is within `margin` half cells
    /// of the centred position, then centre on it under the source clamps.
    mutating func follow(_ cell:GridPoint,margin:Int) {
        var targetX = cell.x*2-columns,targetY = cell.y*2-rows
        guard abs(x-targetX) >= margin || abs(y-targetY) >= margin else { return }
        if targetX < 0 || cell.x*2 < margin { targetX = 0 }
        if targetY < 0 || cell.y*2 < margin { targetY = 0 }
        if columns*2+targetX > width*2 { targetX = width*2-columns*2 }
        if rows*2+targetY > height*2 { targetY = height*2-rows*2 }
        set(targetX,targetY)
    }
    func rect(of cell:GridPoint,in viewport:CGRect,size:Int) -> CGRect {
        CGRect(x:Int(viewport.minX)+(cell.x-x/2)*size,y:Int(viewport.minY)+(cell.y-y/2)*size,width:size,height:size)
    }
    func cell(at point:CGPoint,in viewport:CGRect,size:Int) -> GridPoint? {
        guard viewport.contains(point) else { return nil }
        let cell = GridPoint(x:Int(floor((point.x-viewport.minX)/CGFloat(size)))+x/2,y:Int(floor((point.y-viewport.minY)/CGFloat(size)))+y/2)
        return (0..<width).contains(cell.x) && (0..<height).contains(cell.y) ? cell : nil
    }
}

/// MAIN29500..295D0 builds the panel rows: the leader's own force first on the
/// friendly list, other live units next, retired units last. The enemy list
/// skips the first pass, so a live enemy of force zero stays unlisted.
enum OriginalBattleRoster {
    static func rows(side:Int,units:[Int:OriginalLiveUnit],force:(OriginalLiveUnit) -> Int) -> [Int] {
        let slots = side == 0 ? Array(0..<15) : Array(15..<45)
        let present = slots.compactMap { units[$0] }
        var result:[Int] = []
        if side == 0 { result += present.filter { $0.status == 2 && force($0) == 0 }.map(\.slot) }
        result += present.filter { $0.status == 2 && force($0) != 0 }.map(\.slot)
        result += present.filter { $0.status >= 3 }.map(\.slot)
        return result
    }
    /// MAIN2988A..298E6 marks each unit on the minimap in one of two colours.
    static func markColor(_ unit:OriginalLiveUnit) -> Int { unit.enemy ? 1 : 2 }
    /// MAIN2C668..2C6DF text colour of a row's unit name.
    static func nameColor(_ unit:OriginalLiveUnit) -> Int {
        if unit.status != 2 { return 2 }
        if unit.scriptFlags&2 != 0 { return 3 }
        if unit.enemy { return 15 }
        return unit.orderMode == 7 ? (unit.scriptFlags&0x80 != 0 ? 5 : 7) : 6
    }
}

/// Pure rules of the unit command routine, shared by the view and its tests.
enum OriginalBattleCommand {
    /// MAIN30EF1..30F4E: why a clicked unit opens no command, in source order.
    /// Each case names its refusal in `OriginalBattleCommands.messages`.
    static func denial(_ unit:OriginalLiveUnit) -> String? {
        if unit.enemy { return "notOurs" }
        if unit.scriptFlags&4 != 0 || unit.orderMode != 7 { return "cannotControl" }
        if unit.scriptFlags&2 != 0 { return "confused" }
        if unit.scriptFlags&0x80 != 0 { return "finished" }
        return nil
    }
    /// MAIN2AA26..2AAC4: the window opens one cell right of the unit, stays
    /// above row 272 and flips left past column 224. Each nested window steps
    /// sixteen pixels on from its parent, away from the edge it was pushed from.
    static func window(cell:GridPoint,camera:OriginalBattleCamera,layout:OriginalBattleLayout = .source) -> (origin:CGPoint,step:CGPoint) {
        var x = (cell.x-camera.x/2+1)*layout.cell+layout.viewport[0]
        var y = (cell.y-camera.y/2)*layout.cell+layout.viewport[1]
        var step = CGPoint(x:16,y:16)
        let rows = y>>4-17
        if rows >= 0 { y -= rows<<4;step.y = -16 }
        if UInt16(truncatingIfNeeded:x>>4-1) >= 13 { x -= 160;step.x = -16 }
        return (CGPoint(x:x,y:y),step)
    }
    struct StrategyRow:Equatable { var ability:Int; var cost:Int; var enabled:Bool }
    /// MAIN2DC83..2DD10 lists every ability the level allows. Rows the unit
    /// cannot pay for, and fire rows in rain, stay listed but disabled.
    static func strategyRows(classID:Int,level:Int,mp:UInt8,rain:Bool,levels:[[Int]],costs:[Int]) -> [StrategyRow] {
        // MAIN2DB64 skips the whole list for class 17.
        guard classID != 17,levels.count == 36,costs.count == 36 else { return [] }
        return (0..<36).filter { levels[$0][classID] <= level }.map { ability in
            StrategyRow(ability:ability,cost:costs[ability],enabled:costs[ability] <= Int(mp) && !(ability < 5 && rain))
        }
    }
}

/// Placement and values of the terrain window (MAIN2A6A0..2A8C3).
enum OriginalBattleTerrain {
    /// Sixteen-pixel units: the window opens two units right of the cell, or
    /// eight left from column 14, and three units higher from row 12.
    static func windowOrigin(cell:GridPoint,camera:OriginalBattleCamera) -> CGPoint {
        var column = cell.x*2-camera.x+1
        var row = (cell.y+1)*2-camera.y
        column += column < 14 ? 2 : -8
        row += row < 12 ? 0 : -3
        return CGPoint(x:column*16,y:row*16)
    }
    /// A 255 entry prints the fallback text before the same percent sign.
    static func defenseText(_ value:Int,none:String,percent:String) -> String {
        (value == 255 ? none : String(value))+percent
    }
    static func recovers(terrain:Int) -> Bool { [8,13,14].contains(terrain) }
}

/// Text rules of the victory conditions window.
enum OriginalBattleConditions {
    /// MAIN1610..161B2 fills one line up to `width` half-width columns, stops
    /// at a line feed, and a double-byte character never splits. The window
    /// calls it while its row stays above `lineEnd`.
    static func lines(_ text:String,width:Int,count:Int) -> [String] {
        var result:[String] = [],current = "",columns = 0
        func flush() { result.append(current);current = "";columns = 0 }
        for character in text where result.count < count && character != "\r" {
            if character == "\n" || character == "\r\n" { flush();continue }
            let wide = !character.isASCII
            if wide ? columns+2 > width : columns > width { flush() }
            guard result.count < count else { break }
            current.append(character);columns += wide ? 2 : 1
        }
        if !current.isEmpty && result.count < count { flush() }
        return result
    }
    /// The message formatter treats %u and %w alike; a digit sets the width.
    static func numbered(_ format:String,_ values:[Int]) -> String {
        var text = format
        for value in values {
            guard let range = text.range(of:"%[0-9]?[uw]",options:.regularExpression) else { break }
            let width = text[range].first(where:\.isNumber)?.wholeNumberValue ?? 0
            let digits = String(value)
            text.replaceSubrange(range,with:String(repeating:" ",count:max(0,width-digits.count))+digits)
        }
        return text
    }
    static func title(_ format:String,chapter:String,name:String) -> String {
        [chapter,name].reduce(format) { text,value in
            guard let range = text.range(of:"%s") else { return text }
            return text.replacingCharacters(in:range,with:value)
        }
    }
}

/// MAIN28806..2895A: filled width and the tile chosen from the tenths ratio.
struct OriginalBattleGauge:Equatable {
    var fill:Int; var tile:String
    init(current:Int,maximum:Int,width:Int) {
        let tenths = maximum > 0 ? current*10/maximum : 0
        fill = min(width,maximum > 0 ? width*current/maximum : 0)
        tile = tenths >= 7 ? "high" : tenths >= 3 ? "middle" : "low"
    }
}

/// Images and texts of the battle screen, resolved from local story data.
/// Without those facts the view keeps the layout on plain panels.
struct OriginalBattleStyle {
    var layout = OriginalBattleLayout.source
    var frame:CGImage?
    var minimap:CGImage?
    var functionPressed:CGImage?
    var side:[[CGImage]] = []
    var gauge:[String:CGImage] = [:]
    var ok:CGImage?
    var colors:[NSColor] = (0..<16).map { NSColor(white:CGFloat($0)/15,alpha:1) }
    var texts:OriginalBattleTexts?
    var commands:OriginalBattleCommands?

    static var plain:Self { Self() }
    static func load(definition:BattleDefinition,root:URL,story:OriginalStoryCatalog? = nil) throws -> Self {
        var style = Self.plain
        func picture(_ path:String?) throws -> CGImage? {
            guard let path = path else { return nil }
            let url = try containedResource(root:root,relative:path)
            guard let image = NSBitmapImageRep(data:try Data(contentsOf:url))?.cgImage else {
                throw EngineError.invalid("Battle screen picture is unreadable: \(path)")
            }
            return image
        }
        style.minimap = try picture(definition.minimap)
        let file = root.appendingPathComponent("story.json")
        let catalog = try story ?? (FileManager.default.fileExists(atPath:file.path) ? OriginalStoryCatalog.load(from:file) : nil)
        guard let catalog = catalog,let screen = catalog.screens?.battle else { return style }
        style.layout = screen.layout;style.texts = screen.texts;style.commands = screen.commands
        style.frame = try picture(catalog.frameImage(screen.frameAsset,palette:3))
        style.functionPressed = try picture(screen.parts.function.image)
        style.side = try screen.parts.side.map { try $0.compactMap { try picture($0.image) } }
        style.gauge = try screen.parts.gauge.compactMapValues { try picture($0.image) }
        style.ok = try picture(screen.parts.ok.image)
        style.colors = screen.colors.map { NSColor(srgbRed:CGFloat($0[0])/255,green:CGFloat($0[1])/255,blue:CGFloat($0[2])/255,alpha:1) }
        return style
    }
}
