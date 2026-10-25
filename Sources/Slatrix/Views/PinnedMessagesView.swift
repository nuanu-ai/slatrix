import SwiftUI

struct PinnedMessagesView: View {
    @Environment(\.metrics) private var m
    @ObservedObject var matrix: MatrixService
    @ObservedObject var service: PinnedMessagesService
    let room: ChatRoom
    var onOpen: (ChatMessage) -> Void
    var onOpenProfile: (String, ChatUser?) -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    private var colors: AppColors { appearance.colors }
    private struct Scope: Hashable {
        var roomID: String
        var accountID: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: m.sp8) {
                Spacer()
                Text("\(service.totalPinned) \(service.totalPinned == 1 ? "pin" : "pins")").font(m.font(.caption))
                    .foregroundStyle(colors.muted)
                IconButton(symbol: "arrow.clockwise", label: "Refresh", role: .body) {
                    Task { await service.retry() }
                }.disabled(service.state == "loading")
            }.padding(.horizontal, m.sp24).frame(height: m.control + m.sp16)
            Divider().overlay(colors.border)
            if let error = service.errorMessage {
                HStack {
                    InlineErrorView(message: error)
                    Button("Retry") { Task { await service.retry() } }.buttonStyle(.link).padding(.trailing, m.sp20)
                }
            }
            if service.messages.isEmpty {
                if service.state == "loading" {
                    VStack(spacing: m.sp12) {
                        ProgressView().loadingInterval(.pinsLoading)
                        Text("Loading…").font(m.font(.secondary)).foregroundStyle(colors.muted)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if service.state != "error" {
                    EmptyStateView(
                        symbol: "pin", title: service.totalPinned == 0 ? "No pinned messages" : "Couldn’t load pins")
                } else {
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: m.sp16) {
                        ForEach(service.messages) { message in card(message) }
                        if service.hasMore {
                            Button("Show more") { service.loadMore() }.buttonStyle(.link).font(
                                m.font(.meta)
                            ).padding(m.sp16)
                        }
                    }.padding(m.sp24)
                }
            }
            if let coverage = service.coverageMessage {
                HStack(spacing: m.sp8) {
                    Image(systemName: "info.circle")
                    Text(coverage)
                    Spacer()
                }.font(m.font(.caption)).foregroundStyle(colors.muted).padding(.horizontal, m.sp24).padding(
                    .vertical, m.sp12
                )
                .background(colors.raised)
            }
        }.background(colors.canvas)
            .task(id: Scope(roomID: room.id, accountID: matrix.user?.id)) { await service.open(roomID: room.id) }
            .onDisappear { service.close() }
    }

    private func card(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: m.sp16) {
            HStack(alignment: .top, spacing: m.sp12) {
                Button {
                    profile(message)
                } label: {
                    AvatarView(name: message.senderName, size: m.avatar, matrix: matrix, source: message.avatarURL)
                }.buttonStyle(.row).help("View profile")
                VStack(alignment: .leading, spacing: m.sp8) {
                    HStack(spacing: m.sp8) {
                        Button {
                            profile(message)
                        } label: {
                            Text(message.senderName).font(m.font(.secondary, .semibold))
                        }.buttonStyle(.row)
                        Text(message.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute()).font(
                            m.font(.caption)
                        ).foregroundStyle(colors.muted)
                        if message.isEdited { Text("edited").font(m.font(.caption)).foregroundStyle(colors.muted) }
                        Spacer(minLength: 0)
                        Image(systemName: "pin.fill").font(m.font(.caption)).foregroundStyle(colors.muted)
                    }
                    if message.isRedacted {
                        Text("This message was deleted.").italic().foregroundStyle(colors.muted)
                    } else {
                        NativeMessageBody(
                            body: message.body, formattedBody: message.formattedBody, showsSpoilerControl: false
                        ).lineLimit(8)
                        if let attachment = message.attachment {
                            Label(attachment.name, systemImage: "paperclip").font(m.font(.meta)).foregroundStyle(
                                colors.muted
                            ).lineLimit(1)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if service.canPinUnpin {
                    Button("Unpin") { unpin(message) }.buttonStyle(.row).font(m.font(.caption)).foregroundStyle(
                        colors.muted
                    ).disabled(service.isUpdating)
                }
                Spacer()
                Button {
                    onOpen(message)
                } label: {
                    HStack(spacing: m.sp8) {
                        Text("Open")
                        Image(systemName: "arrow.up.right").font(m.font(.caption, .semibold))
                    }.font(m.font(.meta, .semibold)).foregroundStyle(colors.accent)
                }.buttonStyle(.row)
            }
        }.padding(m.sp20).frame(maxWidth: .infinity, alignment: .leading).background(
            colors.raised, in: RoundedRectangle(cornerRadius: m.radiusLarge)
        ).overlay(RoundedRectangle(cornerRadius: m.radiusLarge).stroke(colors.border))
    }
    private func profile(_ message: ChatMessage) {
        onOpenProfile(
            message.senderID, ChatUser(id: message.senderID, name: message.senderName, avatarURL: message.avatarURL))
    }
    private func unpin(_ message: ChatMessage) {
        let account = matrix.user?.id
        Task {
            guard matrix.user?.id == account, !matrix.isPreview else { return }
            do {
                _ = try await service.unpin(eventID: message.eventID, roomID: message.roomID)
            } catch is CancellationError {
            } catch { if matrix.user?.id == account { matrix.errorMessage = MatrixService.safeError(error) } }
        }
    }
}
