import AppKit
import SwiftUI

/// A person's photo over their initials, as a circle; a space or channel passes a corner radius for a rounded square.
struct AvatarView: View {
    /// Above this side a 128 px thumbnail looks soft, so a larger one replaces it once loaded.
    private static let largeSide: CGFloat = 64
    let name: String
    var size: CGFloat = 36
    /// Green dot when active, a hollow ring when away; nothing when unknown. A gap cut from the photo separates it,
    /// so whatever the avatar sits on shows through: a row's hover, the sidebar, a frame's gradient.
    var presence: Presence? = nil
    /// A rounded square's corners, for spaces and channels; nil draws a person's circle.
    var cornerRadius: CGFloat? = nil
    var matrix: MatrixService? = nil
    var source: String? = nil
    @State private var loaded: Loaded?
    @ThemeColors private var colors
    private struct RequestID: Hashable {
        let userID: String?
        let source: String?
        let large: Bool
    }
    private struct Loaded {
        let request: RequestID
        let image: CGImage
    }
    private var radius: CGFloat { cornerRadius ?? size / 2 }
    private var dot: CGFloat { size * 0.28 }
    private var shift: CGFloat { size * 0.06 }
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
            RoundedRectangle(cornerRadius: radius).fill(avatarColor(name))
                .overlay(
                    // Initials scale with the tile, not with a text role.
                    Text(initials(name)).font(
                        Font(NSFont.systemFont(ofSize: size * (large ? 0.25 : 0.35), weight: .semibold) as CTFont)
                    )
                    .foregroundStyle(.white)
                )
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                            .frame(width: size, height: size).clipped().transition(.opacity)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: radius))
                .mask {
                    Rectangle().overlay(alignment: .bottomTrailing) {
                        if presence != nil {
                            Circle().frame(width: dot + 2, height: dot + 2).offset(x: shift + 1, y: shift + 1)
                                .blendMode(.destinationOut)
                        }
                    }.compositingGroup()
                }
            if let presence {
                Group {
                    if presence == .active {
                        Circle().fill(colors.presenceActive)
                    } else {
                        Circle().strokeBorder(colors.presenceAway, lineWidth: max(1.5, size * 0.05) - 1)
                    }
                }
                .frame(width: dot - 2, height: dot - 2).offset(x: shift - 1, y: shift - 1).accessibilityHidden(true)
            }
        }.frame(width: size, height: size).accessibilityLabel(name)
            .task(id: requestID) {
                let request = requestID
                let started = ContinuousClock.now
                guard let matrix, let source, !matrix.isPreview else { return }
                let images = matrix.avatarImages
                let key = large ? largeKey ?? source : source
                guard images.cachedImage(for: key) == nil else { return }
                let side = large ? 512 : 128
                let image = await images.image(for: key, pixels: side) {
                    try await matrix.avatarThumbnail(source, side: UInt64(side))
                }
                guard !Task.isCancelled, let image else { return }
                withAnimation(Motion.arrival(since: started)) { loaded = Loaded(request: request, image: image) }
            }
    }
}
