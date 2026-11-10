import SwiftUI

/// What Later can do with an item, so rows take plain callbacks rather than the service.
struct LaterActions {
    var open: (SavedMessageReference) -> Void
    var move: (SavedMessageReference, LaterState) -> Void
    var remind: (SavedMessageReference, Date?) -> Void
    var remove: (SavedMessageReference) -> Void
}

/// Slack's Later: In progress, Archived and Completed, each a list of messages read from their conversations.
struct SavedMessagesView: View {
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let list: SavedMessages
    let actions: LaterActions
    @State private var tab = LaterState.inProgress
    @State private var custom: SavedMessageReference?
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let shown = list.tab(tab)
        VStack(spacing: 0) {
            TabBar(
                tabs: LaterState.allCases.map {
                    let count = $0 == .inProgress ? list.tab(.inProgress).count : 0
                    return .init(value: $0, title: $0.title, count: count > 0 ? count : nil)
                }, selection: $tab
            ).padding(.horizontal, m.sp24).frame(maxWidth: .infinity, alignment: .leading)
            Divider().overlay(appearance.colors.border)
            if shown.isEmpty {
                EmptyStateView(symbol: tab.symbol, title: tab.empty).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: m.sp2) {
                        ForEach(shown) { reference in
                            SavedMessageRow(
                                matrix: matrix, reference: reference, actions: actions,
                                onCustomReminder: { custom = reference })
                        }
                    }.padding(.horizontal, m.sp12).padding(.vertical, m.sp4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(appearance.colors.canvas)
        .modal(item: $custom) { reference in
            CustomReminder(
                start: reference.remindAt ?? ReminderPreset.in1Hour.date(from: Date()), onCancel: { custom = nil },
                onSave: {
                    actions.remind(reference, $0)
                    custom = nil
                })
        }
    }
}

extension LaterState {
    var title: String {
        switch self {
        case .inProgress: "In progress"
        case .archived: "Archived"
        case .completed: "Completed"
        }
    }
    /// The toast once an item moves here.
    var moved: String {
        switch self {
        case .inProgress: "Moved to In progress"
        case .archived: "Archived"
        case .completed: "Marked complete"
        }
    }
    fileprivate var symbol: String {
        switch self {
        case .inProgress: "bookmark"
        case .archived: "archivebox"
        case .completed: "checkmark.circle"
        }
    }
    fileprivate var empty: String {
        switch self {
        case .inProgress: "Nothing saved for later"
        case .archived: "Nothing archived"
        case .completed: "Nothing completed yet"
        }
    }
}

/// Slack's custom reminder: a day and a time, no earlier than now.
private struct CustomReminder: View {
    @State var start: Date
    var onCancel: () -> Void
    var onSave: (Date) -> Void

    var body: some View {
        Modal(
            title: "Remind me", size: .small, onClose: onCancel, secondary: ModalAction("Cancel", action: onCancel),
            primary: ModalAction("Save", disabled: start <= Date()) { onSave(start) }
        ) {
            DatePicker("When", selection: $start, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical).labelsHidden()
        }
    }
}

/// When a reminder is due, as Slack says it: soon in minutes or hours, later as a day and time; past it, overdue.
private struct DueLabel: View {
    let date: Date
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        SwiftUI.TimelineView(.everyMinute) { context in
            let overdue = date <= context.date
            Label(text(now: context.date), systemImage: overdue ? "clock.badge.exclamationmark" : "clock")
                .foregroundStyle(overdue ? appearance.colors.destructive : appearance.colors.textSecondary)
        }.font(m.font(.subheadline)).lineLimit(1)
    }

    private func text(now: Date) -> String {
        if date <= now { return "Overdue" }
        if date.timeIntervalSince(now) < 24 * 60 * 60 {
            return "Due \(date.formatted(.relative(presentation: .numeric, unitsStyle: .wide)))"
        }
        return "Due \(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))"
    }
}
/// One saved message, laid out like Slack's Later: the conversation, then the message; a click anywhere opens it.
private struct SavedMessageRow: View {
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let reference: SavedMessageReference
    let actions: LaterActions
    var onCustomReminder: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var message: ChatMessage?
    @State private var error: String?
    @State private var retry = UUID()
    @State private var hovered = false
    private var colors: AppColors { appearance.colors }
    private var room: ChatRoom? { matrix.rooms.first { $0.id == reference.roomID } }

    /// Where it was said: the channel, or a direct message.
    private var location: String {
        guard let room else { return "Conversation unavailable" }
        return room.isDirect ? "Direct message" : "#\(room.name)"
    }

