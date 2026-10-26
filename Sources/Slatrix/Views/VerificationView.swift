import SwiftUI

struct VerificationPresentation: ViewModifier {
    let service: VerificationService
    var enabled = true
    func body(content: Content) -> some View {
        content.modal(
            isPresented: Binding(get: { enabled && service.isPresented }, set: { if !$0 { service.dismiss() } })
        ) {
            VerificationView(service: service, onClose: { service.dismiss() })
        }
    }
}

struct DeviceVerificationSettings: View {
    @Environment(\.metrics) private var m
    let service: VerificationService
    var disabled: Bool
    var onRecovery: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    private var status: String {
        switch service.deviceStatus {
        case .unknown: "Checking…"
        case .unverified: "This device isn’t verified"
        case .verified: "This device is verified"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: m.sp12) {
            Label(
                status, systemImage: service.deviceStatus == .verified ? "checkmark.shield" : "shield.lefthalf.filled"
            )
            .font(m.font(.secondary)).foregroundStyle(appearance.colors.textSecondary)
            // The same two ways in as the sign-in step; the recovery key also unlocks older messages.
            HStack(spacing: m.sp12) {
                if service.deviceStatus != .verified {
                    Button("Use another device") { Task { await service.requestVerification() } }
                }
                Button("Use recovery key", action: onRecovery)
            }.disabled(disabled)
        }
    }
}

struct VerificationView: View {
    private static let emojiHeight: CGFloat = 48
    @Environment(\.metrics) private var m
    let service: VerificationService
    var onClose: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    private var colors: AppColors { appearance.colors }

    var body: some View {
        let actions = actions
        Modal(
            title: title, size: service.phase == .comparison && !service.emojis.isEmpty ? .large : .medium,
            onClose: close, secondary: actions.secondary, primary: actions.primary
        ) {
            if !detail.isEmpty {
                Text(detail).font(m.font(.body)).foregroundStyle(colors.textSecondary).fixedSize(
                    horizontal: false, vertical: true)
            }
            if let request = service.request { requestDetails(request) }
            if service.phase == .comparison { comparison }
            if let error = service.errorMessage {
                InlineErrorView(message: error).clipShape(RoundedRectangle(cornerRadius: m.radiusLarge))
            }
            if waiting {
                HStack(spacing: m.sp12) {
                    DelayedProgress()
                    Text(waitingText).font(m.font(.meta)).foregroundStyle(colors.textSecondary)
                }
                .padding(.vertical, m.sp4).accessibilityElement(children: .combine)
            }
            if let id = service.ownDeviceID {
                HStack(spacing: m.sp8) {
                    Image(systemName: "desktopcomputer")
                    Text("This device: \(id)").textSelection(.enabled)
                }.font(m.font(.caption, design: .monospaced)).foregroundStyle(colors.textSecondary)
            }
        }
    }

    private var title: String {
        switch service.phase {
        case .incoming: "Verification request"
        case .comparison: service.emojis.isEmpty ? "Compare the numbers" : "Compare the emoji"
        case .awaitingConfirmation: "Waiting for the other device"
        case .finished: "Device verified"
        case .cancelled: "Verification cancelled"
        case .cancelling: "Cancelling…"
        case .failed: "Verification failed"
        default: "Verify this device"
        }
    }

    private var detail: String {
        switch service.phase {
        case .incoming: "Accept only if you recognize this person and device."
        case .comparison: "Confirm only if both screens match exactly, in the same order."
        case .ready: "Compare codes on both devices."
        case .awaitingConfirmation: "Confirm on the other device too."
        case .finished, .cancelled, .cancelling: ""
        case .failed: "Nothing was approved. Try again, or use your recovery key."
        default: "Accept the request on another signed-in device."
        }
    }

