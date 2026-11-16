plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The Go core lives in ../../core (relative to this file).
val singlinkCoreDir = rootProject.file("../core/build/android")
val singlinkAbis = listOf("arm64-v8a", "armeabi-v7a", "x86_64")

// Builds the core when any ABI is missing or does not match the pinned
// protocol and current core source (needs Go and the Android NDK; see
// core/Makefile). `make android` re-verifies the pin and fails closed.
// The check runs lazily at execution time; its output is captured, so a
// first build does not print a misleading provenance error.
val singlinkProvenanceCheck = providers.exec {
    workingDir = rootProject.file("..")
    commandLine(
        listOf("python3", "scripts/protocol_provenance.py", "check-artifact") +
            singlinkAbis.map { File(singlinkCoreDir, "$it/libsinglink.so").absolutePath },
    )
    isIgnoreExitValue = true
}
val buildSinglinkCore by tasks.registering(Exec::class) {
    description = "Builds libsinglink.so for every Android ABI"
    workingDir = rootProject.file("../core")
    commandLine("make", "android")
    onlyIf { singlinkProvenanceCheck.result.get().exitValue != 0 }
}
tasks.named("preBuild") { dependsOn(buildSinglinkCore) }

android {
    namespace = "com.singlinklabs.singlinkvpn"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.singlinklabs.singlinkvpn"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    // libsinglink.so (Go core with the TUN bridge) for every ABI, built by
    // `make -C core android` into core/build/android/<abi>/.
    sourceSets {
        getByName("main") {
            jniLibs.srcDir(singlinkCoreDir)
        }
    }

    val releaseStore = providers.environmentVariable("SINGLINK_RELEASE_STORE_FILE").orNull
    val releasePassword = providers.environmentVariable("SINGLINK_RELEASE_STORE_PASSWORD").orNull
    val releaseAlias = providers.environmentVariable("SINGLINK_RELEASE_KEY_ALIAS").orNull
    val releaseKeyPassword = providers.environmentVariable("SINGLINK_RELEASE_KEY_PASSWORD").orNull
    val releaseConfigured = !releaseStore.isNullOrBlank() && !releasePassword.isNullOrBlank() &&
        !releaseAlias.isNullOrBlank() && !releaseKeyPassword.isNullOrBlank() &&
        file(releaseStore).isFile && file(releaseStore).name != "debug.keystore" &&
        file(releaseStore).parentFile?.name != ".android"
    signingConfigs {
        create("protectedRelease") {
            if (releaseConfigured) {
                storeFile = file(releaseStore!!); storePassword = releasePassword
                keyAlias = releaseAlias; keyPassword = releaseKeyPassword
            }
        }
    }
    buildTypes { release { signingConfig = signingConfigs.getByName("protectedRelease") } }
    gradle.taskGraph.whenReady {
        val releaseRequested = allTasks.any { it.project == project && it.name.contains("Release") }
        if (releaseRequested && !releaseConfigured) {
            throw GradleException("Release signing is missing. Configure external protected signing inputs; debug fallback is disabled.")
        }
    }

}

flutter {
    source = "../.."
}

// Test-only dependencies, pinned to verified stable Google Maven releases.
dependencies {
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
}
