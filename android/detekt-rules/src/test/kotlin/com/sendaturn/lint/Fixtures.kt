package com.sendaturn.lint

import java.io.File

/** The fixtures under src/test/fixtures: `<group>/<gate>/<case>/...`, where a case named fail* must fail. */
object Fixtures {
    val root = File(System.getProperty("fixtures") ?: "src/test/fixtures")

    fun gates(group: String): List<String> =
        root.resolve(group).listFiles().orEmpty().filter { it.isDirectory }.map { it.name }.sorted()

    fun cases(
        group: String,
        gate: String,
    ): List<File> = root.resolve("$group/$gate").listFiles().orEmpty().filter { it.isDirectory }.sortedBy { it.name }

    fun File.expectsFailure(): Boolean = name.startsWith("fail")

    fun kotlinFiles(case: File): List<File> = case.walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()
}
