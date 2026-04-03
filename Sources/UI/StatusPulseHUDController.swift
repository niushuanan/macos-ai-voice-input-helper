import AppKit
import SwiftUI

enum HUDPresentationStyle: Equatable {
    case listening
    case processing(title: String)
    case completion
    case feedback
    case cancelled
    case error
}

struct HUDVisibilityPlan: Equatable {
    let keepVisible: Bool
    let hideDelay: TimeInterval
    let fadeDuration: TimeInterval

    static let keepVisible = HUDVisibilityPlan(
        keepVisible: true,
        hideDelay: 0,
        fadeDuration: 0
    )
}

struct HUDProgressFrame: Equatable {
    let style: HUDPresentationStyle
    let progress: Double
    let visibility: HUDVisibilityPlan
}

struct HUDProgressStateMachine {
    private(set) var previousPhase: SessionPhase = .idle
    private(set) var progress: Double = 0
    private(set) var cap: Double = 0
    private(set) var targetProgress: Double = 0

    mutating func transition(
        to phase: SessionPhase,
        progressHint rawProgressHint: Double,
        message _: String
    ) -> HUDProgressFrame {
        let cameFromBusy = previousPhase.isHUDBusyPhase

        let frame: HUDProgressFrame
        switch phase {
        case .listening:
            progress = 0
            cap = 0
            targetProgress = 0
            frame = HUDProgressFrame(
                style: .listening,
                progress: progress,
                visibility: .keepVisible
            )

        case .transcribing, .rewriting, .inserting:
            let plan = busyPlan(for: phase)
            let resolvedHint = min(
                plan.ceiling,
                rawProgressHint > 0 ? rawProgressHint : plan.fallbackHint
            )
            let resolvedTarget = min(plan.ceiling, resolvedHint + 0.08)
            progress = max(progress, resolvedHint)
            cap = plan.ceiling
            targetProgress = max(progress, resolvedTarget)
            frame = HUDProgressFrame(
                style: .processing(title: plan.title),
                progress: progress,
                visibility: .keepVisible
            )

        case .idle:
            if cameFromBusy {
                progress = 1
                cap = 1
                targetProgress = 1
                frame = HUDProgressFrame(
                    style: .completion,
                    progress: progress,
                    visibility: HUDVisibilityPlan(
                        keepVisible: false,
                        hideDelay: 0.26,
                        fadeDuration: 0.12
                    )
                )
            } else {
                progress = 0
                cap = 0
                targetProgress = 0
                frame = HUDProgressFrame(
                    style: .feedback,
                    progress: progress,
                    visibility: HUDVisibilityPlan(
                        keepVisible: false,
                        hideDelay: 0.44,
                        fadeDuration: 0.12
                    )
                )
            }

        case .cancelled:
            progress = 0
            cap = 0
            targetProgress = 0
            frame = HUDProgressFrame(
                style: .cancelled,
                progress: progress,
                visibility: HUDVisibilityPlan(
                    keepVisible: false,
                    hideDelay: 0.46,
                    fadeDuration: 0.12
                )
            )

        case .error:
            progress = 0
            cap = 0
            targetProgress = 0
            frame = HUDProgressFrame(
                style: .error,
                progress: progress,
                visibility: HUDVisibilityPlan(
                    keepVisible: false,
                    hideDelay: 0.90,
                    fadeDuration: 0.12
                )
            )
        }

        previousPhase = phase
        return frame
    }

    mutating func tick() -> Double {
        let fastTarget = min(targetProgress, cap)
        if fastTarget > progress {
            let delta = max(0.004, (fastTarget - progress) * 0.22)
            progress = min(fastTarget, progress + delta)
            return progress
        }

        guard cap > progress else {
            return progress
        }

        let delta = max(0.0012, (cap - progress) * 0.035)
        progress = min(cap, progress + delta)
        return progress
    }

    private func busyPlan(for phase: SessionPhase) -> (title: String, fallbackHint: Double, ceiling: Double) {
        switch phase {
        case .transcribing:
            return ("转写中", SessionHUDProgressHint.transcribing, 0.42)
        case .rewriting:
            return ("魔术先生执行", SessionHUDProgressHint.textTransform, 0.84)
        case .inserting:
            return ("写入中", SessionHUDProgressHint.inserting, 0.97)
        case .idle, .listening, .cancelled, .error:
            return ("处理中", SessionHUDProgressHint.transcribing, 0.42)
        }
    }
}

