// Turn's detekt rules (toolkit/android/detekt-rules). The project includes this build
// and adds it to detektPlugins; its tests also run the grep gates of build-lint.sh
// on the fixtures under src/test/fixtures.
plugins {
    kotlin("jvm") version "2.4.21"
}

group = "com.sendaturn.lint"

val detektVersion = "2.0.0-alpha.6"

kotlin {
    jvmToolchain(21)
}

dependencies {
    compileOnly("dev.detekt:detekt-api:$detektVersion")
    testImplementation("dev.detekt:detekt-api:$detektVersion")
    testImplementation("dev.detekt:detekt-test:$detektVersion")
    testImplementation("junit:junit:4.13.2")
}

tasks.test {
    useJUnit()
    systemProperty("fixtures", layout.projectDirectory.dir("src/test/fixtures").asFile.path)
    systemProperty("buildLint", layout.projectDirectory.file("../build-lint.sh").asFile.path)
    systemProperty("projectLint", layout.projectDirectory.file("../../../lint.sh").asFile.path)
    inputs.dir("src/test/fixtures")
    inputs.file("../build-lint.sh")
}
