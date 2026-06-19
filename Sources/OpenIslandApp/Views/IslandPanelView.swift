import SwiftUI
@preconcurrency import MarkdownUI
import OpenIslandCore

private struct NotificationContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Auto-height container: renders content directly (auto-sizing).
/// When content exceeds maxHeight, wraps in ScrollView at fixed maxHeight.
private struct AutoHeightScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0

    private var isScrollable: Bool { contentHeight > maxHeight }

    var body: some View {
        // Always use ScrollView so the content gets unconstrained vertical
        // space for measurement.  Without this, a tight parent window can
        // cap the GeometryReader measurement, making long content appear
        // truncated instead of scrollable.
        ScrollView(.vertical) {
            content()
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    }
                )
                .onPreferenceChange(ContentHeightKey.self) { height in
                    if height > 0 { contentHeight = height }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(isScrollable ? .automatic : .hidden)
        .frame(height: contentHeight > 0 ? min(contentHeight, maxHeight) : nil)
    }
}

// MARK: - Row Height Estimation

extension AgentSession {
    /// Estimated row height matching `IslandSessionRow` layout for viewport sizing.
    func estimatedIslandRowHeight(at date: Date) -> CGFloat {
        let presence = islandPresence(at: date)
        // v8 list rows are full-width scan rows, not rounded cards.
        // Base: vertical padding (22) + headline (~17) + divider rounding.
        var height: CGFloat = 40
        guard presence != .inactive else { return height }

        let isDesktopApp = id.hasPrefix("desktop_app:")
        if isDesktopApp {
            // Desktop apps display token/quota details under the headline
            height += 28
        } else if spotlightPromptLineText != nil {
            height += 17
        }

        if spotlightActivityLineText != nil { height += 20 }
        if let subagents = claudeMetadata?.activeSubagents, !subagents.isEmpty {
            height += 18
            height += CGFloat(subagents.count) * 18  // each subagent row (spacing 4 + text 14)
        }
        if let tasks = claudeMetadata?.activeTasks, !tasks.isEmpty {
            height += 17
            height += CGFloat(tasks.count) * 16  // each task row (spacing 3 + text 13)
        }
        return height
    }
}

// MARK: - Animations

private let openAnimation = Animation.spring(response: 0.28, dampingFraction: 0.84, blendDuration: 0.08)
private let closeAnimation = Animation.spring(response: 0.24, dampingFraction: 0.90, blendDuration: 0.08)
private let popAnimation = Animation.spring(response: 0.30, dampingFraction: 0.60)
private let openedSurfaceUnmountDelay: TimeInterval = 0.22

private struct ConditionalDrawingGroup: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.drawingGroup()
        } else {
            content
        }
    }
}

// MARK: - Main island view

struct IslandPanelView: View {
    private static let headerControlButtonSize: CGFloat = 22
    private static let headerControlSpacing: CGFloat = 8
    private static let headerHorizontalPadding: CGFloat = 18
    private static let headerTopPadding: CGFloat = 2
    private static let notchHeaderHorizontalPadding: CGFloat = 46
    private static let notchLaneSafetyInset: CGFloat = 12
    private static let minimumRightUsageLaneWidth: CGFloat = 58

    var model: AppModel
    @Namespace private var moduleSelectorNamespace
    private var lang: LanguageManager { model.lang }

    @State private var isHovering = false
    @State private var showingQuitConfirmation = false
    @State private var keepsOpenedSurfaceMounted = false
    @State private var openedSurfaceMountGeneration: UInt64 = 0
    @State private var showingContent = false

    private var isOpened: Bool {
        model.notchStatus == .opened
    }

    private var usesOpenedVisualState: Bool {
        isOpened
    }

    private var shouldRenderOpenedSurface: Bool {
        usesOpenedVisualState || keepsOpenedSurfaceMounted
    }
    
    private var openedContentOpacityAnimation: Animation {
        if usesOpenedVisualState {
            return .easeOut(duration: 0.12).delay(0.08)
        } else {
            return .easeIn(duration: 0.08)
        }
    }

    private var isPopping: Bool {
        model.notchStatus == .popping
    }

    /// Single animation selection based on the current notch status.
    private var notchTransitionAnimation: Animation {
        switch model.notchStatus {
        case .opened:  return openAnimation
        case .closed:  return closeAnimation
        case .popping: return popAnimation
        }
    }

