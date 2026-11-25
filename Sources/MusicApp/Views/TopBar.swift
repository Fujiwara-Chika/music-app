import SwiftUI

/// Window chrome, styled the way macOS does it rather than the way the reference
/// skin did it.
///
/// The reference screenshot came from a Windows app: a strip of 48pt icon tabs
/// with a permanent blue underline, a fake borderless "library" pill and three
/// hand-drawn window buttons on the right. None of that is macOS. Here the real
/// traffic lights are used (the window keeps its standard buttons, we only make
/// the title bar transparent), view switching is a native segmented control, and
/// everything else is SF Symbols in borderless toolbar buttons with the usual
/// 28pt hit target and rounded hover fill.
///
/// The buttons take no keyboard focus, so ⌘-less space keeps toggling playback
/// even after the toolbar has been used.
struct TopBar: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @State private var showsOptions = false
    @EnvironmentObject private var player: PlayerEngine

    @State private var hoveredKey: String?

    private enum L {
        /// Room for the traffic lights, which AppKit draws at the top left.
        static let trafficLightInset: CGFloat = 78
        static let controlSize: CGFloat = 28
        static let symbolSize: CGFloat = 13
        static let itemSpacing: CGFloat = 6
        static let groupSpacing: CGFloat = 12
        static let trailingPadding: CGFloat = 14
        static let segmentWidth: CGFloat = 168
    }

    private static let modes: [(ViewMode, String, String)] = [
        (.playlist, "list.bullet", "播放列表"),
        (.artists, "person", "艺术家"),
        (.albums, "square.stack", "专辑"),
        (.genres, "music.note.list", "流派"),
        (.stats, "chart.bar", "播放统计"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: L.trafficLightInset)

            modePicker

            sourceMenu
                .padding(.leading, L.groupSpacing)

            // Scans run 15s on a big folder; the menu alone gives no signal.
            if store.isScanning {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
                    .padding(.leading, 6)
                    .help("正在扫描资料库…")
                    .accessibilityLabel("正在扫描资料库")
            }

            Spacer(minLength: 12)

            HStack(spacing: L.itemSpacing) {
                toolbarButton("locate", symbol: "music.note", help: "定位到当前播放",
                              enabled: player.currentTrack != nil) {
                    guard let id = player.currentTrack?.id else { return }
                    store.selectedSection = .library
                    store.selectedTrackID = id
                    store.reveal(trackID: id, force: true)
                }

                optionsMenu
            }
        }
        .padding(.trailing, L.trailingPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.windowBG)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.separator).frame(height: 1)
        }
    }

    // MARK: - View switcher

    /// A segmented control is how Finder, Mail and Music expose "which view am I
    /// in"; it also removes the fake active-tab underline entirely.
    @ViewBuilder
    private var modePicker: some View {
        // `ImageRenderer` cannot draw AppKit-backed controls (they come out as
        // yellow placeholders), so the offscreen render path draws the same five
        // symbols without the segmented chrome.
        if RenderMode.isOffscreen {
            HStack(spacing: L.groupSpacing) {
                ForEach(Self.modes, id: \.0) { mode, symbol, title in
                    Image(systemName: symbol)
                        .font(.system(size: L.symbolSize))
                        .foregroundStyle(store.viewMode == mode ? Theme.textStrong : Theme.text.opacity(0.7))
                        .help(title)
                }
            }
        } else {
            Picker("视图", selection: Binding<ViewMode?>(
            // Optional so that "历史记录 / 最常播放" shows as *no* segment selected
            // instead of pretending to be the playlist view.
            get: { store.selectedSection == .library ? store.viewMode : nil },
            set: { mode in
                guard let mode else { return }
                store.selectedSection = .library
                store.viewMode = mode
                // Each mode owns its grouping, so a leftover column sort would
                // silently override it.
                store.sortColumn = nil
                store.sortAscending = true
                store.scrollTarget = nil
            }
        )) {
            ForEach(Self.modes, id: \.0) { mode, symbol, title in
                // A Label with `.iconOnly` keeps the icon-only look but gives
                // VoiceOver the real name instead of the symbol identifier.
                Label(title, systemImage: symbol)
                    .labelStyle(.iconOnly)
                    .help(title)
                    .tag(Optional(mode))
            }
        }
            .pickerStyle(.segmented)
            .labelsHidden()
            .focusable(false)
            .frame(width: L.segmentWidth)
        }
    }

    // MARK: - Library source

    @ViewBuilder
    private var sourceMenu: some View {
        if RenderMode.isOffscreen {
            HStack(spacing: 5) {
                Image(systemName: "cylinder.split.1x2").font(.system(size: 11))
                Text(store.sourceName).font(.system(size: 12))
            }
            .foregroundStyle(Theme.textSecondary)
        } else {
            Menu {
            Text(store.sourceName)
            Divider()
            Button("导入音乐文件夹…") { store.chooseFolder() }
                .keyboardShortcut("o", modifiers: .command)
            Button("载入示例资料库") { store.loadDemoLibrary() }
                .disabled(store.isDemoLibrary)
            if !store.isDemoLibrary {
                Button("移除已导入的资料库") { store.clearImportedLibrary() }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 11))
                Text(store.sourceName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: 190, alignment: .leading)
        }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .focusable(false)
            .fixedSize()
        }
    }

    // MARK: - Toolbar items

    @ViewBuilder
    private var optionsMenu: some View {
        if RenderMode.isOffscreen {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: L.symbolSize))
                .foregroundStyle(Theme.text.opacity(0.86))
        } else {
            Button {
                showsOptions.toggle()
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: L.symbolSize))
                    .foregroundStyle(Theme.text.opacity(0.86))
                    .frame(width: L.controlSize, height: L.controlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel("更多操作")
            .popover(isPresented: $showsOptions, arrowEdge: .bottom) {
                AppearancePanel()
                    .environmentObject(store)
                    .environmentObject(player)
                    .environmentObject(appearance)
            }
        }
    }

    /// One borderless toolbar button: 28pt hit target, rounded hover fill, no
    /// focus ring (space keeps toggling playback).
    private func toolbarButton(
        _ key: String,
        symbol: String,
        help: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        let hovered = hoveredKey == key
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: L.symbolSize, weight: .regular))
                .foregroundStyle(enabled ? (hovered ? Theme.textStrong : Theme.text.opacity(0.86))
                                         : Theme.textDim.opacity(0.6))
                .frame(width: L.controlSize, height: L.controlSize)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovered && enabled ? Color.white.opacity(0.09) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!enabled)
        .onHover { hovering in
            if hovering { hoveredKey = key } else if hoveredKey == key { hoveredKey = nil }
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The ⋯ popover: row density, follow-playback, the two backdrop sliders and the
/// "locate playing" shortcut. A popover (not a menu) because menus cannot hold
/// sliders.
struct AppearancePanel: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toggleRow("跟随播放滚动", isOn: $store.followsPlayback)

            Divider().padding(.vertical, 6)

            sliderRow(
                "背景模糊",
                value: $appearance.backgroundBlur,
                range: AppearanceSettings.blurRange,
                readout: "\(Int(appearance.backgroundBlur)) px"
            )
            sliderRow(
                "背景透明度",
                value: $appearance.backgroundOpacity,
                range: AppearanceSettings.opacityRange,
                readout: "\(Int(appearance.backgroundOpacity * 100))%"
            )
            toggleRow("背景显示专辑封面", isOn: $appearance.usesArtworkBackdrop)

            Divider().padding(.vertical, 6)

            Button {
                guard let id = player.currentTrack?.id else { return }
                store.selectedSection = .library
                store.selectedTrackID = id
                store.reveal(trackID: id, force: true)
                NSApp.keyWindow?.makeFirstResponder(nil)
            } label: {
                Text("定位到当前播放")
                    .font(.system(size: 12.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(player.currentTrack == nil)
            .opacity(player.currentTrack == nil ? 0.45 : 1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .padding(.vertical, 8)
        .frame(width: 236)
        .background(palette.columnHeader)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.checkbox)
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        readout: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12.5))
                Spacer()
                Text(readout)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.textDim)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
