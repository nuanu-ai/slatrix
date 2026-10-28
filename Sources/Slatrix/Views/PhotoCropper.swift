import AppKit
import SwiftUI

/// Slack's Crop your photo: the picked photo with a square frame to drag, resized from its corners, and the rest of
/// the photo dimmed. Save hands back the frame in the photo's pixels.
struct PhotoCropper: View {
    let image: CGImage
    let onCancel: () -> Void
    let onSave: (CGRect) -> Void
    @State private var crop: CGRect
    /// At 100% zoom, so a tall photo leaves the window room around the modal.
    private static let maxHeight: CGFloat = 400
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    init(image: CGImage, onCancel: @escaping () -> Void, onSave: @escaping (CGRect) -> Void) {
        self.image = image
        self.onCancel = onCancel
        self.onSave = onSave
        _crop = State(initialValue: PhotoCrop.centered(in: CGSize(width: image.width, height: image.height)))
    }

    var body: some View {
        Modal(
            title: "Crop your photo", onClose: onCancel, secondary: ModalAction("Cancel", action: onCancel),
            primary: ModalAction("Save") { onSave(crop) }
        ) {
            // As wide as the medium modal's body.
            let scale = min(
                (m.modalMedium - 2 * m.sp24) / CGFloat(image.width), m(Self.maxHeight) / CGFloat(image.height))
            frame(scale: scale)
                .frame(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Crop area")
        }
    }

    /// The photo at `scale` points per pixel, with the frame over it.
    private func frame(scale: CGFloat) -> some View {
        let colors = appearance.colors
        let square = CGRect(
            x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)
        let mark = m.sp4
        return ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1).resizable()
            GeometryReader { proxy in
                Path {
                    $0.addRect(CGRect(origin: .zero, size: proxy.size))
                    $0.addRect(square)
                }.fill(colors.mediaShade, style: FillStyle(eoFill: true))
            }
            Rectangle().strokeBorder(colors.onMedia, lineWidth: 1)
                .frame(width: square.width, height: square.height).offset(x: square.minX, y: square.minY)
            // An L inside each corner, so none hangs off the photo.
            Path { path in
                for corner in PhotoCrop.Corner.allCases {
                    let x = corner.right ? square.maxX - mark / 2 : square.minX + mark / 2
                    let y = corner.bottom ? square.maxY - mark / 2 : square.minY + mark / 2
                    path.move(to: CGPoint(x: x + (corner.right ? -1 : 1) * m.sp16, y: y))
                    path.addLine(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x, y: y + (corner.bottom ? -1 : 1) * m.sp16))
                }
            }.stroke(colors.onMedia, lineWidth: mark)
            CropSurface(crop: crop, image: image, scale: scale, grab: m.sp16) { crop = $0 }
        }
    }
}

/// Takes the mouse over the photo: a drag inside the frame moves it, one from a corner resizes it.
private struct CropSurface: NSViewRepresentable {
    let crop: CGRect
    let image: CGImage
    let scale: CGFloat
    /// The side of the square around each corner that grabs it, in points.
    let grab: CGFloat
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> CropSurfaceView {
        let view = CropSurfaceView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: CropSurfaceView, context: Context) {
        if view.crop != crop || view.scale != scale { view.window?.invalidateCursorRects(for: view) }
        view.crop = crop
        view.size = CGSize(width: image.width, height: image.height)
        view.scale = scale
        view.grab = grab
        view.onChange = onChange
    }
}

final class CropSurfaceView: NSView {
    var crop = CGRect.zero
    var size = CGSize.zero
    var scale: CGFloat = 1
    var grab: CGFloat = 16
    var onChange: (CGRect) -> Void = { _ in }
    /// The frame and the point where the drag began, and the corner it holds, if any.
    private var drag: (crop: CGRect, start: CGPoint, corner: PhotoCrop.Corner?)?

    override var isFlipped: Bool { true }
    // The window moves by its background; without this the window server takes the drag and no mouseDragged arrives.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var square: CGRect {
        CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)
    }

    private func corner(_ corner: PhotoCrop.Corner) -> CGRect {
        CGRect(
            x: (corner.right ? square.maxX : square.minX) - grab / 2,
            y: (corner.bottom ? square.maxY : square.minY) - grab / 2, width: grab, height: grab)
    }

    override func resetCursorRects() {
        addCursorRect(square, cursor: .openHand)
        guard #available(macOS 15, *) else { return }
        for (corner, position) in [
            (PhotoCrop.Corner.topLeft, NSCursor.FrameResizePosition.topLeft), (.topRight, .topRight),
            (.bottomLeft, .bottomLeft), (.bottomRight, .bottomRight),
        ] {
            addCursorRect(self.corner(corner), cursor: .frameResize(position: position, directions: .all))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let corner = PhotoCrop.Corner.allCases.first { self.corner($0).contains(point) }
        guard corner != nil || square.contains(point) else { return }
        drag = (crop, point, corner)
        if corner == nil { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let offset = CGSize(width: (point.x - drag.start.x) / scale, height: (point.y - drag.start.y) / scale)
        onChange(
            drag.corner.map { PhotoCrop.resized(drag.crop, from: $0, by: offset, in: size) }
                ?? PhotoCrop.moved(drag.crop, by: offset, in: size))
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        window?.invalidateCursorRects(for: self)
    }
}