enum StatusPulseHUDTitleResolver {
    static func listeningTitle(for lane: InputLane) -> String {
        switch lane {
        case .directDictation:
            return "语音输入"
        case .selectionRewrite:
            return "魔术先生 · 聆听中"
        case .brainstormDiscussion:
            return "一口气全念对"
        }
    }

    static func processingTitle(
        phase: SessionPhase,
        lane: InputLane,
        message: String,
        defaultTitle: String
    ) -> String {
        guard lane == .selectionRewrite else {
            return defaultTitle
        }

        switch phase {
        case .transcribing:
            return "思考中"
        case .rewriting:
            return magicianRewritingTitle(from: message, fallback: defaultTitle)
        case .inserting:
            return "写入中"
        case .idle, .listening, .cancelled, .error:
            return defaultTitle
        }
    }

    private static func magicianRewritingTitle(from message: String, fallback: String) -> String {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicit = extractMagicianActionTitle(from: normalized) {
            return explicit
        }

        let fallbackTitle = fallback == "魔术先生执行" ? "执行中" : fallback
        return fallbackTitle
    }

    private static func extractMagicianActionTitle(from message: String) -> String? {
        let prefixes = ["魔术先生执行中：", "魔术先生文字处理中："]
        guard let prefix = prefixes.first(where: { message.hasPrefix($0) }) else {
            return nil
        }

        var title = message.dropFirst(prefix.count)
        if let punctuationIndex = title.firstIndex(where: { "。.!！？".contains($0) }) {
            title = title[..<punctuationIndex]
        }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

enum StatusPulseHUDMessageResolver {
    static func completionTitle(for message: String) -> String {
        let normalized = normalizedMessage(message)
        guard !normalized.isEmpty else {
            return "已完成"
        }

        if normalized.contains("复制到剪贴板") {
            return "已复制到剪贴板"
        }
        if normalized.contains("本地 md 文档已创建") || normalized.contains("已写入本地 md") {
            return "已保存本地文档"
        }
        if isCreateNoteSuccess(normalized) {
            return "已写入备忘录"
        }
        if normalized.contains("邮件已发出") || normalized.contains("邮件已发送") {
            return "邮件已发出"
        }
        if normalized.contains("邮件窗口已打开") || normalized.contains("mailto") {
            return "邮件窗口已打开，请你确认"
        }
        if normalized.contains("邮件已填入") {
            return "邮件已填入，待你确认"
        }
        if isComposeEmailSuccess(normalized) {
            return "邮件已填入，待你确认"
        }
        if isCreateEventSuccess(normalized) {
            return "已创建日程"
        }
        if normalized.contains("文本已写入") {
            return "已写入"
        }
        if normalized.contains("已完成") || normalized.contains("下一次语音会话") {
            return "已完成"
        }

        return "已完成"
    }

    static func feedbackMessage(for message: String) -> String {
        let normalized = normalizedMessage(message)
        guard !normalized.isEmpty else {
            return "已准备"
        }

        if normalized.contains("已准备") {
            return "已准备"
        }

        return completionTitle(for: normalized)
    }

    static func cancelledTitle(for message: String) -> String {
        let normalized = normalizedMessage(message)
        if normalized.contains("已取消") {
            return "已取消"
        }
        return "已取消"
    }

    static func errorTitle(for message: String) -> String {
        let normalized = normalizedMessage(message)
        guard !normalized.isEmpty else {
            return "未完成"
        }

        if normalized.contains("辅助功能权限") {
            return "需要辅助功能权限"
        }
        if normalized.contains("日历权限") {
            return "需要日历权限"
        }
        if normalized.contains("未识别到明确时间") {
            return "未识别到明确时间"
        }
        if containsAny(normalized, tokens: ["可写入输入框", "可写入焦点", "焦点不可编辑", "输入区域"]) {
            return "未检测到输入区域"
        }
        if containsAny(normalized, tokens: ["写回失败", "写入失败", "AX 直写失败"]) {
            return "写入失败"
        }
        if normalized.contains("改写失败") {
            return "文字处理失败"
        }
        if normalized.contains("失败") {
            return "执行失败"
        }
        if normalized.contains("执行失败") {
            return "执行失败"
        }
        if normalized.contains("没听清") {
            return "没听清指令"
        }
        if normalized.contains("缺少") && normalized.contains("API") && normalized.contains("密钥") {
            return "缺少 API 密钥"
        }
        if containsAny(normalized, tokens: ["文本模型配置无效", "文本模型没能稳定解析", "文本模型", "文本处理模型"]) {
            return "文本模型不可用"
        }

        return "未完成"
    }

    private static func normalizedMessage(_ message: String) -> String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsAny(_ message: String, tokens: [String]) -> Bool {
        tokens.contains { message.contains($0) }
    }

    private static func isCreateNoteSuccess(_ message: String) -> Bool {
        containsAny(
            message,
            tokens: ["备忘录", "Notes", "快捷指令", "Shortcuts URL 触发写入", "本地 md 文档", "local.md.create"]
        )
    }

    private static func isComposeEmailSuccess(_ message: String) -> Bool {
        containsAny(
            message,
            tokens: ["邮件草稿", "邮件已发送", "邮件已发出", "邮件已填入", "邮件窗口已打开", "Mail", "mailto"]
        )
    }

    private static func isCreateEventSuccess(_ message: String) -> Bool {
        containsAny(
            message,
            tokens: ["已建日程", "已创建日程", "日程："]
        )
    }
}

extension SessionPhase {
    var isHUDBusyPhase: Bool {
        switch self {
        case .transcribing, .rewriting, .inserting:
            return true
        case .idle, .listening, .cancelled, .error:
            return false
        }
    }
}

@MainActor
final class StatusPulseHUDController {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var progressTimer: DispatchSourceTimer?
    private var progressStateMachine = HUDProgressStateMachine()
    private var visibilityGeneration: UInt64 = 0
    private let hudScale: CGFloat = 1.3
    private let baseHUDSize = NSSize(width: 184, height: 34)

    private var currentPhase: SessionPhase = .idle
    private var currentLane: InputLane = .directDictation
    private var currentMessage: String = ""
    private var currentProgress: Double = 0
    private var currentListeningLevel: Double = 0
    private var currentStyle: HUDPresentationStyle = .feedback

    private var hudSize: NSSize {
        scaled(baseHUDSize)
    }

    func show(
        phase: SessionPhase,
        lane: InputLane,
        message: String,
        progressHint: Double,
        listeningLevel: Double
    ) {
        visibilityGeneration &+= 1
        hideWorkItem?.cancel()

        let frame = progressStateMachine.transition(
            to: phase,
            progressHint: progressHint,
            message: message
        )

        currentPhase = phase
        currentLane = lane
        currentMessage = message
        currentListeningLevel = max(0, min(1, listeningLevel))
        currentStyle = resolvedPresentationStyle(
            from: frame.style,
            phase: phase,
            lane: lane,
            message: message
        )
        currentProgress = max(0, min(1, frame.progress))

        if case .processing = frame.style {
            startProgressTickerIfNeeded()
        } else {
            stopProgressTicker()
        }

        let panel = ensurePanel(size: hudSize)
        render(panel: panel)

        panel.orderFrontRegardless()
        panel.alphaValue = 1

        scheduleHide(using: frame.visibility)
    }

    private func ensurePanel(size: NSSize) -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.panel = panel
        return panel
    }

    private func render(panel: NSPanel) {
        panel.contentView = NSHostingView(
            rootView: StatusPulseHUDView(
                phase: currentPhase,
                lane: currentLane,
                message: currentMessage,
                progress: currentProgress,
                listeningLevel: currentListeningLevel,
                presentationStyle: currentStyle,
                scale: hudScale
            )
        )
        position(panel: panel, size: hudSize)
    }

    private func position(panel: NSPanel, size: NSSize) {
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = targetScreen?.visibleFrame else {
            return
        }

        let origin = NSPoint(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.minY + scaled(22)
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        value * hudScale
    }

    private func scaled(_ size: NSSize) -> NSSize {
        NSSize(width: scaled(size.width), height: scaled(size.height))
    }

    private func scheduleHide(using visibility: HUDVisibilityPlan) {
        hideWorkItem?.cancel()

        guard !visibility.keepVisible else {
            return
        }

        let generation = visibilityGeneration
        let work = DispatchWorkItem { [weak self] in
            guard
                let self,
                generation == self.visibilityGeneration,
                let panel = self.panel
            else {
                return
            }

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = visibility.fadeDuration
                panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor [weak self] in
                    guard
                        let self,
                        generation == self.visibilityGeneration
                    else {
                        return
                    }
                    panel.orderOut(nil)
                }
            })
        }

        hideWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + visibility.hideDelay,
            execute: work
        )
    }

    private func startProgressTickerIfNeeded() {
        guard progressTimer == nil else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.04, repeating: 0.04)
        timer.setEventHandler { [weak self] in
            self?.handleProgressTick()
        }
        progressTimer = timer
        timer.resume()
    }

    private func stopProgressTicker() {
        progressTimer?.setEventHandler {}
        progressTimer?.cancel()
        progressTimer = nil
    }

    private func handleProgressTick() {
        guard case .processing = currentStyle else {
            return
        }

        let nextProgress = max(0, min(1, progressStateMachine.tick()))
        guard abs(nextProgress - currentProgress) > 0.0008 else {
            return
        }

        currentProgress = nextProgress
        if let panel {
            render(panel: panel)
        }
    }

    private func resolvedPresentationStyle(
        from style: HUDPresentationStyle,
        phase: SessionPhase,
        lane: InputLane,
        message: String
    ) -> HUDPresentationStyle {
        guard case let .processing(defaultTitle) = style else {
            return style
        }
        return .processing(
            title: StatusPulseHUDTitleResolver.processingTitle(
                phase: phase,
                lane: lane,
                message: message,
                defaultTitle: defaultTitle
            )
        )
    }
}

private struct StatusPulseHUDView: View {
    let phase: SessionPhase
    let lane: InputLane
    let message: String
    let progress: Double
    let listeningLevel: Double
    let presentationStyle: HUDPresentationStyle
    let scale: CGFloat

