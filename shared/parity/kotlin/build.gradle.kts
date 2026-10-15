plugins {
    application
}

val kotlinVersion = providers.gradleProperty("parityKotlinVersion").getOrElse("2.4.21")

providers.gradleProperty("parityBuildDir").orNull?.let { layout.buildDirectory.set(file(it)) }

dependencies {
    implementation("org.jetbrains.kotlin:kotlin-compiler-embeddable:$kotlinVersion")
}

tasks.withType<JavaCompile>().configureEach {
    options.release = 21
}

application {
    mainClass = "parity.Main"
}
