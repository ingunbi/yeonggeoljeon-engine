// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers

@main
struct YeonggeoljeonIPadApp:App {
    var body:some SwiftUI.Scene {WindowGroup {IPadGameScreen()}}
}

/// Colours, icons and button looks shared by every iPad screen.
private enum IPadTheme {
    static let ink = Color(red:0.055,green:0.075,blue:0.12)
    static let surface = Color(red:0.105,green:0.13,blue:0.2)
    static let gold = Color(red:0.96,green:0.79,blue:0.42)
    static let onGold = Color(red:0.16,green:0.11,blue:0.03)

    static func symbol(for title:String) -> String? {
        switch title {
        case "이동":return "figure.walk"
        case "공격":return "bolt.fill"
        case "책략":return "sparkles"
        case "도구":return "shippingbox.fill"
        case "대기":return "pause.circle.fill"
        case "취소":return "xmark.circle.fill"
        case "다음 부대":return "forward.fill"
        case "턴 종료":return "flag.checkered"
        case "인물·목적지":return "map.fill"
        default:return nil
        }
    }
    static let primaryIDs:Set<String> = ["new","yes","confirm","next","deploy","save","use","dialogue","shop-next","retirement","item-next"]
    static func isPrimary(_ action:IPadAction) -> Bool {primaryIDs.contains(action.id)}
    static func isFooter(_ action:IPadAction) -> Bool {
        action.id == "back" || action.id == "deploy" || action.id == "skip" || action.id == "decline" || action.id.hasPrefix("cancel")
    }
}

/// A solid gold button for the main answer, a quiet outlined one for the rest.
private struct IPadPillStyle:ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius:14)
        let fill:Color = primary ? IPadTheme.gold : Color.white.opacity(0.09)
        let edge:Color = primary ? Color.clear : IPadTheme.gold.opacity(0.4)
        let text:Color = primary ? IPadTheme.onGold : IPadTheme.gold
        let alpha:Double = enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35
        return configuration.label
            .font(.headline).foregroundStyle(text)
            .multilineTextAlignment(.center)
            .frame(maxWidth:.infinity,minHeight:52)
            .padding(.horizontal,14)
            .background(shape.fill(fill))
            .overlay(shape.stroke(edge,lineWidth:1))
            .opacity(alpha)
            .contentShape(shape)
    }
}

/// One cell of the bottom command bar: icon over label, spread evenly.
private struct IPadDockStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius:14)
        let fill:Color = Color.white.opacity(configuration.isPressed ? 0.22 : 0.09)
        return configuration.label
            .frame(maxWidth:170,minHeight:62)
            .background(shape.fill(fill))
            .opacity(enabled ? 1 : 0.35)
            .contentShape(shape)
    }
}

private struct IPadRowStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View {
        let fill:Color = Color.white.opacity(configuration.isPressed ? 0.12 : 0)
        return configuration.label
            .background(fill)
            .opacity(enabled ? 1 : 0.35)
    }
}

private struct IPadIconButton:View {
    let symbol:String
    let label:String
    let action:()->Void
    var body:some View {
        Button(action:action) {
            Image(systemName:symbol).font(.title3.weight(.semibold)).foregroundStyle(IPadTheme.gold)
                .frame(width:48,height:48).background(Circle().fill(Color.white.opacity(0.09)))
        }.accessibilityLabel(label)
    }
}

private struct IPadGameScreen:View {
    @StateObject private var game = IPadGameStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var sheetHeight:CGFloat = 420

