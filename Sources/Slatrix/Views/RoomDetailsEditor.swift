import SwiftUI

struct RoomDetailsEditor: View {
    private static let size = CGSize(width: 552, height: 572)
    private static let topicMinHeight: CGFloat = 112
    private static let topicMaxHeight: CGFloat = 180
    @Environment(\.metrics) private var m
    @ObservedObject var matrix: MatrixService
    let roomID: String
    var onClose: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var owner: Context?
    @State private var snapshot: RoomDetailsSnapshot?
    @State private var name = ""
    @State private var topic = ""
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var request = UUID()
    @FocusState private var focusedField: Field?

    private struct Context: Hashable {
        let session: UUID
        let roomID: String
        let userID: String?
        let preview: Bool
    }
    private enum Field: Hashable { case name, topic }
    private var context: Context {
        Context(
            session: matrix.notificationSessionID, roomID: roomID, userID: matrix.user?.id, preview: matrix.isPreview)
    }
    private var current: Bool { owner == context && !matrix.isPreview }
    private var colors: AppColors { appearance.colors }
    private var nameChange: String? {
        guard let snapshot, snapshot.canEditName, name != snapshot.name else { return nil }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == snapshot.name ? nil : value
    }
    private var topicChange: String? {
        guard let snapshot, snapshot.canEditTopic, topic != snapshot.topic else { return nil }
        return topic
    }
    private var blankName: Bool { nameChange?.isEmpty == true }
    private var canSave: Bool {
        current && !loading && !saving && !blankName && (nameChange != nil || topicChange != nil)
    }
    private var destinationName: String {
        if let workspace = matrix.workspaces.first(where: { $0.id == roomID }) { return workspace.name }
        if let room = matrix.rooms.first(where: { $0.id == roomID }) { return room.name }
        if let snapshot, !snapshot.name.isEmpty { return snapshot.name }
        return roomID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: m.sp16) {
                VStack(alignment: .leading, spacing: m.sp8) {
                    Text("Edit details").font(m.font(.header, .bold)).foregroundStyle(
                        colors.primaryText)
                    Text(destinationName).font(m.font(.secondary, .medium)).lineLimit(2)
                    Text(roomID).font(m.font(.caption, design: .monospaced)).foregroundStyle(colors.muted)
                        .textSelection(.enabled).lineLimit(2)
                }
                Spacer(minLength: 0)
                IconButton(symbol: "xmark", label: "Close", role: .secondary, action: onClose).disabled(
                    saving)
            }.padding(m.sp24)
            Divider().overlay(colors.border)
            ScrollView {
                VStack(alignment: .leading, spacing: m.sp24) {
                    if loading {
                        HStack(spacing: m.sp12) {
                            ProgressView().controlSize(.small)
                            Text("Loading…").font(m.font(.secondary)).foregroundStyle(
                                colors.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, m.sp20)
                    } else if let snapshot, current {
                        detailField("Name", editable: snapshot.canEditName) {
                            TextField(snapshot.isSpace ? "Workspace name" : "Conversation name", text: $name)
                                .textFieldStyle(.roundedBorder).font(m.font(.body)).focused(
                                    $focusedField, equals: .name
                                )
                                .disabled(!snapshot.canEditName || saving)
                            if blankName {
                                Text("Enter a name.").font(m.font(.meta)).foregroundStyle(
                                    Color(nsColor: .systemRed))
                            }
                        }
                        detailField("Description", editable: snapshot.canEditTopic) {
                            TextEditor(text: $topic).font(m.font(.secondary)).scrollContentBackground(.hidden)
                                .padding(m.sp8).frame(
                                    minHeight: m(Self.topicMinHeight), maxHeight: m(Self.topicMaxHeight)
                                )
                                .background(colors.raised, in: RoundedRectangle(cornerRadius: m.radius))
                                .overlay(RoundedRectangle(cornerRadius: m.radius).stroke(colors.border))
                                .focused($focusedField, equals: .topic).disabled(!snapshot.canEditTopic || saving)
                        }
                        if !snapshot.canEditName && !snapshot.canEditTopic {
                            Label("You can’t edit these details.", systemImage: "lock")
                                .font(m.font(.meta)).foregroundStyle(colors.muted)
                        }
                    }
                    if let error {
                        VStack(alignment: .leading, spacing: m.sp12) {
                            Text(error).font(m.font(.meta)).foregroundStyle(Color(nsColor: .systemRed))
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            if snapshot == nil && current && !loading {
                                Button("Try again") { Task { await load() } }.buttonStyle(.link)
                            }
                        }.accessibilityElement(children: .contain)
                    }
                }.padding(m.sp24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(colors.border)
            HStack(spacing: m.sp12) {
                if saving {
                    ProgressView().controlSize(.small)
                    Text("Saving…").font(m.font(.meta)).foregroundStyle(colors.muted)
                }
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction).disabled(saving)
                Button(error != nil && snapshot != nil ? "Try again" : "Save", action: save)
                    .buttonStyle(.borderedProminent).tint(colors.accent).disabled(!canSave)
                    .keyboardShortcut(.return, modifiers: .command).help("Save changes (⌘Return)")
            }.padding(.horizontal, m.sp24).padding(.vertical, m.sp16)
        }
        .sheetSize(width: Self.size.width, height: Self.size.height).background(colors.canvas).foregroundStyle(
            colors.text
        )
        .task(id: context) {
            if owner == nil { owner = context }
            guard current else {
                request = UUID()
                snapshot = nil
                name = ""
                topic = ""
                loading = false
                saving = false
                error = "Something changed. Open the editor again."
                return
            }
            await load()
        }
        .onDisappear { request = UUID() }
    }

