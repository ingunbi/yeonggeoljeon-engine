// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers

@main
struct YeonggeoljeonIPadApp:App {
    var body:some SwiftUI.Scene {WindowGroup {IPadGameScreen()}}
}

private struct IPadGameScreen:View {
    @StateObject private var game = IPadGameStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    private let ink = Color(red:0.055,green:0.075,blue:0.12)
    private let gold = Color(red:0.96,green:0.79,blue:0.42)

    var body:some View {
        GeometryReader {geometry in
            VStack(spacing:0) {
                HStack(spacing:16) {
                    VStack(alignment:.leading,spacing:3) {
                        Text(game.header).font(.headline).lineLimit(2)
                        Text(game.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength:8)
                    Button {game.setActive(false);importing = true} label:{Image(systemName:"folder").frame(minWidth:44,minHeight:44)}
                        .accessibilityLabel("저장 파일 가져오기")
                    Button {game.showMenu()} label:{Label("메뉴",systemImage:"line.3.horizontal").frame(minHeight:44)}
                }
                .padding(.horizontal,16).padding(.vertical,8).background(ink)

                ZStack {
                    Color.black
                    if let host = game.host,host.stage.palette == 3,let battle = host.battle,let data = game.data {
                        IPadBattleCanvas(session:battle,data:data,selectedSlot:game.selectedSlot,
                            highlighted:game.highlighted,onCellTap:game.cellTapped)
                            .accessibilityHidden(game.prompt != nil)
                    } else if let image = game.fieldImage {
                        Image(decorative:image,scale:1).resizable().interpolation(.none).aspectRatio(contentMode:.fit)
                            .accessibilityLabel("현재 장면. 아래 행동 목록에서 대화하거나 이동할 수 있습니다.")
                    } else {
                        VStack(spacing:16) {
                            Image(systemName:"flag.2.crossed.fill").font(.system(size:48)).foregroundStyle(gold)
                            Text("삼국지 영걸전").font(.largeTitle.bold())
                        }
                    }
                    if let panel = game.prompt {
                        Color.black.opacity(0.55)
                        IPadPanelView(panel:panel,compact:geometry.size.width < 700)
                            .frame(maxWidth:760,maxHeight:geometry.size.height*0.82)
                            .padding(12)
                    }
                }.clipped()

                if game.prompt == nil,game.host?.stage.palette == 3 {
                    Text("두 손가락으로 확대 · 드래그로 지도 이동")
                        .font(.caption).padding(.horizontal,12).padding(.vertical,5)
                        .frame(maxWidth:.infinity,alignment:.leading).background(ink)
                }

                if !game.actions.isEmpty {
                    ScrollView(.horizontal,showsIndicators:false) {
                        HStack(spacing:10) {
                            ForEach(game.actions) {action in IPadActionButton(action:action)}
                        }.padding(12)
                    }.background(ink).disabled(game.prompt != nil)
                }
            }
            .background(ink).preferredColorScheme(.dark).tint(gold)
            .sheet(isPresented:Binding(get:{game.menu != nil},set:{if !$0 {game.closeMenu()}})) {
                if let panel = game.menu {
                    NavigationStack {
                        IPadPanelView(panel:panel,compact:true).padding(16)
                            .toolbar {ToolbarItem(placement:.cancellationAction) {Button("닫기") {game.closeMenu()}}}
                    }.preferredColorScheme(.dark).tint(gold)
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
}

private struct IPadActionButton:View {
    let action:IPadAction
    var body:some View {
        Button(action:action.perform) {
            VStack(alignment:.leading,spacing:4) {
                Text(action.title).font(.body.weight(.semibold)).fixedSize(horizontal:false,vertical:true)
                if !action.subtitle.isEmpty {Text(action.subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            }.frame(minWidth:64,minHeight:44,alignment:.leading).padding(.horizontal,12).padding(.vertical,4)
        }
        .buttonStyle(.bordered).disabled(!action.enabled)
    }
}

private struct IPadPanelView:View {
    let panel:IPadPanel
    let compact:Bool
    @AccessibilityFocusState private var titleFocused:Bool
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                Text(panel.title).font(.title2.bold()).foregroundStyle(Color(red:0.96,green:0.79,blue:0.42))
                    .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
                if !panel.body.isEmpty {Text(panel.body).font(.body).lineSpacing(5).fixedSize(horizontal:false,vertical:true)}
                LazyVGrid(columns:[GridItem(.adaptive(minimum:compact ? 220 : 260),spacing:12)],alignment:.leading,spacing:10) {
                    ForEach(panel.actions) {action in IPadActionButton(action:action).frame(maxWidth:.infinity,alignment:.leading)}
                }
            }.frame(maxWidth:.infinity,alignment:.leading).padding(20)
        }
        .background(Color(red:0.075,green:0.10,blue:0.16),in:RoundedRectangle(cornerRadius:22))
        .overlay(RoundedRectangle(cornerRadius:22).stroke(Color.white.opacity(0.2),lineWidth:1))
        .accessibilityElement(children:.contain)
        .onAppear {titleFocused = true}
        .onChange(of:panel.title+panel.body) {_ in titleFocused = true}
    }
}