    var body:some View {
        GeometryReader {geometry in
            VStack(spacing:0) {
                header
                stage(geometry)
                if game.prompt == nil,game.host?.stage.palette == 3 {
                    Text("두 손가락으로 확대 · 드래그로 지도 이동")
                        .font(.caption).foregroundStyle(.secondary).padding(.vertical,6)
                        .frame(maxWidth:.infinity).background(IPadTheme.ink)
                }
                if !game.actions.isEmpty,game.host?.hasStarted == true {dock}
            }
            .background(IPadTheme.ink.ignoresSafeArea()).preferredColorScheme(.dark).tint(IPadTheme.gold)
            .sheet(isPresented:Binding(get:{game.menu != nil && game.host?.hasStarted == true},set:{if !$0 {game.closeMenu()}})) {
                if let panel = game.menu {
                    let limit:CGFloat = geometry.size.height*0.82
                    VStack(spacing:0) {
                        HStack {
                            Spacer()
                            Button("닫기") {game.closeMenu()}.font(.body.weight(.semibold)).frame(minWidth:64,minHeight:48)
                        }.padding(.horizontal,12).padding(.top,4)
                        IPadPanelView(panel:panel,maxHeight:limit-60,framed:false)
                    }
                    .background(GeometryReader {proxy in Color.clear.preference(key:IPadSheetHeightKey.self,value:proxy.size.height)})
                    .onPreferenceChange(IPadSheetHeightKey.self) {sheetHeight = $0}
                    .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
                    .background(IPadTheme.surface.ignoresSafeArea())
                    .preferredColorScheme(.dark).tint(IPadTheme.gold)
                    .presentationDetents([.height(max(220,min(sheetHeight,limit))),.large])
                }
            }
            .fileImporter(isPresented:$importing,allowedContentTypes:[.json],allowsMultipleSelection:false) {result in
                importing = false
                game.setActive(scenePhase == .active)
                do {if let url = try result.get().first {game.importSave(url)}}
                catch {game.error = error.localizedDescription}
            }
            .alert("진행을 확인해 주세요",isPresented:Binding(get:{game.error != nil},set:{if !$0 {game.error = nil}})) {
                Button("확인",role:.cancel) {game.error = nil}
            } message:{Text(game.error ?? "")}
            .onChange(of:scenePhase) {game.setActive($0 == .active && !importing)}
            .onChange(of:importing) {game.setActive(!$0 && scenePhase == .active)}
        }
    }

    private var header:some View {
        HStack(spacing:10) {
            VStack(alignment:.leading,spacing:2) {
                Text(game.header).font(.headline).lineLimit(1)
                if !game.status.isEmpty {Text(game.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)}
            }
            Spacer(minLength:8)
            IPadIconButton(symbol:"folder",label:"저장 파일 가져오기") {game.setActive(false);importing = true}
            if game.host?.hasStarted == true {
                Button {game.cycleSpeed()} label: {
                    Text("\(game.speedFactor)×").font(.headline.monospacedDigit())
                        .foregroundStyle(game.speedFactor > 1 ? IPadTheme.onGold : IPadTheme.gold)
                        .frame(minWidth:48,minHeight:48).padding(.horizontal,6)
                        .background(Capsule().fill(game.speedFactor > 1 ? IPadTheme.gold : Color.white.opacity(0.09)))
                }.accessibilityLabel("진행 속도 \(game.speedFactor)배. 누르면 바뀝니다.")
                IPadIconButton(symbol:"line.3.horizontal",label:"메뉴") {game.showMenu()}
            }
        }
        .padding(.horizontal,16).padding(.vertical,6).background(IPadTheme.ink)
    }

    private func stage(_ geometry:GeometryProxy) -> some View {
        ZStack {
            Color.black
            if let host = game.host,host.stage.palette == 3,let battle = host.battle,let data = game.data {
                IPadBattleCanvas(session:battle,data:data,selectedSlot:game.selectedSlot,
                    highlighted:game.highlighted,animation:game.animator,onCellTap:game.cellTapped)
                    .accessibilityHidden(game.prompt != nil)
                if let banner = game.cueBanner {
                    VStack(spacing:0) {
                        Spacer(minLength:0)
                        Button {game.dismissCueNotice()} label: {
                            VStack(spacing:4) {
                                Text(banner.text).font(.headline).multilineTextAlignment(.center)
                                if banner.waits {Text("눌러서 계속").font(.caption).foregroundStyle(.secondary)}
                            }.padding(.horizontal,22).padding(.vertical,14)
                                .background(IPadTheme.ink.opacity(0.94),in:RoundedRectangle(cornerRadius:16))
                                .overlay(RoundedRectangle(cornerRadius:16).stroke(IPadTheme.gold.opacity(0.5),lineWidth:1))
                        }.buttonStyle(.plain)
                        Spacer(minLength:0)
                    }.padding(24)
                }
                if game.prompt == nil,let info = game.unitInfo {
                    VStack(spacing:0) {
                        HStack(spacing:0) {IPadUnitCard(info:info,onDetail:game.showSelectedUnit);Spacer(minLength:0)}
                        Spacer(minLength:0)
                    }.padding(10)
                }
            } else if let image = game.fieldImage {
                IPadFieldView(image:image,touchable:game.fieldIsMap && game.prompt == nil && game.menu == nil,
                              onTap:game.fieldTapped,onScroll:game.scrollField)
                    .accessibilityLabel("현재 장면. 인물이나 문, 도시를 눌러 이동할 수 있고 아래 행동 목록도 쓸 수 있습니다.")
            } else {
                VStack(spacing:16) {
                    Image(systemName:"flag.2.crossed.fill").font(.system(size:48)).foregroundStyle(IPadTheme.gold)
                    Text("삼국지 영걸전").font(.largeTitle.bold())
                }
            }
            if let panel = game.prompt {
                if panel.style == .dialogue {
                    // A tap anywhere closes the line; the card never hides the picture.
                    Color.clear.contentShape(Rectangle()).onTapGesture {game.advanceDialogue()}
                    VStack(spacing:0) {
                        Spacer(minLength:0)
                        IPadDialogueCard(panel:panel,auto:game.dialogueAuto,skipping:game.skipping,onNext:game.advanceDialogue,
                            onAuto:{game.dialogueAuto.toggle();if game.dialogueAuto {game.skipping = false}},onSkip:game.toggleSkip)
                            .padding(.horizontal,12).padding(.bottom,12)
                    }
                } else {
                    Color.black.opacity(0.55)
                    IPadPanelView(panel:panel,maxHeight:geometry.size.height*0.86)
                        .frame(maxWidth:560).padding(16)
                }
            } else if game.host?.hasStarted != true,let panel = game.menu {
                if panel.actions.contains(where:{$0.id == "new"}) {
                    // The title screen: the picture whole, the buttons at its foot.
                    VStack(spacing:0) {
                        Spacer(minLength:0)
                        IPadTitleMenu(panel:panel).padding(20)
                    }
                } else {
                    // Save slots and the like, opened before a game has started.
                    Color.black.opacity(0.55)
                    IPadPanelView(panel:panel,maxHeight:geometry.size.height*0.86)
                        .frame(maxWidth:560).padding(16)
                }
            }
        }.clipped()
    }