    private func s(_ value: CGFloat) -> CGFloat {
        value * scale
    }

    var body: some View {
        Group {
            switch presentationStyle {
            case .listening:
                listeningCapsule
            case let .processing(title):
                processingCapsule(title: title, completion: false)
            case .completion:
                processingCapsule(title: completionTitle, completion: true)
            case .cancelled:
                cancelledCapsule
            case .error:
                errorCapsule
            case .feedback:
                feedbackCapsule
            }
        }
        .padding(.horizontal, s(3))
        .padding(.vertical, s(3))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var normalizedListeningLevel: Double {
        max(0, min(1, listeningLevel))
    }

    private var normalizedProgress: Double {
        max(0, min(1, progress))
    }

    private var phaseAccentColor: Color {
        switch phase {
        case .idle:
            return Color.primary.opacity(0.56)
        case .listening:
            return Color.primary.opacity(0.62)
        case .transcribing, .rewriting:
            return Color.primary.opacity(0.58)
        case .inserting:
            return Color.primary.opacity(0.60)
        case .cancelled:
            return Color.primary.opacity(0.60)
        case .error:
            return Color(red: 0.56, green: 0.26, blue: 0.26)
        }
    }

    private var listeningCapsule: some View {
        statusSplitCapsule(title: listeningTitle) {
            ListeningBars(level: normalizedListeningLevel, scale: scale)
        }
    }

    private var listeningTitle: String {
        StatusPulseHUDTitleResolver.listeningTitle(for: lane)
    }

    private var completionTitle: String {
        StatusPulseHUDMessageResolver.completionTitle(for: message)
    }

    private var cancelledTitle: String {
        StatusPulseHUDMessageResolver.cancelledTitle(for: message)
    }

    private var errorTitle: String {
        StatusPulseHUDMessageResolver.errorTitle(for: message)
    }

    private var feedbackText: String {
        StatusPulseHUDMessageResolver.feedbackMessage(for: message)
    }

    private var cancelledCapsule: some View {
        statusSplitCapsule(title: cancelledTitle) {
            Circle()
                .stroke(Color.primary.opacity(0.42), lineWidth: s(0.8))
                .frame(width: s(11), height: s(11))
                .overlay(
                    Image(systemName: "xmark")
                        .font(.system(size: s(6.5), weight: .bold))
                        .foregroundStyle(Color.primary.opacity(0.66))
                )
        }
    }

    private var errorCapsule: some View {
        statusSplitCapsule(title: errorTitle) {
            Circle()
                .stroke(Color(red: 0.56, green: 0.26, blue: 0.26).opacity(0.66), lineWidth: s(0.9))
                .frame(width: s(11), height: s(11))
                .overlay(
                    Image(systemName: "exclamationmark")
                        .font(.system(size: s(7), weight: .bold))
                        .foregroundStyle(Color(red: 0.56, green: 0.26, blue: 0.26).opacity(0.76))
                )
        }
    }

    @ViewBuilder
    private func processingCapsule(title: String, completion: Bool) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fillWidth = max(s(20), width * normalizedProgress)

            ZStack(alignment: .leading) {
                HUDNativeMaterialCapsule(scale: scale)

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.56),
                                Color.white.opacity(0.30),
                                Color.accentColor.opacity(0.10)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth)
                    .animation(.easeOut(duration: completion ? 0.14 : 0.18), value: normalizedProgress)

