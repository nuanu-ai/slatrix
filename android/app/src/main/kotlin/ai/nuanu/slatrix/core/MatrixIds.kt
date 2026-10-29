package ai.nuanu.slatrix.core

/**
 * An untrusted ID from storage, a notification or the server: the sigil, something after it, a bounded length and no
 * control characters, as the Mac's MatrixID.isValid checks.
 */
internal fun isMatrixId(value: String, sigil: String): Boolean = value.length > sigil.length && value.startsWith(sigil) &&
    value.toByteArray().size <= 2_048 && value.none(Char::isISOControl)
