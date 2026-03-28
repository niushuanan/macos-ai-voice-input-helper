import SwiftUI

struct AccountStatusCapsuleButton: View {
    @ObservedObject var accountStore: AccountStore
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.blue)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(accessibilityTitle)
    }

    private var iconName: String {
        "person.crop.circle"
    }

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
            VStack(alignment: .leading, spacing: 16) {
                headerCard

                if let summary = accountStore.summary {
                    signedInCard(summary: summary)
                } else {
                    signedOutCard
                }

                if let errorMessage = accountStore.errorMessage, !errorMessage.isEmpty {
                    feedbackCard(
                        message: errorMessage,
                        color: .red,
                        icon: "exclamationmark.triangle.fill"
                    )
                } else if !accountStore.isConfigured {
                    feedbackCard(
                        message: accountStore.unavailableMessage,
                        color: .orange,
                        icon: "wrench.and.screwdriver.fill"
                    )
                }
            }
            .padding(22)
        }
        .frame(width: 460, height: 560)
    }

    private var headerCard: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.2),
                                Color.blue.opacity(0.14)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: accountStore.isAuthenticated ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text("账号与版本")
                    .font(.title3.weight(.bold))
                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("关闭") {
                accountStore.dismissSheet()
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .pulseCard(cornerRadius: 18)
    }

    private var signedOutCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("登录后，你才能正式开始语音输入、管理模型配置和后续会员能力。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
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

            Text("开发阶段的新账号会先默认进入专业版，后续会员、设备管理和手机号登录会分阶段补齐。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .pulseCard(cornerRadius: 18)
    }

    private func signedInCard(summary: AccountSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                emailBadge(summary: summary)

                VStack(alignment: .leading, spacing: 6) {
                    Text(summary.email)
                        .font(.headline)
                    editionBadge(summary: summary)

                    if let lastLoginAt = summary.lastLoginAt {
                        Text("最近登录：\(lastLoginAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            DisclosureGroup("额度详情") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(summary.quotaSummary.metrics) { metric in
                        HStack {
                            Text(metric.kind.title)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(metric.summaryText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 8)
            }

            VStack(alignment: .leading, spacing: 8) {
                placeholderRow(title: "开通会员", symbolName: "crown")
                placeholderRow(title: "设备管理", symbolName: "desktopcomputer")
                placeholderRow(title: "更新与版本", symbolName: "square.and.arrow.down")
                placeholderRow(title: "手机号登录", symbolName: "phone")
            }

            Button("退出登录", role: .destructive) {
                Task {
                    await accountStore.signOut()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .pulseCard(cornerRadius: 18)
    }

    private func emailBadge(summary: AccountSummary) -> some View {
        let symbol = summary.email.first.map { String($0).uppercased() } ?? "@"

        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.18),
                            Color.blue.opacity(0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(symbol)
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: 48, height: 48)
    }

    private func editionBadge(summary: AccountSummary) -> some View {
        Label(summary.capsuleTitle, systemImage: editionSymbol(for: summary.edition))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(editionColor(for: summary.edition).opacity(0.14))
            )
            .foregroundStyle(editionColor(for: summary.edition))
    }

    private func placeholderRow(title: String, symbolName: String) -> some View {
        Button {
            onUnavailableFeature("该功能尚未实现")
        } label: {
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
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }

    private func feedbackCard(
        message: String,
        color: Color,
        icon: String
    ) -> some View {
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

    private func editionSymbol(for edition: AccountEdition) -> String {
        switch edition {
        case .free:
            return "leaf"
        case .member:
            return "star"
        case .professional:
            return "bolt.circle"
        }
    }

    private func editionColor(for edition: AccountEdition) -> Color {
        switch edition {
        case .free:
            return .green
        case .member:
            return .orange
        case .professional:
            return .accentColor
        }
    }
}
