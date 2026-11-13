plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.batman.batman_app"
    compileSdk = 37  // reactive_ble_mobile 5.6.0 compiles against 37 (its AAR metadata); targetSdk is the literal 36 below (D6)
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
        // 254-app-update D6: a literal, not flutter.targetSdkVersion — at 37 (Android 17) local network protection needs
        // ACCESS_LOCAL_NETWORK for the update's raw-socket PUT to the node (F24); raising this line is a decision of its
        // own (design §12-6), caught in code review, never a side effect of `flutter upgrade`.
        targetSdk = 36
        // T9 / T12 (instrumented, on the phone; written, run by hand): src/androidTest
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
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
        // 254-app-member-join §9: a second dev install on the same phone (the remote member's app in bench tests):
        // its own applicationId -> its own Keystore aliases and records
        create("dev2") {
            dimension = "trust"
            applicationIdSuffix = ".dev2"
            resValue("string", "app_name", "Batman dev2")
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
    // v0.4.3 BleRx: RxJavaPlugins + BleException — the versions reactive_ble_mobile 5.6.0 already brings (its
    // build.gradle: rxandroidble 1.16.0 -> rxjava 2.2.17); declared here because the plugin's are `implementation`
    implementation("com.polidea.rxandroidble2:rxandroidble:1.16.0")
    implementation("io.reactivex.rxjava2:rxjava:2.2.17")
    testImplementation("junit:junit:4.13.2")
    // 254-app-update T9 / T12 only (androidTest; not part of any APK)
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:core:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}

flutter {
    source = "../.."
}
