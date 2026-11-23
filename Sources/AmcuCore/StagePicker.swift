import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

public struct StageAvailableWindow: Identifiable, Equatable, Sendable {
    public let id: CGWindowID
    public let pid: pid_t
    public let app: String
    public let bundleID: String?
    public let title: String
    public let size: CGSize
    public let profile: String?
    public let tabCount: Int
    public let minimized: Bool
    public let fullScreen: Bool
    public let onAnotherDesktop: Bool
    public let held: Bool
    public let movable: Bool
    public let zOrder: Int

    public init(id: CGWindowID, pid: pid_t, app: String, bundleID: String?, title: String, size: CGSize,
                profile: String? = nil, tabCount: Int = 0, minimized: Bool = false, fullScreen: Bool = false,
                onAnotherDesktop: Bool = false, held: Bool = false, movable: Bool = true, zOrder: Int = Int.max) {
        self.id = id
        self.pid = pid
        self.app = app
        self.bundleID = bundleID
        self.title = title
        self.size = size
        self.profile = profile
        self.tabCount = tabCount
        self.minimized = minimized
        self.fullScreen = fullScreen
        self.onAnotherDesktop = onAnotherDesktop
        self.held = held
        self.movable = movable
        self.zOrder = zOrder
    }
}

public enum StageWindowScanner {
    public struct AppGroup: Identifiable, Equatable, Sendable {
        public let pid: pid_t
        public let app: String
        public let bundleID: String?
        public let windows: [StageAvailableWindow]
        public var id: pid_t { pid }
    }

    static let excludedBundles: Set<String> = [
        "com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.Spotlight", "com.apple.SystemUIServer",
        "com.apple.loginwindow"
    ]

    static let acceptedSubroles: Set<String> = [
        "AXStandardWindow", "AXDialog", "AXSystemDialog", "AXFloatingWindow",
        "AXSystemFloatingWindow", "AXUnknown", ""
    ]

    private struct CGEntry {
        let id: CGWindowID
        let title: String
        let frame: CGRect
        let onScreen: Bool
        let zOrder: Int
    }

    /// Scans all eligible application windows off the stage. Intended to run on
    /// a background queue; uses plain `AXUIElementCreateApplication` so listing
    /// never turns on Chromium web-content accessibility.
    public static func scan(stageBounds: CGRect, onStageIDs: Set<CGWindowID>, heldIDs: Set<CGWindowID>, ownPID: pid_t) -> [StageAvailableWindow] {
        let list = Stage.windowList([.optionAll, .excludeDesktopElements])
        var byPID: [pid_t: [CGEntry]] = [:]
        var cgByID: [CGWindowID: CGEntry] = [:]
        for (index, entry) in list.enumerated() {
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.width >= 60, rect.height >= 60 else { continue }
            let item = CGEntry(
                id: id,
                title: (entry[kCGWindowName as String] as? String) ?? "",
                frame: rect,
                onScreen: (entry[kCGWindowIsOnscreen as String] as? Bool) == true,
                zOrder: index
            )
            byPID[pid, default: []].append(item)
            cgByID[id] = item
        }

        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard !app.isTerminated, app.activationPolicy != .prohibited else { return false }
            let pid = app.processIdentifier
            guard pid != ownPID, byPID[pid] != nil else { return false }
            if let bundle = app.bundleIdentifier, excludedBundles.contains(bundle) { return false }
            return !Stage.isAmcu(pid)
        }