    private var waiting: Bool {
        service.isWorking || service.isCleaningUp
            || [.preparing, .requesting, .waitingForOtherDevice, .exchanging, .awaitingConfirmation].contains(
                service.phase)
    }
    private var waitingText: String {
        if service.isCleaningUp { return "Cancelling…" }
        return switch service.phase {
        case .preparing: "Preparing…"
        case .requesting: "Sending request…"
        case .exchanging: "Exchanging codes…"
        case .awaitingConfirmation: "Waiting for the other device…"
        default: "Waiting for your other device…"
        }
    }

    private func requestDetails(_ request: VerificationService.Request) -> some View {
        VStack(alignment: .leading, spacing: m.sp8) {
            Label(request.name, systemImage: "person.crop.circle").font(m.font(.body, .semibold))
            Text(request.userID).font(m.font(.meta, design: .monospaced)).textSelection(.enabled)
            Text("\(request.deviceName ?? "Matrix session") · \(request.deviceID)").font(m.font(.meta))
                .textSelection(.enabled)
            Text("First seen \(request.firstSeen.formatted(date: .abbreviated, time: .shortened))").font(
                m.font(.caption)
            ).foregroundStyle(colors.textSecondary)
        }.padding(m.sp16).frame(maxWidth: .infinity, alignment: .leading).background(
            colors.raised, in: RoundedRectangle(cornerRadius: m.radiusLarge))
    }

    private var comparison: some View {
        VStack(spacing: m.sp20) {
            if !service.emojis.isEmpty {
                HStack(alignment: .top, spacing: m.sp8) {
                    ForEach(service.emojis) { emoji in
                        VStack(spacing: m.sp8) {
                            Text(emoji.symbol).font(m.font(.hero)).frame(height: m(Self.emojiHeight))
                            Text(emoji.name).font(m.font(.caption, .medium)).multilineTextAlignment(.center)
                                .lineLimit(3).frame(maxWidth: .infinity)
                        }.frame(maxWidth: .infinity).accessibilityElement(children: .ignore).accessibilityLabel(
                            "Item \(emoji.id + 1): \(emoji.name)")
                    }
                }
            } else {
                HStack(spacing: m.sp20) {
                    ForEach(Array(service.decimals.enumerated()), id: \.offset) { index, number in
                        Text(String(number)).font(m.font(.display, .semibold, design: .monospaced))
                            .accessibilityLabel("Group \(index + 1): \(String(number))")
                    }
                }.padding(.vertical, m.sp12)
            }
            Label("A mismatch means you should stop and try again.", systemImage: "exclamationmark.shield").font(
                m.font(.meta)
            ).foregroundStyle(colors.textSecondary)
        }.padding(m.sp20).frame(maxWidth: .infinity).background(
            colors.raised, in: RoundedRectangle(cornerRadius: m.radiusLarge))
    }

    /// Trust decisions take no Return shortcut, so a stray key never accepts or confirms.
    private var actions: (secondary: ModalAction?, primary: ModalAction?) {
        let working = service.isWorking
        switch service.phase {
        case .comparison:
            return (
                ModalAction("They don’t match") { Task { await service.rejectMismatch() } },
                ModalAction("They match", disabled: working, shortcut: nil) { Task { await service.confirmMatch() } }
            )
        case .incoming:
            return (
                ModalAction("Decline") { Task { await service.cancel() } },
                ModalAction("Accept request", disabled: working, shortcut: nil) { Task { await service.accept() } }
            )
        case .ready:
            return (
                ModalAction("Cancel") { Task { await service.cancel() } },
                ModalAction("Compare codes", disabled: working) { Task { await service.startComparison() } }
            )
        case .cancelling: return (ModalAction("Close", action: close), nil)
        case _ where service.phase.isActive || service.phase == .preparing:
            return (ModalAction("Cancel verification") { Task { await service.cancel() } }, nil)
        default: return (nil, ModalAction(service.phase == .finished ? "Done" : "Close", action: close))
        }
    }

    private func close() {
        service.dismiss()
        onClose()
    }
}
