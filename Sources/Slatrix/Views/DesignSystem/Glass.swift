import SwiftUI

extension View {
    /// Chrome that floats over content, as Apple's own apps draw it: Liquid Glass from macOS 26, and before that
    /// `fallback`, lifted with a shadow when `elevated`. The glass sits behind the content rather than wrapping it,
    /// since AppKit finds drop targets through the wrapper's view and would miss the text views inside.
    @ViewBuilder func glass(_ fallback: Color, in shape: some Shape, cornerRadius: CGFloat, elevated: Bool = true)
        -> some View
    {
        if #available(macOS 26, *) {
            background { Color.clear.glassEffect(.regular, in: shape) }
        } else if elevated {
            background(fallback, in: shape).elevation(.e1, cornerRadius: cornerRadius)
        } else {
            background(fallback, in: shape)
        }
    }

    /// A bar over the `edge` of content that scrolls under it. From macOS 26 the content shows through the bar's inner
    /// edge and fades out toward the window's, as Apple's scroll edge effect fades it: a header's title and a
    /// composer's bottom margin stay on the plain canvas, and the composer's glass shows what passes under it. Before
    /// macOS 26 the bar is `canvas`.
    @ViewBuilder func scrollEdge(_ edge: VerticalEdge, _ canvas: Color) -> some View {
        if #available(macOS 26, *) {
            let top = edge == .top
            background {
                LinearGradient(
                    stops: [
                        .init(color: canvas, location: top ? 0.85 : 0.3),
                        .init(color: canvas.opacity(0), location: top ? 1 : 0.6),
                    ],
                    startPoint: top ? .top : .bottom, endPoint: top ? .bottom : .top
                ).allowsHitTesting(false)
            }
        } else {
            background(canvas)
        }
    }
}
