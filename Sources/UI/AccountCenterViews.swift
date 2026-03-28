import AppKit
import SwiftUI

struct AccountStatusCapsuleButton: View {
    @ObservedObject var accountStore: AccountStore
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let avatarImage {
                    Image(nsImage: avatarImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: iconName)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.accentColor)
                        .padding(1)
                }
            }
            .frame(width: 29, height: 29)
            .clipShape(Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(accessibilityTitle)
    }

    private var iconName: String {
        "person.crop.circle.fill"
    }

    private var avatarImage: NSImage? {
        Self.cachedAvatarImage
    }

    private static let cachedAvatarImage: NSImage? = {
        let candidates: [(name: String, ext: String?, subdirectory: String?)] = [
            ("apple-account-avatar", "jpg", "Resources/Images"),
            ("apple-account-avatar", "jpg", nil)
        ]
        for candidate in candidates {
            guard
                let url = Bundle.main.url(
                    forResource: candidate.name,
                    withExtension: candidate.ext,
                    subdirectory: candidate.subdirectory
                ),
                let sourceImage = NSImage(contentsOf: url)
            else {
                continue
            }
            return sourceImage
        }
        return nil
    }()

    private var accessibilityTitle: String {
        accountStore.isAuthenticated
            ? "账号与版本，\(accountStore.statusCapsuleTitle)"
            : "登录"
    }

    private var helpText: String {
        if accountStore.isAuthenticated {
            return accountStore.currentEmail
        }
        if case .codeSent = accountStore.authState {
            return "验证码已发送"
        }
        return "登录"
    }
}

struct AccountCenterSheetView: View {
    @ObservedObject var accountStore: AccountStore
    let onUnavailableFeature: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                AccountCenterHeaderSection(
                    subtitle: headerSubtitle,
                    onClose: { accountStore.dismissSheet() }
                )

                if let summary = accountStore.summary {
                    AccountSummarySection(summary: summary)
                    AccountQuotaSection(metrics: summary.quotaSummary.metrics)
                    AccountActionsSection(onUnavailableFeature: onUnavailableFeature)
                    AccountFooterSection {
                        Task {
                            await accountStore.signOut()
                        }
                    }
                } else {
                    signedOutSection
                }

