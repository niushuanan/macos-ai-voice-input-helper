import Foundation
import Supabase

@MainActor
final class AccountStore: ObservableObject, AccountAccessControlling {
    @Published var emailDraft: String = ""
    @Published var verificationCode: String = ""
    @Published private(set) var isSheetPresented = false
    @Published private(set) var authState: AccountAuthState
    @Published private(set) var summary: AccountSummary?
    @Published private(set) var errorMessage: String?

    private let service: SupabaseAccountService
    private var authChangesTask: Task<Void, Never>?
    private var presentationHandler: ((Bool) -> Void)?

    init(service: SupabaseAccountService) {
        self.service = service
        self.authState = service.isConfigured ? .signedOut : .unavailable
        observeAuthChanges()
    }

    deinit {
        authChangesTask?.cancel()
    }

    var isAuthenticated: Bool {
        summary != nil
    }

    var isConfigured: Bool {
        service.isConfigured
    }

    var currentEmail: String {
        if let summary {
            return summary.email
        }
        if case let .sendingCode(email) = authState {
            return email
        }
        if case let .codeSent(email, _) = authState {
            return email
        }
        if case let .verifying(email) = authState {
            return email
        }
        return emailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var statusCapsuleTitle: String {
        if case .codeSent = authState {
            return "验证码已发送"
        }
        if let summary {
            return summary.capsuleTitle
        }
        return "登录"
    }

    var unavailableMessage: String {
        "当前还没配置 Supabase。先填好 project URL 和 anon key，再回来登录。"
    }

    func configurePresentationHandler(_ handler: @escaping (Bool) -> Void) {
        presentationHandler = handler
    }

    func promptForAuthentication() {
        presentSheet(selectHome: true)
    }

    func presentSheet(selectHome: Bool = false) {
        presentationHandler?(selectHome)
        isSheetPresented = true
    }

    func dismissSheet() {
        isSheetPresented = false
    }

    func boot() {
        Task {
            await refreshSessionIfNeeded()
        }
    }

    func refreshSessionIfNeeded() async {
        guard isConfigured else {
            authState = .unavailable
            summary = nil
            return
        }

        do {
            if let summary = try await service.restoreSession() {
                apply(summary: summary)
            } else if !isOTPFlowPending {
                setSignedOut()
            }
        } catch {
            errorMessage = userFacingMessage(for: error)
            if !isOTPFlowPending {
                setSignedOut()
            }
        }
    }

    func startEmailOTP() async {
        guard isConfigured else {
            authState = .unavailable
            errorMessage = unavailableMessage
            return
        }

        let normalizedEmail = emailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(email: normalizedEmail) else {
            errorMessage = "请输入有效邮箱地址。"
            return
        }

        errorMessage = nil
        authState = .sendingCode(email: normalizedEmail)

        do {
            try await service.startEmailOTP(email: normalizedEmail)
            authState = .codeSent(
                email: normalizedEmail,
                resendAvailableAt: Date().addingTimeInterval(30)
            )
        } catch {
            errorMessage = userFacingMessage(for: error)
            authState = .signedOut
        }
    }

    func verifyEmailOTP() async {
        guard isConfigured else {
            authState = .unavailable
            errorMessage = unavailableMessage
            return
        }

        let email = currentEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = verificationCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter(\.isNumber)

        guard isValid(email: email) else {
            errorMessage = "请先填写有效邮箱地址。"
            return
        }

        guard code.count == 6 else {
            errorMessage = "请输入 6 位验证码。"
            return
        }

        errorMessage = nil
        authState = .verifying(email: email)

        do {
            let summary = try await service.verifyEmailOTP(
                email: email,
                token: code
            )
            verificationCode = ""
            apply(summary: summary)
        } catch {
            errorMessage = userFacingMessage(for: error)
            authState = .codeSent(
                email: email,
                resendAvailableAt: Date()
            )
        }
    }

    func signOut() async {
        do {
            try await service.signOut()
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
        verificationCode = ""
        setSignedOut()
    }

    func resetPendingCodeFlow() {
        verificationCode = ""
        errorMessage = nil
        authState = isConfigured ? .signedOut : .unavailable
    }

    private func observeAuthChanges() {
        guard let stream = service.authStateChanges else {
            return
        }

        authChangesTask = Task { [weak self] in
            guard let self else {
                return
            }

            for await (event, session) in stream {
                await self.handleAuthChange(event: event, session: session)
            }
        }
    }

    private func handleAuthChange(
        event: AuthChangeEvent,
        session: Session?
    ) async {
        switch event {
        case .signedOut:
            if !isOTPFlowPending {
                setSignedOut()
            }
        case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
            guard session != nil else {
                if !isOTPFlowPending {
                    setSignedOut()
                }
                return
            }

            do {
                if let summary = try await service.fetchCurrentSummary(required: false) {
                    apply(summary: summary)
                }
            } catch {
                if self.summary == nil {
                    setSignedOut()
                }
                errorMessage = userFacingMessage(for: error)
            }
        case .passwordRecovery, .userDeleted, .mfaChallengeVerified:
            break
        }
    }

    private var isOTPFlowPending: Bool {
        switch authState {
        case .sendingCode, .codeSent, .verifying:
            return true
        case .unavailable, .signedOut, .signedIn:
            return false
        }
    }

    private func apply(summary: AccountSummary) {
        self.summary = summary
        emailDraft = summary.email
        verificationCode = ""
        errorMessage = nil
        authState = .signedIn
    }

    private func setSignedOut() {
        summary = nil
        verificationCode = ""
        authState = isConfigured ? .signedOut : .unavailable
    }

    private func isValid(email: String) -> Bool {
        let parts = email.split(separator: "@")
        guard parts.count == 2 else {
            return false
        }
        return parts[1].contains(".")
    }

    private func userFacingMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "登录失败，请稍后再试。" : message
    }
}
