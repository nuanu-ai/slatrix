package ai.nuanu.slatrix.lint

import com.android.tools.lint.detector.api.Category
import com.android.tools.lint.detector.api.Detector
import com.android.tools.lint.detector.api.Implementation
import com.android.tools.lint.detector.api.Issue
import com.android.tools.lint.detector.api.Scope
import com.android.tools.lint.detector.api.Severity
import com.android.tools.lint.detector.api.SourceCodeScanner

class DesignTokenDetector : Detector(), SourceCodeScanner {
    companion object {
        val ISSUE = Issue.create(
            "SlatrixDesignTokens",
            "Use design system tokens",
            "Screens use design system color and size roles instead of raw Compose values.",
            Category.CORRECTNESS,
            6,
            Severity.ERROR,
            Implementation(DesignTokenDetector::class.java, Scope.JAVA_FILE_SCOPE),
        )
    }
}
