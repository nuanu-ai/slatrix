import AppKit
import SwiftUI

enum Presence {
    case active, away
}

/// A person's or conversation's photo over its initials, as a rounded square.
struct AvatarView: View {
    /// Above this side a 128 px thumbnail looks soft, so a larger one replaces it once loaded.
    private static let largeSide: CGFloat = 64
    let name: String
    var size: CGFloat = 36
    /// Green dot when active, a hollow ring when away; nothing when unknown.
    var presence: Presence? = nil
    /// The surface the avatar sits on, for the ring that separates the presence dot from the photo.
    var surface: Color? = nil
    var matrix: MatrixService? = nil
    var source: String? = nil
    @State private var loaded: Loaded?
    @EnvironmentObject private var appearance: AppearanceStore
    private struct RequestID: Hashable {
        let userID: String?
        let source: String?
        let large: Bool
    }
    private struct Loaded {
        let request: RequestID
        let image: CGImage
    }
    private var large: Bool { size > Self.largeSide }
    private var requestID: RequestID { RequestID(userID: matrix?.user?.id, source: source, large: large) }
    private var largeKey: String? { source.map { "\($0)#large" } }
    private var cached: CGImage? {
        guard let matrix, let source, !matrix.isPreview else { return nil }
        let images = matrix.avatarImages
        return (large ? largeKey.flatMap(images.cachedImage) : nil) ?? images.cachedImage(for: source)
    }
    var body: some View {
        let image = loaded?.request == requestID ? loaded?.image : cached
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size * 0.19).fill(avatarColor(name))
                .overlay(
                    // Initials scale with the tile, not with a text role.
                    Text(initials(name)).font(Font(NSFont.systemFont(ofSize: size * 0.35, weight: .semibold) as CTFont))
                        .foregroundStyle(.white)
                )
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                            .frame(width: size, height: size).clipped().transition(.opacity)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: size * 0.19))
            if let presence {
                let colors = appearance.colors
                let ring = surface ?? colors.canvas
                Circle().fill(presence == .active ? colors.presenceActive : ring)
                    .overlay {
                        if presence == .away {
                            Circle().strokeBorder(colors.presenceAway, lineWidth: max(1.5, size * 0.05))
                        }
                    }
                    .frame(width: size * 0.28, height: size * 0.28)
                    .overlay(Circle().stroke(ring, lineWidth: 2)).offset(x: size * 0.06, y: size * 0.06)
                    .accessibilityHidden(true)
            }
        }.frame(width: size, height: size).accessibilityLabel(name)
            .task(id: requestID) {
                let request = requestID
                guard let matrix, let source, !matrix.isPreview else { return }
                let images = matrix.avatarImages
                let key = large ? largeKey ?? source : source
                guard images.cachedImage(for: key) == nil else { return }
                let side: UInt64 = large ? 512 : 128
                let image = await images.image(for: key) { try await matrix.avatarThumbnail(source, side: side) }
                guard !Task.isCancelled, let image else { return }
                // Only a photo that was not cached fades in over its initials; a cached one is on the first frame.
                withAnimation(Motion.content) { loaded = Loaded(request: request, image: image) }
            }
    }
}
