import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

val localSigning = Properties().apply {
    val file = rootProject.file("signing.properties")
    if (file.isFile) file.inputStream().use(::load)
}

fun signingValue(property: String, environment: String): String? =
    providers.environmentVariable(environment).orNull
        ?: localSigning.getProperty(property)?.takeIf(String::isNotBlank)

val internalStoreFile = signingValue("internalStoreFile", "CCR_ANDROID_INTERNAL_KEYSTORE_PATH")
val internalStorePassword = signingValue("internalStorePassword", "CCR_ANDROID_INTERNAL_KEYSTORE_PASSWORD")
val internalKeyAlias = signingValue("internalKeyAlias", "CCR_ANDROID_INTERNAL_KEY_ALIAS")
val internalKeyPassword = signingValue("internalKeyPassword", "CCR_ANDROID_INTERNAL_KEY_PASSWORD")
val internalSigningValues = listOf(
    internalStoreFile,
    internalStorePassword,
    internalKeyAlias,
    internalKeyPassword,
)
val configuredInternalSigningValueCount = internalSigningValues.count { !it.isNullOrBlank() }
require(configuredInternalSigningValueCount == 0 || configuredInternalSigningValueCount == 4) {
    "Internal release signing requires all four CCR_ANDROID_INTERNAL_* values (or none)."
}
val hasInternalReleaseSigning = configuredInternalSigningValueCount == 4
val commitSha = providers.environmentVariable("CCR_ANDROID_COMMIT_SHA")
    .orElse(providers.environmentVariable("GITHUB_SHA"))
    .orNull
    ?: runCatching {
        providers.exec {
            workingDir(rootProject.projectDir.parentFile)
            commandLine("git", "rev-parse", "HEAD")
        }.standardOutput.asText.get().trim()
    }.getOrNull()?.takeIf(String::isNotBlank)
    ?: "unknown"
val escapedCommitSha = commitSha
    .replace("\\", "\\\\")
    .replace("\"", "\\\"")

android {
    namespace = "com.snowberried.ctcinereviewer"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.snowberried.ctcinereviewer"
        minSdk = 34
        targetSdk = 37
        versionCode = 5
        versionName = "0.2.0-alpha.4"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "COMMIT_SHA", "\"$escapedCommitSha\"")
    }

    flavorDimensions += "channel"
    productFlavors {
        create("internal") {
            dimension = "channel"
            applicationIdSuffix = ".internal"
        }
    }

    signingConfigs {
        if (hasInternalReleaseSigning) {
            create("internalRelease") {
                storeFile = rootProject.file(internalStoreFile!!)
                storePassword = internalStorePassword
                keyAlias = internalKeyAlias
                keyPassword = internalKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("internalRelease")
        }
        create("benchmark") {
            initWith(getByName("release"))
            isDebuggable = false
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += listOf("release")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }

    androidResources {
        noCompress += listOf("mp4", "json")
    }

    sourceSets.getByName("debug").assets.directories.addAll(
        listOf("../testdata", "../.generated/testdata"),
    )
    sourceSets.getByName("benchmark").assets.directories.addAll(
        listOf("../testdata", "../.generated/testdata"),
    )
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.06.00")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material3.adaptive:adaptive:1.2.0")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    add("benchmarkImplementation", "androidx.metrics:metrics-performance:1.0.0")

    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:core:1.7.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
