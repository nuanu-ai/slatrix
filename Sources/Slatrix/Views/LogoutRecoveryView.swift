import SwiftUI

struct LogoutRecoveryView: View {
    @Environment(\.metrics) private var m
    @ObservedObject var controller: LogoutRecoveryController
    let request: LogoutRecoveryRequest
    var onRetry: () -> Void
    var onLocalSignOut: () -> Void
    var onCancel: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        Modal(
            title: "Couldn’t sign out on the server", busy: controller.isBusy, onClose: onCancel,
            secondary: ModalAction("Try again", action: onRetry),
            primary: ModalAction(
                "Sign out on this Mac only", kind: .destructive, shortcut: nil, action: onLocalSignOut)
        ) {
            Text(request.message).font(m.font(.secondary)).textSelection(.enabled)
            // The one consequence a person must know before choosing the local option.
            Text("Signing out only on this Mac leaves the session active on the server.")
                .font(m.font(.secondary)).foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