                feedbackSection
            }
            .padding(20)
        }
        .frame(width: 460, height: 560)
    }

    private var signedOutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("用邮箱验证码登录后，你可以管理版本、设备和后续会员能力。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("邮箱")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("name@example.com", text: $accountStore.emailDraft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .disabled(emailFieldLocked)
            }

            if shouldShowVerificationFields {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("验证码")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("换个邮箱") {
                            accountStore.resetPendingCodeFlow()
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                    }

                    TextField("6 位验证码", text: verificationCodeBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    resendLine
                }
            }

            HStack(spacing: 10) {
                Button(primaryButtonTitle) {
                    Task {
                        if shouldShowVerificationFields {
                            await accountStore.verifyEmailOTP()
                        } else {
                            await accountStore.startEmailOTP()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(primaryButtonDisabled)

                if shouldShowVerificationFields {
                    Button("重新发送") {
                        Task {
                            await accountStore.startEmailOTP()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canResendCode)
                }
            }

            if shouldShowDevelopmentQuickLoginAction {
                VStack(alignment: .leading, spacing: 8) {
                    Button("开发环境一键登录") {
                        accountStore.enterDevelopmentLogin()
                    }
                    .buttonStyle(.bordered)

                    Text("仅本机开发可用，线上不会出现。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("当前属于开发阶段，会员、设备与手机号能力会逐步完善。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .pulseCard(cornerRadius: 16)
    }

    @ViewBuilder
    private var feedbackSection: some View {
        if let errorMessage = accountStore.errorMessage, !errorMessage.isEmpty {
            AccountFeedbackBanner(
                message: errorMessage,
                color: .red,
                icon: "exclamationmark.triangle.fill"
            )
        } else if !accountStore.isConfigured {
            AccountFeedbackBanner(
                message: accountStore.unavailableMessage,
                color: .orange,
                icon: "wrench.and.screwdriver.fill"
            )
        }
    }

    @ViewBuilder
    private var resendLine: some View {
        if let resendAvailableAt = currentResendAvailableAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(
                    0,
                    Int(resendAvailableAt.timeIntervalSince(context.date).rounded(.up))
                )

                if seconds > 0 {
                    Label("\(seconds) 秒后可重发", systemImage: "timer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("现在可以重新发送验证码", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var currentResendAvailableAt: Date? {
        if case let .codeSent(_, resendAvailableAt) = accountStore.authState {
            return resendAvailableAt
        }
        return nil
    }

    private var canResendCode: Bool {
        guard let resendAvailableAt = currentResendAvailableAt else {
            return false
        }
        return Date() >= resendAvailableAt
    }

    private var shouldShowVerificationFields: Bool {
        switch accountStore.authState {
        case .codeSent, .verifying:
            return true
        case .unavailable, .signedOut, .sendingCode, .signedIn:
            return false
        }
    }

    private var emailFieldLocked: Bool {
        switch accountStore.authState {
        case .sendingCode, .codeSent, .verifying:
            return true
        case .unavailable, .signedOut, .signedIn:
            return false
        }
    }

    private var primaryButtonTitle: String {
        switch accountStore.authState {
        case .sendingCode:
            return "发送中..."
        case .verifying:
            return "验证中..."
        case .codeSent:
            return "验证并登录"
        case .unavailable, .signedOut, .signedIn:
            return "发送验证码"
        }
    }

    private var primaryButtonDisabled: Bool {
        if !accountStore.isConfigured {
            return true
        }

        switch accountStore.authState {
        case .sendingCode, .verifying:
            return true
        case .codeSent:
            return verificationCodeBinding.wrappedValue.count != 6
        case .unavailable, .signedOut, .signedIn:
            return accountStore.emailDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var verificationCodeBinding: Binding<String> {
        Binding(
            get: { accountStore.verificationCode },
            set: { newValue in
                accountStore.verificationCode = String(
                    newValue.filter(\.isNumber).prefix(6)
                )
            }
        )
    }

    private var shouldShowDevelopmentQuickLoginAction: Bool {
        accountStore.shouldShowDevelopmentQuickLogin
    }

    private var headerSubtitle: String {
        switch accountStore.authState {
        case .unavailable:
            return "先配置好 Supabase，再启用账号体系。"
        case .signedOut:
            return "邮箱验证码登录，后续版本再补手机号和会员闭环。"
        case .sendingCode:
            return "正在发送验证码，请留意邮箱。"
        case .codeSent:
            return "验证码已发送，回到这里填 6 位数字即可完成登录。"
        case .verifying:
            return "正在校验验证码。"
        case .signedIn:
            return "当前设备已绑定到你的账号。"
        }
    }
}

private struct AccountCenterHeaderSection: View {
    let subtitle: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("账号与版本")
                    .font(.title3.weight(.bold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button("关闭", action: onClose)
                .buttonStyle(.bordered)
        }
        .padding(14)
        .pulseCard(cornerRadius: 16)
    }
}

private struct AccountSummarySection: View {
    let summary: AccountSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            accountBadge

            VStack(alignment: .leading, spacing: 6) {
                Text(summary.email)
                    .font(.headline)
                    .textSelection(.enabled)

                Label(summary.capsuleTitle, systemImage: editionSymbol)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(editionColor.opacity(0.14))
                    )
                    .foregroundStyle(editionColor)

                if let lastLoginAt = summary.lastLoginAt {
                    Text("最近登录：\(lastLoginAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(14)
        .pulseCard(cornerRadius: 16)
    }

    private var accountBadge: some View {
        let symbol = summary.email.first.map { String($0).uppercased() } ?? "@"

        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.18),
                            Color.blue.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(symbol)
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: 44, height: 44)
    }

    private var editionSymbol: String {
        switch summary.edition {
        case .free:
            return "leaf"
        case .member:
            return "star"
        case .professional:
            return "bolt.circle"
        }
    }

    private var editionColor: Color {
        switch summary.edition {
        case .free:
            return .green
        case .member:
            return .orange
        case .professional:
            return .accentColor
        }
    }
}

private struct AccountQuotaSection: View {
    let metrics: [AccountQuotaMetric]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("额度详情")
                .font(.subheadline.weight(.semibold))

            ForEach(metrics) { metric in
                HStack {
                    Text(metric.kind.title)
                        .font(.subheadline)
                    Spacer()
                    Text(metric.summaryText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .pulseCard(cornerRadius: 16)
    }
}

private struct AccountActionsSection: View {
    let onUnavailableFeature: (String) -> Void

    private let actions: [(title: String, symbolName: String)] = [
        ("开通会员", "crown"),
        ("设备管理", "desktopcomputer"),
        ("更新与版本", "square.and.arrow.down"),
        ("手机号登录", "phone")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("常用入口")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(actions, id: \.title) { action in
                AccountActionRow(
                    title: action.title,
                    symbolName: action.symbolName
                ) {
                    onUnavailableFeature("该功能尚未实现")
                }
            }
        }
        .padding(14)
        .pulseCard(cornerRadius: 16)
    }
}

private struct AccountActionRow: View {
    let title: String
    let symbolName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbolName)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)

                Text(title)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.56))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AccountFooterSection: View {
    let onSignOut: () -> Void

    var body: some View {
        HStack {
            Button("退出登录", role: .destructive, action: onSignOut)
                .buttonStyle(.bordered)
            Spacer()
        }
        .padding(14)
        .pulseCard(cornerRadius: 16)
    }
}

private struct AccountFeedbackBanner: View {
    let message: String
    let color: Color
    let icon: String

    var body: some View {
        Label(message, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color.opacity(0.08))
            )
    }
}
