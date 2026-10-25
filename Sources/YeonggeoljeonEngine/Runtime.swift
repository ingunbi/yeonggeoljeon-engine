// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum EngineError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let text): return text } }
}

enum JSONValue: Codable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

struct Direction: Codable { var frame: Int; var flip: Bool }
struct Neighbor: Codable { var dx: Int; var dy: Int; var direction: Int }
struct MapObject: Codable {
    var id: String; var image: String; var x: Int; var y: Int
    var anchorX: Int; var anchorY: Int; var width: Int; var height: Int
    var source: JSONValue?
}
struct MapResource: Codable {
    var image: String; var width: Int; var height: Int
    var viewport: [Int]?
    var walkWidth: Int?; var walkHeight: Int?; var walkGrid: [String]?
    var walkBytes: [Int]?
    var neighborsEven: [Neighbor]?; var neighborsOdd: [Neighbor]?
    var objects: [MapObject]?
    var geometry:String? = nil
    var stepMicroseconds:Int64? = nil
    var placementDirections:[Int]? = nil
}
struct ActorResource: Codable {
    var image: String; var frameWidth: Int; var frameHeight: Int; var frames: Int
    var anchorX: Int; var anchorY: Int; var directions: [Direction]?
}
struct Resources: Codable {
    var format: Int; var title: String?
    var maps: [String: MapResource]; var actors: [String: ActorResource]
    var portraits: [String: JSONValue]?
    var provenance: JSONValue?
}
struct Timing: Codable { var stepMicroseconds: Int64; var terminalMicroseconds: Int64 }
struct Coordinates: Codable { var grid: [Int]; var columnStaggerY: Int; var actorAnchor: [Int] }
struct Command: Codable {
    var op: String
    var map: Int?; var person: Int?; var x: Int?; var y: Int?; var facing: Int?
    // Opcode01/0A facing is a quarter-direction byte. Cache/default placement
    // already owns the generic raw8 field; the two domains are exclusive.
    var sourcePlacementFacing:Int?
    var speaker: String?; var text: String?; var reason: String?
    var seconds: Double?; var to: String?; var coordinateUnits: String?
    var boundary: String?
    var source: JSONValue?; var textSource: JSONValue?
    init(_ op: String, person: Int? = nil, x: Int? = nil, y: Int? = nil, facing: Int? = nil,
         map: Int? = nil, text: String? = nil, seconds: Double? = nil,sourcePlacementFacing:Int? = nil) {
        self.op = op; self.person = person; self.x = x; self.y = y; self.facing = facing
        self.map = map; self.text = text; self.seconds = seconds
        self.sourcePlacementFacing = sourcePlacementFacing
    }
    func genericPlacementDirection() throws -> Int? {
        guard facing == nil || sourcePlacementFacing == nil else { throw EngineError.invalid("Original placement mixes script and generic facing domains") }
        if let raw = sourcePlacementFacing {
            guard (0..<8).contains(raw) else { throw EngineError.invalid("Invalid original generic placement facing") }
            return raw
        }
        guard let script = facing else { return nil }
        guard (0..<4).contains(script) else { throw EngineError.invalid("Invalid original script facing") }
        return script*2
    }
}
struct Scene: Codable {
    var format: Int; var id: String; var name: String; var width: Int; var height: Int
    var coordinateSystem: String; var viewport: [Int]?
    var coordinates: Coordinates?; var timing: Timing?
    var commands: [Command]; var provenance: JSONValue?
}
func containedResource(root:URL,relative:String) throws -> URL {
    guard !relative.isEmpty, !relative.hasPrefix("/"),
          !relative.split(separator:"/").contains(".."), !relative.contains(":") else {
        throw EngineError.invalid("Image path is not a contained relative path: \(relative)")
    }
    let base = root.standardizedFileURL.resolvingSymlinksInPath()
    let url = base.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
    let prefix = base.path.hasSuffix("/") ? base.path : base.path+"/"
    guard url.path.hasPrefix(prefix) else { throw EngineError.invalid("Image path escapes data root") }
    return url
}
struct DataSet {
    let root: URL; let resources: Resources; let scene: Scene
    init(root: URL) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        let decoder = JSONDecoder()
        resources = try decoder.decode(Resources.self, from: Data(contentsOf: self.root.appendingPathComponent("resources.json")))
        scene = try decoder.decode(Scene.self, from: Data(contentsOf: self.root.appendingPathComponent("scene.json")))
        try validate()
    }
    init(resources: Resources, scene: Scene) throws {
        root = URL(fileURLWithPath: "."); self.resources = resources; self.scene = scene
        try validate()
    }
    init(root:URL, resources:Resources, scene:Scene) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.resources = resources; self.scene = scene
        try validate()
    }
    func replacingScene(_ scene:Scene) throws -> DataSet {
        try DataSet(root:root,resources:resources,scene:scene)
    }
    func containedFile(_ relative: String) throws -> URL {
        try containedResource(root:root,relative:relative)
    }
    private func validate() throws {
        guard resources.format == 1, scene.format == 1, scene.width == 640, scene.height == 400,
              scene.coordinateSystem == "town" else { throw EngineError.invalid("Unsupported data format or coordinate system") }
        if let c = scene.coordinates {
            guard c.grid == [16,16], c.columnStaggerY == 8, c.actorAnchor == [0,24] else {
                throw EngineError.invalid("Unsupported town source geometry")
            }
        }
        if let t = scene.timing {
            guard t.stepMicroseconds > 0, t.terminalMicroseconds >= 0 else { throw EngineError.invalid("Invalid source movement timing") }
        }
        func validateViewport(_ v: [Int]?) throws {
            guard let v = v else { return }
            guard v.count == 4, (0...640).contains(v[0]), (0...400).contains(v[1]),
                  (1...640).contains(v[2]), (1...400).contains(v[3]),
                  v[0]+v[2] <= 640, v[1]+v[3] <= 400 else { throw EngineError.invalid("Invalid source viewport") }
        }
        try validateViewport(scene.viewport)
        for key in resources.actors.keys {
            guard let person = Int(key), (0..<384).contains(person), String(person) == key else { throw EngineError.invalid("Actor key is not a literal source person ID") }
        }
        for actor in resources.actors.values {
            guard actor.frameWidth == 32, actor.frameHeight == 40, actor.frames == 4,
                  actor.anchorX == 0, actor.anchorY == 24 else { throw EngineError.invalid("Unsupported source actor geometry") }
            guard let directions = actor.directions, directions.count == 4,
                  directions.allSatisfy({ $0.frame >= 0 && $0.frame < actor.frames - 1 }) else {
                throw EngineError.invalid("Actor direction mapping is missing or invalid")
            }
            _ = try containedFile(actor.image)
        }
        for map in resources.maps.values {
            try validateViewport(map.viewport)
            guard map.width == 512, map.height == 320 else { throw EngineError.invalid("Unsupported palace bitmap dimensions") }
            guard let w = map.walkWidth, let h = map.walkHeight, w > 0, h > 0,
                  w <= map.width/16, h <= map.height/16 else { throw EngineError.invalid("Walk grid exceeds source map dimensions") }
            _ = try containedFile(map.image)
            for object in map.objects ?? [] {
                guard (0...255).contains(object.x), (0...255).contains(object.y),
                      object.width > 0, object.width <= map.width, object.height >= 16, object.height <= map.height,
                      object.anchorX == 0, object.anchorY == object.height-16 else { throw EngineError.invalid("Invalid source prop geometry") }
                _ = try containedFile(object.image)
            }
        }
        if let title = resources.title { _ = try containedFile(title) }
    }
}

