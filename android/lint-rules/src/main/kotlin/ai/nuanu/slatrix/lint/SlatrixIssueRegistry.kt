package ai.nuanu.slatrix.lint

import com.android.tools.lint.client.api.IssueRegistry
import com.android.tools.lint.client.api.Vendor
import com.android.tools.lint.detector.api.CURRENT_API

class SlatrixIssueRegistry : IssueRegistry() {
    override val api = CURRENT_API
    override val issues = listOf(DesignTokenDetector.ISSUE)
    override val vendor = Vendor(
        vendorName = "Slatrix",
        identifier = "ai.nuanu.slatrix",
        feedbackUrl = "https://github.com/nuanu-ai/slatrix/issues",
    )
}
