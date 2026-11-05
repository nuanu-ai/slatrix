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
}