    private var targetOverlayScreen: NSScreen? {
        if let targetScreenID = model.overlayPlacementDiagnostics?.targetScreenID,
           let screen = NSScreen.screens.first(where: { screenID(for: $0) == targetScreenID }) {
            return screen
        }

        return NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    private var usesNotchAwareOpenedHeader: Bool {
        model.overlayPlacementDiagnostics?.mode == .notch
            || targetOverlayScreen?.safeAreaInsets.top ?? 0 > 0
    }

    /// True when the closed island sits on an external (non-notched) display.
    /// The central black rectangle is otherwise aligned with the physical
    /// notch, so center content is only useful here.
    private var isExternalDisplayPlacement: Bool {
        if let mode = model.overlayPlacementDiagnostics?.mode {
            return mode == .topBar
        }
        // Fallback when diagnostics haven't been populated yet.
        return (targetOverlayScreen?.safeAreaInsets.top ?? 0) == 0
    }

    private var openedHeaderButtonsWidth: CGFloat {
        (Self.headerControlButtonSize * 3) + (Self.headerControlSpacing * 2)
    }

    private var openedHeaderHorizontalPadding: CGFloat {
        usesNotchAwareOpenedHeader ? Self.notchHeaderHorizontalPadding : Self.headerHorizontalPadding
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.clear

                notchContent(availableSize: geometry.size)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .alert(model.lang.t("island.quit.confirmTitle"), isPresented: $showingQuitConfirmation) {
            Button(model.lang.t("island.quit.confirmAction"), role: .destructive) {
                model.quitApplication()
            }
            Button(model.lang.t("settings.general.cancel"), role: .cancel) {}
        } message: {
            Text(model.lang.t("island.quit.confirmMessage"))
        }
        .onAppear {
            syncOpenedSurfaceMount(with: model.notchStatus, immediate: true)
            showingContent = usesOpenedVisualState
        }
        .onChange(of: model.notchStatus) { _, status in
            syncOpenedSurfaceMount(with: status)
        }
        .onChange(of: usesOpenedVisualState) { _, newValue in
            if newValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                    if usesOpenedVisualState {
                        withAnimation(.easeOut(duration: 0.16)) {
                            showingContent = true
                        }
                    }
                }
            } else {
                showingContent = false
                // model.scheduler.userLockedModuleId = nil
            }
        }
    }

    @ViewBuilder
    private func notchContent(availableSize: CGSize) -> some View {
        // Window is always at opened size — use opened insets unconditionally.
        let panelShadowHorizontalInset = IslandChromeMetrics.openedShadowHorizontalInset
        let panelShadowBottomInset = IslandChromeMetrics.openedShadowBottomInset
        let layoutWidth = max(0, availableSize.width - (panelShadowHorizontalInset * 2))
        let layoutHeight = max(0, availableSize.height - panelShadowBottomInset)

        let outerHorizontalPadding: CGFloat = 0
        let outerBottomPadding: CGFloat = 0
        let openedWidth = max(0, layoutWidth - outerHorizontalPadding)
        let openedHeight = max(closedNotchHeight, layoutHeight - outerBottomPadding)

        let closedWidth: CGFloat = {
            let layout: V6ClosedLayout = isExternalDisplayPlacement ? .external : .macbook
            
            let effectiveModule = model.scheduler.activeModule
            
            if layout == .macbook {
                let physicalNotchWidth: CGFloat = targetOverlayScreen?.notchSize.width ?? 180
                let leftWidth: CGFloat = effectiveModule?.leftPillWidth ?? 24
                let rightWidth: CGFloat = effectiveModule?.rightPillWidth ?? 0
                let pad = closedNotchHeight / 2
                let leftReserve = max(44, leftWidth + pad)
                let rightReserve = max(44, rightWidth + pad)
                return leftReserve + physicalNotchWidth + rightReserve
            } else {
                let leftWidth: CGFloat = effectiveModule?.leftPillWidth ?? 24
                let rightWidth: CGFloat = effectiveModule?.rightPillWidth ?? 0
                
                let glyphW: CGFloat = effectiveModule != nil ? leftWidth : 24
                let label = isExternalDisplayPlacement ? model.islandClosedLabel() : nil
                let labelW = label.map { V6CenterLabelView.intrinsicWidth(of: $0) } ?? 0
                
                let rightSlot = model.islandClosedRightSlotContent()
                let rightW = (effectiveModule != nil && rightWidth > 0) ? rightWidth : (rightSlot.map { V6RightSlotView.intrinsicWidth(of: $0) } ?? 0)
                
                let labelBlock = (label == nil ? 0 : 6 + labelW)
                let rightBlock = ((rightSlot == nil && (effectiveModule == nil || rightWidth == 0)) ? 0 : 6 + rightW)
                let pad = closedNotchHeight / 2
                let intrinsic = pad * 2 + glyphW + labelBlock + rightBlock
                return max(70, intrinsic)
            }
        }()

        let closedOffset: CGFloat = {
            let layout: V6ClosedLayout = isExternalDisplayPlacement ? .external : .macbook
            
            let mediaModule = model.scheduler.getModules().first(where: { $0.id == "media_control" }) as? MediaControlModule
            let showLyrics = UserDefaults.standard.bool(forKey: "showLyricsOnClosedIsland")
            let shouldShowMediaPill = mediaModule?.isPlaying == true && showLyrics
            let effectiveModule = shouldShowMediaPill ? mediaModule : model.scheduler.activeModule
            
            if layout == .macbook {
                let leftWidth: CGFloat = effectiveModule?.leftPillWidth ?? 24
                let rightWidth: CGFloat = effectiveModule?.rightPillWidth ?? 0
                let pad = closedNotchHeight / 2
                let leftReserve = max(44, leftWidth + pad)
                let rightReserve = max(44, rightWidth + pad)
                return (rightReserve - leftReserve) / 2
            } else {
                return 0
            }
        }()

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // 共享的黑色磨砂玻璃背景底壳，随 notchStatus 状态非线性平滑形变
                let currentBottomRadius: CGFloat = usesOpenedVisualState ? NotchShape.openedBottomRadius : 11
                let currentShape = OpenedIslandSurfaceShape(
                    topProfile: (usesOpenedVisualState && usesNotchAwareOpenedHeader) ? .notch : .topBar,
                    bottomCornerRadius: currentBottomRadius
                )
                let currentWidth = usesOpenedVisualState ? openedWidth : closedWidth
                let currentHeight = usesOpenedVisualState ? openedHeight : closedNotchHeight
                let currentXOffset = usesOpenedVisualState ? 0 : closedOffset
                
                currentShape
                    .fill(Color.black)
                    .frame(width: currentWidth, height: currentHeight)
                    .overlay {
                        currentShape
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(usesOpenedVisualState ? 0.18 : 0.08),
                                        Color.white.opacity(0.04),
                                        Color.white.opacity(usesOpenedVisualState ? 0.10 : 0.04)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    }
                    .clipShape(currentShape)
                    .shadow(
                        color: Color.black.opacity(usesOpenedVisualState ? 0.15 : 0.06),
                        radius: usesOpenedVisualState ? 8 : 3,
                        x: 0,
                        y: usesOpenedVisualState ? 3 : 1
                    )
                    .offset(x: currentXOffset)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: currentWidth)

                if shouldRenderOpenedSurface {
                    openedSurface(width: currentWidth, height: currentHeight)
                        .frame(width: currentWidth, height: currentHeight, alignment: .top)
                        .clipShape(currentShape)
                        .scaleEffect(usesOpenedVisualState ? 1.0 : 0.94, anchor: .top)
                        .offset(y: usesOpenedVisualState ? 0 : -8)
                        .allowsHitTesting(usesOpenedVisualState)
                }

                v6ClosedSurface()
                    .frame(width: currentWidth, height: currentHeight)
                    .clipShape(currentShape)
                    .opacity(usesOpenedVisualState ? 0 : 1)
                    .scaleEffect(usesOpenedVisualState ? 1.12 : 1.0, anchor: .top)
                    .offset(x: currentXOffset, y: usesOpenedVisualState ? 8 : 0)
                    .allowsHitTesting(!usesOpenedVisualState)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: currentWidth)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scaleEffect(usesOpenedVisualState ? 1 : (isHovering ? IslandChromeMetrics.closedHoverScale : 1), anchor: .top)
        .padding(.horizontal, panelShadowHorizontalInset)
        .padding(.bottom, panelShadowBottomInset)
        .animation(notchTransitionAnimation, value: model.notchStatus)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                isHovering = hovering
            }
        }
        .onTapGesture {
            if model.notchStatus != .opened {
                model.notchOpen(reason: .click)
            }
        }
    }

    private func syncOpenedSurfaceMount(with status: NotchStatus, immediate: Bool = false) {
        openedSurfaceMountGeneration &+= 1
        let generation = openedSurfaceMountGeneration

        switch status {
        case .opened:
            keepsOpenedSurfaceMounted = true
        case .closed, .popping:
            guard !immediate else {
                keepsOpenedSurfaceMounted = false
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + openedSurfaceUnmountDelay) {
                guard openedSurfaceMountGeneration == generation,
                      model.notchStatus != .opened else {
                    return
                }
                keepsOpenedSurfaceMounted = false
            }
        }
    }

    // MARK: - v6 closed surface

    /// Closed island per v6 spec. Renders the flat-top pill with the
    /// UnifiedBars glyph, respecting the user's right-slot / center-label
    /// preferences. AppModel is @Observable so any change to sessions /
    /// preferences re-renders this automatically; UnifiedBars runs its own
    /// TimelineView internally for bar animation.
    private func v6ClosedSurface() -> some View {
        let layout: V6ClosedLayout = isExternalDisplayPlacement ? .external : .macbook
        let physicalNotchWidth: CGFloat = targetOverlayScreen?.notchSize.width ?? 180
        
        let effectiveModule = model.scheduler.activeModule
        
        let leftWidth: CGFloat = effectiveModule?.leftPillWidth ?? 24
        let rightWidth: CGFloat = effectiveModule?.rightPillWidth ?? 0

        let currentLabel: String? = {
            if effectiveModule?.id == "media_control" {
                if let media = effectiveModule as? MediaControlModule, !media.title.isEmpty, media.title != "Not Playing", media.title != "No active track" {
                    return media.title
                }
                return nil
            } else {
                return layout == .external ? model.islandClosedLabel() : nil
            }
        }()
        
        return V6ClosedPill(
            mode: model.islandClosedMode,
            label: currentLabel,
            rightSlot: model.islandClosedRightSlotContent(),
            layout: layout,
            height: closedNotchHeight,
            physicalNotchWidth: layout == .macbook ? physicalNotchWidth : 0,
            minWidth: 70,
            leftCustomView: effectiveModule.map { $0.leftPillView() },
            rightCustomView: effectiveModule.map { $0.rightPillView() },
            leftCustomViewWidth: leftWidth,
            rightCustomViewWidth: rightWidth,
            drawBackground: false
        )
        .scaleEffect(isPopping ? 1.04 : 1, anchor: .top)
        .animation(popAnimation, value: isPopping)
    }

    // MARK: - Opened surface

    @ViewBuilder
    private func openedSurface(width openedWidth: CGFloat, height openedHeight: CGFloat) -> some View {
        let horizontalInset = 0.0
        let bottomInset = 0.0

        VStack(spacing: 0) {
            if showingContent {
                openedHeaderContent
                    .frame(height: closedNotchHeight)
                    .transition(.opacity)

                openedContent
                    .frame(width: openedWidth)
                    .frame(maxHeight: max(0, openedHeight - closedNotchHeight), alignment: .top)
                    .clipped()
                    .transition(.opacity)
            }
        }
        .frame(width: openedWidth, height: openedHeight, alignment: .top)
        .padding(.horizontal, horizontalInset)
        .padding(.bottom, bottomInset)
    }

    // MARK: - Closed state

    private var closedNotchWidth: CGFloat {
        (targetOverlayScreen ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }))?.notchSize.width ?? NSScreen.externalDisplayNotchWidth
    }

    private var closedNotchHeight: CGFloat {
        (targetOverlayScreen ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }))?.islandClosedHeight ?? 24
    }

    @ViewBuilder
    private var openedHeaderContent: some View {
        if usesNotchAwareOpenedHeader {
            GeometryReader { geometry in
                let providers = openedUsageProviders
                let providerGroups = splitUsageProviders(providers)
                let metrics = openedHeaderMetrics(for: geometry.size.width)

                HStack(spacing: 0) {
                    usageLaneView(providerGroups.left, alignment: .leading)
                        .frame(width: metrics.leftUsageWidth, alignment: .leading)

                    Color.clear
                        .frame(width: metrics.centerGapWidth)

                    HStack(spacing: Self.headerControlSpacing) {
                        if metrics.rightUsageWidth > 0, !providerGroups.right.isEmpty {
                            usageLaneView(providerGroups.right, alignment: .trailing)
                                .frame(width: metrics.rightUsageWidth, alignment: .trailing)
                        }
                        openedHeaderButtons
                    }
                    .frame(width: metrics.rightLaneWidth, alignment: .trailing)
                }
                .padding(.horizontal, openedHeaderHorizontalPadding)
                .padding(.top, Self.headerTopPadding)
            }
        } else {
            HStack(spacing: 12) {
                openedUsageSummary
                    .frame(maxWidth: .infinity, alignment: .leading)

                openedHeaderButtons
            }
            .padding(.leading, openedHeaderHorizontalPadding)
            .padding(.trailing, openedHeaderHorizontalPadding)
            .padding(.top, Self.headerTopPadding)
        }
    }

    private var openedHeaderButtons: some View {
        HStack(spacing: Self.headerControlSpacing) {
            headerIconButton(
                systemName: model.isSoundMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                tint: model.isSoundMuted ? .orange.opacity(0.92) : .white.opacity(0.62)
            ) {
                model.toggleSoundMuted()
            }

            headerIconButton(systemName: "gearshape.fill", tint: .white.opacity(0.62)) {
                model.showSettings()
            }

            headerIconButton(
                systemName: "power",
                tint: .white.opacity(0.62),
                accessibilityLabel: model.lang.t("island.quit.confirmTitle")
            ) {
                showingQuitConfirmation = true
            }
        }
    }

    private func headerIconButton(
        systemName: String,
        tint: Color,
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: Self.headerControlButtonSize, height: Self.headerControlButtonSize)
                .background(.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? systemName)
    }

    private var openedContent: some View {
        VStack(spacing: 8) {
            moduleSelector

            if let activeModule = model.scheduler.activeModule, activeModule.id != "agent_monitor" {
                activeModule.expandedView()
            } else {
                if !model.hasAnyInstalledAgent {
                    installHooksHint
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                }

                if model.shouldShowSessionBootstrapPlaceholder {
                    sessionBootstrapPlaceholder
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                } else if model.islandListSessions.isEmpty {
                    emptyState
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                } else {
                    sessionList
                }
            }
        }
        .padding(.bottom, 0)
    }

    private var moduleSelector: some View {
        HStack(spacing: 2) {
            ForEach(model.scheduler.getModules(), id: \.id) { module in
                let isSelected = model.scheduler.activeModule?.id == module.id
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                        model.scheduler.activeModule = module
                        model.scheduler.userLockedModuleId = module.id
                    }
                } label: {
                    HStack(spacing: 5) {
                        moduleIcon(for: module.id)
                            .imageScale(.small)
                            .font(.system(size: 11, weight: .medium))
                        
                        Text(moduleDisplayName(for: module.id))
                            .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.45))
                    .background(
                        ZStack {
                            if isSelected {
                                Capsule()
                                    .fill(Color.white.opacity(0.12))
                                    .matchedGeometryEffect(id: "active_module_capsule", in: moduleSelectorNamespace)
                            }
                        }
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.05))
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func moduleIcon(for id: String) -> some View {
        Group {
            switch id {
            case "agent_monitor":
                Image(systemName: "cpu")
            case "media_control":
                Image(systemName: "music.note")
            case "timer":
                Image(systemName: "hourglass")
            case "system_telemetry":
                Image(systemName: "chart.bar.fill")
            case "message_center":
                Image(systemName: "message")
            default:
                Image(systemName: "app.fill")
            }
        }
    }

    private func moduleDisplayName(for id: String) -> String {
        let isChinese = model.lang.language.resolvedCode.hasPrefix("zh")
        switch id {
        case "agent_monitor":
            return isChinese ? "AI" : "Agent"
        case "media_control":
            return isChinese ? "音乐" : "Music"
        case "timer":
            return isChinese ? "番茄钟" : "Timer"
        case "system_telemetry":
            return isChinese ? "系统" : "System"
        case "message_center":
            return isChinese ? "消息" : "Messages"
        default:
            return id
        }
    }

    /// Persistent hint at the top of the expanded island while no agent
    /// hooks are installed. Decoupled from session presence — process
    /// discovery routinely surfaces sessions even on a freshly cleaned
    /// install, so the empty-state branch alone never reaches users who
    /// already run an agent.
    private var installHooksHint: some View {
        Button {
            model.showOnboarding()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(model.lang.t("island.hint.installHooks"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.35), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var sessionBootstrapPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white.opacity(0.7))
                .scaleEffect(0.8)
            Text(model.lang.t("island.checkingTerminals"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
            Text(model.lang.t("island.terminalOwnership"))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.28))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(model.lang.t("island.noTerminals"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            Text(model.recentSessions.isEmpty
                ? model.lang.t("island.startAgent")
                : model.lang.t("island.recentSessions"))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.25))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var actionableSessionID: String? {
        model.islandSurface.sessionID
    }

    /// Whether the panel was opened by a notification (show only actionable session + footer).
    private var isNotificationMode: Bool {
        model.notchOpenReason == .notification && actionableSessionID != nil
    }

    private static let maxSessionListHeight: CGFloat = 560

    private var sessionListSideInset: CGFloat {
        usesNotchAwareOpenedHeader ? 46 : 16
    }

    private var sessionList: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let referenceDate = context.date

            if isNotificationMode {
                // Notification mode: NO ScrollView — content sizes naturally
                sessionListContent(referenceDate: referenceDate)
                    .padding(.vertical, 2)
                    .onHover { hovering in
                        if hovering {
                            model.notePointerInsideIslandSurface()
                        } else {
                            model.handlePointerExitedIslandSurface()
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: NotificationContentHeightKey.self,
                                value: geo.size.height
                            )
                        }
                    )
                    .onPreferenceChange(NotificationContentHeightKey.self) { height in
                        if height > 0 {
                            model.measuredNotificationContentHeight = height
                        }
                    }
            } else {
                VStack(spacing: 0) {
                    sessionPanelHeader(referenceDate: referenceDate)

                    ScrollView(.vertical) {
                        sessionRowsContent(referenceDate: referenceDate)
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)

                    sessionPanelFooter
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func sessionListContent(referenceDate: Date) -> some View {
        VStack(spacing: 0) {
            if !isNotificationMode {
                sessionPanelHeader(referenceDate: referenceDate)
            }

            if isNotificationMode, let session = model.activeIslandCardSession {
                IslandSessionRow(
                    session: session,
                    referenceDate: referenceDate,
                    stateIndicator: model.islandSessionStateIndicator,
                    completedStaleThreshold: model.completedStaleThreshold.seconds,
                    isActionable: true,
                    useDrawingGroup: model.notchStatus == .opened,
                    isInteractive: model.notchStatus == .opened,
                    presentation: .notification,
                    sideInset: sessionListSideInset,
                    lang: model.lang,
                    onApprove: { model.approvePermission(for: session.id, action: $0) },
                    onAnswer: { model.answerQuestion(for: session.id, answer: $0) },
                    onReply: TerminalTextSender.canReply(to: session, enabled: model.completionReplyEnabled)
                        ? { model.replyToSession(session, text: $0) } : nil,
                    onJump: { model.jumpToSession(session) },
                    onKill: { model.forceKillSessionProcess(sessionID: session.id) }
                )
                .id(notificationCardIdentity(for: session))

                if model.allSessions.count > 1 {
                    Button {
                        let isCompletion = session.phase == .completed
                        model.expandNotificationToSessionList(clearExpansion: isCompletion)
                    } label: {
                        Text(model.lang.t("island.showAll", model.allSessions.count))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.36))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, sessionListSideInset)
                            .padding(.top, 6)
                            .padding(.bottom, 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ForEach(model.islandSessionSections) { section in
                    VStack(alignment: .leading, spacing: 0) {
                        if model.islandSessionGroup != .none {
                            sessionSectionHeader(section)
                        }

                        ForEach(section.sessions) { session in
                            IslandSessionRow(
                                session: session,
                                referenceDate: referenceDate,
                                stateIndicator: model.islandSessionStateIndicator,
                                completedStaleThreshold: model.completedStaleThreshold.seconds,
                                isActionable: session.phase.requiresAttention || session.id == actionableSessionID,
                                useDrawingGroup: model.notchStatus == .opened,
                                isInteractive: model.notchStatus == .opened,
                                sideInset: sessionListSideInset,
                                lang: model.lang,
                                onApprove: { model.approvePermission(for: session.id, action: $0) },
                                onAnswer: { model.answerQuestion(for: session.id, answer: $0) },
                                onReply: TerminalTextSender.canReply(to: session, enabled: model.completionReplyEnabled)
                                    ? { model.replyToSession(session, text: $0) } : nil,
                                onJump: { model.jumpToSession(session) },
                                onDismiss: session.isRemote ? { model.dismissSession(session.id) } : nil,
                                onKill: { model.forceKillSessionProcess(sessionID: session.id) },
                                summaryOverride: usageText(for: session)
                            )
                        }
                    }
                }
            }

            if !isNotificationMode {
                sessionPanelFooter
            }
        }
    }

    private func notificationCardIdentity(for session: AgentSession) -> String {
        switch session.phase {
        case .waitingForApproval:
            return "\(session.id)|approval|\(session.permissionRequest?.id.uuidString ?? "none")"
        case .waitingForAnswer:
            return "\(session.id)|question|\(session.questionPrompt?.id.uuidString ?? "none")"
        case .completed:
            return "\(session.id)|completed|\(session.updatedAt.timeIntervalSinceReferenceDate)"
        case .running:
            return "\(session.id)|running"
        }
    }

    @ViewBuilder
    private func sessionRowsContent(referenceDate: Date) -> some View {
        ForEach(model.islandSessionSections) { section in
            VStack(alignment: .leading, spacing: 8) {
                if model.islandSessionGroup != .none {
                    sessionSectionHeader(section)
                }

                ForEach(section.sessions) { session in
                    IslandSessionRow(
                        session: session,
                        referenceDate: referenceDate,
                        stateIndicator: model.islandSessionStateIndicator,
                        completedStaleThreshold: model.completedStaleThreshold.seconds,
                        isActionable: session.phase.requiresAttention || session.id == actionableSessionID,
                        useDrawingGroup: model.notchStatus == .opened,
                        isInteractive: model.notchStatus == .opened,
                        sideInset: sessionListSideInset,
                        lang: model.lang,
                        onApprove: { model.approvePermission(for: session.id, action: $0) },
                        onAnswer: { model.answerQuestion(for: session.id, answer: $0) },
                        onReply: TerminalTextSender.canReply(to: session, enabled: model.completionReplyEnabled)
                            ? { model.replyToSession(session, text: $0) } : nil,
                        onJump: { model.jumpToSession(session) },
                        onDismiss: session.isRemote ? { model.dismissSession(session.id) } : nil,
                        onKill: { model.forceKillSessionProcess(sessionID: session.id) },
                        summaryOverride: usageText(for: session)
                    )
                }
            }
        }
    }

    private func sessionPanelHeader(referenceDate: Date) -> some View {
        let overview = sessionOverviewItems(referenceDate: referenceDate)

        return HStack(spacing: 8) {
            Text(lang.t("island.sessionList.title").uppercased())
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(V6Palette.paper.opacity(0.55))

            ViewThatFits(in: .horizontal) {
                sessionOverviewView(overview, compact: false)
                sessionOverviewView(overview, compact: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, sessionListSideInset)
        .padding(.trailing, sessionListSideInset)
        .frame(height: 36)
    }

    private var sessionPanelFooter: some View {
        Color.clear
            .frame(height: 10)
    }

    private func usageText(for session: AgentSession) -> String? {
        let isChinese = model.lang.language.resolvedCode.hasPrefix("zh")
        if session.id == "desktop_app:codex" {
            guard let snapshot = model.codexUsageSnapshot, !snapshot.isEmpty else {
                return isChinese ? "暂无额度数据" : "No usage data"
            }
            return snapshot.windows.map { window in
                let remaining = max(0, 100 - window.roundedUsedPercentage)
                return isChinese
                    ? "\(window.label) 剩\(remaining)%"
                    : "\(window.label) \(remaining)% left"
            }.joined(separator: " | ")
        } else if session.id == "desktop_app:antigravity" {
            if let snapshot = model.antigravityUsageSnapshot {
                var parts: [String] = []
                if let fiveHour = snapshot.fiveHour {
                    let remaining = max(0, 100 - Int(fiveHour.usedPercentage.rounded()))
                    parts.append(isChinese ? "5h 剩\(remaining)%" : "5h \(remaining)% left")
                }
                if let sevenDay = snapshot.sevenDay {
                    let remaining = max(0, 100 - Int(sevenDay.usedPercentage.rounded()))
                    parts.append(isChinese ? "7d 剩\(remaining)%" : "7d \(remaining)% left")
                }
                if !parts.isEmpty {
                    return parts.joined(separator: " | ")
                }
            }
            return isChinese ? "暂无额度数据" : "No usage data"
        }
        return nil
    }

    private func sessionOverviewItems(referenceDate: Date) -> [SessionOverviewItem] {
        let sessions = model.islandListSessions
        guard !sessions.isEmpty else { return [] }

        let threshold = model.completedStaleThreshold.seconds
        let waiting = sessions.filter(\.phase.requiresAttention).count
        let running = sessions.filter { $0.phase == .running }.count
        let done = sessions.filter {
            $0.phase == .completed
                && !isIdleSessionOverviewItem($0, referenceDate: referenceDate, threshold: threshold)
        }.count
        let idle = sessions.filter {
            isIdleSessionOverviewItem($0, referenceDate: referenceDate, threshold: threshold)
        }.count

        return [
            SessionOverviewItem(id: "total", title: lang.t("island.sessionOverview.total"), compactTitle: "", count: sessions.count, tint: nil),
            SessionOverviewItem(id: "waiting", title: lang.t("island.sessionOverview.waiting"), compactTitle: lang.t("island.sessionOverview.waitingCompact"), count: waiting, tint: IslandDesignPalette.Status.waitingAggregate),
            SessionOverviewItem(id: "running", title: lang.t("island.sessionOverview.running"), compactTitle: lang.t("island.sessionOverview.runningCompact"), count: running, tint: IslandDesignPalette.Status.running),
            SessionOverviewItem(id: "done", title: lang.t("island.sessionOverview.done"), compactTitle: lang.t("island.sessionOverview.done"), count: done, tint: IslandDesignPalette.Status.completed),
            SessionOverviewItem(id: "idle", title: lang.t("island.sessionOverview.idle"), compactTitle: lang.t("island.sessionOverview.idle"), count: idle, tint: IslandDesignPalette.Status.idle),
        ].filter { $0.id == "total" || $0.count > 0 }
    }

    private func isIdleSessionOverviewItem(
        _ session: AgentSession,
        referenceDate: Date,
        threshold: TimeInterval
    ) -> Bool {
        guard session.phase == .completed else { return false }
        return session.isStaleCompletedForIsland(at: referenceDate, threshold: threshold)
            || session.islandPresence(at: referenceDate) == .inactive
    }

    private func sessionOverviewView(_ items: [SessionOverviewItem], compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 8) {
            ForEach(items) { item in
                sessionOverviewMetric(item, compact: compact)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func sessionOverviewMetric(_ item: SessionOverviewItem, compact: Bool) -> some View {
        let isTotal = item.tint == nil
        let glowColor = item.tint ?? Color.white
        let titleColor = isTotal ? V6Palette.paper.opacity(0.55) : V6Palette.paper.opacity(0.8)

        let fillColor: Color = {
            if isTotal {
                return Color.white.opacity(0.04)
            } else if let tint = item.tint {
                return tint.opacity(0.06)
            } else {
                return Color.white.opacity(0.04)
            }
        }()

        let strokeColor: Color = {
            if isTotal {
                return Color.white.opacity(0.06)
            } else if let tint = item.tint {
                return tint.opacity(0.18)
            } else {
                return Color.white.opacity(0.06)
            }
        }()

        return HStack(spacing: 5) {
            if let tint = item.tint {
                Circle()
                    .fill(tint)
                    .frame(width: 5.2, height: 5.2)
                    .shadow(color: glowColor.opacity(0.6), radius: 1.5)
            }

            Text(sessionOverviewMetricTitle(item, compact: compact))
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(titleColor)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(strokeColor, lineWidth: 0.5)
        )
    }

    private func sessionOverviewMetricTitle(_ item: SessionOverviewItem, compact: Bool) -> String {
        if item.id == "total" {
            return compact ? "\(item.count)" : "\(item.count) \(item.title)"
        }

        return "\(item.count) \(compact ? item.compactTitle : item.title)"
    }

    private func sessionSectionHeader(_ section: IslandSessionSection) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(sectionTint(for: section))
                .frame(width: 7, height: 7)
            Text(sessionSectionTitle(for: section).uppercased())
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(sectionLabelColor(for: section))
            Text("\(section.sessions.count)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(V6Palette.paper.opacity(0.4))
            Spacer(minLength: 0)
        }
        .padding(.leading, sessionListSideInset)
        .padding(.trailing, sessionListSideInset)
        .padding(.top, 10)
        .padding(.bottom, 7)
        .background(Color.white.opacity(0.008))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.055))
                .frame(height: 1)
        }
    }

    private func sectionTint(for section: IslandSessionSection) -> Color {
        guard let first = section.sessions.first else { return IslandDesignPalette.Status.idle }
        if section.id == "state-idle" { return IslandDesignPalette.Status.idle }
        return IslandDesignPalette.Status.tint(for: first.phase)
    }

    private func sessionSectionTitle(for section: IslandSessionSection) -> String {
        if section.title.hasPrefix("island.") {
            return lang.t(section.title)
        }
        return section.title
    }

    private func sectionLabelColor(for section: IslandSessionSection) -> Color {
        switch section.id {
        case "state-approval":
            return IslandDesignPalette.Status.waitingForApproval.opacity(0.86)
        case "state-answer":
            return IslandDesignPalette.Status.waitingForAnswer.opacity(0.86)
        default:
            return V6Palette.paper.opacity(0.7)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var openedUsageSummary: some View {
        let providers = openedUsageProviders

        if providers.isEmpty == false {
            ViewThatFits(in: .horizontal) {
                compactUsageSummaryView(providers, usesShortTitles: false)
                compactUsageSummaryView(providers, usesShortTitles: true)
            }
        } else {
            Color.clear
        }
    }

    private var openedUsageProviders: [UsageProviderPresentation] {
        guard model.islandUsageDisplay == .compact else {
            return []
        }

        var providers: [UsageProviderPresentation] = []

        let isAntigravityRunning = model.islandListSessions.contains { $0.id == "desktop_app:antigravity" }
        let isCodexRunning = model.islandListSessions.contains { $0.id == "desktop_app:codex" }

        if let snapshot = model.claudeUsageSnapshot,
           snapshot.isEmpty == false {
            var windows: [UsageWindowPresentation] = []

            if let fiveHour = snapshot.fiveHour {
                windows.append(
                    UsageWindowPresentation(
                        id: "claude-5h",
                        label: "5h",
                        usedPercentage: fiveHour.usedPercentage,
                        resetsAt: fiveHour.resetsAt
                    )
                )
            }

            if let sevenDay = snapshot.sevenDay {
                windows.append(
                    UsageWindowPresentation(
                        id: "claude-7d",
                        label: "7d",
                        usedPercentage: sevenDay.usedPercentage,
                        resetsAt: sevenDay.resetsAt
                    )
                )
            }

            if windows.isEmpty == false {
                providers.append(
                    UsageProviderPresentation(
                        id: "claude",
                        title: "Claude",
                        windows: windows
                    )
                )
            }
        }

        if let snapshot = model.antigravityUsageSnapshot,
           snapshot.isEmpty == false {
            var windows: [UsageWindowPresentation] = []

            if let fiveHour = snapshot.fiveHour {
                windows.append(
                    UsageWindowPresentation(
                        id: "antigravity-5h",
                        label: "5h",
                        usedPercentage: fiveHour.usedPercentage,
                        resetsAt: fiveHour.resetsAt
                    )
                )
            }

            if let sevenDay = snapshot.sevenDay {
                windows.append(
                    UsageWindowPresentation(
                        id: "antigravity-7d",
                        label: "7d",
                        usedPercentage: sevenDay.usedPercentage,
                        resetsAt: sevenDay.resetsAt
                    )
                )
            }

            if windows.isEmpty == false {
                providers.append(
                    UsageProviderPresentation(
                        id: "antigravity",
                        title: "Antigravity",
                        windows: windows
                    )
                )
            }
        } else if isAntigravityRunning {
            providers.append(
                UsageProviderPresentation(
                    id: "antigravity",
                    title: "Antigravity",
                    windows: [],
                    isPlaceholder: true
                )
            )
        }

        if model.showCodexUsage,
           let snapshot = model.codexUsageSnapshot,
           snapshot.isEmpty == false {
            let windows = snapshot.windows.map { window in
                UsageWindowPresentation(
                    id: "codex-\(window.key)",
                    label: window.label,
                    usedPercentage: window.usedPercentage,
                    resetsAt: window.resetsAt
                )
            }

            if windows.isEmpty == false {
                providers.append(
                    UsageProviderPresentation(
                        id: "codex",
                        title: "Codex",
                        windows: windows
                    )
                )
            }
        } else if isCodexRunning {
            providers.append(
                UsageProviderPresentation(
                    id: "codex",
                    title: "Codex",
                    windows: [],
                    isPlaceholder: true
                )
            )
        }

        return providers
    }

    private func splitUsageProviders(
        _ providers: [UsageProviderPresentation]
    ) -> (left: [UsageProviderPresentation], right: [UsageProviderPresentation]) {
        switch providers.count {
        case 0:
            return ([], [])
        case 1:
            return ([providers[0]], [])
        case 2:
            return ([providers[0]], [providers[1]])
        default:
            let splitIndex = Int(ceil(Double(providers.count) / 2.0))
            return (
                Array(providers.prefix(splitIndex)),
                Array(providers.dropFirst(splitIndex))
            )
        }
    }

    @ViewBuilder
    private func usageLaneView(
        _ providers: [UsageProviderPresentation],
        alignment: Alignment
    ) -> some View {
        if providers.isEmpty {
            Color.clear
                .frame(maxWidth: .infinity)
        } else {
            ViewThatFits(in: .horizontal) {
                compactUsageSummaryView(providers, usesShortTitles: false)
                compactUsageSummaryView(providers, usesShortTitles: true)
            }
            .frame(maxWidth: .infinity, alignment: alignment)
        }
    }

    private func openedHeaderMetrics(for totalWidth: CGFloat) -> OpenedHeaderMetrics {
        let horizontalPadding = openedHeaderHorizontalPadding
        let contentWidth = max(0, totalWidth - (horizontalPadding * 2))
        guard usesNotchAwareOpenedHeader,
              let screen = targetOverlayScreen else {
            let rightLaneWidth = min(contentWidth, openedHeaderButtonsWidth + (contentWidth / 2))
            let leftUsageWidth = max(0, contentWidth - rightLaneWidth)
            return OpenedHeaderMetrics(
                leftUsageWidth: leftUsageWidth,
                centerGapWidth: 0,
                rightUsageWidth: max(0, rightLaneWidth - openedHeaderButtonsWidth - Self.headerControlSpacing),
                rightLaneWidth: rightLaneWidth
            )
        }

        let panelMinX = screen.frame.midX - (totalWidth / 2)
        let panelMaxX = panelMinX + totalWidth
        let contentMinX = panelMinX + horizontalPadding
        let contentMaxX = panelMaxX - horizontalPadding

        let fallbackNotchHalfWidth = screen.notchSize.width / 2
        let notchLeftEdge = screen.frame.midX - fallbackNotchHalfWidth
        let notchRightEdge = screen.frame.midX + fallbackNotchHalfWidth
        let leftVisibleMaxX = screen.auxiliaryTopLeftArea?.maxX ?? notchLeftEdge
        let rightVisibleMinX = screen.auxiliaryTopRightArea?.minX ?? notchRightEdge

        let rawLeftWidth = max(0, min(contentMaxX, leftVisibleMaxX) - contentMinX)
        let rawRightWidth = max(0, contentMaxX - max(contentMinX, rightVisibleMinX))

        let leftUsageWidth = max(0, rawLeftWidth - Self.notchLaneSafetyInset)
        let rightAvailableWidth = max(0, rawRightWidth - Self.notchLaneSafetyInset)
        let proposedRightUsageWidth = max(
            0,
            rightAvailableWidth - openedHeaderButtonsWidth - Self.headerControlSpacing
        )
        let rightUsageWidth = proposedRightUsageWidth >= Self.minimumRightUsageLaneWidth
            ? proposedRightUsageWidth
            : 0
        let rightLaneWidth = min(
            contentWidth,
            openedHeaderButtonsWidth
                + (rightUsageWidth > 0 ? Self.headerControlSpacing + rightUsageWidth : 0)
        )
        let centerGapWidth = max(0, contentWidth - leftUsageWidth - rightLaneWidth)

        return OpenedHeaderMetrics(
            leftUsageWidth: leftUsageWidth,
            centerGapWidth: centerGapWidth,
            rightUsageWidth: rightUsageWidth,
            rightLaneWidth: rightLaneWidth
        )
    }

    private func compactUsageSummaryView(
        _ providers: [UsageProviderPresentation],
        usesShortTitles: Bool
    ) -> some View {
        HStack(spacing: 7) {
            ForEach(providers) { provider in
                compactUsageChip(provider, usesShortTitle: usesShortTitles)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func screenID(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return "display-\(number.uint32Value)"
        }

        return screen.localizedName
    }

    private func compactUsageChip(_ provider: UsageProviderPresentation, usesShortTitle: Bool) -> some View {
        let isChinese = model.lang.language.resolvedCode.hasPrefix("zh")
        return HStack(spacing: 5) {
            Text(usesShortTitle ? provider.shortTitle : provider.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.74))

            if provider.isPlaceholder {
                Text(isChinese ? "运行中" : "Active")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))
            } else {
                Text(provider.peakWindowLabel)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))

                let remainingText = isChinese
                    ? "剩\(provider.peakRemainingPercentage)%"
                    : "\(provider.peakRemainingPercentage)% left"

                Text(remainingText)
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(usageColor(for: provider.peakUsedPercentage))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white.opacity(0.055), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Capsule())
        .onTapGesture {
            let session: AgentSession?
            if provider.id == "claude" {
                if let antigravitySession = model.islandListSessions.first(where: { $0.id == "desktop_app:antigravity" }) {
                    session = antigravitySession
                } else {
                    session = model.islandListSessions.first(where: { $0.tool == .claudeCode })
                }
            } else if provider.id == "codex" {
                session = model.islandListSessions.first(where: { $0.id == "desktop_app:codex" })
            } else {
                session = nil
            }
            if let session {
                model.jumpToSession(session)
            }
        }
        .help(usageHelpText(for: provider))
    }

    private func usageHelpText(for provider: UsageProviderPresentation) -> String {
        if provider.isPlaceholder {
            return model.lang.language.resolvedCode.hasPrefix("zh")
                ? "Antigravity 桌面端正在运行"
                : "Antigravity Desktop is running"
        }
        return provider.windows.map { window in
            var parts = ["\(window.label) \(window.roundedUsedPercentage)%"]
            if let resetsAt = window.resetsAt,
               let remaining = remainingDurationString(until: resetsAt) {
                parts.append(remaining)
            }
            return parts.joined(separator: " ")
        }
        .joined(separator: " · ")
    }

    private func headerPill(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.08), in: Capsule())
    }

    private func usageColor(for percentage: Double) -> Color {
        switch percentage {
        case 90...:
            .red.opacity(0.95)
        case 70..<90:
            .orange.opacity(0.95)
        default:
            .green.opacity(0.95)
        }
    }

    private func remainingDurationString(until date: Date) -> String? {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else {
            return nil
        }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated

        if interval >= 86_400 {
            formatter.allowedUnits = [.day]
            formatter.maximumUnitCount = 1
        } else if interval >= 3_600 {
            formatter.allowedUnits = [.hour, .minute]
            formatter.maximumUnitCount = 2
        } else {
            formatter.allowedUnits = [.minute]
            formatter.maximumUnitCount = 1
        }

        return formatter.string(from: interval)
    }
}

