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

    /// A bar over the `edge` of content that scrolls under it. A header is `canvas`, ruled off by the timeline once
    /// messages pass under it, so nothing ends half cut at an edge no one can see. From macOS 26 a composer's bar lets
    /// the content show through its inner edge and fade toward the window's, as Apple's scroll edge effect fades it, so
    /// the composer's glass shows what passes under it; before, it is `canvas` too.
    @ViewBuilder func scrollEdge(_ edge: VerticalEdge, _ canvas: Color) -> some View {
        if #available(macOS 26, *), edge == .bottom {
            background {
                LinearGradient(
                    stops: [.init(color: canvas, location: 0.3), .init(color: canvas.opacity(0), location: 0.6)],
                    startPoint: .bottom, endPoint: .top
                ).allowsHitTesting(false)
            }
        } else {
            background(canvas)
        }
    }

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

/// The floating sidebar panel's surface: native macOS sidebar vibrancy under a tint for Glass, a built-in vertical
/// gradient for colored themes, or a flat opaque fill for Neutral and Sand.
struct SidebarBackground: View {
    let colors: AppColors
    var cornerRadius: CGFloat = 0
    /// In the narrow-window drawer over a dimmed conversation, blur within the window instead of punching through to
    /// the desktop behind it.
    var inDrawer = false

    var body: some View {
        if colors.translucentSidebar {
            SidebarMaterial(cornerRadius: cornerRadius, blendingMode: inDrawer ? .withinWindow : .behindWindow)
                .overlay(colors.sidebar)
        } else if colors.coloredSidebar {
            // Mostly downward, so the floating sidebar island carries a subtle vertical drift.
            LinearGradient(
                stops: [
                    .init(color: colors.sidebar, location: 0.1),
                    .init(color: colors.sidebarEnd, location: 0.9),
                ],
                startPoint: UnitPoint(x: 0.4, y: 0), endPoint: UnitPoint(x: 0.6, y: 1))
        } else {
            colors.sidebar
        }
    }
}

/// Apple's sidebar material, letting the desktop (or in-window backdrop in the drawer) show through and dimming while
/// the window is inactive, masked to `cornerRadius` so vibrancy never bleeds outside the floating panel's corners.
private struct SidebarMaterial: NSViewRepresentable {
    var cornerRadius: CGFloat = 0
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    final class MaskedVisualEffectView: NSVisualEffectView {
        var appliedCornerRadius: CGFloat = -1
    }

    func makeNSView(context: Context) -> MaskedVisualEffectView {
        let view = MaskedVisualEffectView()
        (view.material, view.blendingMode, view.state) = (.sidebar, blendingMode, .followsWindowActiveState)
        applyMask(to: view)
        return view
    }

    func updateNSView(_ view: MaskedVisualEffectView, context: Context) {
        if view.blendingMode != blendingMode { view.blendingMode = blendingMode }
        applyMask(to: view)
    }

    private func applyMask(to view: MaskedVisualEffectView) {
        guard view.appliedCornerRadius != cornerRadius else { return }
        view.appliedCornerRadius = cornerRadius
        guard cornerRadius > 0 else {
            view.maskImage = nil
            return
        }
        let side = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        view.maskImage = image
    }
}
