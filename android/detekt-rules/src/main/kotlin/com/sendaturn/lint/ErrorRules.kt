package com.sendaturn.lint

import dev.detekt.api.Config
import dev.detekt.api.Entity
import dev.detekt.api.Finding
import dev.detekt.api.Rule
import dev.detekt.api.config
import org.jetbrains.kotlin.lexer.KtTokens
import org.jetbrains.kotlin.psi.KtBinaryExpressionWithTypeRHS
import org.jetbrains.kotlin.psi.KtBlockExpression
import org.jetbrains.kotlin.psi.KtCallExpression
import org.jetbrains.kotlin.psi.KtCatchClause
import org.jetbrains.kotlin.psi.KtClassOrObject
import org.jetbrains.kotlin.psi.KtElement
import org.jetbrains.kotlin.psi.KtLambdaExpression
import org.jetbrains.kotlin.psi.KtNameReferenceExpression
import org.jetbrains.kotlin.psi.KtNamedFunction
import org.jetbrains.kotlin.psi.KtParameter
import org.jetbrains.kotlin.psi.KtQualifiedExpression
import org.jetbrains.kotlin.psi.KtThrowExpression
import org.jetbrains.kotlin.psi.KtTryExpression
import org.jetbrains.kotlin.psi.KtTypeConstraint
import org.jetbrains.kotlin.psi.KtTypeParameter
import org.jetbrains.kotlin.psi.KtTypeProjection
import org.jetbrains.kotlin.psi.KtTypeReference
import org.jetbrains.kotlin.psi.KtUserType
import org.jetbrains.kotlin.psi.psiUtil.collectDescendantsOfType
import org.jetbrains.kotlin.psi.psiUtil.getStrictParentOfType

private fun KtElement.logsError(): Boolean =
    collectDescendantsOfType<KtCallExpression>().any { it.calleeName() == "error" && it.receiverText() == "Log" }

private fun KtElement.throws(): Boolean = collectDescendantsOfType<KtThrowExpression>().isNotEmpty()

/** do_try_check: a caught error is logged, rethrown, or carries // non-actionable: <reason>. */
class SwallowedError(
    config: Config,
) : Rule(config, "Every catch logs with Log.error, rethrows, or says // non-actionable: <reason>.") {
    override fun visitCatchSection(catchClause: KtCatchClause) {
        super.visitCatchSection(catchClause)
        val body = catchClause.catchBody as? KtBlockExpression ?: return
        val justified = NON_ACTIONABLE.containsMatchIn(catchClause.text) || NON_ACTIONABLE.containsMatchIn(catchClause.firstLine())
        if (body.statements.isEmpty() && !justified) {
            report(Finding(Entity.from(catchClause), "Empty catch: log with Log.error, rethrow, or say // non-actionable: <reason>."))
            return
        }
        if (justified || body.logsError() || body.throws()) return
        report(Finding(Entity.from(catchClause), "Unjustified catch: log with Log.error, rethrow, or add // non-actionable: <reason>."))
    }

    override fun visitCallExpression(expression: KtCallExpression) {
        super.visitCallExpression(expression)
        if (expression.calleeName() != "runCatching") return
        var chain: KtElement = expression
        while (true) {
            val parent = chain.parent as? KtQualifiedExpression ?: break
            if (parent.receiverExpression != chain && parent.selectorExpression != chain) break
            chain = parent
        }
        val handlers =
            chain.collectDescendantsOfType<KtCallExpression>().filter {
                it !== expression && it.calleeName() in setOf("onFailure", "getOrElse", "fold", "recover", "getOrThrow")
            }
        val handled =
            handlers.any { handler ->
                handler.calleeName() == "getOrThrow" || handler.lambdaArguments.any { it.logsError() || it.throws() } ||
                    handler.valueArguments.any { it.getArgumentExpression()?.let { arg -> arg.logsError() || arg.throws() } == true }
            }
        if (handled || NON_ACTIONABLE.containsMatchIn(chain.linesWithLineAbove())) return
        report(
            Finding(
                Entity.from(expression),
                "runCatching swallows the error: add .onFailure { Log.error(...) }, or // non-actionable: <reason>.",
            ),
        )
    }
}

private val CATCH_ALL = setOf("Exception", "Throwable", "RuntimeException", "IllegalStateException")
private val COROUTINE_BUILDERS =
    setOf("launch", "async", "withContext", "coroutineScope", "supervisorScope", "runTest", "withTimeout", "withTimeoutOrNull", "flow")

/** A catch-all in coroutine code rethrows CancellationException first (platform-mapping.md, Cancellation). */
class CancellationRethrow(
    config: Config,
) : Rule(config, "A catch-all in a coroutine rethrows CancellationException before anything else.") {
    override fun visitTryExpression(expression: KtTryExpression) {
        super.visitTryExpression(expression)
        if (!expression.isInCoroutine()) return
        val clauses = expression.catchClauses
        for ((index, clause) in clauses.withIndex()) {
            val type = clause.catchParameter?.typeReference?.text?.substringAfterLast('.') ?: continue
            if (type == "CancellationException") return
            if (type !in CATCH_ALL) continue
            val rethrows = clauses.take(index).any { it.catchParameter?.typeReference?.text?.endsWith("CancellationException") == true }
            val body = clause.catchBody?.text.orEmpty()
            val checksFirst = Regex("""is\s+(kotlinx\.coroutines\.)?CancellationException\)?\s*(\{\s*)?throw""").containsMatchIn(body)
            if (!rethrows && !checksFirst) {
                report(
                    Finding(
                        Entity.from(clause),
                        "catch ($type) in a coroutine: rethrow CancellationException first " +
                            "(catch (e: CancellationException) { throw e }, or if (e is CancellationException) throw e).",
                    ),
                )
            }
        }
    }

    private fun KtElement.isInCoroutine(): Boolean {
        var current = parent
        while (current != null) {
            when (current) {
                is KtNamedFunction -> return current.isSuspend()
                is KtLambdaExpression -> if (current.callName() in COROUTINE_BUILDERS) return true
                is KtClassOrObject -> return false
            }
            current = current.parent
        }
        return false
    }
}