private struct UsageProviderPresentation: Identifiable {
    let id: String
    let title: String
    let windows: [UsageWindowPresentation]
    var isPlaceholder: Bool = false

    var peakWindow: UsageWindowPresentation? {
        windows.max { lhs, rhs in
            lhs.usedPercentage < rhs.usedPercentage
        }
    }

    var peakWindowLabel: String {
        peakWindow?.label ?? ""
    }

    var peakUsedPercentage: Double {
        peakWindow?.usedPercentage ?? 0
    }

    var peakUsagePercentage: Int {
        peakWindow?.roundedUsedPercentage ?? 0
    }

    var peakRemainingPercentage: Int {
        max(0, 100 - peakUsagePercentage)
    }

    var shortTitle: String {
        switch id {
        case "claude":
            return title == "Antigravity" ? "An" : "Cl"
        case "codex":
            return "Cx"
        default:
            return String(title.prefix(2))
        }
    }
}

private struct UsageWindowPresentation: Identifiable {
    let id: String
    let label: String
    let usedPercentage: Double
    let resetsAt: Date?

    var roundedUsedPercentage: Int {
        Int(usedPercentage.rounded())
    }
}

private struct OpenedHeaderMetrics {
    let leftUsageWidth: CGFloat
    let centerGapWidth: CGFloat
    let rightUsageWidth: CGFloat
    let rightLaneWidth: CGFloat
}