struct GridPoint: Codable, Equatable, Hashable { var x: Int; var y: Int }
struct ActorState: Codable, Equatable {
    var person: Int; var position: GridPoint; var facing: Int; var phase: Int
    var registration: Int; var walking: Bool
}
struct RouteNode: Codable, Equatable { var position: GridPoint; var facing: Int }
struct Motion: Codable, Equatable {
    var person: Int; var route: [RouteNode]; var finalFacing: Int; var source: JSONValue?
}
struct MoveBatch: Codable, Equatable {
    var motions: [Motion]; var elapsed: Int64; var duration: Int64
    var step: Int64; var terminal: Int64
}
struct TraceEntry: Codable {
    var microseconds: Int64; var command: Int; var operation: String
    var source: JSONValue?; var textSource: JSONValue?; var details: String
}
struct SourceCommandFailure:Error {
    var index:Int;var command:Command;var reason:String
}
struct Snapshot: Codable, Equatable {
    var mode: String; var microseconds: Int64; var nextCommand: Int
    var map: Int?; var camera: [Int]; var blackAlpha: Double
    var actors: [ActorState]; var dialogue: CommandSnapshot?; var batch: MoveBatch?
    var endReason: String?; var inputCount: Int
    var visible: Bool; var caption: String?
    var termination: Termination?
    var followPerson:Int? = nil
    var storyPanel:OriginalStoryPanel? = nil
    var palette:Int? = nil
}
struct OriginalStoryPanel:Codable,Equatable {
    var image:String; var mode:Int; var source:JSONValue?
}
enum Termination: String, Codable { case sourceBoundary, unsupportedBoundary, runtimeFailure, unexpectedEOF }
struct CommandSnapshot: Codable, Equatable {
    var person: Int?; var speaker: String; var text: String; var source: JSONValue?
    var textSource: JSONValue?
}

