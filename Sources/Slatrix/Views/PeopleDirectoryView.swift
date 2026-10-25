import SwiftUI

struct PeopleAccountIdentity: Hashable {
    var userID: String?
    var isPreview: Bool
}

struct PeopleDirectoryView: View {
    private static let searchHeight: CGFloat = 40
    @Environment(\.metrics) private var m
    @ObservedObject var matrix: MatrixService
    @ObservedObject var people: PeopleService
    var onOpenProfile: (String, ChatUser?) -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var query = ""
    @State private var selectedID: String?
    @State private var retryRevision = 0
    @State private var activeRequest: SearchRequest?
    @FocusState private var searchFocused: Bool
    private var colors: AppColors { appearance.colors }
    private var account: PeopleAccountIdentity {
        PeopleAccountIdentity(userID: matrix.user?.id, isPreview: matrix.isPreview)
    }
    private var results: [PersonProfile] { activeRequest == request ? people.results : [] }
    private var selection: String? { results.first(where: { $0.id == selectedID })?.id ?? results.first?.id }
    private var exactID: String? { try? PeopleMapping.validatedID(query) }
    private struct SearchRequest: Hashable {
        var query: String
        var account: PeopleAccountIdentity
        var retry: Int
    }
    private var request: SearchRequest { SearchRequest(query: query, account: account, retry: retryRevision) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: m.sp12) {
                HStack(spacing: m.sp12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(colors.muted)
                    TextField("Search people", text: $query).textFieldStyle(.plain).font(
                        m.font(.body)
                    ).focused($searchFocused)
                        .onSubmit(openSelected)
                        .onKeyPress(.upArrow) { move(-1) }
                        .onKeyPress(.downArrow) { move(1) }
                        .accessibilityLabel("Search people")
                    if people.searchState == "loading" {
                        ProgressView().controlSize(.small).accessibilityLabel("Searching people").loadingInterval(
                            .peopleLoading)
                    }
                    if !query.isEmpty {
                        IconButton(symbol: "xmark.circle.fill", label: "Clear search", role: .body) {
                            query = ""
                            searchFocused = true
                        }
                    }
                }.padding(.horizontal, m.sp12).frame(height: m(Self.searchHeight)).background(
                    colors.raised, in: RoundedRectangle(cornerRadius: m.radiusLarge)
                ).overlay(RoundedRectangle(cornerRadius: m.radiusLarge).stroke(colors.border))
            }.padding(.horizontal, m.sp24).padding(.vertical, m.sp20)
            Divider().overlay(colors.border)
            directoryResults
        }.background(colors.canvas)
            .onAppear { searchFocused = true }
            .onChange(of: query) { _, _ in selectedID = nil }
            .onChange(of: account) { _, _ in
                query = ""
                selectedID = nil
                people.cancelSearch()
            }
            .onDisappear { people.cancelSearch() }
            .task(id: request) {
                let submitted = request
                activeRequest = submitted
                await people.search(submitted.query)
            }
    }

    @ViewBuilder private var directoryResults: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyStateView(symbol: "person.2", title: matrix.isPreview ? "Sign in to find people" : "Search for people")
        } else if (people.searchState == "loading" || activeRequest != request) && results.isEmpty {
            VStack(spacing: m.sp12) {
                ProgressView().loadingInterval(.peopleLoading)
                Text("Searching people…").font(m.font(.secondary)).foregroundStyle(colors.muted)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if people.searchState == "error" && results.isEmpty {
            EmptyStateView(
                symbol: "exclamationmark.circle", title: people.searchErrorMessage ?? "Couldn’t search. Try again."
            ) {
                HStack(spacing: m.sp16) {
                    Button("Try again") { retry() }
                    if let id = exactID { Button("View profile") { onOpenProfile(id, nil) } }
                }
            }
        } else if results.isEmpty {
            EmptyStateView(
                symbol: "person.crop.circle.badge.questionmark",
                title: people.searchState == "idle" ? "Search is paused" : "No people found"
            ) {
                if people.searchState == "idle" {
                    Button("Search again") { retry() }
                } else if let id = exactID {
                    Button("View profile") { onOpenProfile(id, nil) }
                }
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("PEOPLE").font(m.font(.caption, .semibold)).tracking(0.7)
                            Spacer()
                            if people.limited { Text("Showing top results").font(m.font(.caption)) }
                        }.foregroundStyle(colors.muted).padding(.horizontal, m.sp24).padding(.top, m.sp20).padding(
                            .bottom, m.sp12)
                        ForEach(results) { person in
                            Button {
                                open(person)
                            } label: {
                                PersonDirectoryRow(matrix: matrix, person: person, selected: selection == person.id)
                            }.buttonStyle(.row).id(person.id)
                            Divider().overlay(colors.border).padding(.leading, m.sp24 + m.avatar + m.sp12)
                        }
                    }.padding(.bottom, m.sp16)
                }
                .onChange(of: selection) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }

    private func open(_ person: PersonProfile) {
        let fallback =
            person.profileAvailable ? ChatUser(id: person.id, name: person.name, avatarURL: person.avatarURL) : nil
        onOpenProfile(person.id, fallback)
    }
    private func openSelected() {
        if let person = results.first(where: { $0.id == selection }) {
            open(person)
        } else if let id = exactID {
            onOpenProfile(id, nil)
        }
    }
    private func move(_ direction: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        let index = results.firstIndex(where: { $0.id == selection }) ?? 0
        selectedID = results[(index + direction + results.count) % results.count].id
        return .handled
    }
    private func retry() { retryRevision += 1 }
}

