import com.android.build.api.dsl.LibraryExtension

plugins {
    id("com.android.library")
}

val sdkDirectory = rootProject.layout.projectDirectory.dir("../.build/native-sdk-android")
val verifierVersion = providers.fileContents(sdkDirectory.file("Cargo.lock")).asText.map { lock ->
    Regex("""(?m)^name = "rustls-platform-verifier-android"\r?\nversion = "([^"]+)"\r?$""")
        .find(lock)?.groupValues?.get(1)
        ?: error("rustls-platform-verifier-android is missing from the packaged Cargo.lock")
}

extensions.configure<LibraryExtension> {
    namespace = "ai.nuanu.slatrix.matrix.sdk"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
    }

    sourceSets.named("main") {
        kotlin.srcDir(sdkDirectory.dir("kotlin"))
        jniLibs.srcDir(sdkDirectory.dir("jniLibs"))
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("net.java.dev.jna:jna:5.18.1@aar")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
    implementation("androidx.annotation:annotation:1.9.1")
    implementation("org.rustls:rustls-platform-verifier:${verifierVersion.get()}")
}
