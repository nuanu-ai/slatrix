package ai.nuanu.slatrix.lint

import com.android.tools.lint.detector.api.Category
import com.android.tools.lint.detector.api.Detector
import com.android.tools.lint.detector.api.Implementation
import com.android.tools.lint.detector.api.Issue
import com.android.tools.lint.detector.api.JavaContext
import com.android.tools.lint.detector.api.Scope
import com.android.tools.lint.detector.api.Severity
import com.android.tools.lint.detector.api.SourceCodeScanner
import com.android.tools.lint.client.api.UElementHandler
import com.intellij.psi.PsiMember
import com.intellij.psi.PsiMethod
import org.jetbrains.uast.UCallExpression
import org.jetbrains.uast.UElement
import org.jetbrains.uast.ULiteralExpression
import org.jetbrains.uast.UQualifiedReferenceExpression
import org.jetbrains.uast.USimpleNameReferenceExpression

class DesignTokenDetector : Detector(), SourceCodeScanner {
    override fun getApplicableUastTypes(): List<Class<out UElement>> = listOf(
        UCallExpression::class.java,
        USimpleNameReferenceExpression::class.java,
    )

    override fun createUastHandler(context: JavaContext): UElementHandler? {
        val packageName = context.uastFile?.packageName ?: return null
        if (packageName == DESIGN_SYSTEM || packageName.startsWith("$DESIGN_SYSTEM.")) return null
        return object : UElementHandler() {
            override fun visitCallExpression(node: UCallExpression) {
                val method = node.resolve() ?: return
                val owner = method.containingClass?.qualifiedName ?: return
                if ((method.isConstructor && owner == COLOR) ||
                    (method.name == "Color" && owner.startsWith("androidx.compose.ui.graphics.") &&
                        method.returnType?.canonicalText == COLOR)
                ) {
                    context.report(ISSUE, node, context.getLocation(node), "Use a design system color role.")
                }
            }

            override fun visitSimpleNameReferenceExpression(node: USimpleNameReferenceExpression) {
                val member = node.resolve() as? PsiMember ?: return
                val owner = member.containingClass?.qualifiedName ?: return
                if (owner == "$COLOR.Companion" && member is PsiMethod && member.name.startsWith("get")) {
                    context.report(ISSUE, node, context.getLocation(node), "Use a design system color role.")
                }
                val qualified = node.uastParent as? UQualifiedReferenceExpression ?: return
                val receiver = qualified.receiver as? ULiteralExpression ?: return
                if (receiver.value !is Number || member !is PsiMethod) return
                if (owner.startsWith("androidx.compose.ui.unit.") && member.name in setOf("getDp", "getSp", "getEm")) {
                    context.report(ISSUE, qualified, context.getLocation(qualified), "Use a design system size token.")
                }
            }
        }
    }

    companion object {
        private const val COLOR = "androidx.compose.ui.graphics.Color"
        private const val DESIGN_SYSTEM = "ai.nuanu.slatrix.ui.designsystem"
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
