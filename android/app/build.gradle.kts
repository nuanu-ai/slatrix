plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "ai.nuanu.slatrix"
    compileSdk = 36
    defaultConfig {
        applicationId = "ai.nuanu.slatrix"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    testOptions {
        unitTests.isIncludeAndroidResources = true
    }
    lint { warningsAsErrors = true }
}

kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }

dependencies {
    implementation(project(":matrix-sdk"))
    implementation(platform("androidx.compose:compose-bom:2025.10.01"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.11.0")
    lintChecks(project(":lint-rules"))
    testImplementation("junit:junit:4.13.2")
    testImplementation("com.google.code.gson:gson:2.13.2")
}

tasks.withType<Test>().configureEach {
    systemProperty("slatrix.root", rootDir.parentFile.absolutePath)
}