private struct SessionOverviewItem: Identifiable {
    let id: String
    let title: String
    let compactTitle: String
    let count: Int
    let tint: Color?
}

// MARK: - Session row (opened state)

private enum IslandSessionRowPresentation {
    case list
    case notification
}

private struct IslandSessionRow: View {
    let session: AgentSession
    let referenceDate: Date
    var stateIndicator: IslandSessionStateIndicator = .animatedDot
    var completedStaleThreshold: TimeInterval = AgentSession.staleCompletedDisplayThreshold
    var isActionable: Bool = false
    var useDrawingGroup: Bool = true
    var isInteractive: Bool = true
    var presentation: IslandSessionRowPresentation = .list
    var sideInset: CGFloat = 16
    var lang: LanguageManager = .shared
    var onApprove: ((ApprovalAction) -> Void)?
    var onAnswer: ((QuestionPromptResponse) -> Void)?
    var onReply: ((String) -> Void)?
    let onJump: () -> Void
    var onDismiss: (() -> Void)?
    var onKill: (() -> Void)? = nil
    var summaryOverride: String? = nil

    @State private var isHighlighted = false
    @State private var isPressed = false
    @State private var detailOverride: Bool?
    @State private var replyText: String = ""

    var body: some View {
        rowBody(referenceDate: referenceDate)
    }

