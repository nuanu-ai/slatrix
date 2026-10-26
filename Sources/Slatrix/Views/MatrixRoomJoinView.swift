import SwiftUI

struct MatrixRoomJoinView: View {
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let request: MatrixRoomJoinRequest
    var onJoined: (MatrixRoomJoinDestination) -> Void
    var onClose: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var ownerID: UUID?
    @State private var joining = false
    @State private var accepted: MatrixRoomJoinDestination?
    @State private var error: String?
    @State private var operation = UUID()

    private struct Context: Hashable {
        let request: MatrixRoomJoinRequest
        let session: UUID
        let accountID: String?
        let preview: Bool
    }
    private var context: Context {
        Context(
            request: request, session: matrix.notificationSessionID, accountID: matrix.user?.id,
            preview: matrix.isPreview)
    }
    private var current: Bool {
        ownerID == request.id && !matrix.isPreview && matrix.notificationSessionID == request.sessionID
            && matrix.user?.id == request.accountID
    }
    private var colors: AppColors { appearance.colors }
    private var resolvedRoomIsDifferent: Bool { request.address != request.roomID }
    private var title: String {
        if accepted != nil { return "You’ve joined" }
        return request.isSpaceHint == true ? "Join this workspace?" : "Join this conversation?"
    }

    var body: some View {
        Modal(
            title: title, busy: joining, onClose: onClose,
            secondary: accepted == nil ? ModalAction("Cancel", action: onClose) : nil,
            primary: accepted == nil
                // No Return shortcut: presenting a link must never consume the key as consent to join.
                ? ModalAction(error == nil ? "Join" : "Try again", disabled: !current, shortcut: nil, action: join)
                : ModalAction("Done", action: onClose)
        ) {
            VStack(alignment: .leading, spacing: m.sp20) {
                detail("Address", value: request.address)
                if resolvedRoomIsDifferent {
                    detail("Room ID", value: request.roomID)
                }
                if !request.via.isEmpty {
                    VStack(alignment: .leading, spacing: m.sp8) {
                        Text("Via").font(m.font(.meta, .semibold)).foregroundStyle(
                            colors.textPrimary)
                        ForEach(Array(request.via.enumerated()), id: \.offset) { _, server in
                            Text(server).font(m.font(.meta, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let eventID = request.eventID {
                    detail("Message", value: eventID)
                }
                VStack(alignment: .leading, spacing: m.sp8) {
                    Label("Joining as", systemImage: "person.crop.circle").font(
                        m.font(.meta, .semibold)
                    ).foregroundStyle(colors.textPrimary)
                    Text(request.accountID).font(m.font(.meta, design: .monospaced)).textSelection(.enabled)
                }.padding(m.sp12).frame(maxWidth: .infinity, alignment: .leading).background(
                    colors.raised, in: RoundedRectangle(cornerRadius: m.radiusLarge))
                if let accepted,
                    let warning = accepted.warning
                        ?? (accepted.isSpace == nil
                            ? "It’ll appear in your sidebar in a moment."
                            : nil)
                {
                    Label(warning, systemImage: "info.circle").font(m.font(.meta)).foregroundStyle(
                        colors.textSecondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let error {
                    Text(error).font(m.font(.meta)).foregroundStyle(colors.destructive)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: context) {
            if ownerID == nil { ownerID = request.id }
            guard current else {
                operation = UUID()
                joining = false
                accepted = nil
                error = "Something changed. Open the link again."
                return
            }
        }
        .onDisappear { operation = UUID() }
    }

    private func detail(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: m.sp8) {
            Text(title).font(m.font(.meta, .semibold)).foregroundStyle(colors.textPrimary)
            Text(value).font(m.font(.meta, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor private func join() {
        guard current, !joining, accepted == nil else { return }
        let submitted = request
        let token = UUID()
        operation = token
        joining = true
        error = nil
        Task { @MainActor in
            guard current, request == submitted, operation == token else { return }
            do {
                let destination = try await matrix.joinMatrixRoom(submitted)
                guard current, request == submitted, operation == token else { return }
                accepted = destination
                joining = false
                guard destination.roomID == submitted.roomID, destination.eventID == submitted.eventID else {
                    error =
                        "Joined, but couldn’t open it. Find it in your sidebar."
                    return
                }
                onJoined(destination)
            } catch is CancellationError {
                guard current, request == submitted, operation == token else { return }
                joining = false
                error = "Joining was interrupted. Try again."
            } catch {
                guard current, request == submitted, operation == token else { return }
                joining = false
                self.error = MatrixService.safeError(error)
            }
        }
    }
}
