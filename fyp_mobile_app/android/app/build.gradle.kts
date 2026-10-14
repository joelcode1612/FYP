plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.fyp"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.fyp"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// AGP 8+ requires every Android library to have a unique namespace, but the
// Sceneform 1.17.1 artifacts pulled in by ar_flutter_plugin declare the same
// manifest package (`com.google.ar.sceneform`) in both `core` and
// `sceneform-base`, which fails manifest merging. `sceneform-base` ships no
// resources/components of its own, so we swap it for a byte-identical copy
// whose manifest package is `com.google.ar.sceneform.base`
// (see android/libs/). No app or plugin code is affected — the Java/Kotlin
// classes are unchanged.
configurations.all {
    exclude(group = "com.google.ar.sceneform", module = "sceneform-base")
}

dependencies {
    implementation(files("../libs/sceneform-base-1.17.1-nsfix.aar"))
}

flutter {
    source = "../.."
}