    private func rowBody(referenceDate: Date) -> some View {
        let rawPresence = session.islandPresence(at: referenceDate)
        let isStaleCompleted = session.isStaleCompletedForIsland(
            at: referenceDate,
            threshold: completedStaleThreshold
        )
        let defaultShowsDetail = !isStaleCompleted && (rawPresence != .inactive || isActionable)
        let showsDetail = detailOverride ?? defaultShowsDetail
        let presence = isStaleCompleted
            ? .inactive
            : ((showsDetail && rawPresence == .inactive) ? .active : rawPresence)
        
        let content = VStack(alignment: .leading, spacing: 0) {
            rowSummary(presence: presence, showsDetail: showsDetail)

            if showsDetail {
                rowAuxiliaryDetails(presence: presence)

                if shouldShowEmbeddedDetailBody {
                    embeddedDetailBody
                        .padding(.leading, presentation == .notification ? detailLeadingInset : 12)
                        .padding(.trailing, presentation == .notification ? sideInset : 12)
                        .padding(.bottom, 13)
                }
            }
        }
        .overlay(alignment: .leading) {
            if showsLeadingStatusBar {
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(statusTint(for: presence))
                    .frame(width: 3)
                    .padding(.vertical, showsDetail ? 8 : 6)
                    .padding(.leading, 8)
            }
        }

        if presentation == .notification {
            return AnyView(
                content
                    .background(Color.clear)
                    .opacity(isStaleCompleted ? 0.7 : 1)
                    .modifier(ConditionalDrawingGroup(enabled: useDrawingGroup && !isActionable))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: handlePrimaryTap)
            )
        } else {
            let isDesktopApp = session.id.hasPrefix("desktop_app:")
            let cornerRadius: CGFloat = isDesktopApp ? 10 : 12
            let hPadding: CGFloat = isDesktopApp ? 10 : 12
            let vPadding: CGFloat = isDesktopApp ? 6 : 10
            
            return AnyView(
                content
                    .padding(.horizontal, hPadding)
                    .padding(.vertical, vPadding)
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(isPressed ? (isDesktopApp ? 0.08 : 0.12) : (isHighlighted ? (isDesktopApp ? 0.05 : 0.075) : (isDesktopApp ? 0.015 : 0.025))),
                                        Color.white.opacity(isPressed ? (isDesktopApp ? 0.04 : 0.06) : (isHighlighted ? (isDesktopApp ? 0.025 : 0.035) : (isDesktopApp ? 0.005 : 0.01)))
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(isPressed ? (isDesktopApp ? 0.15 : 0.20) : (isHighlighted ? (isDesktopApp ? 0.10 : 0.14) : (isDesktopApp ? 0.04 : 0.06))),
                                        Color.white.opacity(isPressed ? (isDesktopApp ? 0.06 : 0.08) : (isHighlighted ? (isDesktopApp ? 0.03 : 0.04) : (isDesktopApp ? 0.005 : 0.01)))
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                    }
                    .shadow(
                        color: Color.black.opacity(isHighlighted ? (isDesktopApp ? 0.12 : 0.18) : 0.0),
                        radius: isDesktopApp ? 5 : 8,
                        x: 0,
                        y: isDesktopApp ? 2 : 4
                    )
                    .padding(.horizontal, sideInset)
                    .padding(.vertical, 2)
                    .scaleEffect(isPressed ? 0.98 : (isHighlighted ? 1.01 : 1.0))
                    .animation(.spring(response: 0.15, dampingFraction: 0.7), value: isPressed)
                    .animation(.spring(response: 0.24, dampingFraction: 0.8), value: isHighlighted)
                    .opacity(isStaleCompleted ? 0.65 : 1)
                    .modifier(ConditionalDrawingGroup(enabled: useDrawingGroup && !isActionable))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: handlePrimaryTap)
                    .onHover { hovering in
                        guard isInteractive, allowsRowHoverHighlight else { return }
                        isHighlighted = hovering
                    }
                    .onChange(of: isInteractive) { _, interactive in
                        if !interactive {
                            detailOverride = nil
                        }
                    }
            )
        }
    }

    private func rowSummary(presence: IslandSessionPresence, showsDetail: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if showsLeadingStatusIndicator {
                statusIndicator(for: presence)
                    .frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 3) {
                let isDesktopApp = session.id.hasPrefix("desktop_app:")
                if isDesktopApp {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Image(systemName: "app.window.up.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.35))
                                
                                Text(summaryHeadlineText)
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(titleColor(for: presence))
                                
                                Circle()
                                    .fill(presence == .active ? Color.green : Color.gray)
                                    .frame(width: 5, height: 5)
                                    .shadow(color: presence == .active ? Color.green.opacity(0.8) : Color.clear, radius: 2)
                            }
                            
                            if session.id == "desktop_app:antigravity",
                               let account = AntigravityAccountLoader.loadEmail() {
                                HStack(spacing: 3.5) {
                                    Image(systemName: "envelope.fill")
                                        .font(.system(size: 7.5))
                                    Text(account)
                                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                }
                                .foregroundStyle(.white.opacity(0.35))
                            } else if session.id == "desktop_app:codex" {
                                let account = CodexAccountLoader.loadEmail() ?? "Local Account"
                                HStack(spacing: 3.5) {
                                    Image(systemName: account.contains("@") ? "envelope.fill" : "person.fill")
                                        .font(.system(size: 7.5))
                                    Text(account)
                                        .font(.system(size: 9.5, weight: .medium, design: account.contains("@") ? .monospaced : .rounded))
                                }
                                .foregroundStyle(.white.opacity(0.35))
                            }
                            
                            HStack(spacing: 4) {
                                if let pid = session.pid {
                                    HStack(spacing: 3) {
                                        Image(systemName: "cpu")
                                            .font(.system(size: 7.5))
                                        Text("PID \(pid)")
                                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    }
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 3))
                                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.05), lineWidth: 0.5))
                                    .foregroundStyle(.white.opacity(0.55))
                                }
                                
                                if let cpu = session.cpuUsage {
                                    let (textColor, bgColor, borderColor, icon) = cpuBadgeStyle(cpu: cpu)
                                    HStack(spacing: 3) {
                                        Image(systemName: icon)
                                            .font(.system(size: 7.5))
                                        Text(String(format: "CPU %.1f%%", cpu))
                                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    }
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(bgColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
                                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(borderColor.opacity(0.15), lineWidth: 0.5))
                                    .foregroundStyle(textColor)
                                }
                            }
                        }
                        
                        if let quotaText = summaryOverride {
                            if quotaText == "暂无额度数据" || quotaText == "No usage data" {
                                Text(quotaText)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.3))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 4))
                            } else {
                                let brandColor = Color(hex: session.tool.brandColorHex) ?? .blue
                                let parsed = parseQuota(from: quotaText)
                                HStack(spacing: 8) {
                                    ForEach(parsed, id: \.label) { q in
                                        quotaProgressBar(label: q.label, percentageLeft: q.percentage, brandColor: brandColor)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    if presentation == .list {
                        HStack(spacing: 5) {
                            let isDesktopApp = session.id.hasPrefix("desktop_app:")
                            if isDesktopApp {
                                Image(systemName: "app.window.up.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                            
                            Text(summaryHeadlineText)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(titleColor(for: presence))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    } else {
                        Text(summaryHeadlineText)
                            .font(summaryTitleFont)
                            .foregroundStyle(titleColor(for: presence))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    
                    if let cpu = session.cpuUsage, cpu >= 90.0 {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                            Text(String(format: "CPU 异常 (%.0f%%) 可能卡死", cpu))
                                .font(.system(size: 9.5, weight: .bold))
                        }
                        .foregroundStyle(.red)
                    } else if showsDetail,
                       let promptLine = summaryPromptLineText {
                        Text(promptLine)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(summaryPromptColor(for: presence).opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            Spacer(minLength: 10)

            HStack(spacing: 6) {
                if let cpu = session.cpuUsage, cpu >= 90.0 {
                    Button {
                        onKill?()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark.octagon.fill")
                                .font(.system(size: 8))
                            Text("强杀")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
                
                if !session.id.hasPrefix("desktop_app:") {
                    agentBadge
                }
                if session.isRemote {
                    sideBadge("SSH")
                }
                if let terminalBadge = session.spotlightTerminalBadge,
                   !session.id.hasPrefix("desktop_app:") {
                    sideBadge(terminalBadge)
                }
                if !session.id.hasPrefix("desktop_app:") {
                    Text(session.spotlightAgeBadge)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(summaryAgeColor(for: presence))
                        .frame(minWidth: 30, alignment: .trailing)
                    detailToggleButton(isOpen: showsDetail)
                }
                if let onDismiss {
                    DismissButton(action: onDismiss)
                }
            }
        }
        .padding(.leading, presentation == .notification ? rowLeadingInset : 0)
        .padding(.trailing, presentation == .notification ? sideInset : 0)
        .padding(.top, presentation == .notification ? 11 : 0)
        .padding(.bottom, presentation == .notification ? (showsDetail ? 8 : 11) : 0)
    }

    @ViewBuilder
    private func rowAuxiliaryDetails(presence: IslandSessionPresence) -> some View {
        if !shouldShowEmbeddedDetailBody,
           let activityLine = session.spotlightActivityLineText ?? expandedActivityLineText,
           activityLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "ready" {
            Text(activityLine)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(activityColor(for: presence).opacity(0.94))
                .lineLimit(2)
                .padding(.leading, detailLeadingInset)
                .padding(.trailing, sideInset)
                .padding(.bottom, 10)
        }

        if let subagents = session.claudeMetadata?.activeSubagents,
           !subagents.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .medium))
                    Text(lang.t("subagents.title", subagents.count))
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(.cyan.opacity(0.8))

                ForEach(subagents, id: \.agentID) { sub in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(sub.summary != nil
                                ? IslandDesignPalette.Status.completed
                                : IslandDesignPalette.Status.running)
                            .frame(width: 6, height: 6)
                        Text(sub.agentType ?? sub.agentID)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                        if let desc = sub.taskDescription {
                            Text("(\(desc))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if sub.summary != nil {
                            Text(lang.t("subagents.completed"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.4))
                        } else if let started = sub.startedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                Text(subagentElapsed(since: started, at: timeline.date))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                    }
                }
            }
            .padding(.leading, detailLeadingInset)
            .padding(.trailing, sideInset)
            .padding(.bottom, 10)
        }

        if let tasks = session.claudeMetadata?.activeTasks,
           !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(taskSummary(tasks))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                ForEach(tasks) { task in
                    HStack(spacing: 5) {
                        taskStatusIcon(task.status)
                        Text(task.title)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(task.status == .completed
                                ? .white.opacity(0.4)
                                : .white.opacity(0.7))
                            .strikethrough(task.status == .completed)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.leading, detailLeadingInset)
            .padding(.trailing, sideInset)
            .padding(.bottom, 10)
        }
    }

    private func parseQuota(from quotaText: String) -> [(label: String, percentage: Double)] {
        guard quotaText != "暂无额度数据" && quotaText != "No usage data" else {
            return []
        }
        
        var results: [(label: String, percentage: Double)] = []
        let parts = quotaText.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for part in parts {
            let label: String
            if part.contains("5h") {
                label = "5h"
            } else if part.contains("7d") {
                label = "7d"
            } else {
                label = "Quota"
            }
            
            var cleanPart = part
            if label != "Quota" {
                cleanPart = cleanPart.replacingOccurrences(of: label, with: "")
            }
            
            let numbers = cleanPart.filter { "0123456789".contains($0) }
            if let pct = Double(numbers) {
                results.append((label: label, percentage: pct))
            }
        }
        return results
    }

    private func quotaProgressBar(label: String, percentageLeft: Double, brandColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2.5) {
            HStack(spacing: 0) {
                Text(label)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.35))
                Spacer()
                Text("\(Int(percentageLeft.rounded()))%")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(percentageLeft <= 20.0 ? Color.red : (percentageLeft <= 50.0 ? Color.orange : brandColor))
            }
            
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.05))
                    .frame(height: 3)
                
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                (percentageLeft <= 20.0 ? Color.red : (percentageLeft <= 50.0 ? Color.orange : brandColor)).opacity(0.65),
                                (percentageLeft <= 20.0 ? Color.red : (percentageLeft <= 50.0 ? Color.orange : brandColor))
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, min(80, 80 * CGFloat(percentageLeft / 100.0))), height: 3)
            }
            .frame(width: 80, height: 3)
        }
        .frame(width: 80)
    }

    @ViewBuilder
    private func telemetryBadge(
        text: String,
        icon: String?,
        textColor: Color,
        bgColor: Color,
        borderColor: Color
    ) -> some View {
        HStack(spacing: 3) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 8))
            }
            Text(text)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(bgColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(borderColor, lineWidth: 0.5))
    }

    private func cpuBadgeStyle(cpu: Double) -> (textColor: Color, bgColor: Color, borderColor: Color, icon: String) {
        if cpu >= 80.0 {
            return (.red, .red.opacity(0.12), .red.opacity(0.3), "exclamationmark.triangle.fill")
        } else if cpu >= 30.0 {
            return (.orange, .orange.opacity(0.1), .orange.opacity(0.25), "waveform.path.ecg")
        } else {
            return (.white.opacity(0.55), .white.opacity(0.04), .white.opacity(0.1), "waveform.path.ecg")
        }
    }

    private var agentBadge: some View {
        let tint = Color(hex: session.tool.brandColorHex) ?? V6Palette.paper
        return HStack(spacing: 3) {
            Image(systemName: "sparkles")
                .font(.system(size: 8))
                .foregroundStyle(tint.opacity(0.8))
            Text(agentBadgeTitle)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .tracking(0.3)
        }
        .foregroundStyle(tint.opacity(presentation == .notification ? notificationChromeOpacity : 0.9))
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(tint.opacity(presentation == .notification ? notificationBadgeFillOpacity : 0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(tint.opacity(presentation == .notification ? notificationBadgeStrokeOpacity : 0.15), lineWidth: 0.5))
    }

    private func sideBadge(_ title: String) -> some View {
        HStack(spacing: 3) {
            if title.lowercased().contains("ssh") {
                Image(systemName: "network")
                    .font(.system(size: 8))
            } else if title.lowercased().contains("iterm") || title.lowercased().contains("terminal") || title.lowercased().contains("ghostty") {
                Image(systemName: "terminal")
                    .font(.system(size: 8))
            }
            Text(title)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .tracking(0.3)
        }
        .foregroundStyle(V6Palette.paper.opacity(presentation == .notification ? 0.52 : 0.65))
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(.white.opacity(presentation == .notification ? 0.045 : 0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(presentation == .notification ? 0.045 : 0.08), lineWidth: 0.5))
    }

    private var summaryPromptLineText: String? {
        if presentation == .notification {
            if session.phase == .completed {
                return notificationCompletedPromptLineText
            }
            return session.notificationHeaderPromptLineText
        }

        return session.spotlightPromptLineText ?? expandedPromptLineText
    }

    private var summaryHeadlineText: String {
        if presentation == .notification, session.phase == .completed {
            return notificationWorkspaceHeadlineText
        }

        return session.spotlightHeadlineText
    }

    private var notificationWorkspaceHeadlineText: String {
        let workspace = session.spotlightWorkspaceName.trimmedForNotificationCard
        let title = workspace.isEmpty ? session.tool.displayName : workspace
        guard let branch = session.spotlightWorktreeBranch?.trimmedForNotificationCard,
              !branch.isEmpty else {
            return title
        }

        return "\(title) (\(branch))"
    }

    private var notificationCompletedPromptLineText: String? {
        if let prompt = session.latestUserPromptText?.trimmedForNotificationCard, !prompt.isEmpty {
            return "You: \(prompt)"
        }

        if let prompt = session.initialUserPromptText?.trimmedForNotificationCard, !prompt.isEmpty {
            return "You: \(prompt)"
        }

        return nil
    }

    private var agentBadgeTitle: String {
        switch session.tool {
        case .claudeCode:
            "claude"
        case .geminiCLI:
            "gemini"
        case .qwenCode:
            "qwen"
        case .kimiCLI:
            "kimi"
        case .antigravity:
            "antigravity"
        default:
            session.tool.shortName.lowercased()
        }
    }

    private var rowLeadingInset: CGFloat {
        if presentation == .notification {
            return sideInset
        }
        return 12
    }

    private var detailLeadingInset: CGFloat {
        if presentation == .notification {
            return sideInset
        }

        return switch stateIndicator {
        case .bar:
            28
        case .tint:
            12
        case .animatedDot, .glyph:
            38
        }
    }

    private var showsLeadingStatusIndicator: Bool {
        presentation == .list && stateIndicator != .tint && stateIndicator != .bar
    }

    private var showsLeadingStatusBar: Bool {
        presentation == .list && stateIndicator == .bar
    }

    private var summaryTitleFont: Font {
        .system(size: presentation == .notification ? 13.2 : (isActionable ? 13.8 : 13.2), weight: .semibold)
    }

    private func summaryPromptColor(for presence: IslandSessionPresence) -> Color {
        if presentation == .notification {
            return V6Palette.paper.opacity(session.phase == .completed ? 0.38 : 0.46)
        }

        return V6Palette.paper.opacity(presence == .inactive ? 0.34 : 0.52)
    }

    private func summaryAgeColor(for presence: IslandSessionPresence) -> Color {
        if presentation == .notification {
            return V6Palette.paper.opacity(0.36)
        }

        return V6Palette.paper.opacity(presence == .inactive ? 0.32 : 0.45)
    }

    private var notificationChromeOpacity: Double {
        presentation == .notification ? 0.82 : 1
    }

    private var notificationBadgeFillOpacity: Double {
        presentation == .notification ? 0.08 : 0.13
    }

    private var notificationBadgeStrokeOpacity: Double {
        presentation == .notification ? 0.24 : 0.35
    }

    private func titleColor(for presence: IslandSessionPresence) -> Color {
        if stateIndicator == .tint && presence != .inactive {
            return statusTint(for: presence)
        }

        if presentation == .notification, session.phase == .completed {
            return .white.opacity(0.78)
        }

        return headlineColor(for: presence)
    }

    private var actionableBorderColor: Color {
        if isActionable {
            return actionableStatusTint.opacity(isHighlighted ? 0.45 : 0.28)
        }
        return isHighlighted ? .white.opacity(0.24) : .white.opacity(0.04)
    }

    private var actionableStatusTint: Color {
        IslandDesignPalette.Status.tint(for: session.phase)
    }

    @ViewBuilder
    private var actionableBody: some View {
        switch session.phase {
        case .waitingForApproval:
            approvalActionBody
        case .waitingForAnswer:
            questionActionBody
        case .completed:
            completionActionBody
        case .running:
            EmptyView()
        }
    }

    private var shouldShowEmbeddedDetailBody: Bool {
        if session.phase.requiresAttention {
            return true
        }
        if session.phase == .completed {
            return isActionable && completionHasExpandedBody
        }
        return session.phase == .running && runningDetailText != nil
    }

    private var completionHasExpandedBody: Bool {
        !completionMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || onReply != nil
    }

    @ViewBuilder
    private var embeddedDetailBody: some View {
        switch session.phase {
        case .waitingForApproval, .waitingForAnswer, .completed:
            actionableBody
        case .running:
            runningDetailBody
        }
    }

    private var runningDetailBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let runningDetailText {
                Text(runningDetailText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.045))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.white.opacity(0.06))
                    )
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Approval action area

    private var approvalActionBody: some View {
        let cleanPath = session.permissionRequest?.affectedPath.trimmedForNotificationCard
        let commandPreview = session.currentCommandPreviewText?.trimmedForNotificationCard
        let summaryText = session.permissionRequest?.summary.trimmedForNotificationCard
        let showPath: Bool = if let cleanPath, !cleanPath.isEmpty {
            cleanPath != commandPreview && cleanPath != summaryText
        } else {
            false
        }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IslandDesignPalette.Status.waitingForApproval)
                Text(lang.t("approval.toolPermissionRequested"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(V6Palette.paper.opacity(0.86))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(V6Palette.paper.opacity(0.45))
                        .padding(.top, 1)

                    Text(commandPreviewText)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(V6Palette.paper.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if showPath, let cleanPath {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 9.5))
                            .foregroundStyle(V6Palette.paper.opacity(0.3))
                        Text(cleanPath)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(V6Palette.paper.opacity(0.45))
                            .lineLimit(1)
                    }
                    .padding(.leading, 16)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.25))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            )

            HStack(spacing: 8) {
                Button(session.permissionRequest?.secondaryActionTitle ?? lang.t("approval.deny")) { onApprove?(.deny) }
                    .buttonStyle(IslandActionButtonStyle(kind: .secondary, expands: true))
                Button(session.permissionRequest?.primaryActionTitle ?? lang.t("approval.allowOnce")) { onApprove?(.allowOnce) }
                    .buttonStyle(IslandActionButtonStyle(kind: .primary, expands: true))
                if let toolName = session.permissionRequest?.toolName {
                    Button(lang.t("approval.alwaysAllow", toolName)) {
                        let rule = ClaudePermissionRuleValue(toolName: toolName)
                        let update = ClaudePermissionUpdate.addRules(
                            destination: .session,
                            rules: [rule],
                            behavior: .allow
                        )
                        onApprove?(.allowWithUpdates([update]))
                    }
                    .buttonStyle(IslandActionButtonStyle(kind: .warning, expands: true))
                }
            }
        }
    }

    // MARK: - Question action area

    private var questionActionBody: some View {
        StructuredQuestionPromptView(
            prompt: session.questionPrompt,
            lang: lang,
            onAnswer: { onAnswer?($0) }
        )
    }

    // MARK: - Completion action area

    private var completionActionBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !completionMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AutoHeightScrollView(maxHeight: 160) {
                    Markdown(completionMessageText)
                        .markdownTheme(MarkdownUI.Theme.completionCard)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
            } else {
                completionEmptyState
            }

            if onReply != nil {
                Rectangle()
                    .fill(.white.opacity(completionDividerOpacity))
                    .frame(height: 1)

                completionReplyInput
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(completionCardFillOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(completionCardStrokeOpacity))
        )
    }

    private var completionDoneOpacity: Double {
        presentation == .notification ? 0.82 : 0.96
    }

    private var completionDividerOpacity: Double {
        presentation == .notification ? 0.035 : 0.04
    }

    private var completionCardFillOpacity: Double {
        presentation == .notification ? 0.035 : 0.045
    }

    private var completionCardStrokeOpacity: Double {
        presentation == .notification ? 0.06 : 0.08
    }

    private var completionEmptyState: some View {
        HStack {
            Text(lang.t("completion.done"))
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(IslandDesignPalette.Status.completed.opacity(completionDoneOpacity))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var completionReplyInput: some View {
        HStack(spacing: 8) {
            ReplyTextField(
                placeholder: lang.t("completion.replyPlaceholder", session.completionReplyRecipientName),
                text: $replyText,
                onSubmit: { submitReply() }
            )
            .frame(height: 32)

            Button {
                submitReply()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(replyText.trimmingCharacters(in: .whitespaces).isEmpty
                        ? .white.opacity(0.2) : .white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func submitReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        replyText = ""
        onReply?(text)
    }

    // MARK: - Actionable helpers

    private var completionMessageText: String {
        if let text = session.completionAssistantMessageText?.trimmedForNotificationCard, !text.isEmpty {
            return text
        }
        let summary = session.summary.trimmedForNotificationCard
        return summary == SessionPhase.completed.displayName ? "" : summary
    }

    private var commandLabel: String {
        switch session.currentToolName {
        case "exec_command", "Bash": return "Bash"
        case "AskUserQuestion": return "Question"
        case "ExitPlanMode": return "Plan"
        case "apply_patch": return "Patch"
        case "write_stdin": return "Input"
        case let value?: return AgentSession.currentToolDisplayName(for: value)
        case nil: return "Command"
        }
    }

    private var commandPreviewText: String {
        let preview = session.currentCommandPreviewText?.trimmedForNotificationCard
        if let preview, !preview.isEmpty {
            return "$ \(preview)"
        }
        return session.permissionRequest?.summary.trimmedForNotificationCard ?? session.summary.trimmedForNotificationCard
    }

    private var runningDetailText: String? {
        if let preview = session.currentCommandPreviewText?.trimmedForNotificationCard,
           !preview.isEmpty {
            return "$ \(preview)"
        }

        if let activity = session.spotlightActivityLineText?.trimmedForNotificationCard,
           !activity.isEmpty {
            return activity
        }

        let summary = session.summary.trimmedForNotificationCard
        guard !summary.isEmpty else { return nil }
        
        let lowercaseSummary = summary.lowercased().replacingOccurrences(of: " ", with: "")
        let genericWords: Set<String> = ["running", "completed", "idle", "pending", "waitingforapproval", "waitingforanswer", "done"]
        if genericWords.contains(lowercaseSummary) {
            return nil
        }
        
        return summary
    }

    private func subagentElapsed(since start: Date, at now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(start))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let secs = seconds % 60
        return "\(minutes)m \(secs)s"
    }

    private func taskSummary(_ tasks: [ClaudeTaskInfo]) -> String {
        let done = tasks.filter { $0.status == .completed }.count
        let prog = tasks.filter { $0.status == .inProgress }.count
        let pend = tasks.filter { $0.status == .pending }.count
        return lang.t("tasks.summary", done, prog, pend)
    }

    @ViewBuilder
    private func taskStatusIcon(_ status: ClaudeTaskInfo.Status) -> some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark.square.fill")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.35))
        case .inProgress:
            Circle()
                .fill(IslandDesignPalette.Status.running)
                .frame(width: 6, height: 6)
        case .pending:
            Circle()
                .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                .frame(width: 6, height: 6)
        }
    }

    @ViewBuilder
    private func statusIndicator(for presence: IslandSessionPresence) -> some View {
        let tint = statusTint(for: presence)
        switch stateIndicator {
        case .animatedDot:
            TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { context in
                let pulse = presence == .running || isActionable
                    ? (sin(context.date.timeIntervalSinceReferenceDate * 2.0) + 1) / 2
                    : 0
                Circle()
                    .fill(tint)
                    .frame(width: 6.5, height: 6.5)
                    .opacity(presence == .inactive ? 0.46 : 0.6 + pulse * 0.4)
                    .shadow(color: tint.opacity(presence == .inactive ? 0 : 0.3), radius: 1)
            }
            .frame(width: 16, height: 24, alignment: .center)
        case .bar:
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(tint)
                .frame(width: 4, height: isActionable ? 34 : 28)
                .padding(.top, 2)
        case .glyph:
            Image(systemName: statusGlyphName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14, height: 20)
                .padding(.top, 1)
        case .tint:
            Circle()
                .fill(tint.opacity(presence == .inactive ? 0.54 : 0.92))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
        }
    }

    private func rowFillColor(for presence: IslandSessionPresence) -> Color {
        if presentation == .notification {
            return Color.clear
        }

        let base = isHighlighted ? Color.white.opacity(isActionable ? 0.06 : 0.04) : Color.clear
        guard stateIndicator == .tint else { return base }

        let tintOpacity: Double
        if isHighlighted {
            tintOpacity = isActionable ? 0.16 : 0.11
        } else {
            tintOpacity = presence == .inactive ? 0.035 : 0.075
        }
        return statusTint(for: presence).opacity(tintOpacity)
    }

    private var statusGlyphName: String {
        switch session.phase {
        case .waitingForApproval:
            "exclamationmark.triangle.fill"
        case .waitingForAnswer:
            "questionmark.circle.fill"
        case .running:
            "circle.dashed"
        case .completed:
            "checkmark.circle.fill"
        }
    }

    private var allowsRowHoverHighlight: Bool {
        presentation != .notification
    }

    /// Prompt line for manually expanded inactive rows (bypasses time-based filter).
    private var expandedPromptLineText: String? {
        guard detailOverride == true, let prompt = session.spotlightPromptText else { return nil }
        return "You: \(prompt)"
    }

    /// Activity line for manually expanded inactive rows (bypasses time-based filter).
    private var expandedActivityLineText: String? {
        guard detailOverride == true else { return nil }
        let trimmed = session.lastAssistantMessageText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let assistantMessage = trimmed, !assistantMessage.isEmpty {
            return assistantMessage
        }
        return session.jumpTarget != nil ? "Ready" : "Completed"
    }

    private func handlePrimaryTap() {
        guard isInteractive else { return }
        withAnimation(.easeOut(duration: 0.08)) {
            isPressed = true
        }
        // 增加 120ms 微小延迟，让用户能够肉眼感知到按压缩小的回弹动画，使交互更具物理质感与高级感
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            onJump()
            isPressed = false
        }
    }

    private func detailToggleButton(isOpen: Bool) -> some View {
        Button {
            guard isInteractive else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                detailOverride = !isOpen
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isOpen || isHighlighted ? .white.opacity(0.68) : .white.opacity(0.42))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(.white.opacity(detailToggleFillOpacity(isOpen: isOpen)))
                )
                .rotationEffect(.degrees(isOpen ? 180 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen ? "Collapse session detail" : "Expand session detail")
    }

    private func detailToggleFillOpacity(isOpen: Bool) -> Double {
        if isHighlighted {
            return isOpen ? 0.075 : 0.055
        }

        return isOpen ? 0.045 : 0.02
    }

    private func compactBadge(
        _ title: String,
        presence: IslandSessionPresence,
        icon: String? = nil
    ) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 7.5, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(badgeTextColor(for: presence))
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(Color(red: 0.14, green: 0.14, blue: 0.15), in: Capsule())
    }

    private func headlineColor(for presence: IslandSessionPresence) -> Color {
        presence == .inactive ? .white.opacity(0.78) : .white
    }

    private func badgeTextColor(for presence: IslandSessionPresence) -> Color {
        presence == .inactive ? .white.opacity(0.42) : .white.opacity(0.56)
    }

    private func statusTint(for presence: IslandSessionPresence) -> Color {
        IslandDesignPalette.Status.tint(for: session.phase, presence: presence)
    }

    private func activityColor(for presence: IslandSessionPresence) -> Color {
        switch session.spotlightActivityTone {
        case .attention:
            IslandDesignPalette.Status.tint(for: session.phase)
        case .live:
            statusTint(for: presence)
        case .idle:
            .white.opacity(0.46)
        case .ready:
            presence == .inactive ? .white.opacity(0.46) : statusTint(for: presence)
        }
    }
}

