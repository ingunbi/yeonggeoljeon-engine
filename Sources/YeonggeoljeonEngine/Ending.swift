// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct OriginalEndingAsset: Codable, Equatable {
    var id: String
    var image: String
    var width: Int
    var height: Int
}
struct OriginalEndingLayer: Codable, Equatable {
    var asset: String
    var x: Int
    var y: Int
}
struct OriginalEndingCaption: Codable, Equatable {
    var asset: String
    var lines: [String]
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var lineHeight: Int
    var sourceChunk: Int
}
struct OriginalEndingFrame: Codable, Equatable {
    var sourceTicks: Int
    var layers: [OriginalEndingLayer]
    var caption: OriginalEndingCaption?
}
struct OriginalEndingFrontier: Codable, Equatable {
    var resource: String
    var offset: Int
    var reason: String
}
struct OriginalEndingProgram: Codable, Equatable {
    var id: String
    var frames: [OriginalEndingFrame]
    var complete: Bool
    var frontier: OriginalEndingFrontier
}
struct OriginalEndingSelection: Codable, Equatable {
    var value: Int
    var program: String
    var complete: Bool
}
struct OriginalEndingCatalog: Codable, Equatable {
    var format: Int
    var sourceDigest: String
    var canvas: [Int]
    var sourceTicksPerSecond: Int
    var assets: [OriginalEndingAsset]
    var selections: [OriginalEndingSelection]
    var programs: [OriginalEndingProgram]
    var limitations: [String]?

    static func load(from url: URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }
    func validate() throws {
        guard format == 1, sourceDigest.count == 64,
              sourceDigest.allSatisfy({ $0.isHexDigit }), canvas == [640, 400], sourceTicksPerSecond == 100,
              !assets.isEmpty, assets.count <= 1024, !programs.isEmpty, programs.count <= 256,
              Set(assets.map(\.id)).count == assets.count,
              Set(programs.map(\.id)).count == programs.count,
              Set(selections.map(\.value)).count == selections.count else {
            throw EngineError.invalid("Original ending catalog identity is invalid")
        }
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        for asset in assets {
            let path = asset.image.split(separator: "/", omittingEmptySubsequences: false)
            guard !asset.id.isEmpty, !asset.image.hasPrefix("/"), !asset.image.contains("\\"),
                  !path.contains(".."), !path.contains("."), !path.contains(""),
                  (1...2048).contains(asset.width), (1...400).contains(asset.height) else {
                throw EngineError.invalid("Original ending asset path or dimensions are invalid")
            }
        }
        for program in programs {
            // A frame list ending is not evidence that the source program ended.
            guard !program.complete, !program.frames.isEmpty, program.frames.count <= 4096,
                  program.frontier.offset >= 0, !program.frontier.resource.isEmpty,
                  !program.frontier.reason.isEmpty else {
                throw EngineError.invalid("Original ending requires an explicit unrestored frontier")
            }
            for frame in program.frames {
                guard frame.sourceTicks > 0, frame.sourceTicks <= Int(UInt16.max),
                      frame.layers.count <= 64 else {
                    throw EngineError.invalid("Original ending frame duration or layer count is invalid")
                }
                for layer in frame.layers {
                    guard let asset = byID[layer.asset], (0..<640).contains(layer.x),
                          (0..<400).contains(layer.y), asset.width <= 640 - layer.x,
                          asset.height <= 400 - layer.y else {
                        throw EngineError.invalid("Original ending layer is outside its source canvas")
                    }
                }
                if let caption = frame.caption {
                    guard let asset = byID[caption.asset], caption.width == asset.width,
                          caption.height == asset.height, caption.x > -caption.width,
                          caption.x < 640, caption.y >= 0, caption.y + caption.height <= 400,
                          caption.lineHeight > 0, caption.lines.count * caption.lineHeight == caption.height,
                          caption.sourceChunk >= 0 else {
                        throw EngineError.invalid("Original ending caption has no bounded source bitmap")
                    }
                }
            }
        }
        for selection in selections {
            guard (0...255).contains(selection.value), !selection.complete,
                  programs.contains(where: { $0.id == selection.program }) else {
                throw EngineError.invalid("Original ending selection has no restored source program")
            }
        }
    }
}

struct OriginalEndingState: Codable, Equatable {
    var sourceDigest: String
    var selection: Int
    var programID: String
    var frameIndex: Int
    var elapsedSourceTicks: Int
}
enum OriginalEndingOutput: Equatable {
    case frame(OriginalEndingFrame)
    case unsupported(OriginalEndingFrontier)
}

/// Owns source ordering and clock units. END reads DOS centiseconds and builds
/// elapsed deadlines at 100 ticks/second; the host supplies elapsed source ticks.
final class OriginalEndingSession {
    let catalog: OriginalEndingCatalog
    let program: OriginalEndingProgram
    private(set) var state: OriginalEndingState

    init(catalog: OriginalEndingCatalog, selection: Int, state restored: OriginalEndingState? = nil) throws {
        try catalog.validate()
        guard let route = catalog.selections.first(where: { $0.value == selection }),
              let program = catalog.programs.first(where: { $0.id == route.program }) else {
            throw EngineError.invalid("Original ending selection \(selection) is not restored")
        }
        self.catalog = catalog
        self.program = program
        state = restored ?? OriginalEndingState(sourceDigest: catalog.sourceDigest, selection: selection,
                                                 programID: program.id, frameIndex: 0, elapsedSourceTicks: 0)
        guard state.sourceDigest == catalog.sourceDigest, state.selection == selection,
              state.programID == program.id, (0...program.frames.count).contains(state.frameIndex),
              state.elapsedSourceTicks >= 0,
              (state.frameIndex < program.frames.count
                ? state.elapsedSourceTicks < program.frames[state.frameIndex].sourceTicks
                : state.elapsedSourceTicks == 0) else {
            throw EngineError.invalid("Original ending checkpoint does not match the selected source program")
        }
    }
    var output: OriginalEndingOutput {
        state.frameIndex == program.frames.count ? .unsupported(program.frontier) : .frame(program.frames[state.frameIndex])
    }
    @discardableResult func advance(sourceTicks: Int) throws -> OriginalEndingOutput {
        guard sourceTicks >= 0 else { throw EngineError.invalid("Original ending cannot advance by negative source ticks") }
        var remaining = sourceTicks
        while remaining > 0, state.frameIndex < program.frames.count {
            let duration = program.frames[state.frameIndex].sourceTicks - state.elapsedSourceTicks
            if remaining < duration {
                state.elapsedSourceTicks += remaining
                remaining = 0
            } else {
                remaining -= duration
                state.frameIndex += 1
                state.elapsedSourceTicks = 0
            }
        }
        return output
    }
    func snapshot() -> OriginalEndingState { state }
}
