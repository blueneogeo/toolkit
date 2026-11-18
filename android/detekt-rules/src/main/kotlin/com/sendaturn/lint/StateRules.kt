package com.sendaturn.lint

import dev.detekt.api.Config
import dev.detekt.api.Entity
import dev.detekt.api.Finding
import dev.detekt.api.Rule
import dev.detekt.api.config
import org.jetbrains.kotlin.lexer.KtTokens
import org.jetbrains.kotlin.psi.KtBinaryExpression
import org.jetbrains.kotlin.psi.KtCallExpression
import org.jetbrains.kotlin.psi.KtClass
import org.jetbrains.kotlin.psi.KtExpression
import org.jetbrains.kotlin.psi.KtLambdaExpression
import org.jetbrains.kotlin.psi.KtNameReferenceExpression
import org.jetbrains.kotlin.psi.KtNamedFunction
import org.jetbrains.kotlin.psi.KtProperty
import org.jetbrains.kotlin.psi.KtQualifiedExpression
import org.jetbrains.kotlin.psi.KtUnaryExpression
import org.jetbrains.kotlin.psi.psiUtil.getStrictParentOfType

private val ASSIGNMENTS = setOf(KtTokens.EQ, KtTokens.PLUSEQ, KtTokens.MINUSEQ, KtTokens.MULTEQ, KtTokens.DIVEQ, KtTokens.PERCEQ)
private val MUTATING_CALLS =
    setOf(
        "add", "addAll", "remove", "removeAt", "removeAll", "removeFirst", "removeLast", "removeIf", "retainAll",
        "clear", "put", "putAll", "set", "sort", "sortBy", "shuffle", "fill", "replaceAll",
    )
private val ALLOW_VIEW_STATE_MUTATION = Regex("""// lint:allow view-state-mutation \S""")

/** The innermost receiver of `state.feed.items`: `state`. */
private fun KtExpression.rootName(): String? {
    var current: KtExpression? = this
    while (current is KtQualifiedExpression) current = current.receiverExpression
    return (current as? KtNameReferenceExpression)?.getReferencedName()
}

/** Views read state and call handlers; they never assign into it (do_view_state_mutation_check). */
class ViewStateMutation(
    config: Config,
) : Rule(config, "Views must not mutate state directly: route through an on<Subject><Event> handler.") {
    private val folder: String by config("view")
    private val stateNames: List<String> by config(listOf("state", "appState"))

    override fun visitBinaryExpression(expression: KtBinaryExpression) {
        super.visitBinaryExpression(expression)
        if (expression.operationToken !in ASSIGNMENTS) return
        val left = expression.left as? KtQualifiedExpression ?: return
        check(expression, left)
    }

    override fun visitUnaryExpression(expression: KtUnaryExpression) {
        super.visitUnaryExpression(expression)
        val token = expression.operationReference.getReferencedNameElementType()
        if (token != KtTokens.PLUSPLUS && token != KtTokens.MINUSMINUS) return
        val operand = expression.baseExpression as? KtQualifiedExpression ?: return
        check(expression, operand)
    }

    override fun visitCallExpression(expression: KtCallExpression) {
        super.visitCallExpression(expression)
        if (expression.calleeName() !in MUTATING_CALLS) return
        val parent = expression.parent as? KtQualifiedExpression ?: return
        if (parent.selectorExpression != expression) return
        val receiver = parent.receiverExpression as? KtQualifiedExpression ?: return
        check(expression, receiver)
    }

    private fun check(
        expression: KtExpression,
        target: KtQualifiedExpression,
    ) {
        if (!expression.isUnder(folder)) return
        if (target.rootName() !in stateNames) return
        if (ALLOW_VIEW_STATE_MUTATION.containsMatchIn(expression.lines())) return
        report(
            Finding(
                Entity.from(expression),
                "Views must not mutate state directly: route through an on<Subject><Event> handler. " +
                    "Override with // lint:allow view-state-mutation <reason>",
            ),
        )
    }
}

private val SNAPSHOT_STATE = Regex("""mutable\w*StateOf|mutableStateListOf|mutableStateMapOf""")