private struct StructuredQuestionPromptView: View {
    let prompt: QuestionPrompt?
    var lang: LanguageManager = .shared
    let onAnswer: (QuestionPromptResponse) -> Void

    @State private var selections: [String: Set<String>] = [:]
    @State private var freeformTexts: [String: String] = [:]
    @State private var typedReply: String = ""
    @State private var hoveredOptionKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsPromptTitle {
                Text(promptTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IslandDesignPalette.Status.waitingForAnswer)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if structuredQuestions.isEmpty {
                freeformAnswerBody
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(structuredQuestions, id: \.question) { question in
                        questionRow(question)
                    }
                }

                quickReplyField

                Button(submitButtonTitle) {
                    submitAnswer()
                }
                .buttonStyle(IslandActionButtonStyle(kind: canSubmit ? .primary : .secondary, expands: true))
                .disabled(!canSubmit)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.05))
        )
    }

    // MARK: - Per-question row

    /// Renders a single question with its header, text, and vertical option list.
    @ViewBuilder
    private func questionRow(_ question: QuestionPromptItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if structuredQuestions.count > 1 {
                Text(question.header)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Text(question.question)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                    optionRow(option, optionIndex: index, question: question)
                }
            }
        }
    }

    // MARK: - Option row (vertical, CLI-style)

    @ViewBuilder
    private func optionRow(
        _ option: QuestionOption,
        optionIndex: Int,
        question: QuestionPromptItem
    ) -> some View {
        let isSelected = selectedLabels(for: question).contains(option.label)
        let key = optionKey(for: question, option: option)
        let isHovered = hoveredOptionKey == key
        let showsFreeform = option.allowsFreeform && isSelected
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggle(option: option.label, for: question)
            } label: {
                HStack(spacing: 10) {
                    Text("\(optionIndex + 1)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isSelected ? .black.opacity(0.82) : V6Palette.paper.opacity(0.42))
                        .frame(width: 22, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? V6Palette.paper.opacity(0.88) : Color.white.opacity(0.045))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(.white.opacity(isSelected ? 0 : 0.08))
                        )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.label)
                            .font(.system(size: 12.2, weight: .medium))
                            .foregroundStyle(.white.opacity(isSelected ? 1 : 0.78))

                        if !option.description.isEmpty {
                            Text(option.description)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(isHovered || isSelected ? 0.48 : 0.38))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(IslandDesignPalette.Status.completed)
                    }
                }
                .contentShape(Rectangle())
                .padding(.vertical, 5)
                .padding(.horizontal, 11)
            }
            .buttonStyle(.plain)

            if showsFreeform {
                Divider()
                    .overlay(Color.white.opacity(0.08))
                freeformField(for: option, question: question)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(optionFillColor(isSelected: isSelected, isHovered: isHovered))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(optionStrokeColor(isSelected: isSelected, isHovered: isHovered))
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredOptionKey = hovering ? key : (hoveredOptionKey == key ? nil : hoveredOptionKey)
            }
        }
    }

    @ViewBuilder
    private func freeformField(for option: QuestionOption, question: QuestionPromptItem) -> some View {
        let key = freeformKey(for: question, option: option)
        ReplyTextField(
            placeholder: lang.t("question.otherPlaceholder"),
            text: Binding(
                get: { freeformTexts[key] ?? "" },
                set: { freeformTexts[key] = $0 }
            ),
            onSubmit: {
                if hasCompleteSelection {
                    onAnswer(QuestionPromptResponse(answers: answerMap))
                }
            }
        )
        .frame(height: 22)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
    }

    private var freeformAnswerBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            quickReplyField

            Button(lang.t("question.submit")) {
                submitAnswer()
            }
            .buttonStyle(IslandActionButtonStyle(kind: canSubmit ? .primary : .secondary, expands: true))
            .disabled(!canSubmit)
        }
    }

    @ViewBuilder
    private var quickReplyField: some View {
        if showsGlobalReplyField {
            HStack(spacing: 6) {
                ReplyTextField(
                    placeholder: lang.t("question.otherPlaceholder"),
                    text: $typedReply,
                    onSubmit: {
                        if canSubmit {
                            submitAnswer()
                        }
                    }
                )
                .frame(height: 30)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.055))
            )
        }
    }

    // MARK: - Helpers

    private var structuredQuestions: [QuestionPromptItem] {
        if let questions = prompt?.questions, !questions.isEmpty {
            return questions
        }

        guard let prompt, !prompt.options.isEmpty else {
            return []
        }

        return [
            QuestionPromptItem(
                question: prompt.title,
                header: lang.t("question.answerNeeded"),
                options: prompt.options.map { QuestionOption(label: $0) }
            ),
        ]
    }

    private var promptTitle: String {
        prompt?.title.trimmedForNotificationCard ?? lang.t("question.answerNeeded")
    }

    private var showsPromptTitle: Bool {
        guard !promptTitle.isEmpty else {
            return false
        }

        guard structuredQuestions.count == 1,
              let questionTitle = structuredQuestions.first?.question.trimmedForNotificationCard else {
            return true
        }

        return questionTitle.caseInsensitiveCompare(promptTitle) != .orderedSame
    }

    private var answerMap: [String: String] {
        Dictionary(uniqueKeysWithValues: structuredQuestions.compactMap { question in
            let values = resolvedAnswers(for: question)
            guard !values.isEmpty else {
                return nil
            }
            return (question.question, values.joined(separator: ", "))
        })
    }

    private var trimmedReply: String {
        typedReply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsGlobalReplyField: Bool {
        structuredQuestions.isEmpty || !structuredQuestions.contains { question in
            question.options.contains { $0.allowsFreeform }
        }
    }

    private var primarySelectedAnswer: String? {
        guard structuredQuestions.count == 1,
              let question = structuredQuestions.first else {
            return nil
        }

        let values = resolvedAnswers(for: question)
        guard !values.isEmpty else {
            return nil
        }

        return values.joined(separator: ", ")
    }

    private var canSubmit: Bool {
        !trimmedReply.isEmpty || (!structuredQuestions.isEmpty && hasCompleteSelection)
    }

    private var submitButtonTitle: String {
        if !trimmedReply.isEmpty {
            return lang.t("question.sendReply")
        }

        if let primarySelectedAnswer, !primarySelectedAnswer.isEmpty {
            return lang.t("question.sendAnswer")
        }

        return lang.t("question.submit")
    }

    private func submitAnswer() {
        if !trimmedReply.isEmpty {
            onAnswer(QuestionPromptResponse(answer: trimmedReply))
            return
        }

        onAnswer(
            QuestionPromptResponse(
                rawAnswer: primarySelectedAnswer,
                answers: answerMap
            )
        )
    }

    private var hasCompleteSelection: Bool {
        structuredQuestions.allSatisfy { question in
            let selected = selectedLabels(for: question)
            guard !selected.isEmpty else {
                return false
            }
            // When a freeform option is selected, require non-empty text.
            for option in question.options where option.allowsFreeform && selected.contains(option.label) {
                if trimmedFreeform(for: question, option: option).isEmpty {
                    return false
                }
            }
            return true
        }
    }

    private func selectedLabels(for question: QuestionPromptItem) -> Set<String> {
        selections[question.question] ?? []
    }

    private func resolvedAnswers(for question: QuestionPromptItem) -> [String] {
        let selected = selectedLabels(for: question)
        guard !selected.isEmpty else { return [] }

        let optionOrder = question.options
        var answers: [String] = []
        for option in optionOrder where selected.contains(option.label) {
            if option.allowsFreeform {
                let text = trimmedFreeform(for: question, option: option)
                answers.append(text.isEmpty ? option.label : text)
            } else {
                answers.append(option.label)
            }
        }
        return answers
    }

    private func freeformKey(for question: QuestionPromptItem, option: QuestionOption) -> String {
        "\(question.question)|\(option.label)"
    }

    private func optionKey(for question: QuestionPromptItem, option: QuestionOption) -> String {
        "\(question.question)|\(option.label)"
    }

    private func optionFillColor(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return V6Palette.paper.opacity(0.10)
        }
        if isHovered {
            return Color.white.opacity(0.065)
        }
        return Color.white.opacity(0.028)
    }

    private func optionStrokeColor(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return V6Palette.paper.opacity(0.36)
        }
        if isHovered {
            return .white.opacity(0.13)
        }
        return .white.opacity(0.045)
    }

    private func trimmedFreeform(for question: QuestionPromptItem, option: QuestionOption) -> String {
        (freeformTexts[freeformKey(for: question, option: option)] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func toggle(option: String, for question: QuestionPromptItem) {
        var selected = selections[question.question] ?? []

        if question.multiSelect {
            if selected.contains(option) {
                selected.remove(option)
            } else {
                selected.insert(option)
            }
        } else {
            if selected.contains(option) {
                selected.removeAll()
            } else {
                selected = [option]
            }
        }

        typedReply = ""
        selections[question.question] = selected
    }
}

// MARK: - Reply TextField (NSTextField wrapper for IME-safe Enter handling)

/// NSTextField wrapper that fires `onSubmit` only when the IME composition
/// is finished — pressing Enter during Chinese/Japanese IME composition
/// confirms the candidate instead of submitting.
private struct ReplyTextField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.35),
                .font: NSFont.systemFont(ofSize: 13),
            ]
        )
        field.delegate = context.coordinator
        field.cell?.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Let AppKit handle Enter during IME composition (e.g. confirming
                // a Chinese/Japanese candidate). Only submit when no marked text.
                guard !textView.hasMarkedText() else { return false }
                onSubmit()
                return true
            }
            return false
        }
    }
}