private val CRASH_CALLS = setOf("error", "TODO", "check", "checkNotNull", "require", "requireNotNull", "assert")

private val COMPOSITION_LOCALS = setOf("compositionLocalOf", "staticCompositionLocalOf")

/**
 * iOS no_fatal_error, no_precondition_failure, no_precondition, no_assertion_failure. A
 * CompositionLocal's default may fail, as SwiftUI's @Environment does when nothing provides it.
 */
class NoCrashCall(
    config: Config,
) : Rule(config, "Crash calls crash in production: handle the state instead.") {
    override fun visitCallExpression(expression: KtCallExpression) {
        super.visitCallExpression(expression)
        val name = expression.calleeName() ?: return
        if (name !in CRASH_CALLS || expression.isQualified() || expression.isPortStub()) return
        if (expression.getStrictParentOfType<KtLambdaExpression>()?.callName() in COMPOSITION_LOCALS) return
        report(Finding(Entity.from(expression), "$name() crashes in production: handle the state instead."))
    }

    override fun visitThrowExpression(expression: KtThrowExpression) {
        super.visitThrowExpression(expression)
        val thrown = expression.thrownExpression as? KtCallExpression ?: return
        if (thrown.calleeName() == "IllegalStateException") {
            report(Finding(Entity.from(expression), "throw IllegalStateException crashes in production: handle the state instead."))
        }
    }
}

private val MAP_TYPES = setOf("Map", "MutableMap", "HashMap", "LinkedHashMap")

/**
 * do_any_check: `Any` erases type information. A file that still holds `TODO("port: ...")`
 * stubs is skipped: the spine writes `Any` where an iOS framework type has no Kotlin twin yet.
 */
class NoAnyErasure(
    config: Config,
) : Rule(config, "'Any' erases type information. This gate has no override: restructure.") {
    // UserDefaults.kt stands in for Foundation's UserDefaults, which stores Any.
    private val allowedFiles: List<String> by config(listOf("service/UserDefaults.kt"))

    override fun visitTypeReference(typeReference: KtTypeReference) {
        super.visitTypeReference(typeReference)
        val text = typeReference.text.replace(" ", "")
        if (text != "Any" && text != "Any?" && text != "kotlin.Any" && text != "kotlin.Any?") return
        when (val parent = typeReference.parent) {
            is KtTypeParameter, is KtTypeConstraint -> return
            is KtParameter -> if (parent.isEqualsParameter() || parent.isVarArg) return
            is KtTypeProjection -> if (parent.isMapArgument()) return
            else -> Unit
        }
        if (typeReference.isInFile(allowedFiles) || typeReference.containingKtFile.text.contains("TODO(\"port:")) return
        val what = if (typeReference.parent is KtBinaryExpressionWithTypeRHS) "Cast to Any" else "Any as a type"
        report(Finding(Entity.from(typeReference), "$what erases type information. This gate has no override: restructure."))
    }

    private fun KtParameter.isEqualsParameter(): Boolean {
        val function = getStrictParentOfType<KtNamedFunction>() ?: return false
        return function.name == "equals" && function.hasModifier(KtTokens.OVERRIDE_KEYWORD)
    }

    // iOS's gate lets [String: Any] through: notification payloads and launch options keep that shape.
    private fun KtTypeProjection.isMapArgument(): Boolean {
        val userType = parent?.parent as? KtUserType ?: return false
        return userType.referencedName in MAP_TYPES
    }
}

/**
 * Detekt's UnusedParameter, except in the spine's `TODO("port: ...")` stubs, whose parameters
 * are used once the port lands.
 */
class UnusedParameter(
    config: Config,
) : Rule(config, "Function parameter is unused.") {
    private val allowedNames: String by config("ignored|expected|_")

    override fun visitNamedFunction(function: KtNamedFunction) {
        super.visitNamedFunction(function)
        if (function.isPortStubBody()) return
        val body = function.bodyExpression ?: return
        if (function.hasModifier(KtTokens.OVERRIDE_KEYWORD) ||
            function.hasModifier(KtTokens.OPEN_KEYWORD) ||
            function.hasModifier(KtTokens.ABSTRACT_KEYWORD) ||
            function.hasModifier(KtTokens.EXTERNAL_KEYWORD) ||
            function.hasModifier(KtTokens.ACTUAL_KEYWORD) ||
            function.hasModifier(KtTokens.EXPECT_KEYWORD) ||
            function.hasModifier(KtTokens.OPERATOR_KEYWORD)
        ) {
            return
        }
        if (function.getStrictParentOfType<org.jetbrains.kotlin.psi.KtClass>()?.isInterface() == true) return
        val allowed = Regex(allowedNames)
        val parameters = function.valueParameters
        val used =
            buildSet {
                (listOf(body) + parameters.mapNotNull { it.defaultValue })
                    .flatMap { it.collectDescendantsOfType<KtNameReferenceExpression>() }
                    .forEach { add(it.getReferencedName()) }
            }
        for (parameter in parameters) {
            val name = parameter.name ?: continue
            if (allowed.matches(name) || name in used) continue
            report(Finding(Entity.from(parameter), "Function parameter `$name` is unused."))
        }
    }
}