    private var dock:some View {
        HStack(spacing:8) {
            ForEach(game.actions) {action in IPadDockButton(action:action)}
        }
        .frame(maxWidth:.infinity)
        .padding(.horizontal,12).padding(.vertical,10)
        .background(IPadTheme.ink.ignoresSafeArea(edges:.bottom)).disabled(game.prompt != nil)
    }
}

/// The unit being looked at: portrait, name, class and the three gauges.
private struct IPadUnitCard:View {
    let info:IPadUnitInfo
    let onDetail:()->Void
    var body:some View {
        let accent:Color = info.enemy ? Color(red:1,green:0.55,blue:0.5) : IPadTheme.gold
        return HStack(alignment:.top,spacing:10) {
            if let portrait = info.portrait {
                Image(decorative:portrait,scale:1).resizable().interpolation(.none).aspectRatio(contentMode:.fit)
                    .frame(width:52,height:65).clipShape(RoundedRectangle(cornerRadius:6))
            }
            VStack(alignment:.leading,spacing:5) {
                HStack(spacing:6) {
                    Text(info.name).font(.headline).foregroundStyle(accent)
                    Text("\(info.className) Lv.\(info.level)").font(.caption).foregroundStyle(.secondary)
                }
                gauge("병력",info.troops,info.maxTroops,Color(red:0.45,green:0.8,blue:0.5))
                gauge("사기",info.morale,100,Color(red:0.95,green:0.75,blue:0.35))
                gauge("MP",info.mp,info.maxMP,Color(red:0.45,green:0.65,blue:1))
                HStack(spacing:8) {
                    Text("지형 "+info.terrain+(info.confused ? " · 혼란" : "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength:4)
                    Button("상세",action:onDetail).font(.caption.weight(.semibold)).buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(10).frame(width:290)
        .background(IPadTheme.ink.opacity(0.92),in:RoundedRectangle(cornerRadius:14))
        .overlay(RoundedRectangle(cornerRadius:14).stroke(Color.white.opacity(0.2),lineWidth:1))
        .accessibilityElement(children:.combine)
        .accessibilityLabel("\(info.name), \(info.className) 레벨 \(info.level), 병력 \(info.troops) 중 \(info.maxTroops), 사기 \(info.morale), MP \(info.mp)")
    }
    private func gauge(_ title:String,_ value:Int,_ limit:Int,_ color:Color) -> some View {
        HStack(spacing:6) {
            Text(title).font(.caption2).foregroundStyle(.secondary).frame(width:28,alignment:.leading)
            ProgressView(value:Double(min(max(0,value),limit)),total:Double(max(1,limit))).tint(color)
            Text("\(value)").font(.caption2.monospacedDigit()).frame(width:40,alignment:.trailing)
        }
    }
}

private struct IPadDockButton:View {
    let action:IPadAction
    var body:some View {
        Button(action:action.perform) {
            VStack(spacing:4) {
                if let symbol = IPadTheme.symbol(for:action.title) {Image(systemName:symbol).font(.title3)}
                Text(action.title).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }.foregroundStyle(IPadTheme.gold).padding(.horizontal,6)
        }
        .buttonStyle(IPadDockStyle()).disabled(!action.enabled)
    }
}

/// The opening menu: three plain buttons, no card heading over the artwork.
private struct IPadTitleMenu:View {
    let panel:IPadPanel
    var body:some View {
        VStack(spacing:10) {
            ForEach(panel.actions) {action in
                Button(action:action.perform) {
                    VStack(spacing:2) {
                        Text(action.title)
                        if !action.subtitle.isEmpty {Text(action.subtitle).font(.caption).foregroundStyle(.secondary)}
                    }
                }
                .buttonStyle(IPadPillStyle(primary:action.id == "new")).disabled(!action.enabled)
            }
        }
        .padding(18).frame(maxWidth:380)
        .background(RoundedRectangle(cornerRadius:24).fill(IPadTheme.ink.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius:24).stroke(Color.white.opacity(0.16),lineWidth:1))
    }
}

private struct IPadSheetHeightKey:PreferenceKey {
    static var defaultValue:CGFloat = 0
    static func reduce(value:inout CGFloat,nextValue:()->CGFloat) {value = max(value,nextValue())}
}

private struct IPadHeightKey:PreferenceKey {
    static var defaultValue:CGFloat = 0
    static func reduce(value:inout CGFloat,nextValue:()->CGFloat) {value = max(value,nextValue())}
}

/// A prompt or menu: a short yes/no answer as side-by-side buttons, anything
/// longer as a list of rows with the way out kept apart beneath it.
private struct IPadPanelView:View {
    let panel:IPadPanel
    var maxHeight:CGFloat = .infinity
    /// A panel drawn on its own gets a card; one inside a sheet does not (the sheet is the card).
    var framed = true
    /// Shrink to the content (prompts); a sheet instead fills what it is given.
    var fitsContent = true
    @State private var contentHeight:CGFloat = 0
    @AccessibilityFocusState private var titleFocused:Bool

    private var isChoice:Bool {panel.actions.count <= 3 && panel.actions.allSatisfy {$0.subtitle.isEmpty}}
    private var listed:[IPadAction] {panel.actions.filter {!IPadTheme.isFooter($0)}}
    private var footer:[IPadAction] {panel.actions.filter {IPadTheme.isFooter($0)}}

    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text(panel.title).font(.title2.bold())
                    .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
                if !panel.body.isEmpty {Text(panel.body).font(.body).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal:false,vertical:true)}
                if isChoice {
                    HStack(spacing:12) {ForEach(panel.actions) {action in pill(action)}}
                } else {
                    if !listed.isEmpty {rows}
                    if !footer.isEmpty {
                        HStack(spacing:12) {ForEach(footer) {action in pill(action)}}
                    }
                }
            }.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,20).padding(.top,framed ? 20 : 4).padding(.bottom,20)
                .background(GeometryReader {proxy in Color.clear.preference(key:IPadHeightKey.self,value:proxy.size.height)})
        }
        .onPreferenceChange(IPadHeightKey.self) {contentHeight = $0}
        .frame(height:fitsContent && contentHeight > 0 ? min(contentHeight,maxHeight) : nil)
        .background(framed ? IPadTheme.surface : Color.clear,in:RoundedRectangle(cornerRadius:24))
        .overlay(RoundedRectangle(cornerRadius:24).stroke(Color.white.opacity(framed ? 0.16 : 0),lineWidth:1))
        .accessibilityElement(children:.contain)
        .onAppear {titleFocused = true}
        .onChange(of:panel.title+panel.body) {_ in titleFocused = true}
    }

