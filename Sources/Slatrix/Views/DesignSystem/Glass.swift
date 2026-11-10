import AppKit
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

    /// In a frame theme, the conversation and its panes as a card on the frame, inset as the sidebar is; `leading`
    /// insets that edge too while no sidebar sits beside it. Elsewhere it changes nothing, and switching keeps the
    /// conversation as it is.
    func frameCard(_ framed: Bool, leading: Bool) -> some View { modifier(FrameCard(framed: framed, leading: leading)) }

    /// Fades this view out over `height` at its bottom edge, into whatever lies behind it.
    func fadeOut(bottom height: CGFloat) -> some View {
        mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: height)
            }
        }
    }
}

/// The window behind the sidebar and the conversation: the canvas, or a frame theme's frame, fading into a
/// neighboring hue with the window gradient. Glass is the system's sidebar material under the theme's tint.
struct FrameBackground: View {
    let colors: AppColors
    let gradient: Bool

    var body: some View {
        if colors.translucentFrame {
            SidebarMaterial().overlay(colors.frame)
        } else {
            // Mostly downward, so the sidebar carries the drift.
            LinearGradient(
                stops: [
                    .init(color: colors.frame, location: 0.1),
                    .init(color: gradient ? colors.frameEnd : colors.frame, location: 0.9),
                ],
                startPoint: UnitPoint(x: 0.4, y: 0), endPoint: UnitPoint(x: 0.6, y: 1))
        }
    }
}

/// Apple's sidebar material, which lets the desktop through and dims while the window is inactive.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        (view.material, view.blendingMode, view.state) = (.sidebar, .behindWindow, .followsWindowActiveState)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct FrameCard: ViewModifier {
    let framed: Bool
    let leading: Bool
    @ThemeColors private var colors
    @Environment(\.metrics) private var m

    func body(content: Content) -> some View {
        let inset = framed ? m.sidebarInset : 0
        content.background(colors.canvas).clipShape(RoundedRectangle(cornerRadius: framed ? m.radiusLarge : 0))
            .padding([.vertical, .trailing], inset).padding(.leading, leading ? inset : 0)
    }
}