    private func detailField<Content: View>(_ title: String, editable: Bool, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: m.sp8) {
            HStack(spacing: m.sp8) {
                Text(title).font(m.font(.secondary, .semibold)).foregroundStyle(colors.primaryText)
                if !editable {
                    Label("Read only", systemImage: "lock").font(m.font(.caption)).foregroundStyle(colors.muted)
                }
            }
            content()
        }
    }

    @MainActor private func load() async {
        guard current, !saving else { return }
        let identity = context
        let token = UUID()
        request = token
        loading = true
        error = nil
        do {
            let loaded = try await matrix.loadRoomDetails(roomID: identity.roomID)
            guard !Task.isCancelled, current, context == identity, request == token, loaded.roomID == identity.roomID
            else { return }
            snapshot = loaded
            name = loaded.name
            topic = loaded.topic
            loading = false
            focusedField = loaded.canEditName ? .name : loaded.canEditTopic ? .topic : nil
        } catch {
            guard !Task.isCancelled, current, context == identity, request == token else { return }
            loading = false
            self.error = MatrixService.safeError(error)
        }
    }

    @MainActor private func save() {
        guard canSave else { return }
        let identity = context
        let token = UUID()
        let changedName = nameChange
        let changedTopic = topicChange
        request = token
        saving = true
        error = nil
        Task { @MainActor in
            guard current, context == identity, request == token else { return }
            do {
                let result = try await matrix.saveRoomDetails(
                    roomID: identity.roomID, name: changedName, topic: changedTopic)
                guard current, context == identity, request == token, result.snapshot.roomID == identity.roomID else {
                    return
                }
                snapshot = result.snapshot
                name = result.snapshot.name
                topic = result.snapshot.topic
                saving = false
                onClose()
            } catch let partial as RoomDetailsPartialFailure {
                guard current, context == identity, request == token, partial.result.snapshot.roomID == identity.roomID
                else { return }
                snapshot = partial.result.snapshot
                if partial.result.savedFields.contains(.name) { name = partial.result.snapshot.name }
                if partial.result.savedFields.contains(.topic) { topic = partial.result.snapshot.topic }
                saving = false
                error = partial.warning
            } catch {
                guard current, context == identity, request == token else { return }
                saving = false
                self.error = MatrixService.safeError(error)
            }
        }
    }
}