private struct PersonDirectoryRow: View {
    @Environment(\.metrics) private var m
    @ObservedObject var matrix: MatrixService
    var person: PersonProfile
    var selected = false
    @EnvironmentObject private var appearance: AppearanceStore
    private var colors: AppColors { appearance.colors }
    var body: some View {
        HStack(spacing: m.sp12) {
            AvatarView(name: person.name, size: m.avatar, matrix: matrix, source: person.avatarURL)
            VStack(alignment: .leading, spacing: m.sp4) {
                Text(person.name).font(m.font(.body, .semibold)).foregroundStyle(colors.primaryText)
                    .lineLimit(1)
                Text(person.id).font(m.font(.caption)).foregroundStyle(colors.muted).lineLimit(1)
                if !person.profileAvailable {
                    Text("No public profile").font(m.font(.caption)).foregroundStyle(
                        colors.muted)
                }
            }
            Spacer()
            Image(systemName: selected ? "return" : "chevron.right").font(m.font(.caption)).foregroundStyle(
                colors.muted)
        }.padding(.horizontal, m.sp24).padding(.vertical, m.sp16).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? colors.selection.opacity(0.4) : .clear).contentShape(Rectangle())
            .accessibilityElement(children: .combine).accessibilityLabel("View profile, \(person.name), \(person.id)")
    }
}