        var found: [StageAvailableWindow] = []
        for app in apps {
            let pid = app.processIdentifier
            let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
            let bundleID = app.bundleIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            AX.setMessagingTimeout(appElement, seconds: 0.4)
            var seen = Set<CGWindowID>()
            for element in AX.windows(appElement) {
                AX.setMessagingTimeout(element, seconds: 0.4)
                guard let id = AX.windowID(element), !onStageIDs.contains(id) else { continue }
                seen.insert(id)
                let cg = cgByID[id]
                let frame = AX.frame(element) ?? cg?.frame ?? .zero
                guard frame.width >= 60, frame.height >= 60 else { continue }
                if !stageBounds.isEmpty, StageGeometry.isOnStage(frame, stage: stageBounds) { continue }
                let subrole = AX.string(element, kAXSubroleAttribute as String) ?? ""
                guard acceptedSubroles.contains(subrole) else { continue }
                let rawTitle = AX.string(element, kAXTitleAttribute as String) ?? ""
                let title = rawTitle.isEmpty ? (cg?.title ?? "") : rawTitle
                let minimized = AX.bool(element, kAXMinimizedAttribute as String) == true
                let fullScreen = AX.bool(element, "AXFullScreen") == true
                let movable = !fullScreen && (minimized || AX.isSettable(element, kAXPositionAttribute as String))
                found.append(StageAvailableWindow(
                    id: id, pid: pid, app: name, bundleID: bundleID, title: title, size: frame.size,
                    minimized: minimized, fullScreen: fullScreen, onAnotherDesktop: false,
                    held: heldIDs.contains(id), movable: movable, zOrder: cg?.zOrder ?? Int.max
                ))
            }
            for cg in byPID[pid] ?? [] where !seen.contains(cg.id) && !onStageIDs.contains(cg.id) {
                guard !cg.onScreen, !cg.title.isEmpty, cg.frame.width >= 100, cg.frame.height >= 100 else { continue }
                if !stageBounds.isEmpty, StageGeometry.isOnStage(cg.frame, stage: stageBounds) { continue }
                found.append(StageAvailableWindow(
                    id: cg.id, pid: pid, app: name, bundleID: bundleID, title: cg.title, size: cg.frame.size,
                    minimized: false, fullScreen: false, onAnotherDesktop: true,
                    held: heldIDs.contains(cg.id), movable: true, zOrder: cg.zOrder
                ))
            }
        }

        let paired = StageTabs.collect(for: found.map { (windowID: $0.id, pid: $0.pid) })
        if !paired.isEmpty {
            found = found.map { item in
                guard let info = paired[item.id] else { return item }
                return StageAvailableWindow(
                    id: item.id, pid: item.pid, app: item.app, bundleID: item.bundleID, title: item.title,
                    size: item.size, profile: info.profile, tabCount: info.tabs.count,
                    minimized: item.minimized, fullScreen: item.fullScreen,
                    onAnotherDesktop: item.onAnotherDesktop, held: item.held,
                    movable: item.movable, zOrder: item.zOrder
                )
            }
        }
        return found.sorted { $0.zOrder < $1.zOrder }
    }

    public static func group(_ windows: [StageAvailableWindow], query: String) -> [AppGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = needle.isEmpty ? windows : windows.filter { item in
            item.app.lowercased().contains(needle)
                || item.title.lowercased().contains(needle)
                || (item.profile?.lowercased().contains(needle) ?? false)
                || (item.bundleID?.lowercased().contains(needle) ?? false)
        }
        var order: [pid_t] = []
        var grouped: [pid_t: [StageAvailableWindow]] = [:]
        for item in filtered {
            if grouped[item.pid] == nil { order.append(item.pid) }
            grouped[item.pid, default: []].append(item)
        }
        return order.compactMap { pid in
            guard let list = grouped[pid], let first = list.first else { return nil }
            return AppGroup(pid: pid, app: first.app, bundleID: first.bundleID, windows: list)
        }
    }
}

private func t(_ english: String, _ chinese: String) -> String {
    StageText.t(english, chinese)
}

struct StageWindowPickerSheet: View {
    @ObservedObject var model: StageViewModel
    @State private var query = ""
    @State private var selected = Set<CGWindowID>()
    @State private var follow = false
    @State private var savingPreset = false
    @State private var presetName = ""

    private var groups: [StageWindowScanner.AppGroup] {
        StageWindowScanner.group(model.candidates, query: query)
    }

