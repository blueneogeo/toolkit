package com.sendaturn.lint

import com.sendaturn.lint.Fixtures.expectsFailure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.concurrent.TimeUnit

/** Runs each grep gate of build-lint.sh, and each check of the project's lint.sh, on its fixtures. */
class GrepGateFixtureTests {
    private val buildLint = File(System.getProperty("buildLint") ?: "../build-lint.sh")

    // The project hook sits at the root of the project that holds the toolkit (android/lint.sh).
    private val projectLint = File(System.getProperty("projectLint") ?: "../../../lint.sh")

    private fun bash(
        script: String,
        vararg args: String,
    ): Pair<Int, String> {
        val process =
            ProcessBuilder(listOf("bash", "-c", script, "gate") + args)
                .redirectErrorStream(true)
                .start()
        val output = process.inputStream.bufferedReader().readText()
        process.waitFor(60, TimeUnit.SECONDS)
        return process.exitValue() to output
    }

    private fun gates(): List<String> {
        val (code, output) = bash("source \"$1\"; printf '%s\\n' \"\${ANDROID_GATES[@]}\"", buildLint.path)
        assertEquals(output, 0, code)
        return output.lines().filter { it.isNotBlank() }
    }

    @Test
    fun everyGateHasFailingAndPassingFixtures() {
        val gates = gates()
        assertTrue("build-lint.sh lists no gates", gates.isNotEmpty())
        for (gate in gates) {
            val cases = Fixtures.cases("grep", gate)
            assertTrue("$gate has no failing fixture", cases.any { it.expectsFailure() })
            assertTrue("$gate has no passing fixture", cases.any { !it.expectsFailure() })
        }
        for (folder in Fixtures.gates("grep")) {
            assertTrue("fixtures/grep/$folder names no gate", folder in gates)
        }
    }

    @Test
    fun grepGatesFailAndPassOnTheirFixtures() {
        val problems = mutableListOf<String>()
        for (gate in gates()) {
            for (case in Fixtures.cases("grep", gate)) {
                val (code, output) = bash("source \"$1\"; PROJECT_ROOT=\"$2\"; \"$3\"", buildLint.path, case.path, gate)
                if (case.expectsFailure() && code == 0) problems += "$gate/${case.name}: passed, expected to fail\n$output"
                if (!case.expectsFailure() && code != 0) problems += "$gate/${case.name}: failed, expected to pass\n$output"
            }
        }
        assertEquals(emptyList<String>(), problems)
    }

    @Test
    fun projectChecksFailAndPassOnTheirFixtures() {
        if (!projectLint.isFile) return
        val problems = mutableListOf<String>()
        for (check in Fixtures.gates("project")) {
            val cases = Fixtures.cases("project", check)
            assertTrue("$check has no failing fixture", cases.any { it.expectsFailure() })
            assertTrue("$check has no passing fixture", cases.any { !it.expectsFailure() })
            for (case in cases) {
                val (code, output) =
                    bash(
                        "PROJECT_ROOT=\"$2\" SOURCE_DIR=app/src/main/kotlin/com/example bash \"$1\" \"$3\"",
                        projectLint.path,
                        case.path,
                        check,
                    )
                if (case.expectsFailure() && code == 0) problems += "$check/${case.name}: passed, expected to fail\n$output"
                if (!case.expectsFailure() && code != 0) problems += "$check/${case.name}: failed, expected to pass\n$output"
            }
        }
        assertEquals(emptyList<String>(), problems)
    }
}
