plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The Go core lives in ../../core (relative to this file).
val singlinkCoreDir = rootProject.file("../core/build/android")
val singlinkAbis = listOf("arm64-v8a", "armeabi-v7a", "x86_64")

// Builds the core when any ABI is missing (needs Go and the Android NDK; see
// core/Makefile). Delete core/build/android to force a rebuild.
val buildSinglinkCore by tasks.registering(Exec::class) {
    description = "Builds libsinglink.so for every Android ABI"
    workingDir = rootProject.file("../core")
    commandLine("make", "android")
    onlyIf { singlinkAbis.any { !File(singlinkCoreDir, "$it/libsinglink.so").exists() } }
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
    }

    // libsinglink.so (Go core with the TUN bridge) for every ABI, built by
    // `make -C core android` into core/build/android/<abi>/.
    sourceSets {
        getByName("main") {
            jniLibs.srcDir(singlinkCoreDir)
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