    private var movableSelected: [StageAvailableWindow] {
        model.candidates.filter { selected.contains($0.id) && $0.movable }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            if !model.presets.isEmpty || savingPreset || !movableSelected.isEmpty || !model.cards.isEmpty {
                presetsStrip
            }
            if let error = model.pickerError, !error.isEmpty {
                errorBanner(error)
            }
            content
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 520)
        .background(StagePalette.background)
        .onChange(of: model.candidates) { _, latest in
            let valid = Set(latest.filter(\.movable).map(\.id))
            selected = selected.intersection(valid)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t("Move Windows to Stage", "将窗口收入舞台"))
                    .font(.system(size: 14, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.refreshCandidates()
            } label: {
                if model.scanningCandidates {
                    ProgressView().controlSize(.small)
                } else {
                    Label(t("Refresh", "刷新"), systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(StageCapsuleButton(prominent: false))
            .disabled(model.scanningCandidates)
            .help(t("Scan open windows again", "重新识别当前所有窗口"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(StagePalette.card)
    }

    private var headerSubtitle: String {
        let total = model.candidates.count
        if model.scanningCandidates && total == 0 {
            return t("Scanning open windows…", "正在识别所有窗口…")
        }
        if total == 0 {
            return t("No other open windows found outside the stage", "没有发现舞台之外的其他窗口")
        }
        return t("Recognised \(total) window\(total == 1 ? "" : "s") outside the stage", "已识别舞台外的 \(total) 个窗口")
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(t("Filter by app, window title, or profile…", "搜索应用、窗口标题或 profile…"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StagePalette.card))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StagePalette.stroke, lineWidth: 1))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var presetsStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text(t("Workspaces:", "工作组："))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    ForEach(model.presets) { preset in
                        Button {
                            model.applyPreset(preset)
                        } label: {
                            Label("\(preset.name) (\(preset.items.count))", systemImage: "folder.fill")
                        }
                        .buttonStyle(StageCapsuleButton(prominent: false))
                        .help(t("Move all matching windows in '\(preset.name)' onto the stage (right-click to release or delete)", "一键将工作组「\(preset.name)」匹配的窗口全部收入舞台（右键可释放或删除）"))
                        .contextMenu {
                            Button(t("Move All to Stage", "一键收入舞台")) { model.applyPreset(preset) }
                            Button(t("Release All from Stage", "一键释放回屏幕")) { model.releasePreset(preset) }
                            Divider()
                            Button(t("Delete Workspace", "删除工作组"), role: .destructive) { model.deletePreset(preset.name) }
                        }
                    }
                    if !savingPreset && (!movableSelected.isEmpty || !model.cards.isEmpty) {
                        Button {
                            presetName = ""
                            savingPreset = true
                        } label: {
                            Label(
                                movableSelected.isEmpty
                                    ? t("Save stage as group", "保存当前舞台为组")
                                    : t("Save selected as group", "将已选存为工作组"),
                                systemImage: "folder.badge.plus"
                            )
                        }
                        .buttonStyle(StageCapsuleButton(prominent: false))
                    }
                }
                .padding(.horizontal, 14)
            }
            if savingPreset {
                HStack(spacing: 6) {
                    TextField(t("Workspace name (e.g. Shops)", "输入工作组名称（如：店铺号）"), text: $presetName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { commitPreset() }
                    Button(t("Save", "保存")) { commitPreset() }
                        .buttonStyle(StageCapsuleButton(prominent: true))
                        .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(t("Cancel", "取消")) { savingPreset = false }
                        .buttonStyle(StageCapsuleButton(prominent: false))
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.bottom, 8)
    }

    private func commitPreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let items = movableSelected.isEmpty
            ? []
            : StagePresetStore.buildItems(from: movableSelected.map { ($0.app, $0.bundleID, $0.profile, $0.title) })
        model.savePreset(name, items)
        savingPreset = false
        presetName = ""
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { model.pickerError = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if model.scanningCandidates && model.candidates.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text(t("Scanning open windows…", "正在识别所有窗口…"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(query.isEmpty ? t("No windows to move", "没有可收入的窗口") : t("No matching windows", "没有匹配的窗口"))
                    .font(.system(size: 13, weight: .medium))
                Text(query.isEmpty
                     ? t("All detected windows are already on the stage.", "已识别的窗口都已经在舞台上了。")
                     : t("Try a different search keyword.", "换个关键词试试。"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { group in
                        appSection(group)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
    }

    private func appSection(_ group: StageWindowScanner.AppGroup) -> some View {
        let movable = group.windows.filter(\.movable)
        let allPicked = !movable.isEmpty && movable.allSatisfy { selected.contains($0.id) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(nsImage: model.icon(forPID: group.pid, bundleID: group.bundleID))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 17, height: 17)
                Text(group.app)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text("\(group.windows.count)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                if movable.count > 1 {
                    Button(allPicked ? t("Clear", "取消全选") : t("Select all", "全选")) {
                        if allPicked {
                            movable.forEach { selected.remove($0.id) }
                        } else {
                            movable.forEach { selected.insert($0.id) }
                        }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 4)

            VStack(spacing: 1) {
                ForEach(group.windows) { item in
                    windowRow(item)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StagePalette.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StagePalette.stroke, lineWidth: 1))
        }
    }

    private func windowRow(_ item: StageAvailableWindow) -> some View {
        let isPicked = selected.contains(item.id)
        return HStack(spacing: 9) {
            Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isPicked ? Color.orange : (item.movable ? Color.secondary.opacity(0.55) : Color.secondary.opacity(0.25)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let profile = item.profile {
                        StageProfileTag(profile: profile)
                    }
                    Text(item.title.isEmpty ? t("(Untitled window)", "（无标题窗口）") : item.title)
                        .font(.system(size: 12.5, weight: isPicked ? .medium : .regular))
                        .foregroundStyle(item.movable ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 6) {
                    Text("\(Int(item.size.width))×\(Int(item.size.height))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    if item.tabCount > 0 {
                        Text(t("\(item.tabCount) tab\(item.tabCount == 1 ? "" : "s")", "\(item.tabCount) 个标签"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    if item.held {
                        StageBadge(text: t("taken over", "接管中"), tint: .orange)
                    }
                    if item.onAnotherDesktop {
                        StageBadge(text: t("other desktop", "其他桌面"), tint: .accentColor)
                    }
                    if item.minimized {
                        StageBadge(text: t("minimised", "已最小化"), tint: .secondary)
                    }
                    if item.fullScreen {
                        StageBadge(text: t("full screen — exit first", "全屏（需先退出全屏）"), tint: .secondary)
                    } else if !item.movable {
                        StageBadge(text: t("fixed position", "不可移动"), tint: .secondary)
                    }
                }
            }
            Spacer(minLength: 6)
            if item.movable {
                Button(item.held ? t("Hand back", "交还") : t("Stage", "收入")) {
                    stage([item])
                }
                .buttonStyle(StageCapsuleButton(prominent: false))
                .help(item.held ? t("Put this window back on the stage", "把此窗口放回舞台") : t("Move this window onto the stage", "将此窗口收入舞台"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isPicked ? Color.orange.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            guard item.movable else { return }
            if isPicked { selected.remove(item.id) } else { selected.insert(item.id) }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle(t("Follow new windows of these apps", "同时跟随所选应用的新窗口"), isOn: $follow)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .help(t("When checked, new windows opened later by these apps also move to the stage.", "勾选后，这些应用之后新开的窗口也会自动收入舞台（默认关闭，只收纳选中的窗口）。"))
            Spacer()
            Button(t("Cancel", "取消")) {
                model.showingPicker = false
            }
            .keyboardShortcut(.cancelAction)
            Button {
                stage(movableSelected)
            } label: {
                let count = movableSelected.count
                Label(count > 0 ? t("Move \(count) to Stage", "收入舞台 (\(count))") : t("Move to Stage", "收入舞台"), systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(StageCapsuleButton(prominent: true))
            .disabled(movableSelected.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(StagePalette.strip)
    }

    private func stage(_ items: [StageAvailableWindow]) {
        guard !items.isEmpty else { return }
        let moves = model.stageWindows(items.map { (pid: $0.pid, windowID: $0.id) }, follow)
        let failed = moves.filter { !$0.ok }
        if failed.isEmpty {
            model.pickerError = nil
            model.showingPicker = false
        } else {
            model.pickerError = failed.map { "\($0.app): \($0.note ?? t("could not move", "无法移动"))" }.joined(separator: "；")
            model.refreshCandidates()
        }
    }
}
