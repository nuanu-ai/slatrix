package ai.nuanu.slatrix.core

/** When an open conversation's newest message counts as seen; the cases are in spec/read-state.json. */
object ReadState {
    /** Seen once any part of it is on screen, so a message taller than the screen reads as soon as it shows. */
    fun seen(top: Float, bottom: Float, screenTop: Float, screenBottom: Float) = top < screenBottom && bottom > screenTop
}
