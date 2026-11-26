package ai.nuanu.slatrix.core

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import androidx.core.graphics.createBitmap
import androidx.core.graphics.get
import com.caverock.androidsvg.SVG
import java.io.ByteArrayInputStream
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Rasterizes SVG image attachments cleanly off the main thread without executing scripts or fetching external URLs. */
object SvgDecoder {
    private const val MAX_RENDER_PIXELS = 2_048
    private const val HEADER_SNIFF_BYTES = 2_048
    private val SVG_TAG = Regex("<svg(?=[\\s>/]|$)")

    fun looksLikeSvg(bytes: ByteArray): Boolean {
        if (bytes.isEmpty()) return false
        var start = 0
        if (bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()) {
            start = 3
        }
        val length = min(bytes.size - start, HEADER_SNIFF_BYTES)
        if (length <= 0) return false
        val trimmed = String(bytes, start, length, Charsets.UTF_8).trimStart().lowercase()
        if (trimmed.startsWith("<svg")) {
            val after = trimmed.getOrNull(4)
            return after == null || after == '>' || after == '/' || after.isWhitespace()
        }
        return (trimmed.startsWith("<?xml") || trimmed.startsWith("<!--") || trimmed.startsWith("<!doctype")) &&
            SVG_TAG.containsMatchIn(trimmed)
    }

    fun dimensions(bytes: ByteArray): Pair<Int, Int>? {
        if (!looksLikeSvg(bytes)) return null
        return try {
            val svg = SVG.getFromInputStream(ByteArrayInputStream(bytes)) ?: return null
            val (w, h) = intrinsicSize(svg) ?: return null
            if (w > 16_384f || h > 16_384f) return null
            w.roundToInt() to h.roundToInt()
        } catch (_: StackOverflowError) {
            null
        } catch (_: OutOfMemoryError) {
            null
        } catch (_: Exception) {
            null
        }
    }

    fun decode(bytes: ByteArray, maxWidth: Int, maxHeight: Int): Bitmap? {
        if (!looksLikeSvg(bytes)) return null
        val boundW = maxWidth.coerceIn(1, MAX_RENDER_PIXELS)
        val boundH = maxHeight.coerceIn(1, MAX_RENDER_PIXELS)
        return try {
            val svg = SVG.getFromInputStream(ByteArrayInputStream(bytes)) ?: return null
            val (docW, docH) = intrinsicSize(svg) ?: (boundW.toFloat() to boundH.toFloat())
            if (svg.documentViewBox == null) svg.setDocumentViewBox(0f, 0f, docW, docH)
            val scale = min(boundW / docW, boundH / docH)
            val targetW = max(1, min(boundW, (docW * scale).roundToInt()))
            val targetH = max(1, min(boundH, (docH * scale).roundToInt()))
            svg.setDocumentWidth("100%")
            svg.setDocumentHeight("100%")
            val raw = createBitmap(targetW, targetH).also { bitmap ->
                svg.renderToCanvas(Canvas(bitmap))
            }
            applyContrastMatteIfTransparent(raw)
        } catch (_: StackOverflowError) {
            null
        } catch (_: OutOfMemoryError) {
            null
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Adds a subtle light or dark surface behind transparent SVGs so dark-ink diagrams stay legible in dark mode and
     * `MediaViewer` (and light-ink icons stay legible in light mode), while leaving opaque SVGs untouched.
     */
    private fun applyContrastMatteIfTransparent(bitmap: Bitmap): Bitmap {
        val width = bitmap.width
        val height = bitmap.height
        if (width <= 0 || height <= 0) return bitmap
        val steps = 32
        var borderAlphaSum = 0.0
        var borderCount = 0
        var fgLuminanceSum = 0.0
        var fgCount = 0
        for (row in 0 until steps) {
            val y = min(height - 1, (row * (height - 1)) / max(1, steps - 1))
            for (col in 0 until steps) {
                val x = min(width - 1, (col * (width - 1)) / max(1, steps - 1))
                val pixel = bitmap[x, y]
                val alpha = Color.alpha(pixel) / 255.0
                if (row == 0 || row == steps - 1 || col == 0 || col == steps - 1) {
                    borderAlphaSum += alpha
                    borderCount++
                }
                if (alpha > 0.15) {
                    fgLuminanceSum += (0.2126 * Color.red(pixel) + 0.7152 * Color.green(pixel) + 0.0722 * Color.blue(pixel)) / 255.0
                    fgCount++
                }
            }
        }
        if (borderCount == 0 || borderAlphaSum / borderCount >= 0.75) return bitmap
        val averageLuminance = if (fgCount > 0) fgLuminanceSum / fgCount else 0.0
        val matte = if (averageLuminance < 0.45) Color.rgb(0xF5, 0xF6, 0xF8) else Color.rgb(0x1C, 0x1E, 0x22)
        val composited = createBitmap(width, height)
        val canvas = Canvas(composited)
        canvas.drawColor(matte)
        canvas.drawBitmap(bitmap, 0f, 0f, null)
        bitmap.recycle()
        return composited
    }

    private fun intrinsicSize(svg: SVG): Pair<Float, Float>? {
        val viewBox = svg.documentViewBox
        if (viewBox != null && viewBox.width().isFinite() && viewBox.height().isFinite() &&
            viewBox.width() > 0f && viewBox.height() > 0f) {
            return viewBox.width() to viewBox.height()
        }
        val w = svg.documentWidth
        val h = svg.documentHeight
        if (w.isFinite() && h.isFinite() && w > 0f && h > 0f) return w to h
        return null
    }
}