    var body: some View {
        Button {
            actions.open(reference)
        } label: {
            HStack(alignment: .top, spacing: m.sp12) {
                AvatarView(name: message?.senderName ?? "", size: m.avatar, matrix: matrix, source: message?.avatarURL)
                    .padding(.top, m.sp16 + m.sp2)
                VStack(alignment: .leading, spacing: m.sp2) {
                    // The reminder shares the conversation's line, so setting one never changes the row's height.
                    HStack(spacing: m.sp8) {
                        Text(location).font(m.font(.subheadline, .semibold)).foregroundStyle(colors.textSecondary)
                        if let remindAt = reference.remindAt { DueLabel(date: remindAt) }
                    }.lineLimit(1).frame(height: m.sp16)
                    HStack(alignment: .firstTextBaseline, spacing: m.sp8) {
                        Text(message?.senderName ?? "Placeholder name").font(m.font(.reading, .semibold))
                            .foregroundStyle(colors.textPrimary)
                        Text(
                            message?.timestamp ?? reference.savedAt,
                            format: .dateTime.month(.abbreviated).day().hour().minute()
                        ).font(m.font(.subheadline)).foregroundStyle(colors.textSecondary)
                    }.lineLimit(1)
                    content
                }
                // Room for the actions that show on hover, so they never cover the text.
                .padding(.trailing, m(120)).frame(maxWidth: .infinity, alignment: .leading)
            }
            // Until the message arrives, its outline holds the row's place.
            .redacted(reason: message == nil && error == nil ? .placeholder : [])
            .padding(m.sp12)
            .background(hovered ? colors.hover : .clear, in: RoundedRectangle(cornerRadius: m.radius))
            .contentShape(Rectangle())
        }.buttonStyle(.row).disabled(room?.membership != "join")
            .overlay(alignment: .topTrailing) {
                if hovered { toolbar.padding(.trailing, m.sp12).padding(.top, m.sp12) }
            }
            // After the overlay, so the pointer on the actions still hovers the row.
            .onHover { hovered = $0 }
            .accessibilityActions {
                ForEach(commands, id: \.title) { command in Button(command.title, action: command.run) }
                if reference.laterState == .inProgress {
                    ForEach(ReminderPreset.allCases, id: \.self) { preset in
                        Button("Remind me \(preset.title.lowercased())") {
                            actions.remind(reference, preset.date(from: Date()))
                        }
                    }
                }
                Button("Remove from Later") { actions.remove(reference) }
            }
            .task(id: retry) { await load() }
            .onDisappear {
                message = nil
                error = nil
            }
    }

    private struct Command {
        let title: String
        let symbol: String
        let run: () -> Void
    }

    /// The tab's own actions, first on the toolbar and for VoiceOver.
    private var commands: [Command] {
        switch reference.laterState {
        case .inProgress:
            [
                Command(title: "Mark complete", symbol: "checkmark") { actions.move(reference, .completed) },
                Command(title: "Archive", symbol: "archivebox") { actions.move(reference, .archived) },
            ]
        case .archived:
            [
                Command(title: "Move to In progress", symbol: "arrow.uturn.backward") {
                    actions.move(reference, .inProgress)
                }
            ]
        case .completed:
            [Command(title: "Mark incomplete", symbol: "arrow.uturn.backward") { actions.move(reference, .inProgress) }]
        }
    }

    private var toolbar: some View {
        ToolbarCapsule {
            if let primary = commands.first {
                IconButton(symbol: primary.symbol, label: primary.title, role: .body, action: primary.run)
            }
            if reference.laterState == .inProgress {
                let title = reference.remindAt == nil ? "Remind me" : "Edit reminder"
                Menu {
                    ForEach(ReminderPreset.allCases, id: \.self) { preset in
                        Button(preset.title) { actions.remind(reference, preset.date(from: Date())) }
                    }
                    Divider()
                    Button("Custom…", action: onCustomReminder)
                    if reference.remindAt != nil { Button("Clear reminder") { actions.remind(reference, nil) } }
                } label: {
                    icon("clock")
                }.menuStyle(.button).buttonStyle(.icon).menuIndicator(.hidden).help(title).accessibilityLabel(title)
            }
            Menu {
                ForEach(commands.dropFirst(), id: \.title) { command in Button(command.title, action: command.run) }
                Button("Remove from Later") { actions.remove(reference) }
            } label: {
                icon("ellipsis")
            }.menuStyle(.button).buttonStyle(.icon).menuIndicator(.hidden).help("More actions")
                .accessibilityLabel("More actions")
        }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(m.font(.body)).frame(width: m.iconButton, height: m.iconButton)
    }

    @ViewBuilder private var content: some View {
        if let message {
            if message.isRedacted {
                Text("This message was deleted.").italic().foregroundStyle(colors.textSecondary)
            } else {
                // A text view keeps clicks for selecting; here a click anywhere opens the message, as in Slack.
                NativeMessageBody(body: message.body, formattedBody: message.formattedBody, showsSpoilerControl: false)
                    .lineLimit(3).allowsHitTesting(false)
                if let attachment = message.attachment {
                    Label(attachment.name, systemImage: "paperclip").font(m.font(.subheadline))
                        .foregroundStyle(colors.textSecondary).lineLimit(1)
                }
            }
        } else if let error {
            HStack(spacing: m.sp8) {
                Text(error).foregroundStyle(colors.textSecondary)
                Button("Retry") { retry = UUID() }.buttonStyle(.textLink)
            }.font(m.font(.subheadline))
        } else {
            Text("Placeholder for the message while it loads").font(m.font(.reading))
        }
    }

    private func load() async {
        error = nil
        message = nil
        do {
            let current: ChatMessage
            if matrix.isPreview {
                guard
                    let sample = (matrix.messages + matrix.threadMessages).first(where: {
                        $0.roomID == reference.roomID && $0.eventID == reference.eventID
                    })
                else { throw MatrixServiceError.noRoom }
                current = sample
            } else {
                current = try await matrix.messagePreview(roomID: reference.roomID, eventID: reference.eventID)
            }
            guard !Task.isCancelled else { return }
            message = current
        } catch {
            guard !Task.isCancelled else { return }
            self.error = MatrixService.safeError(error)
        }
    }
}