struct PersonRecipientPicker: View {
    private static let resultsMaxHeight: CGFloat = 176
    @Environment(\.metrics) private var m
    @ObservedObject var matrix: MatrixService
    @ObservedObject var people: PeopleService
    @Binding var recipientID: String
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var query = ""
    @State private var chosen: PersonProfile?
    @State private var selectedID: String?
    @State private var retryRevision = 0
    @State private var activeRequest: Request?
    @FocusState private var focused: Bool
    private var colors: AppColors { appearance.colors }
    private var account: PeopleAccountIdentity {
        PeopleAccountIdentity(userID: matrix.user?.id, isPreview: matrix.isPreview)
    }
    private struct Request: Hashable {
        var query: String
        var account: PeopleAccountIdentity
        var retry: Int
    }
    private var request: Request { Request(query: query, account: account, retry: retryRevision) }
    private var results: [PersonProfile] { activeRequest == request ? people.results : [] }
    private var selection: String? { results.first(where: { $0.id == selectedID })?.id ?? results.first?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: m.sp8) {
            Text("To").font(m.font(.secondary, .semibold))
            if let chosen {
                HStack(spacing: m.sp8) {
                    AvatarView(name: chosen.name, size: m.avatar, matrix: matrix, source: chosen.avatarURL)
                    VStack(alignment: .leading, spacing: m.sp4) {
                        Text(chosen.name).font(m.font(.secondary, .medium))
                        Text(chosen.id).font(m.font(.caption)).foregroundStyle(colors.muted)
                    }
                    Spacer()
                    IconButton(symbol: "xmark", label: "Remove recipient", role: .caption) {
                        self.chosen = nil
                        recipientID = ""
                        query = ""
                        focused = true
                    }
                }.padding(m.sp8).background(colors.raised, in: RoundedRectangle(cornerRadius: m.radius)).overlay(
                    RoundedRectangle(cornerRadius: m.radius).stroke(colors.border))
                if !chosen.profileAvailable {
                    Text("No public profile; check the ID.").font(m.font(.caption))
                        .foregroundStyle(colors.muted)
                }
            } else {
                HStack(spacing: m.sp8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(colors.muted)
                    TextField("Name or @name:server.org", text: $query).textFieldStyle(.plain).font(m.font(.body))
                        .focused($focused)
                        .onSubmit(selectCurrent)
                        .onKeyPress(.upArrow) { move(-1) }.onKeyPress(.downArrow) { move(1) }
                        .onKeyPress(.return) {
                            selectCurrent()
                            return .handled
                        }
                        .accessibilityLabel("Search and select a recipient")
                    if people.searchState == "loading" {
                        ProgressView().controlSize(.small).loadingInterval(.peopleLoading)
                    }
                }.padding(m.sp12).background(colors.raised, in: RoundedRectangle(cornerRadius: m.radius)).overlay(
                    RoundedRectangle(cornerRadius: m.radius).stroke(colors.muted.opacity(0.5)))
                if !query.isEmpty {
                    if people.searchState == "error" {
                        HStack(spacing: m.sp8) {
                            Text(people.searchErrorMessage ?? "Couldn’t search.")
                            Button("Retry") { retryRevision += 1 }.buttonStyle(.link)
                        }.font(m.font(.caption)).foregroundStyle(colors.muted)
                    }
                    if !results.isEmpty {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(results) { person in
                                        Button {
                                            select(person)
                                        } label: {
                                            HStack(spacing: m.sp8) {
                                                AvatarView(
                                                    name: person.name, size: m.avatarMedium, matrix: matrix,
                                                    source: person.avatarURL)
                                                VStack(alignment: .leading, spacing: m.sp4) {
                                                    Text(person.name).font(m.font(.meta, .medium))
                                                    Text(person.id).font(m.font(.caption)).foregroundStyle(
                                                        colors.muted
                                                    ).lineLimit(1)
                                                }
                                                Spacer()
                                                if person.id == selection {
                                                    Image(systemName: "return").font(m.font(.caption)).foregroundStyle(
                                                        colors.muted)
                                                }
                                            }.padding(m.sp8).frame(maxWidth: .infinity, alignment: .leading).background(
                                                person.id == selection ? colors.selection.opacity(0.4) : .clear
                                            ).contentShape(Rectangle())
                                        }.buttonStyle(.row).id(person.id).accessibilityLabel(
                                            "Select \(person.name), \(person.id)")
                                    }
                                }
                            }.frame(maxHeight: m(Self.resultsMaxHeight)).background(
                                colors.raised, in: RoundedRectangle(cornerRadius: m.radius)
                            )
                            .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                        }
                    } else if people.searchState == "ready" {
                        Text("No matches. Enter a full ID like @name:server.org.").font(m.font(.caption))
                            .foregroundStyle(colors.muted)
                    }
                }
            }
        }
        .onAppear {
            query = recipientID
            focused = true
        }
        .onChange(of: query) { _, value in
            if chosen == nil { recipientID = (try? PeopleMapping.validatedID(value)) ?? "" }
            selectedID = nil
        }
        .onChange(of: account) { _, _ in
            chosen = nil
            query = ""
            recipientID = ""
            people.cancelSearch()
        }
        .onDisappear { people.cancelSearch() }
        .task(id: request) {
            if chosen == nil {
                let submitted = request
                activeRequest = submitted
                await people.search(submitted.query)
            }
        }
    }

    private func select(_ person: PersonProfile) {
        chosen = person
        recipientID = person.id
        people.cancelSearch()
    }
    private func selectCurrent() { if let person = results.first(where: { $0.id == selection }) { select(person) } }
    private func move(_ direction: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        let index = results.firstIndex(where: { $0.id == selection }) ?? 0
        selectedID = results[(index + direction + results.count) % results.count].id
        return .handled
    }
}
