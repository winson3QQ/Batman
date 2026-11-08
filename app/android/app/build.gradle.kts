plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.batman.batman_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "30.0.16248370"  // the installed NDK, fixed (design §2: NDK version pinned)

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
        resValues = true
    }

    defaultConfig {
        applicationId = "dev.batman.app"
        minSdk = 31  // Android 12+ (design §1): PURPOSE_AGREE_KEY, KeyInfo.securityLevel
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk { abiFilters += listOf("arm64-v8a") }  // design §2: arm64-v8a only
    }

    // design v8.5.1 §4.1: dev / field are build constants. Each flavor has its own applicationId (own Keystore aliases,
    // records, launcher name; one cannot be installed over the other) and its own DEV_TRUST, which must equal the Rust
    // library's (startup cross-check; the Rust side is the Cargo feature `dev-trust`).
    flavorDimensions += "trust"
    productFlavors {
        create("dev") {
            dimension = "trust"
            applicationIdSuffix = ".dev"
            resValue("string", "app_name", "Batman dev")
            buildConfigField("boolean", "DEV_TRUST", "true")
        }
        create("field") {
            dimension = "trust"
            resValue("string", "app_name", "Batman")
            buildConfigField("boolean", "DEV_TRUST", "false")
        }
    }

    buildTypes {
        release {
            // TODO: release signing (not before the field build exists, #255)
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

flutter {
    source = "../.."
}
