plugins { id("org.jetbrains.kotlin.jvm") }

kotlin { jvmToolchain(17) }

dependencies {
    compileOnly("com.android.tools.lint:lint-api:32.2.1")
    testImplementation("com.android.tools.lint:lint-api:32.2.1")
    testImplementation("com.android.tools.lint:lint-tests:32.2.1")
    testImplementation("junit:junit:4.13.2")
}

tasks.jar {
    manifest { attributes("Lint-Registry-v2" to "ai.nuanu.slatrix.lint.SlatrixIssueRegistry") }
}
