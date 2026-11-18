package com.sendaturn.lint

import com.sendaturn.lint.Fixtures.expectsFailure
import dev.detekt.api.Config
import dev.detekt.test.lint
import dev.detekt.test.utils.compileForTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RuleFixtureTests {
    private val rules = TurnRuleSetProvider.RULES.map { it(Config.empty) }

    @Test
    fun everyRuleHasFailingAndPassingFixtures() {
        for (rule in rules) {
            val cases = Fixtures.cases("detekt", rule.ruleName.value)
            assertTrue("${rule.ruleName.value} has no failing fixture", cases.any { it.expectsFailure() })
            assertTrue("${rule.ruleName.value} has no passing fixture", cases.any { !it.expectsFailure() })
        }
    }

    @Test
    fun everyFixtureFolderNamesARule() {
        val names = rules.map { it.ruleName.value }.toSet()
        for (gate in Fixtures.gates("detekt")) {
            assertTrue("fixtures/detekt/$gate names no rule", gate in names)
        }
    }

    @Test
    fun failingFixturesFailAndPassingFixturesPass() {
        val problems = mutableListOf<String>()
        for (rule in rules) {
            for (case in Fixtures.cases("detekt", rule.ruleName.value)) {
                for (file in Fixtures.kotlinFiles(case)) {
                    val findings = rule.lint(compileForTest(file.toPath()))
                    val name = "${rule.ruleName.value}/${case.name}/${file.relativeTo(case)}"
                    if (case.expectsFailure() && findings.isEmpty()) problems += "$name: expected a finding, got none"
                    if (!case.expectsFailure() && findings.isNotEmpty()) problems += "$name: expected none, got ${findings.map { it.message }}"
                }
            }
        }
        assertEquals(emptyList<String>(), problems)
    }
}
