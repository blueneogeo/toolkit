package com.sendaturn.lint

import dev.detekt.api.RuleSet
import dev.detekt.api.RuleSetId
import dev.detekt.api.RuleSetProvider

/** Turn's rules: the iOS gates that need the syntax tree (spec/tooling.md 3.6). */
class TurnRuleSetProvider : RuleSetProvider {
    override val ruleSetId = RuleSetId("turn")

    override fun instance(): RuleSet = RuleSet(ruleSetId, RULES)

    companion object {
        val RULES =
            listOf(
                ::ErrorLineOnly,
                ::HairlineOnly,
                ::NoHapticTapInHandler,
                ::IndicationNull,
                ::ViewStateMutation,
                ::ComposableLocalState,
                ::StateClassShape,
                ::ResetPresence,
                ::SwallowedError,
                ::CancellationRethrow,
                ::NoCrashCall,
                ::NoAnyErasure,
                ::UnusedParameter,
            )
    }
}