                HStack(spacing: s(7)) {
                    Spacer(minLength: 0)
                    Text(title)
                        .font(.system(size: s(11.5), weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.86))
                        .lineLimit(1)

                    if completion {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: s(10), weight: .semibold))
                            .foregroundStyle(Color.accentColor.opacity(0.68))
                            .frame(width: s(22), height: s(10), alignment: .center)
                    } else {
                        ThinkingDots(progress: normalizedProgress, scale: scale)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, s(10))
            }
        }
        .frame(height: s(22))
    }

    private var feedbackCapsule: some View {
        HStack(spacing: s(6)) {
            Image(systemName: phase.menuBarSymbol)
                .font(.system(size: s(9.5), weight: .semibold))
                .foregroundStyle(phaseAccentColor)
            Text(feedbackText)
                .font(.system(size: s(10.2), weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.80))
                .lineLimit(1)
        }
        .padding(.horizontal, s(9))
        .padding(.vertical, s(4.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HUDNativeMaterialCapsule(scale: scale))
    }

    @ViewBuilder
    private func statusSplitCapsule<Indicator: View>(
        title: String,
        @ViewBuilder indicator: () -> Indicator
    ) -> some View {
        HStack(spacing: s(7)) {
            Text(title)
                .font(.system(size: s(11.5), weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.84))
                .lineLimit(1)

            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.16))
                .frame(width: s(0.7), height: s(9))

            indicator()
                .frame(width: s(20), height: s(10), alignment: .center)
        }
        .padding(.horizontal, s(11))
        .padding(.vertical, s(4.5))
        .frame(maxWidth: .infinity, alignment: .center)
        .background(HUDNativeMaterialCapsule(scale: scale))
    }
}

private struct ListeningBars: View {
    let level: Double
    let scale: CGFloat

    private func s(_ value: CGFloat) -> CGFloat {
        value * scale
    }

    private var isActive: Bool {
        level > 0.035
    }

    var body: some View {
        HStack(alignment: .center, spacing: s(3)) {
            ForEach(0..<4, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isActive ? 0.78 : 0.28))
                    .frame(width: s(1.6), height: barHeight(for: index))
                    .animation(.easeOut(duration: 0.10), value: level)
            }
        }
        .frame(width: s(19), height: s(10), alignment: .center)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base: [CGFloat] = [1.7, 2.7, 2.3, 3.2]
        let gain: [CGFloat] = [2.4, 3.3, 2.8, 3.7]
        let normalized = CGFloat(max(0, min(1, level)))
        let eased = sqrt(normalized)
        return s(base[index] + (gain[index] * eased))
    }
}

private struct ThinkingDots: View {
    let progress: Double
    let scale: CGFloat

    private func s(_ value: CGFloat) -> CGFloat {
        value * scale
    }

    var body: some View {
        HStack(spacing: s(3)) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(Color.primary.opacity(dotOpacity(for: index)))
                    .frame(width: s(3.8), height: s(3.8))
            }
        }
        .frame(width: s(22), height: s(10), alignment: .center)
        .animation(.easeOut(duration: 0.16), value: progress)
    }

    private func dotOpacity(for index: Int) -> Double {
        let shifted = (progress * 5.8) + (Double(index) * 0.22)
        let wave = (sin(shifted * .pi) + 1) / 2
        return 0.25 + (wave * 0.60)
    }
}

private struct HUDNativeMaterialCapsule: View {
    let scale: CGFloat

    private func s(_ value: CGFloat) -> CGFloat {
        value * scale
    }

    var body: some View {
        ZStack {
            MacVisualEffectMaterialView(
                material: .popover,
                blendingMode: .withinWindow,
                state: .active
            )
            .clipShape(Capsule(style: .continuous))

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.74),
                            Color.white.opacity(0.48),
                            Color(nsColor: .windowBackgroundColor).opacity(0.30)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.52),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blendMode(.screen)

            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.88), lineWidth: s(0.58))
        }
    }
}

private struct MacVisualEffectMaterialView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context _: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}
