// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct OriginalStoryAsset:Codable {
    var id:Int; var image:String; var width:Int; var height:Int
    var imagesByPalette:[String:String]; var source:JSONValue?
}
struct OriginalStoryLayout:Codable {
    var mode:Int; var clearRect:[Int]?; var panelRect:[Int]; var pictureRect:[Int]
    var source:JSONValue?
}
/// One HUD writer of MAIN's field screen (CF5:C456 and its helpers).
struct OriginalHUDField:Codable,Equatable {
    var rect:[Int]
    var clearColor:Int?
    var text:[Int]?
    var format:String?
    var textColor:Int?
    var portraitID:Int?
    var source:JSONValue?
}
/// Words of the four field icons (MAIN 0x22DB8..0x23DBA).
struct OriginalFieldTexts:Codable {
    var personInfo,itemExchange,exchangePrompt,personOne,personTwo,people,storyInfo,wholeMap,notHere,noItems,level:String
    /// Troops, attack and defense labels of the person screen.
    var stats:[String]
}
struct OriginalFieldScreen:Codable {
    var frameAsset:Int; var viewport:[Int]; var hud:[String:OriginalHUDField]; var source:JSONValue?
    var texts:OriginalFieldTexts? = nil
    /// Story, people, whole map and menu, in the order of the DS:3636 handlers.
    var icons:[[Int]]? = nil
}
struct OriginalBattleScreen:Codable {
    var frameAsset:Int; var layout:OriginalBattleLayout; var colors:[[Int]]
    var texts:OriginalBattleTexts; var parts:OriginalBattleParts
    var commands:OriginalBattleCommands; var source:JSONValue?
}
/// PACKGRP screen frames and the field HUD layout read from MAIN immediates.
/// One CF5:2C92 button menu drawn from MARK art without its labels
/// (tools/menu_windows.py): the window, its button rectangles and picture.
struct OriginalMenuWindow:Codable {
    var window:[Int]; var buttons:[[Int]]; var image:String
    var backgroundSaved:Bool; var currentChoiceDisabled:Bool; var source:JSONValue?
}
/// The title menu, its options and their two-choice sub-menus, with the
/// label colours 7 and 2 of palette slot 0.
struct OriginalMenuWindows:Codable {
    var windows:[String:OriginalMenuWindow]; var text:[Int]; var disabled:[Int]; var source:JSONValue?
}
struct OriginalScreenFacts:Codable {
    var field:OriginalFieldScreen; var battle:OriginalBattleScreen; var limitations:[String]?
    var menus:OriginalMenuWindows? = nil
    static let hudNames:Set<String> = ["caption","money","level","territory","portrait"]
}
/// MARK member0 Yes/No button pattern for the two-button selector.
struct OriginalChoiceButton:Codable {
    var value:Int; var label:String; var width:Int; var height:Int
    var imagesByPalette:[String:String]; var source:JSONValue?
}
struct OriginalStoryCatalog:Codable {
    var format:Int; var assets:[OriginalStoryAsset]; var layouts:[OriginalStoryLayout]
    var portraitAssets:[OriginalStoryAsset]?
    var choiceButtons:[OriginalChoiceButton]?
    var screens:OriginalScreenFacts?
    var source:JSONValue?; var limitations:[String]?
    static func load(from url:URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
        guard value.format == 1,value.assets.count <= 256,Set(value.assets.map(\.id)).count == value.assets.count,
              value.layouts.allSatisfy({[0,1].contains($0.mode) && $0.panelRect == [152,32,240,160] && $0.pictureRect == [160,40,224,144]}) else {
            throw EngineError.invalid("Original story asset/layout contract is invalid")
        }
        if let screens = value.screens {
            let frames = [screens.field.frameAsset,screens.battle.frameAsset].map { id in value.assets.first(where:{$0.id == id}) }
            let inside:([Int]) -> Bool = { $0.count == 4 && $0[0] >= 0 && $0[1] >= 0 && $0[2] > 0 && $0[3] > 0 && $0[0]+$0[2] <= 640 && $0[1]+$0[3] <= 400 }
            let battle = screens.battle
            guard battle.layout == .source,battle.colors.count == 16,battle.colors.allSatisfy({ $0.count == 3 && $0.allSatisfy((0...255).contains) }),
                  battle.texts.forces.count == 15,battle.texts.forces.allSatisfy({ !$0.isEmpty }),!battle.texts.retired.isEmpty,
                  battle.parts.side.count == 2,battle.parts.side.allSatisfy({ $0.count == 2 && $0.allSatisfy({ $0.width == 32 && $0.height == 32 }) }),
                  battle.parts.function.width == 64,battle.parts.function.height == 16,battle.commands.isValid,
                  battle.parts.ok.width == 48,battle.parts.ok.height == 20,
                  Set(battle.parts.gauge.keys) == ["high","middle","low"],battle.parts.gauge.values.allSatisfy({ $0.width == 8 && $0.height == 10 }) else {
                throw EngineError.invalid("Original battle screen facts are invalid")
            }
            guard frames.allSatisfy({ $0?.width == 640 && $0?.height == 400 }),screens.field.viewport == [16,16,512,320],
                  Set(screens.field.hud.keys) == OriginalScreenFacts.hudNames,screens.field.hud.values.allSatisfy({ inside($0.rect) }),
                  screens.field.hud["portrait"]?.rect.suffix(2) == [64,80] else {
                throw EngineError.invalid("Original screen frame/HUD facts are invalid")
            }
        }
        return value
    }
    func frameImage(_ id:Int,palette:Int) -> String? {
        assets.first(where:{$0.id == id && $0.width == 640 && $0.height == 400})?.imagesByPalette[String(palette)]
    }
    func choiceButtonImage(value:Int,palette:Int) -> String? {
        choiceButtons?.first(where:{$0.value == value && $0.width == 48 && $0.height == 20})?.imagesByPalette[String(palette)]
    }
    func portraitImage(_ id:Int,palette:Int) -> String? {
        portraitAssets?.first(where:{$0.id == id})?.imagesByPalette[String(palette)]
    }
    func picture(_ id:Int,mode:Int,palette:Int) throws -> String {
        guard layouts.contains(where:{$0.mode == mode}),let asset = assets.first(where:{$0.id == id}),
              asset.width == 224,asset.height == 144,let image = asset.imagesByPalette[String(palette)] else {
            throw EngineError.invalid("Original story figure/layout/palette is not supported by its source image")
        }
        return image
    }
}