extension String {
    var trimmedForNotificationCard: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Compact button style

private struct IslandCompactButtonStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint == .secondary ? .white.opacity(0.7) : tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                (tint == .secondary ? Color.white.opacity(0.08) : tint.opacity(0.15)),
                in: Capsule()
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct IslandActionButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case warning
    }

    let kind: Kind
    var expands = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.8, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .lineLimit(1)
            .frame(maxWidth: expands ? .infinity : nil)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(backgroundColor(configuration.isPressed), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
    }

    private var foregroundColor: Color {
        guard isEnabled else {
            return V6Palette.paper.opacity(0.42)
        }

        switch kind {
        case .primary:
            return .black.opacity(0.88)
        case .warning:
            return .white
        case .secondary:
            return V6Palette.paper.opacity(0.78)
        }
    }

    private var strokeColor: Color {
        guard isEnabled else {
            return .white.opacity(0.07)
        }

        switch kind {
        case .primary:
            return V6Palette.paper.opacity(0.86)
        case .warning:
            return Color(red: 0.85, green: 0.55, blue: 0.15).opacity(0.42)
        case .secondary:
            return .white.opacity(0.07)
        }
    }

    private func backgroundColor(_ isPressed: Bool) -> Color {
        guard isEnabled else {
            return Color.white.opacity(0.055)
        }

        let pressedFactor: Double = isPressed ? 0.78 : 1
        switch kind {
        case .primary:
            return V6Palette.paper.opacity(pressedFactor)
        case .warning:
            return Color(red: 0.85, green: 0.55, blue: 0.15).opacity(pressedFactor)
        case .secondary:
            return Color.white.opacity(isPressed ? 0.11 : 0.065)
        }
    }
}

