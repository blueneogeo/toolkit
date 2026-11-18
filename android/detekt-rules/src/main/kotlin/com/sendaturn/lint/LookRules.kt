package com.sendaturn.lint

import dev.detekt.api.Config
import dev.detekt.api.Entity
import dev.detekt.api.Finding
import dev.detekt.api.Rule
import dev.detekt.api.config
import org.jetbrains.kotlin.psi.KtCallExpression
import org.jetbrains.kotlin.psi.KtDotQualifiedExpression
import org.jetbrains.kotlin.psi.KtQualifiedExpression
import org.jetbrains.kotlin.psi.psiUtil.getStrictParentOfType

private val ERROR_COLOUR = Regex("""\b(Palette|colors)\.error\b""")
private val ERROR_NAME_CHAIN = Regex("""^[\w.?!]*[eE]rror[\w.?!]*$""")

/** iOS `error_line` (.swiftlint.yml): error text goes through ErrorLine, at one size. */
class ErrorLineOnly(
    config: Config,
) : Rule(config, "Show an error with ErrorLine(message), so every screen says it the same way.") {
    private val allowedFiles: List<String> by config(
        listOf(
            "view/component/ErrorLine.kt",
            "view/component/TurnAlert.kt",
            "view/component/TurnActionSheet.kt",
            "view/component/TurnMenu.kt",
        ),
    )

    override fun visitCallExpression(expression: KtCallExpression) {
        super.visitCallExpression(expression)
        val name = expression.calleeName()
        if (name != "Text" && name != "BasicText") return
        if (expression.isInFile(allowedFiles)) return
        val color = expression.argument("color")?.text.orEmpty()
        val style = expression.argument("style")?.text.orEmpty()
        val text = expression.argument("text", 0)?.text.orEmpty()
        val readsErrorColour = ERROR_COLOUR.containsMatchIn(color) || (style.contains(".copy(") && ERROR_COLOUR.containsMatchIn(style))
        val namesAnError = name == "Text" && ERROR_NAME_CHAIN.matches(text)
        if (readsErrorColour || namesAnError) {
            report(Finding(Entity.from(expression), "Show an error with ErrorLine(message), so every screen says it the same way."))
        }
    }
}

private val HAIRLINE_COLOUR = Regex("""\blinen\b|\bfeedInk\.copy\(\s*alpha\s*=""")
private val ONE_DP = Regex("""^1\.dp$""")
private val ONE_UNIT = Regex("""\b1(\.dp(\.toPx\(\))?|f)\b""")

/** iOS `hairline` (.swiftlint.yml): a dividing line is Hairline(), never drawn by hand. */
class HairlineOnly(
    config: Config,
) : Rule(config, "Draw a dividing line with Hairline(), so every line is the same.") {
    private val allowedFiles: List<String> by config(listOf("view/component/Hairline.kt"))

    override fun visitDotQualifiedExpression(expression: KtDotQualifiedExpression) {
        super.visitDotQualifiedExpression(expression)
        if (expression.parent is KtQualifiedExpression && (expression.parent as KtQualifiedExpression).receiverExpression == expression) return
        if (expression.isInFile(allowedFiles)) return
        val calls = chainCalls(expression)
        val oneHigh =
            calls.any { call ->
                when (call.calleeName()) {
                    "height", "requiredHeight" -> ONE_DP.matches(call.argument("height", 0)?.text.orEmpty())
                    "size", "requiredSize" -> ONE_DP.matches(call.argument("height", 1)?.text.orEmpty())
                    else -> false
                }
            }
        val hairlineFill =
            calls.any { call ->
                call.calleeName() == "background" && HAIRLINE_COLOUR.containsMatchIn(call.argument("color", 0)?.text.orEmpty())
            }
        if (oneHigh && hairlineFill) {
            report(Finding(Entity.from(expression), "Draw a dividing line with Hairline(), so every line is the same."))
        }
    }

    override fun visitCallExpression(expression: KtCallExpression) {
        super.visitCallExpression(expression)
        val name = expression.calleeName()
        if (name != "drawLine" && name != "drawRect") return
        if (expression.isInFile(allowedFiles)) return
        val args = expression.valueArguments.map { it.getArgumentExpression()?.text.orEmpty() }
        val colour = args.any { HAIRLINE_COLOUR.containsMatchIn(it) }
        val oneUnit =
            if (name == "drawLine") {
                ONE_UNIT.containsMatchIn(expression.argument("strokeWidth", 3)?.text.orEmpty())
            } else {
                args.any { ONE_UNIT.containsMatchIn(it) }
            }
        if (colour && oneUnit) {
            report(Finding(Entity.from(expression), "Draw a dividing line with Hairline(), so every line is the same."))
        }
    }

    private fun chainCalls(expression: KtDotQualifiedExpression): List<KtCallExpression> {
        val calls = mutableListOf<KtCallExpression>()
        var current: org.jetbrains.kotlin.psi.KtExpression? = expression
        while (current is KtQualifiedExpression) {
            (current.selectorExpression as? KtCallExpression)?.let(calls::add)
            current = current.receiverExpression
        }
        (current as? KtCallExpression)?.let(calls::add)
        return calls
    }
}

/**
 * A button's tap comes from its press style (FeedbackButtonStyle.kt); handlers tick, press,
 * heavy or sent. The two exceptions are iOS's own (spec/elements-shared.md).
 */
class NoHapticTapInHandler(
    config: Config,
) : Rule(config, "Haptics.tap() is the button's: call it only in FeedbackButtonStyle.kt.") {
    private val allowedFiles: List<String> by config(listOf("view/component/FeedbackButtonStyle.kt"))

    // AppState+Feed.swift:207 (decisions.md B37) and AppState+RecordingTake.swift:35, the countdown's tick.
    private val allowedFunctions: List<String> by config(listOf("onPaperCardTapped", "startTakeAfterCountdown"))

    override fun visitCallExpression(expression: KtCallExpression) {
        super.visitCallExpression(expression)
        if (expression.calleeName() != "tap" || expression.receiverText() != "Haptics") return
        if (expression.isInFile(allowedFiles)) return
        if (expression.enclosingFunctionName() in allowedFunctions) return
        report(
            Finding(
                Entity.from(expression),
                "Haptics.tap() is the button's: call it only in FeedbackButtonStyle.kt. A handler ticks, presses, goes heavy or sent.",
            ),
        )
    }
}

private val CLICKABLES = setOf("clickable", "combinedClickable", "toggleable", "triStateToggleable", "selectable")

/** No ripple: every clickable passes `indication = null`, except the top bar's icon buttons. */
class IndicationNull(
    config: Config,
) : Rule(config, "Pass indication = null: Turn's buttons show no ripple.") {
    private val allowedFiles: List<String> by config(listOf("view/component/TopBarIconButton.kt"))

    override fun visitCallExpression(expression: KtCallExpression) {
        super.visitCallExpression(expression)
        if (expression.calleeName() !in CLICKABLES) return
        if (expression.getStrictParentOfType<org.jetbrains.kotlin.psi.KtImportDirective>() != null) return
        if (expression.isInFile(allowedFiles)) return
        if (expression.argument("indication")?.text == "null") return
        report(Finding(Entity.from(expression), "Pass indication = null: Turn's buttons show no ripple."))
    }
}