/** `remember { mutableStateOf(...) }` and `rememberSaveable` are a view's own state, as `@State` on iOS. */
class ComposableLocalState(
    config: Config,
) : Rule(config, "View-local state needs // non-actionable: <reason>, or it moves to the state class.") {
    override fun visitCallExpression(expression: KtCallExpression) {
        super.visitCallExpression(expression)
        val name = expression.calleeName()
        val holdsState =
            when (name) {
                "rememberSaveable" -> true
                "remember" -> expression.lambdaArguments.any { SNAPSHOT_STATE.containsMatchIn(it.text) }
                else -> false
            }
        if (!holdsState) return
        val statement = expression.getStrictParentOfType<KtProperty>() ?: expression
        if (NON_ACTIONABLE.containsMatchIn(statement.linesWithLineAbove())) return
        report(
            Finding(
                Entity.from(expression),
                "$name holds state in the view: add // non-actionable: <reason> on the same line, or move it to the state class.",
            ),
        )
    }
}

private val STATE_CLASS_NAME = Regex(""".+(State|Settings)$""")
private val SNAPSHOT_DELEGATE = Regex("""^mutable\w*StateOf\b|^mutableStateListOf\b|^mutableStateMapOf\b""")

private fun KtClass.isDomainStateClass(rootName: String): Boolean {
    val name = name ?: return false
    if (!STATE_CLASS_NAME.matches(name) || name == rootName) return false
    if (isData() || isEnum() || isInterface() || isAnnotation() || isSealed() || isInner()) return false
    return !hasModifier(KtTokens.VALUE_KEYWORD)
}

/** do_observable_class_check: domain state classes are @Stable, final, and every var is snapshot state. */
class StateClassShape(
    config: Config,
) : Rule(config, "Domain state classes are @Stable final classes whose vars are snapshot state.") {
    private val folder: String by config("model")
    private val rootName: String by config("AppState")

    override fun visitClass(klass: KtClass) {
        super.visitClass(klass)
        if (!klass.isUnder(folder) || !klass.isDomainStateClass(rootName)) return
        if (klass.annotationEntries.none { it.shortName?.asString() == "Stable" }) {
            report(Finding(Entity.atName(klass), "${klass.name} is a state class: mark it @Stable."))
        }
        if (klass.hasModifier(KtTokens.OPEN_KEYWORD) || klass.hasModifier(KtTokens.ABSTRACT_KEYWORD)) {
            report(Finding(Entity.atName(klass), "${klass.name} is a state class: make it final (no open or abstract)."))
        }
        for (property in klass.body?.properties.orEmpty()) {
            if (!property.isVar) continue
            val delegate = property.delegateExpression?.text
            val snapshot = delegate != null && SNAPSHOT_DELEGATE.containsMatchIn(delegate)
            val computed = property.getter != null || property.setter?.bodyExpression != null
            if (!snapshot && !computed) {
                report(
                    Finding(
                        Entity.atName(property),
                        "${property.name} in ${klass.name} is a var without snapshot state: write `by mutableStateOf(...)`.",
                    ),
                )
            }
        }
        for (parameter in klass.primaryConstructorParameters) {
            if (parameter.isMutable) {
                report(
                    Finding(
                        Entity.from(parameter),
                        "${parameter.name} in ${klass.name} is a constructor var: make it a body property `by mutableStateOf(...)`.",
                    ),
                )
            }
        }
    }
}

/** do_reset_presence_check: every domain state class declares reset(). */
class ResetPresence(
    config: Config,
) : Rule(config, "Domain state classes must define reset().") {
    private val folder: String by config("model")
    private val rootName: String by config("AppState")

    override fun visitClass(klass: KtClass) {
        super.visitClass(klass)
        if (!klass.isUnder(folder) || !klass.isDomainStateClass(rootName)) return
        val hasReset =
            klass.body?.functions.orEmpty().any { it.name == "reset" && it.valueParameters.isEmpty() && it.receiverTypeReference == null }
        if (!hasReset) {
            report(Finding(Entity.atName(klass), "${klass.name} is a state class missing fun reset()."))
        }
    }
}

internal fun KtLambdaExpression.callName(): String? =
    (parent?.parent as? KtCallExpression)?.calleeName()
        ?: ((parent?.parent?.parent as? KtCallExpression)?.calleeName())

internal fun KtNamedFunction.isSuspend(): Boolean = hasModifier(KtTokens.SUSPEND_KEYWORD)
