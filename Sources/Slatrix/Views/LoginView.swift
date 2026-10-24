import SwiftUI

struct LoginView: View {
    private static let heroTile: CGFloat = 88
    private static let heroRadius: CGFloat = 24
    private static let formWidth: CGFloat = 360
    private static let fieldHeight: CGFloat = 40
    private static let buttonHeight: CGFloat = 44
    @Environment(\.metrics) private var m
    @ObservedObject var matrix: MatrixService
    @EnvironmentObject var appearance: AppearanceStore
    @State private var homeserver = "matrix.org"
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @State private var clearingSavedSession = false
    @FocusState private var focused: Field?
    var onPreview: () -> Void
    enum Field { case username, password }
    private var colors: AppColors { appearance.colors }
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: m.sp24) {
                Image(systemName: "circle.hexagongrid.fill").font(m.font(.hero)).foregroundStyle(
                    colors.accent
                )
                .frame(width: m(Self.heroTile), height: m(Self.heroTile)).background(
                    colors.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: m(Self.heroRadius)))
                Text("Sign in to Slatrix").font(m.font(.display, .bold)).foregroundStyle(colors.primaryText)
                VStack(alignment: .leading, spacing: m.sp16) {
                    field("Homeserver") {
                        TextField("https://matrix.example.org", text: $homeserver).textContentType(.URL)
                    }
                    field("Username") {
                        TextField("@you:example.org", text: $username).textContentType(.username).focused(
                            $focused, equals: .username)
                    }
                    field("Password") {
                        SecureField("", text: $password).textContentType(.password).focused(
                            $focused, equals: .password
                        ).onSubmit(signIn)
                    }
                    if let message = error ?? matrix.errorMessage {
                        InlineErrorView(message: message).padding(.horizontal, -m.sp12)
                    }
                    if matrix.sessionCleanupPending {
                        Button(
                            clearingSavedSession ? "Signing out…" : "Finish signing out",
                            action: clearSavedSession
                        )
                        .buttonStyle(.bordered).disabled(clearingSavedSession || busy)
                    }
                    Button(action: signIn) {
                        HStack(spacing: m.sp8) {
                            if busy { ProgressView().controlSize(.small).tint(.white) }
                            Text(busy ? "Connecting…" : "Sign in").fontWeight(.semibold)
                            if !busy { Image(systemName: "arrow.right") }
                        }
                        .frame(maxWidth: .infinity).frame(height: m(Self.buttonHeight)).background(
                            Color(hex: 0x228369), in: RoundedRectangle(cornerRadius: m.radiusLarge)
                        ).foregroundStyle(.white)
                    }.buttonStyle(.row).disabled(
                        busy || clearingSavedSession || !matrix.canChangeAuthentication
                            || username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                }.frame(width: m(Self.formWidth)).padding(m.sp24).background(
                    colors.raised, in: RoundedRectangle(cornerRadius: m.radiusPanel)
                )
                .overlay(RoundedRectangle(cornerRadius: m.radiusPanel).stroke(colors.border))
                Button("Try it without signing in") {
                    guard matrix.canChangeAuthentication else { return }
                    onPreview()
                }.disabled(busy || clearingSavedSession || !matrix.canChangeAuthentication).buttonStyle(.row).font(
                    m.font(.secondary)
                ).foregroundStyle(colors.accent)
            }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(colors.canvas).onAppear { focused = .username }
    }
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: m.sp8) {
            Text(label).font(m.font(.secondary, .semibold))
            content().textFieldStyle(.plain).padding(.horizontal, m.sp12).frame(height: m(Self.fieldHeight)).background(
                colors.canvas, in: RoundedRectangle(cornerRadius: m.radius)
            ).overlay(RoundedRectangle(cornerRadius: m.radius).stroke(colors.border)).font(m.font(.body))
        }
    }
    private func clearSavedSession() {
        guard matrix.sessionCleanupPending, !busy, !clearingSavedSession else { return }
        let owner = LogoutOwner(
            sessionID: matrix.notificationSessionID, userID: matrix.user?.id, isPreview: matrix.isPreview)
        clearingSavedSession = true
        error = nil
        Task { @MainActor in
            defer { clearingSavedSession = false }
            guard
                owner
                    == LogoutOwner(
                        sessionID: matrix.notificationSessionID, userID: matrix.user?.id, isPreview: matrix.isPreview)
            else { return }
            do { try await matrix.logoutLocally() } catch {
                // Cleanup changes its own generation. Matrix publishes that
                // failure; only a still-original context may add a local error.
                guard
                    owner
                        == LogoutOwner(
                            sessionID: matrix.notificationSessionID, userID: matrix.user?.id,
                            isPreview: matrix.isPreview)
                else { return }
                self.error = MatrixService.safeError(error)
            }
        }
    }
    private func signIn() {
        guard !busy, !clearingSavedSession, matrix.canChangeAuthentication, !username.isEmpty, !password.isEmpty else {
            return
        }
        busy = true
        error = nil
        Task {
            do {
                try await matrix.login(
                    homeserver: homeserver, username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password)
                password = ""
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
