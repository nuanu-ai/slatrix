import SwiftUI

/// After signing in on a new device, asks the person to confirm it's them before the encrypted conversations they
/// cannot read yet, as Element X does. Shown when this device is unverified and the account has or may have an
/// identity; skipping is remembered per account and device, and Preferences keeps both ways in.
struct IdentityGate<Content: View>: View {
    let verification: VerificationService
    let accountID: String?
    let hasIdentity: () async -> Bool?
    let onRecovery: () -> Void
    @ViewBuilder let content: Content
    @State private var identity = IdentityGatePolicy.Identity.unknown
    @State private var skipped = false
    private static var skippedKey: String { "identity.skipped" }

    private var deviceKey: String? {
        guard let accountID, let device = verification.ownDeviceID else { return nil }
        return accountID + "|" + device
    }
    private var prompting: Bool {
        IdentityGatePolicy.shouldPrompt(
            hasDevice: deviceKey != nil, isUnverified: verification.deviceStatus == .unverified,
            identity: identity, skipped: skipped)
    }

    var body: some View {
        content.disabled(prompting).accessibilityHidden(prompting)
            .overlay {
                if prompting { ConfirmIdentityView(verification: verification, onRecovery: onRecovery, onSkip: skip) }
            }
            .task(id: "\(deviceKey ?? "")|\(verification.deviceStatus)") {
                identity = .unknown
                skipped = deviceKey.map { Self.skippedDevices.contains($0) } ?? false
                guard verification.deviceStatus == .unverified else { return }
                guard deviceKey != nil else {
                    identity = .unavailable
                    return
                }
                let result = await hasIdentity()
                guard !Task.isCancelled else { return }
                identity = result.map { $0 ? .present : .absent } ?? .unavailable
            }
    }

    private static var skippedDevices: [String] { UserDefaults.standard.stringArray(forKey: skippedKey) ?? [] }
    private func skip() {
        guard let deviceKey else { return }
        UserDefaults.standard.set(Self.skippedDevices + [deviceKey], forKey: Self.skippedKey)
        skipped = true
    }
}

private struct ConfirmIdentityView: View {
    private static let width: CGFloat = 360
    let verification: VerificationService
    let onRecovery: () -> Void
    let onSkip: () -> Void
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        VStack(spacing: m.sp24) {
            Image(systemName: "lock.shield").font(m.font(.hero)).foregroundStyle(colors.accent)
            VStack(spacing: m.sp8) {
                Text("Confirm it’s you").font(m.font(.display, .bold)).foregroundStyle(colors.textPrimary)
                Text("Verify this Mac to read your encrypted messages.").font(m.font(.body)).foregroundStyle(
                    colors.textSecondary
                ).multilineTextAlignment(.center)
            }
            VStack(spacing: m.sp12) {
                Button {
                    Task { await verification.requestVerification() }
                } label: {
                    Label("Use another device", systemImage: "laptopcomputer.and.iphone")
                }.buttonStyle(.primary)
                Button(action: onRecovery) { Label("Use recovery key", systemImage: "key") }.buttonStyle(.secondary)
            }.frame(width: m(Self.width))
            if verification.ownDeviceID != nil {
                Button("Skip", action: onSkip).buttonStyle(.textLink).font(m.font(.secondary))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(colors.canvas)
        .accessibilityAddTraits(.isModal)
    }
}