    private func pill(_ action:IPadAction) -> some View {
        Button(action:action.perform) {Text(action.title)}
            .buttonStyle(IPadPillStyle(primary:IPadTheme.isPrimary(action))).disabled(!action.enabled)
    }

    private var rows:some View {
        VStack(spacing:0) {
            ForEach(Array(listed.enumerated()),id:\.element.id) {index,action in
                if index > 0 {Divider().overlay(Color.white.opacity(0.1))}
                row(action)
            }
        }
        .background(RoundedRectangle(cornerRadius:16).fill(Color.white.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius:16))
    }

    private func row(_ action:IPadAction) -> some View {
        Button(action:action.perform) {
            HStack(spacing:12) {
                VStack(alignment:.leading,spacing:3) {
                    Text(action.title).font(.headline).foregroundStyle(.primary)
                    if !action.subtitle.isEmpty {Text(action.subtitle).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                }
                Spacer(minLength:8)
                Image(systemName:"chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal,16).padding(.vertical,12).frame(maxWidth:.infinity,minHeight:56,alignment:.leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(IPadRowStyle()).disabled(!action.enabled)
    }
}

/// A spoken line over the picture: portrait, speaker, text and a hint to tap.
private struct IPadDialogueCard:View {
    let panel:IPadPanel
    let auto:Bool
    let skipping:Bool
    let onNext:()->Void
    let onAuto:()->Void
    let onSkip:()->Void
    var body:some View {
        HStack(alignment:.top,spacing:14) {
            if let portrait = panel.portrait {
                Image(decorative:portrait,scale:1).resizable().interpolation(.none).aspectRatio(contentMode:.fit)
                    .frame(width:84,height:105).clipShape(RoundedRectangle(cornerRadius:8))
                    .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.white.opacity(0.25),lineWidth:1))
            }
            VStack(alignment:.leading,spacing:6) {
                if !panel.title.isEmpty {
                    Text(panel.title).font(.headline).foregroundStyle(IPadTheme.gold)
                }
                Text(panel.body).font(.title3).lineSpacing(5).fixedSize(horizontal:false,vertical:true)
                HStack(spacing:8) {
                    toggle("자동",systemImage:"play.circle",on:auto,action:onAuto)
                    toggle("건너뛰기",systemImage:"forward.fill",on:skipping,action:onSkip)
                    Spacer()
                    Label("눌러서 다음",systemImage:"chevron.down.circle.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth:.infinity,alignment:.leading).padding(16)
        .background(IPadTheme.ink.opacity(0.94),in:RoundedRectangle(cornerRadius:18))
        .overlay(RoundedRectangle(cornerRadius:18).stroke(Color.white.opacity(0.22),lineWidth:1))
        .contentShape(RoundedRectangle(cornerRadius:18)).onTapGesture(perform:onNext)
        .accessibilityElement(children:.contain)
        .accessibilityLabel((panel.title.isEmpty ? "" : panel.title+", ")+panel.body)
        .accessibilityAction(named:"다음 대사",onNext)
    }

    private func toggle(_ title:String,systemImage:String,on:Bool,action:@escaping()->Void) -> some View {
        Button(action:action) {
            Label(title,systemImage:systemImage).font(.subheadline.weight(.semibold))
                .foregroundStyle(on ? IPadTheme.onGold : IPadTheme.gold)
                .padding(.horizontal,12).frame(minHeight:40)
                .background(Capsule().fill(on ? IPadTheme.gold : Color.white.opacity(0.1)))
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The town, palace or world picture. A tap reports where it landed as a
/// fraction of the image; a drag scrolls a world map a tile at a time.
private struct IPadFieldView:View {
    let image:CGImage
    let touchable:Bool
    let onTap:(CGPoint)->Void
    let onScroll:(Int,Int)->Void
    @State private var carried = CGSize.zero
    var body:some View {
        GeometryReader {proxy in
            let size = CGSize(width:CGFloat(image.width),height:CGFloat(image.height))
            let scale = min(proxy.size.width/size.width,proxy.size.height/size.height)
            let shown = CGSize(width:size.width*scale,height:size.height*scale)
            let origin = CGPoint(x:(proxy.size.width-shown.width)/2,y:(proxy.size.height-shown.height)/2)
            let tile = shown.width/32
            Image(decorative:image,scale:1).resizable().interpolation(.none).frame(width:shown.width,height:shown.height)
                .position(x:origin.x+shown.width/2,y:origin.y+shown.height/2)
                .contentShape(Rectangle())
                .gesture(touchable ? SpatialTapGesture().onEnded {value in
                    let x = (value.location.x-origin.x)/shown.width,y = (value.location.y-origin.y)/shown.height
                    if (0...1).contains(x) && (0...1).contains(y) {onTap(CGPoint(x:x,y:y))}
                } : nil)
                .simultaneousGesture(touchable ? DragGesture(minimumDistance:16).onChanged {value in
                    let wholeX = Int((value.translation.width-carried.width)/tile),wholeY = Int((value.translation.height-carried.height)/tile)
                    guard wholeX != 0 || wholeY != 0 else {return}
                    // Dragging right reveals the left: the view moves the other way.
                    onScroll(-wholeX,-wholeY)
                    carried.width += CGFloat(wholeX)*tile;carried.height += CGFloat(wholeY)*tile
                }.onEnded {_ in carried = .zero} : nil)
        }
    }
}
