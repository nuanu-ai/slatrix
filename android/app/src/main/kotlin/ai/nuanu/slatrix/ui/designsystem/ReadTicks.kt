package ai.nuanu.slatrix.ui.designsystem

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics

/** By your message's time, as messengers draw it: one tick once the server has it, two once someone has read it. */
@Composable
fun ReadTicks(seen: Boolean, color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier.size(UiMetrics.TicksWidth, UiMetrics.TicksHeight).semantics { contentDescription = if (seen) "Seen" else "Sent" }) {
        // Drawn on a 24 by 16 grid; the second tick of a pair runs parallel to the first.
        fun p(x: Float, y: Float) = Offset(x * size.width / 24, y * size.height / 16)
        fun tick(start: Offset, corner: Offset, end: Offset) = Path().apply {
            moveTo(start.x, start.y)
            lineTo(corner.x, corner.y)
            lineTo(end.x, end.y)
        }
        val stroke = Stroke(size.width * 0.1f, cap = StrokeCap.Round, join = StrokeJoin.Round)
        if (seen) {
            drawPath(tick(p(1.5f, 8.5f), p(6f, 13f), p(14.5f, 3f)), color, style = stroke)
            drawPath(tick(p(10.5f, 11.5f), p(12f, 13f), p(20.5f, 3f)), color, style = stroke)
        } else drawPath(tick(p(5f, 8.5f), p(9.5f, 13f), p(18f, 3f)), color, style = stroke)
    }
}