/// Contract: research/bootstrap-contract.md. Original-byte exporters own image,
/// walk-grid, neighbor, timing and command provenance; this runtime consumes
/// those facts without importing a pre-existing game's implementation or pack.
/// Integer simulation time is advanced only while a source command is running.
/// Dialogue/title/end wait for input; one input cannot also dismiss the next line.
final class Runtime {
    let data: DataSet
    private(set) var mode = "title"
    private(set) var clock: Int64 = 0
    private(set) var cursor = 0
    private(set) var mapID: Int?
    private(set) var actors: [Int: ActorState] = [:]
    private(set) var dialogue: CommandSnapshot?
    private(set) var batch: MoveBatch?
    private(set) var blackAlpha = 0.0
    private(set) var camera = [0,0]
    private(set) var endReason: String?
    private(set) var trace: [TraceEntry] = []
    private(set) var inputCount = 0
    private(set) var visible = false
    private(set) var caption: String?
    private(set) var termination: Termination?
    private var registration = 0
    private var waitRemaining: Int64 = 0
    private var fadeRemaining: Int64 = 0
    private var fadeDuration: Int64 = 0
    private var fadeStart = 0.0
    private var fadeTarget = 0.0
    private var commands:[Command]
    let hostDriven:Bool
    private var hostMaps:[Int:MapResource] = [:]
    private var hostActors:[String:ActorResource]?
    private var followPerson:Int?
    private(set) var storyPanel:OriginalStoryPanel?
    private(set) var palette = 0 // Original new-game store MAIN1E49A/1E628.

