package com.sendaturn.lint

import org.jetbrains.kotlin.psi.KtBlockExpression
import org.jetbrains.kotlin.psi.KtCallExpression
import org.jetbrains.kotlin.psi.KtDeclarationWithBody
import org.jetbrains.kotlin.psi.KtElement
import org.jetbrains.kotlin.psi.KtExpression
import org.jetbrains.kotlin.psi.KtNameReferenceExpression
import org.jetbrains.kotlin.psi.KtNamedFunction
import org.jetbrains.kotlin.psi.KtQualifiedExpression
import org.jetbrains.kotlin.psi.KtStringTemplateExpression
import org.jetbrains.kotlin.psi.KtValueArgument
import org.jetbrains.kotlin.psi.psiUtil.getStrictParentOfType

/** The file's path with forward slashes, for rules that allow one file by name. */
internal fun KtElement.filePath(): String {
    val file = containingKtFile
    return (file.virtualFile?.path ?: file.name).replace('\\', '/')
}

/** True when the file's path ends with one of [suffixes] ("view/component/ErrorLine.kt"). */
internal fun KtElement.isInFile(suffixes: List<String>): Boolean {
    val path = filePath()
    return suffixes.any { path == it || path.endsWith("/$it") }
}

internal fun KtElement.isUnder(folder: String): Boolean = filePath().contains("/$folder/")

internal fun KtCallExpression.calleeName(): String? = (calleeExpression as? KtNameReferenceExpression)?.getReferencedName()

/** `x.call()` or `x?.call()`: the call is a selector with a receiver. */
internal fun KtCallExpression.isQualified(): Boolean {
    val parent = parent as? KtQualifiedExpression ?: return false
    return parent.selectorExpression == this
}

internal fun KtCallExpression.receiverText(): String? {
    val parent = parent as? KtQualifiedExpression ?: return null
    if (parent.selectorExpression != this) return null
    return parent.receiverExpression.text
}

internal fun KtValueArgument.name(): String? = getArgumentName()?.asName?.asString()

/** The argument named [name], else the positional one at [position]. */
internal fun KtCallExpression.argument(
    name: String,
    position: Int? = null,
): KtExpression? {
    valueArguments.firstOrNull { it.name() == name }?.let { return it.getArgumentExpression() }
    if (position == null) return null
    val positional = valueArguments.filter { it.name() == null && it !is org.jetbrains.kotlin.psi.KtLambdaArgument }
    return positional.getOrNull(position)?.getArgumentExpression()
}

/** `TODO("port: ...")`: the spine's stub bodies, which every gate lets through. */
internal fun KtCallExpression.isPortStub(): Boolean {
    if (calleeName() != "TODO" || isQualified()) return false
    val text = (valueArguments.firstOrNull()?.getArgumentExpression() as? KtStringTemplateExpression)?.text ?: return false
    return text.startsWith("\"port:")
}

/** A function, getter or setter whose whole body is `TODO("port: ...")`. */
internal fun KtDeclarationWithBody.isPortStubBody(): Boolean {
    val body = bodyExpression ?: return false
    val only =
        if (body is KtBlockExpression) {
            body.statements.singleOrNull()
        } else {
            body
        }
    return (only as? KtCallExpression)?.isPortStub() == true
}

/** The text of every source line [element] spans, and of the line above it. */
internal fun KtElement.linesWithLineAbove(): String {
    val text = containingKtFile.text
    val start = textRange.startOffset
    val end = textRange.endOffset
    var lineStart = text.lastIndexOf('\n', (start - 1).coerceAtLeast(0)).let { if (it < 0 || start == 0) 0 else it + 1 }
    if (lineStart > 0) {
        lineStart = text.lastIndexOf('\n', lineStart - 2).let { if (it < 0) 0 else it + 1 }
    }
    val lineEnd = text.indexOf('\n', end).let { if (it < 0) text.length else it }
    return text.substring(lineStart, lineEnd)
}

/** The text of every source line [element] spans. */
internal fun KtElement.lines(): String {
    val text = containingKtFile.text
    val start = textRange.startOffset
    val lineStart = if (start == 0) 0 else text.lastIndexOf('\n', start - 1) + 1
    val lineEnd = text.indexOf('\n', textRange.endOffset).let { if (it < 0) text.length else it }
    return text.substring(lineStart, lineEnd)
}

internal fun KtElement.firstLine(): String {
    val text = containingKtFile.text
    val start = textRange.startOffset
    val lineStart = if (start == 0) 0 else text.lastIndexOf('\n', start - 1) + 1
    val lineEnd = text.indexOf('\n', start).let { if (it < 0) text.length else it }
    return text.substring(lineStart, lineEnd)
}

internal val NON_ACTIONABLE = Regex("""// non-actionable:\s*\S""")

internal fun KtElement.enclosingFunctionName(): String? = getStrictParentOfType<KtNamedFunction>()?.name
