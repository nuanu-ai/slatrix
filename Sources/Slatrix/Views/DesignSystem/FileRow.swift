import SwiftUI

/// A file in a list, as Slack's Files browser shows it: a 40 pt tile, the name, a muted line such as "Shared by Alice
/// in #design · Oct 24", and on hover or keyboard focus a download button and a ⋮ menu. A click opens it.
struct FileRow<Menu: View>: View {
    private enum Focus { case row, download, menu }
    private static var tileSide: CGFloat { 40 }
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    let tile: FileRowTile
    let name: String
    let caption: String
    var downloading = false
    /// Nil leaves out the download button, for a row without a file.
    var onDownload: (() -> Void)?
    @State var hovering = false
    let onOpen: () -> Void
    @ViewBuilder let menu: () -> Menu
    @FocusState private var focus: Focus?

    var body: some View {
        let colors = appearance.colors
        Button(action: onOpen) {
            HStack(spacing: m.sp12) {
                tileView
                VStack(alignment: .leading, spacing: m.sp2) {
                    Text(name).font(m.font(.body, .semibold)).foregroundStyle(colors.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(caption).font(m.font(.secondary)).foregroundStyle(colors.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, m.sp12).padding(.vertical, m.sp8)
            .background(hovering ? colors.hover : .clear, in: RoundedRectangle(cornerRadius: m.radiusLarge))
        }
        .buttonStyle(.row).focused($focus, equals: .row).help(name)
        .accessibilityActions { if let onDownload { Button("Download", action: onDownload) } }
        .overlay(alignment: .trailing) {
            if hovering || downloading || focus != nil { actions.padding(.trailing, m.sp12) }
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var tileView: some View {
        let colors = appearance.colors
        let shape = RoundedRectangle(cornerRadius: m.radius)
        switch tile {
        case .thumbnail(let image):
            shape.fill(colors.sunken)
                .overlay {
                    if let image { Image(decorative: image, scale: 1).resizable().scaledToFill().transition(.opacity) }
                }
                .frame(width: m(Self.tileSide), height: m(Self.tileSide)).clipShape(shape)
                .overlay(shape.strokeBorder(colors.border)).animation(Motion.content, value: image != nil)
        case .file(let kind): FileTypeIcon(kind: kind, side: Self.tileSide)
        case .link:
            shape.fill(colors.sunken)
                .overlay {
                    Image(systemName: "link").font(m.font(.title, .semibold)).foregroundStyle(colors.textSecondary)
                }
                .frame(width: m(Self.tileSide), height: m(Self.tileSide))
        }
    }

    private var actions: some View {
        let colors = appearance.colors
        let side = MessageToolbar.button
        return HStack(spacing: 0) {
            if downloading {
                DelayedProgress().frame(width: m(side), height: m(side))
            } else if let onDownload {
                IconButton(symbol: "arrow.down.to.line", label: "Download", role: .body, side: side, action: onDownload)
                    .focused($focus, equals: .download)
            }
            SwiftUI.Menu(content: menu) {
                Image(systemName: "ellipsis").font(m.font(.body)).frame(width: m(side), height: m(side))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: m(side)).help("More actions")
                .focused($focus, equals: .menu)
        }.padding(.horizontal, m.sp2).frame(height: m(side))
            .background(colors.overlay, in: RoundedRectangle(cornerRadius: m.radius))
            .overlay(RoundedRectangle(cornerRadius: m.radius).stroke(colors.border))
            .elevation(.e1, cornerRadius: m.radius)
    }
}

/// What leads a file row.
enum FileRowTile {
    /// An image or video still; empty until it loads.
    case thumbnail(CGImage?)
    case file(FileKind)
    case link
}