// MARK: - Menu bar content (unchanged)

// MARK: - MarkdownUI Theme

extension MarkdownUI.Theme {
    @MainActor static let completionCard = Theme()
        .text {
            ForegroundColor(.white.opacity(0.88))
            FontSize(13.5)
            FontWeight(.medium)
        }
        .link {
            ForegroundColor(.blue)
        }
        .strong {
            FontWeight(.bold)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(12.5)
            ForegroundColor(.white.opacity(0.88))
            BackgroundColor(.white.opacity(0.08))
        }
        .codeBlock { configuration in
            configuration.label
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(12.5)
                    ForegroundColor(.white.opacity(0.88))
                }
                .padding(10)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(16)
                    FontWeight(.bold)
                    ForegroundColor(.white.opacity(0.88))
                }
                .markdownMargin(top: 8, bottom: 4)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(15)
                    FontWeight(.bold)
                    ForegroundColor(.white.opacity(0.88))
                }
                .markdownMargin(top: 8, bottom: 4)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(14)
                    FontWeight(.semibold)
                    ForegroundColor(.white.opacity(0.88))
                }
                .markdownMargin(top: 6, bottom: 2)
        }
        .blockquote { configuration in
            configuration.label
                .markdownTextStyle {
                    ForegroundColor(.white.opacity(0.6))
                    FontSize(13.5)
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 3)
                }
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 2, bottom: 2)
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(.allBorders, color: .white.opacity(0.15), strokeStyle: .init(lineWidth: 1)))
                .markdownTableBackgroundStyle(
                    .alternatingRows(Color.white.opacity(0.04), Color.white.opacity(0.08))
                )
                .markdownMargin(top: 4, bottom: 8)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .relativeLineSpacing(.em(0.25))
        }
}

private struct DismissButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(isHovered ? 0.8 : 0.4))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
