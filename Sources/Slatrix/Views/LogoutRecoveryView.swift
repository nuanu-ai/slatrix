import SwiftUI

struct LogoutRecoveryView: View {
    private static let width: CGFloat = 560
    @Environment(\.metrics) private var m
    @ObservedObject var controller: LogoutRecoveryController
    let request: LogoutRecoveryRequest
    var onRetry: () -> Void
    var onLocalSignOut: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: m.sp20) {
            Label("Couldn’t sign out on the server", systemImage: "wifi.exclamationmark")
                .font(m.font(.title, .semibold))
            Text(request.message).font(m.font(.secondary)).textSelection(.enabled)
            // The one consequence a person must know before choosing the local option.
            Text("Signing out only on this Mac leaves the session active on the server.")
                .font(m.font(.secondary)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: m.sp12) {
                if controller.isBusy { ProgressView().controlSize(.small) }
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Try again", action: onRetry)
                Button("Sign out on this Mac only", role: .destructive, action: onLocalSignOut)
            }.disabled(controller.isBusy)
        }.padding(m.sp24).sheetSize(width: Self.width)
            .interactiveDismissDisabled(controller.isBusy)
    }
}
