import SwiftUI

extension View {
    /// Chrome that floats over content, as Apple's own apps draw it: Liquid Glass from macOS 26, and before that
    /// `fallback`, lifted with a shadow when `elevated`.
    @ViewBuilder func glass(_ fallback: Color, in shape: some Shape, cornerRadius: CGFloat, elevated: Bool = true)
        -> some View
    {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else if elevated {
            background(fallback, in: shape).elevation(.e1, cornerRadius: cornerRadius)
        } else {
            background(fallback, in: shape)
        }
    }
}
