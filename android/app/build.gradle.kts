import com.android.build.api.dsl.ApplicationExtension
import com.android.build.api.variant.ApplicationAndroidComponentsExtension
import com.google.gms.googleservices.GoogleServicesTask
import java.net.URI
import java.io.File

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("io.github.takahirom.roborazzi")
}

val googleServices = providers.gradleProperty("slatrixGoogleServices").orNull?.let(::File)
val pushGateway = providers.gradleProperty("slatrixPushGateway").orNull.orEmpty()
require((googleServices == null) == pushGateway.isEmpty()) {
    "Supply slatrixGoogleServices and slatrixPushGateway together."
}
if (googleServices != null) {
    require(googleServices.isAbsolute && googleServices.isFile) { "slatrixGoogleServices must name an existing absolute file." }
    val gateway = URI(pushGateway)
    require(gateway.scheme == "https" && !gateway.host.isNullOrEmpty() && gateway.rawUserInfo == null &&
        gateway.rawQuery == null && gateway.rawFragment == null && gateway.path == "/_matrix/push/v1/notify") {
        "slatrixPushGateway must be an HTTPS /_matrix/push/v1/notify endpoint."
    }
    apply(plugin = "com.google.gms.google-services")
    extensions.configure<ApplicationAndroidComponentsExtension> {
        // The plugin registers each task with its default file list before this callback.
        onVariants { variant ->
            val variantName = variant.name.replaceFirstChar { it.uppercaseChar() }
            tasks.named<GoogleServicesTask>("process${variantName}GoogleServices") {
                googleServicesJsonFiles.set(listOf(googleServices))
            }
        }
    }
}

extensions.configure<ApplicationExtension> {
    namespace = "ai.nuanu.slatrix"
    compileSdk = 36
    defaultConfig {
        applicationId = "ai.nuanu.slatrix"
        buildConfigField("String", "PUSH_GATEWAY", "\"$pushGateway\"")
        manifestPlaceholders["authRedirectScheme"] = "com.github.nuanu-ai.slatrix"
        minSdk = 24
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    buildFeatures {
        compose = true
        buildConfig = true
        resValues = true
    }
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildTypes {
        debug {
            applicationIdSuffix = ".dev"
            manifestPlaceholders["authRedirectScheme"] = "com.github.nuanu-ai.slatrix.dev"
            versionNameSuffix = "-dev"
            resValue("string", "app_name", "Slatrix Dev")
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    testOptions {
        unitTests.isIncludeAndroidResources = true
    }
    lint {
        warningsAsErrors = true
        // Toolchain updates are reviewed separately, so pinned builds stay reproducible.
        disable += setOf("OldTargetApi", "GradleDependency", "AndroidGradlePluginVersion", "NewerVersionAvailable")
    }
}

kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }

dependencies {
    implementation(project(":matrix-sdk"))
    implementation(platform("com.google.firebase:firebase-bom:35.1.0"))
    implementation("com.google.firebase:firebase-messaging")
    implementation("androidx.work:work-runtime-ktx:2.12.0")
    implementation("androidx.browser:browser:1.10.0")
    implementation("org.jsoup:jsoup:1.23.2")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs_nio:2.1.5")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    implementation(platform("androidx.compose:compose-bom:2025.10.01"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.11.0")
    lintChecks(project(":lint-rules"))
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:core:1.7.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    testImplementation(platform("androidx.compose:compose-bom:2025.10.01"))
    testImplementation("androidx.compose.ui:ui-test-junit4")
    testImplementation("org.robolectric:robolectric:4.16.1")
    testImplementation("io.github.takahirom.roborazzi:roborazzi:1.76.0")
    testImplementation("io.github.takahirom.roborazzi:roborazzi-compose:1.76.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("com.google.code.gson:gson:2.13.2")
}

tasks.withType<Test>().configureEach {
    systemProperty("slatrix.root", rootDir.parentFile.absolutePath)
}