    init(_ data: DataSet,hostDriven:Bool = false) {
        self.data = data; self.hostDriven = hostDriven
        commands = hostDriven ? [] : data.scene.commands
    }
    var hostWaiting:Bool { hostDriven && mode == "scene" && !busy && dialogue == nil && cursor == commands.count }
    /// Campaign VM supplies source batches to one persistent stage. Exhaustion
    /// suspends the stage, retaining actors, camera, clock and source map state.
    func enqueue(_ batch:[Command]) throws {
        guard hostDriven, mode != "ended", commands.count+batch.count <= 1_000_000 else {
            throw EngineError.invalid("Campaign stage queue is unavailable or exceeds its retained command bound")
        }
        commands.append(contentsOf:batch)
        if mode == "scene" { pump() }
    }
    var busy: Bool { batch != nil || waitRemaining > 0 || fadeRemaining > 0 }
    func sourceRoute(person:Int,to target:GridPoint) throws -> [RouteNode] {
        guard hostWaiting,let actor = actors[person] else { throw EngineError.invalid("Original exploration route requires an idle live actor") }
        return try route(from:actor,to:target)
    }
    func setNativeFacing(person:Int,direction:Int) throws {
        guard hostWaiting,var actor = actors[person],(0..<(currentMap?.geometry == "world" ? 8 : 4)).contains(direction) else {
            throw EngineError.invalid("Original input facing requires an idle live actor and native direction")
        }
        actor.facing = direction;actors[person] = actor
    }
    /// Source input planners may trim the final actor-target step. Keep that
    /// exact source route instead of re-solving toward the adjacent endpoint.
    func enqueueSourceRoute(person:Int,route:[RouteNode],finalFacing:Int) throws {
        guard hostWaiting,let actor = actors[person],let first = route.first,
              first.position == actor.position,(0..<(currentMap?.geometry == "world" ? 8 : 4)).contains(finalFacing),
              route.count <= 131073 else { throw EngineError.invalid("Original input route has no matching idle actor state") }
        for node in route { try validateGridPosition(node.position) }
        let timing = currentMap?.stepMicroseconds.map { Timing(stepMicroseconds:$0,terminalMicroseconds:0) }
            ?? data.scene.timing ?? Timing(stepMicroseconds:99_488,terminalMicroseconds:99_488)
        let (travel,overflow) = timing.stepMicroseconds.multipliedReportingOverflow(by:Int64(route.count-1))
        let (duration,overflow2) = travel.addingReportingOverflow(timing.terminalMicroseconds)
        guard !overflow && !overflow2 else { throw EngineError.invalid("Original input movement clock overflow") }
        batch = MoveBatch(motions:[Motion(person:person,route:route,finalFacing:finalFacing,source:nil)],elapsed:0,
            duration:duration,step:timing.stepMicroseconds,terminal:timing.terminalMicroseconds)
        updateActors();if duration == 0 { settleBatch() }
    }
    var currentMap: MapResource? { mapID.flatMap { hostMaps[$0] ?? data.resources.maps[String($0)] } }
    func actorResource(_ person:Int) -> ActorResource? { (hostActors ?? data.resources.actors)[String(person)] }
    func configureMap(_ id:Int,resource:MapResource,actors:[String:ActorResource]?) throws {
        guard hostDriven,(1...4096).contains(resource.width),(1...4096).contains(resource.height),
              let w = resource.walkWidth,let h = resource.walkHeight,w > 0,h > 0,w*h <= 65536,
              resource.geometry == nil || resource.geometry == "world" else {
            throw EngineError.invalid("Original host stage map geometry is invalid")
        }
        _ = try data.containedFile(resource.image)
        if let actors = actors {
            for actor in actors.values {
                guard actor.frameWidth > 0,actor.frameHeight > 0,actor.frames > 0,
                      let directions = actor.directions,!directions.isEmpty,
                      directions.allSatisfy({$0.frame >= 0 && $0.frame+1 < actor.frames}) else {
                    throw EngineError.invalid("Original host actor geometry is invalid")
                }
                _ = try data.containedFile(actor.image)
            }
        }
        hostMaps[id] = resource; hostActors = actors
    }
    func clearActors() throws {
        guard hostWaiting else { throw EngineError.invalid("Cannot clear a running campaign stage") }
        actors.removeAll(); registration = 0
    }
    /// MAIN2255A doubles source logical coordinates as bytes, then211C2
    /// clamps the half-grid origin against the original32×20-cell viewport.
    func worldCamera(x:Int,y:Int,source:JSONValue?) throws {
        guard hostDriven,(0...255).contains(x),(0...255).contains(y),currentMap?.geometry == "world" else {
            throw EngineError.invalid("Original world camera requires its source world map and byte coordinates")
        }
        try centerWorldCamera(GridPoint(x:Int(UInt8(truncatingIfNeeded:2*x)),y:Int(UInt8(truncatingIfNeeded:2*y))))
        followPerson = nil
        var command = Command("world-camera",x:x,y:y);command.source = source;record(cursor,command)
    }
    func worldFollow(person:Int,source:JSONValue?) throws {
        guard hostDriven,currentMap?.geometry == "world" else { throw EngineError.invalid("Original world follow requires its world map") }
        // MAIN2259C leaves the previous follow identity unchanged on lookup failure.
        if actors[person] != nil { followPerson = person }
        var command = Command("world-follow",person:person);command.source = source;record(cursor,command)
    }
    func setPalette(_ value:Int) throws {
        guard (0...3).contains(value) else { throw EngineError.invalid("Original palette context is unsupported") }
        palette = value
    }
    func beginStory(image:String,mode:Int,source:JSONValue?) throws {
        guard hostDriven,[0,1].contains(mode) else { throw EngineError.invalid("Original story mode is outside the restored layout") }
        _ = try data.containedFile(image)
        if mode == 0 { visible = false }
        storyPanel = OriginalStoryPanel(image:image,mode:mode,source:source)
    }
    func closeStory() { storyPanel = nil }
    private func centerWorldCamera(_ point:GridPoint) throws {
        guard let map = currentMap,map.width/16 >= 32,map.height/16 >= 20 else { throw EngineError.invalid("Original world viewport exceeds its picture dimensions") }
        let w = map.width/16,h = map.height/16
        let x = point.x < 15 ? 0 : point.x > w-17 ? w-32 : point.x-15
        let y = point.y < 10 ? 0 : point.y > h-10 ? h-20 : point.y-10
        camera = [x*16,y*16]
    }
    var viewport: [Int] { currentMap?.viewport ?? data.scene.viewport ?? [16,16,512,320] }
    func snapshot() -> Snapshot {
        Snapshot(mode: mode, microseconds: clock, nextCommand: cursor, map: mapID,
                 camera: camera, blackAlpha: blackAlpha,
                 actors: actors.values.sorted { $0.registration < $1.registration },
                 dialogue: dialogue, batch: batch, endReason: endReason, inputCount: inputCount,
                 visible: visible, caption: caption, termination: termination,followPerson:followPerson,storyPanel:storyPanel,palette:palette)
    }
    private func record(_ index: Int, _ command: Command, _ details: String = "") {
        trace.append(TraceEntry(microseconds: clock, command: index, operation: command.op, source: command.source, textSource: command.textSource, details: details))
    }
    func acknowledge() {
        guard !busy, mode != "ended" else { return }
        if mode == "title" { mode = "scene"; inputCount += 1; pump(); return }
        guard dialogue != nil else { return }
        dialogue = nil; inputCount += 1; pump()
    }
    var verifiedBoundary: Bool { termination == .sourceBoundary || termination == .unsupportedBoundary }
    private func finish(_ reason: String, kind: Termination) {
        termination = kind
        mode = "ended"; endReason = reason; batch = nil; waitRemaining = 0; fadeRemaining = 0
    }
    private func required(_ value: Int?, _ name: String) throws -> Int {
        guard let v = value else { throw EngineError.invalid("Missing \(name)") }; return v
    }
    private func duration(_ seconds: Double?) throws -> Int64 {
        guard let s = seconds, s.isFinite, s >= 0, s * 1_000_000 < Double(Int64.max) else {
            throw EngineError.invalid("Invalid command duration")
        }
        return Int64((s * 1_000_000).rounded())
    }
    private func point(_ command: Command) throws -> GridPoint {
        let p = GridPoint(x: try required(command.x, "x"), y: try required(command.y, "y"))
        guard p.x >= 0 && p.y >= 0 else { throw EngineError.invalid("Negative source coordinate") }
        return currentMap?.geometry == "world" ? GridPoint(x:p.x*2,y:p.y*2) : p
    }
    private func facing(_ command: Command, fallback: Int = 0) throws -> Int {
        guard let raw = try command.genericPlacementDirection() else {
            guard (0..<(currentMap?.geometry == "world" ? 8 : 4)).contains(fallback) else { throw EngineError.invalid("Invalid retained native facing") }
            return fallback
        }
        if currentMap?.geometry == "world" {
            guard let directions = currentMap?.placementDirections,directions.count == 8 else { throw EngineError.invalid("Original world placement direction facts are absent") }
            return directions[raw]
        }
        return raw>>1
    }
    private func pump() {
        guard mode == "scene", dialogue == nil, !busy else { return }
        while cursor < commands.count && mode == "scene" && dialogue == nil && !busy {
            let index = cursor, c = commands[cursor]; cursor += 1
            do {
                switch c.op {
                case "close-story": closeStory();record(index,c)
                case "map":
                    let id = try required(c.map, "map")
                    guard hostMaps[id] != nil || data.resources.maps[String(id)] != nil else { throw EngineError.invalid("Map resource is unavailable: \(id)") }
                    mapID = id; actors.removeAll(); camera = [0,0]; registration = 0;followPerson = nil
                    try setPalette(id>>12)
                    visible = false; caption = nil; record(index,c)
                case "show": visible = true; record(index,c)
                case "caption":
                    guard let text = c.text else { throw EngineError.invalid("Caption text is missing") }
                    caption = text; record(index,c,text)
                case "redraw": dialogue = nil; record(index,c)
                case "place":
                    guard currentMap != nil else { throw EngineError.invalid("Place without a map") }
                    let person = try required(c.person,"person"), p = try point(c)
                    guard actorResource(person) != nil else { throw EngineError.invalid("Actor resource is unavailable: \(person)") }
                    try validateGridPosition(p)
                    let slot = actors[person]?.registration ?? registration
                    if actors[person] == nil { registration += 1 }
                    actors[person] = ActorState(person: person, position: p, facing: try facing(c), phase: 0, registration: slot, walking: false)
                    record(index,c,"grid=\(p.x),\(p.y)")
                case "move":
                    var moves = [(index,c)]
                    while cursor < commands.count && commands[cursor].op == "move" {
                        moves.append((cursor,commands[cursor])); cursor += 1
                    }
                    var motions: [Motion] = [], people = Set<Int>()
                    for (at, move) in moves {
                        do {
                        let person = try required(move.person,"person")
                        guard people.insert(person).inserted, let actor = actors[person] else { throw EngineError.invalid("Move actor is missing or repeated in its batch: \(person)") }
                        let target = try point(move), route = try route(from: actor, to: target)
                        motions.append(Motion(person: person, route: route, finalFacing: try facing(move, fallback: actor.facing), source: move.source))
                        record(at,move,"source route nodes=\(route.count)")
                        } catch { throw SourceCommandFailure(index:at,command:move,reason:"\(error)") }
                    }
                    let timing = currentMap?.stepMicroseconds.map { Timing(stepMicroseconds:$0,terminalMicroseconds:0) }
                        ?? data.scene.timing ?? Timing(stepMicroseconds: 99_488,terminalMicroseconds: 99_488)
                    let hops = motions.map { $0.route.count - 1 }.max() ?? 0
                    let (travel, overflow) = timing.stepMicroseconds.multipliedReportingOverflow(by: Int64(hops))
                    let (total, overflow2) = travel.addingReportingOverflow(timing.terminalMicroseconds)
                    guard !overflow && !overflow2 else { throw EngineError.invalid("Movement clock overflow") }
                    batch = MoveBatch(motions: motions, elapsed: 0, duration: total, step: timing.stepMicroseconds, terminal: timing.terminalMicroseconds)
                    updateActors()
                    if total == 0 { settleBatch() }
                case "say":
                    guard let text = c.text else { throw EngineError.invalid("Dialogue text is missing") }
                    dialogue = CommandSnapshot(person: c.person,speaker: c.speaker ?? "",text: text,source: c.source,textSource: c.textSource)
                    record(index,c)
                case "remove":
                    let person = try required(c.person,"person")
                    actors.removeValue(forKey: person); record(index,c,"removed=\(person)")
                case "wait": waitRemaining = try duration(c.seconds); record(index,c)
                case "fade":
                    guard c.to == "black" || c.to == "visible" else { throw EngineError.invalid("Unknown fade destination") }
                    fadeDuration = try duration(c.seconds); fadeRemaining = fadeDuration
                    fadeStart = blackAlpha; fadeTarget = c.to == "black" ? 1 : 0
                    if fadeDuration == 0 { blackAlpha = fadeTarget }; record(index,c)
                case "camera":
                    guard c.coordinateUnits == "pixels" else { throw EngineError.invalid("Camera source units are not established") }
                    let x = try required(c.x,"x"), y = try required(c.y,"y")
                    guard let map = currentMap, x >= 0, y >= 0, x <= map.width, y <= map.height else { throw EngineError.invalid("Camera origin exceeds source map") }
                    camera = [x,y]; record(index,c)
                case "end":
                    guard c.boundary == nil || c.boundary == "unsupported" || c.boundary == "source" else { throw EngineError.invalid("Unknown declared boundary kind") }
                    record(index,c,c.reason ?? "Explicit source boundary")
                    finish(c.reason ?? "Explicit source boundary",kind:c.boundary == "unsupported" ? .unsupportedBoundary : .sourceBoundary)
                default: throw EngineError.invalid("Unsupported source command: \(c.op)")
                }
            } catch {
                if let failed = error as? SourceCommandFailure {
                    record(failed.index,failed.command,"ERROR: \(failed.reason)");finish(failed.reason,kind:.runtimeFailure)
                } else { record(index,c,"ERROR: \(error)"); finish("\(error)",kind:.runtimeFailure) }
            }
        }
        if !hostDriven && cursor == commands.count && !busy && dialogue == nil && mode == "scene" {
            finish("Command stream ended without an explicit source boundary",kind:.unexpectedEOF)
        }
    }
    func advance(microseconds: Int64) {
        guard microseconds > 0, mode == "scene", dialogue == nil else { return }
        var available = microseconds
        while available > 0 && mode == "scene" && dialogue == nil {
            if var b = batch {
                let used = min(available,b.duration - b.elapsed)
                guard advanceClock(used) else { return }
                b.elapsed += used; available -= used; batch = b; updateActors()
                if b.elapsed == b.duration { settleBatch(); pump() }
            } else if waitRemaining > 0 {
                let used = min(available,waitRemaining); guard advanceClock(used) else { return }
                waitRemaining -= used; available -= used
                if waitRemaining == 0 { pump() }
            } else if fadeRemaining > 0 {
                let used = min(available,fadeRemaining); guard advanceClock(used) else { return }
                fadeRemaining -= used; available -= used
                blackAlpha = fadeStart + (fadeTarget-fadeStart) * Double(fadeDuration-fadeRemaining) / Double(fadeDuration)
                if fadeRemaining == 0 { pump() }
            } else { pump(); if !busy { break } }
        }
    }
    private func advanceClock(_ value: Int64) -> Bool {
        let (next, overflow) = clock.addingReportingOverflow(value)
        if overflow {
            trace.append(TraceEntry(microseconds:clock,command:max(0,cursor-1),operation:"runtimeFailure",source:nil,textSource:nil,details:"Simulation clock overflow"))
            finish("Simulation clock overflow",kind:.runtimeFailure); return false
        }
        clock = next; return true
    }
    private func updateActors() {
        guard let b = batch else { return }
        for motion in b.motions {
            guard var actor = actors[motion.person] else { continue }
            let stepIndex = min(Int(b.elapsed / b.step),motion.route.count-1)
            actor.position = motion.route[stepIndex].position
            actor.facing = motion.route[stepIndex].facing
            actor.walking = b.elapsed < Int64(motion.route.count-1) * b.step
            actor.phase = actor.walking ? stepIndex & 1 : 0
            actors[motion.person] = actor
        }
        if let person = followPerson,let actor = actors[person] {
            do { try centerWorldCamera(actor.position) }
            catch { finish("\(error)",kind:.runtimeFailure) }
        }
    }
    private func settleBatch() {
        guard let b = batch else { return }
        for m in b.motions {
            if var actor = actors[m.person] {
                actor.position = m.route.last!.position; actor.facing = m.finalFacing
                actor.walking = false; actor.phase = 0; actors[m.person] = actor
            }
        }
        batch = nil
    }
    private func validateGridPosition(_ p: GridPoint) throws {
        guard let map = currentMap, let width = map.walkWidth, let height = map.walkHeight,
              p.x < width*(map.geometry == "world" ? 2 : 1), p.y < height*(map.geometry == "world" ? 2 : 1) else { throw EngineError.invalid("Source coordinate lies outside the walk grid") }
    }
    /// Destination flood followed by source-ordered strict-lower selection.
    /// Geometry, blocked bits and neighbor directions are resource-owner facts.
    private func route(from actor: ActorState, to target: GridPoint) throws -> [RouteNode] {
        try validateGridPosition(actor.position); try validateGridPosition(target)
        guard let map = currentMap, let width = map.walkWidth, let height = map.walkHeight,
              let grid = map.walkGrid, grid.count == height,
              let even = map.neighborsEven, let odd = map.neighborsOdd,
              even.count == (map.geometry == "world" ? 8 : 4), odd.count == even.count else { throw EngineError.invalid("Source walk facts are unavailable") }
        if map.geometry == "world" { return try worldRoute(from:actor,to:target,map:map) }
        let cells = grid.map { Array($0) }
        guard cells.allSatisfy({ $0.count == width && $0.allSatisfy { $0 == "." || $0 == "#" } }),
              (even+odd).allSatisfy({ (-1...1).contains($0.dx) && (-1...1).contains($0.dy) && (0..<4).contains($0.direction) }) else {
            throw EngineError.invalid("Invalid source walk facts")
        }
        if actor.position == target { return [RouteNode(position: target,facing: actor.facing)] }
        func passable(_ p: GridPoint) -> Bool {
            // MAIN256BC..256D4 gates only source walk-byte bit80. Dynamic
            // actor IDs below80 are not obstacles, including queued movers.
            p.x >= 0 && p.y >= 0 && p.x < width && p.y < height && cells[p.y][p.x] == "."
        }
        guard passable(target) else { throw EngineError.invalid("Movement destination is blocked") }
        var distances = [GridPoint: Int](), queue = [target], at = 0
        distances[target] = 0
        while at < queue.count {
            let point = queue[at]; at += 1
            for n in (point.x & 1 == 0 ? even : odd) {
                let next = GridPoint(x:point.x+n.dx,y:point.y+n.dy)
                if distances[next] == nil && (passable(next) || next == actor.position) {
                    distances[next] = distances[point]! + 1; queue.append(next)
                }
            }
        }
        guard distances[actor.position] != nil else { throw EngineError.invalid("No source walk route reaches the destination") }
        var point = actor.position, result = [RouteNode(position:actor.position,facing:actor.facing)]
        while point != target {
            var best = distances[point]!, chosen: RouteNode?
            for n in (point.x & 1 == 0 ? even : odd) {
                let next = GridPoint(x:point.x+n.dx,y:point.y+n.dy)
                if let d = distances[next], d < best {
                    best = d; chosen = RouteNode(position:next,facing:n.direction)
                }
            }
            guard let node = chosen else { throw EngineError.invalid("Source route reconstruction failed") }
            result.append(node); point = node.position
        }
        return result
    }
    private func worldRoute(from actor:ActorState,to target:GridPoint,map:MapResource) throws -> [RouteNode] {
        guard let w = map.walkWidth,let h = map.walkHeight,let rows = map.walkGrid,
              rows.count == h,rows.allSatisfy({$0.count == w}),let neighbors = map.neighborsEven,
              actor.position.x&1 == 0,actor.position.y&1 == 0,target.x&1 == 0,target.y&1 == 0 else {
            throw EngineError.invalid("Original world grid/halfstep state is invalid")
        }
        let grid = rows.map(Array.init),start = GridPoint(x:actor.position.x/2,y:actor.position.y/2),goal = GridPoint(x:target.x/2,y:target.y/2)
        func passable(_ p:GridPoint) -> Bool { p.x >= 0 && p.y >= 0 && p.x < w && p.y < h && grid[p.y][p.x] == "." }
        guard passable(goal) else { throw EngineError.invalid("Original world destination is blocked") }
        var queue = [goal],distances = [goal:0],cursor = 0
        while cursor < queue.count {
            let p = queue[cursor]; cursor += 1
            for n in neighbors {
                let next = GridPoint(x:p.x+n.dx,y:p.y+n.dy)
                if distances[next] == nil && (passable(next) || next == start) {
                    distances[next] = distances[p]!+1; queue.append(next)
                }
            }
        }
        guard distances[start] != nil else { throw EngineError.invalid("Original world destination is unreachable") }
        var p = start,result = [RouteNode(position:actor.position,facing:actor.facing)]
        while p != goal {
            var best = distances[p]!,chosen:Neighbor?
            for n in neighbors {
                let next = GridPoint(x:p.x+n.dx,y:p.y+n.dy)
                if let distance = distances[next],distance < best { best = distance;chosen = n }
            }
            guard let n = chosen else { throw EngineError.invalid("Original world route lost strict descent") }
            result.append(RouteNode(position:GridPoint(x:p.x*2+n.dx,y:p.y*2+n.dy),facing:n.direction))
            p = GridPoint(x:p.x+n.dx,y:p.y+n.dy)
            result.append(RouteNode(position:GridPoint(x:p.x*2,y:p.y*2),facing:n.direction))
        }
        return result
    }
}
