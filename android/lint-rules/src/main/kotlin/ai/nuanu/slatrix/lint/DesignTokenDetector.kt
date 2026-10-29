package ai.nuanu.slatrix.lint

import com.android.tools.lint.detector.api.Category
import com.android.tools.lint.detector.api.ConstantEvaluator
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
import org.jetbrains.kotlin.psi.KtProperty
import org.jetbrains.uast.UCallExpression
import org.jetbrains.uast.UElement
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
                    (method.name == "Color" && owner == "${COLOR}Kt") ||
                    (owner == "$COLOR.Companion" && method.name.substringBefore('-') in setOf("hsv", "hsl"))
                ) {
                    context.report(ISSUE, node, context.getLocation(node), "Use a design system color role.")
                }
                if (owner.startsWith("androidx.compose.animation.core.") && method.name in ANIMATION_SPECS) {
                    context.report(ISSUE, node, context.getLocation(node), "Use a design system motion token.")
                }
                if (((method.isConstructor && owner == "androidx.compose.ui.unit.Dp") ||
                        (owner == "androidx.compose.ui.unit.TextUnitKt" &&
                            method.name.substringBefore('-') == "TextUnit")) &&
                    node.valueArguments.firstOrNull()?.let { ConstantEvaluator.evaluate(context, it) } is Number
                ) {
                    context.report(ISSUE, node, context.getLocation(node), "Use a design system size token.")
                }
            }

            override fun visitSimpleNameReferenceExpression(node: USimpleNameReferenceExpression) {
                val resolved = node.resolve()
                val member = resolved as? PsiMember
                val owner = member?.containingClass?.qualifiedName
                val property = resolved as? KtProperty
                val propertyOwner = property?.fqName?.parent()?.asString()
                if ((owner == "$COLOR.Companion" && member is PsiMethod && member.name.startsWith("get")) ||
                    propertyOwner == "$COLOR.Companion"
                ) {
                    context.report(ISSUE, node, context.getLocation(node), "Use a design system color role.")
                }
                val qualified = node.uastParent as? UQualifiedReferenceExpression ?: return
                if (ConstantEvaluator.evaluate(context, qualified.receiver) !is Number) return
                if ((owner?.startsWith("androidx.compose.ui.unit.") == true &&
                        member is PsiMethod && member.name in setOf("getDp", "getSp", "getEm")) ||
                    (propertyOwner == "androidx.compose.ui.unit" && property.name in setOf("dp", "sp", "em"))
                ) {
                    context.report(ISSUE, qualified, context.getLocation(qualified), "Use a design system size token.")
                }
            }
        }
    }

    companion object {
        private const val COLOR = "androidx.compose.ui.graphics.Color"
        private const val DESIGN_SYSTEM = "ai.nuanu.slatrix.ui.designsystem"
        /** Animation specs carry their own timing, which only the design system's motion tokens may set. */
        private val ANIMATION_SPECS = setOf("tween", "spring", "keyframes", "repeatable", "infiniteRepeatable", "snap")
        val ISSUE = Issue.create(
            "SlatrixDesignTokens",
            "Use design system tokens",
            "Screens use design system color, size and motion roles instead of raw Compose values.",
            Category.CORRECTNESS,
            6,
            Severity.ERROR,
            Implementation(DesignTokenDetector::class.java, Scope.JAVA_FILE_SCOPE),
        )
    }
}
